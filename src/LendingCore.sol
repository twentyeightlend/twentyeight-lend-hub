// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {MarketParams, Market, Position, Id, MarketParamsLib} from "./libraries/Types.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {IVeAdapter} from "./interfaces/IVeAdapter.sol";
import {ICreditLineManager} from "./interfaces/ICreditLineManager.sol";
import {IIrm} from "./interfaces/IIrm.sol";

/// @title LendingCore
/// @notice Immutable singleton hosting isolated veNFT-collateralised lending markets.
/// @dev Morpho Blue ethos: no upgradeability, no admin pause, permissionless market
///      creation. Each market is keyed by the hash of its MarketParams so a NEST blow-up
///      can never touch KITTEN lenders. Collateral is a single veNFT per position,
///      custodied by the market's IVeAdapter (the only contract that knows the
///      protocol-specific Voter/bribe wiring).
contract LendingCore is IERC721Receiver, ReentrancyGuard {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_FEE = 0.25e18; // 25% of interest, hard ceiling
    /// @dev Per-second borrow-rate ceiling (~3150%/yr linear). Clamps a malicious/buggy IRM so it
    ///      can't overflow interest (which would brick _accrue → repay/withdraw) or extract value.
    uint256 internal constant MAX_RATE_PER_SECOND = 1e12;
    /// @dev How long a cached credit line stays valid. The fee inputs are closed-epoch (stable
    ///      for the week), so the only intra-TTL drift is the oracle price leg — kept short to
    ///      bound it while still letting borrow() avoid the gas-heavy inline recompute.
    uint256 internal constant CREDIT_TTL = 15 minutes;
    /// @dev A loan can't be opened against an expiring (non-permanent) lock inside this window.
    uint256 internal constant MIN_LOAN_MATURITY = 7 days;

    /// @notice Treasury fee recipient. The ONLY governance surface besides per-market fee.
    address public feeRecipient;
    address public owner;
    address public pendingOwner;

    mapping(Id => Market) public market;
    /// @dev positions[id][veTokenId].
    mapping(Id => mapping(uint256 => Position)) public position;
    /// @dev lender supply shares: supplyShares[id][account].
    mapping(Id => mapping(address => uint256)) public supplyShares;
    /// @dev write-once credit-line manager per market (set at createMarket).
    mapping(Id => address) public creditManager;
    /// @dev write-once self-repay engine per market (address(0) => self-repay disabled).
    mapping(Id => address) public selfRepayEngine;
    /// @dev write-once vote keeper per market; may re-vote idle positions so they keep earning
    ///      (mitigates the non-liquidating freeze if a borrower goes dark). address(0) => none.
    mapping(Id => address) public voteKeeper;
    /// @dev marketParams kept on-chain for adapters/keepers to reconstruct.
    mapping(Id => MarketParams) internal _idToParams;

    event CreateMarket(Id indexed id, MarketParams params, address creditManager, address engine);
    event Harvest(Id indexed id, uint256 indexed tokenId, address engine);
    event Vote(Id indexed id, uint256 indexed tokenId, address caller);
    event Supply(Id indexed id, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(Id indexed id, address indexed onBehalf, address receiver, uint256 assets, uint256 shares);
    event SupplyCollateral(Id indexed id, uint256 indexed tokenId, address indexed onBehalf);
    event WithdrawCollateral(Id indexed id, uint256 indexed tokenId, address receiver);
    event Borrow(Id indexed id, uint256 indexed tokenId, address receiver, uint256 assets, uint256 shares);
    event Repay(Id indexed id, uint256 indexed tokenId, address indexed onBehalf, uint256 assets, uint256 shares);
    event AccrueInterest(Id indexed id, uint256 interest, uint256 feeShares);
    event SetFeeRecipient(address recipient);
    event SetFee(Id indexed id, uint256 fee);

    error NotOwner();
    error MarketExists();
    error MarketNotCreated();
    error ZeroAddress();
    error InconsistentInput();
    error NotPositionOwner();
    error PositionNotEmpty();
    error CreditLineExceeded();
    error InsufficientLiquidity();
    error MaxFeeExceeded();
    error NotEngine();
    error SelfRepayDisabled();
    error LockTooCloseToExpiry();
    error NotAuthorizedToVote();
    error AdapterPaused();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _feeRecipient) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        feeRecipient = _feeRecipient;
    }

    // ---------------------------------------------------------------------
    // Market lifecycle
    // ---------------------------------------------------------------------

    /// @param _engine     Self-repay engine for this market (address(0) disables self-repay).
    /// @param _voteKeeper Optional keeper allowed to re-vote idle positions (address(0) = none).
    /// @dev WARNING to lenders: creditManager, engine, voteKeeper, and the MarketParams
    ///      (veAdapter/oracle/irm) are trust-critical and immutable per market. A market with
    ///      a malicious manager/adapter can mis-price collateral. Vet these before supplying.
    function createMarket(
        MarketParams memory params,
        address _creditManager,
        address _engine,
        address _voteKeeper
    ) external {
        if (params.loanToken == address(0) || params.veAdapter == address(0)) revert ZeroAddress();
        if (_creditManager == address(0)) revert ZeroAddress();
        Id id = params.id();
        if (market[id].lastUpdate != 0) revert MarketExists();
        // sanity: adapter must expose a non-zero underlying & escrow.
        if (IVeAdapter(params.veAdapter).underlyingToken() == address(0)) revert ZeroAddress();

        market[id].lastUpdate = uint128(block.timestamp);
        creditManager[id] = _creditManager;
        selfRepayEngine[id] = _engine; // may be address(0) to disable self-repay
        voteKeeper[id] = _voteKeeper;
        _idToParams[id] = params;
        emit CreateMarket(id, params, _creditManager, _engine);
    }

    function idToParams(Id id) external view returns (MarketParams memory) {
        return _idToParams[id];
    }

    // ---------------------------------------------------------------------
    // Lender side
    // ---------------------------------------------------------------------

    function supply(MarketParams memory params, uint256 assets, address onBehalf)
        external
        nonReentrant
        returns (uint256 shares)
    {
        Id id = params.id();
        _accrue(id, params);
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (assets == 0) revert InconsistentInput();
        if (onBehalf == address(0)) revert ZeroAddress();
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused();

        shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        supplyShares[id][onBehalf] += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        SafeTransferLib.safeTransferFrom(params.loanToken, msg.sender, address(this), assets);
        emit Supply(id, onBehalf, assets, shares);
    }

    function withdraw(MarketParams memory params, uint256 assets, address onBehalf, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        Id id = params.id();
        _accrue(id, params);
        if (assets == 0) revert InconsistentInput();
        if (receiver == address(0)) revert ZeroAddress();

        shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        if (msg.sender != onBehalf) revert NotPositionOwner();

        supplyShares[id][onBehalf] -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        if (_liquidity(id) < 0) revert InsufficientLiquidity();
        SafeTransferLib.safeTransfer(params.loanToken, receiver, assets);
        emit Withdraw(id, onBehalf, receiver, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Collateral (veNFT) side
    // ---------------------------------------------------------------------

    /// @notice Custody a veNFT as collateral. Caller must own & approve it to the adapter.
    function supplyCollateral(MarketParams memory params, uint256 tokenId, address onBehalf)
        external
        nonReentrant
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (onBehalf == address(0)) revert ZeroAddress();
        if (position[id][tokenId].borrower != address(0)) revert PositionNotEmpty();
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused();

        position[id][tokenId].borrower = onBehalf;
        IVeAdapter(params.veAdapter).custody(tokenId, msg.sender);
        emit SupplyCollateral(id, tokenId, onBehalf);
    }

    function withdrawCollateral(MarketParams memory params, uint256 tokenId, address receiver)
        external
        nonReentrant
    {
        Id id = params.id();
        _accrue(id, params);
        Position storage pos = position[id][tokenId];
        if (pos.borrower != msg.sender) revert NotPositionOwner();
        if (pos.borrowShares != 0) revert PositionNotEmpty();
        if (receiver == address(0)) revert ZeroAddress();

        delete position[id][tokenId];
        IVeAdapter(params.veAdapter).recoverUnderlying(tokenId, receiver);
        emit WithdrawCollateral(id, tokenId, receiver);
    }

    // ---------------------------------------------------------------------
    // Borrow / repay
    // ---------------------------------------------------------------------

    function borrow(MarketParams memory params, uint256 tokenId, uint256 assets, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        Id id = params.id();
        _accrue(id, params);
        Position storage pos = position[id][tokenId];
        if (pos.borrower != msg.sender) revert NotPositionOwner();
        if (assets == 0) revert InconsistentInput();
        if (receiver == address(0)) revert ZeroAddress();
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused();

        // Reject drawing fresh debt against a non-permanent lock about to expire (fees would
        // soon stop). Permanent locks (e.g. veNEST) are exempt.
        if (
            !IVeAdapter(params.veAdapter).isPermanentLock(tokenId)
                && IVeAdapter(params.veAdapter).lockEnd(tokenId) < block.timestamp + MIN_LOAN_MATURITY
        ) revert LockTooCloseToExpiry();

        shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        pos.borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        uint256 owed = uint256(pos.borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );
        // Use the cached credit line when fresh; otherwise recompute (gas-heavy for NEST) and
        // cache. A keeper/borrower can pre-warm via {refreshCreditLine} to keep borrow cheap.
        uint256 line = _creditLine(id, params, pos, tokenId);
        if (owed > line) revert CreditLineExceeded();
        if (_liquidity(id) < 0) revert InsufficientLiquidity();

        SafeTransferLib.safeTransfer(params.loanToken, receiver, assets);
        emit Borrow(id, tokenId, receiver, assets, shares);
    }

    /// @notice Pre-compute and cache a position's credit line. Lets borrowers/keepers pay the
    ///         (potentially heavy) manager read in its own tx so {borrow} stays gas-bounded.
    function refreshCreditLine(MarketParams memory params, uint256 tokenId)
        external
        returns (uint256 line)
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused(); // no warming a compromised market
        line = ICreditLineManager(creditManager[id]).creditLine(params, tokenId);
        Position storage pos = position[id][tokenId];
        pos.creditLine = line.toUint128();
        pos.creditLineExpiry = uint64(block.timestamp + CREDIT_TTL);
    }

    function _creditLine(Id id, MarketParams memory params, Position storage pos, uint256 tokenId)
        internal
        returns (uint256 line)
    {
        if (pos.creditLineExpiry >= block.timestamp && pos.creditLine != 0) {
            return pos.creditLine; // fresh cache
        }
        line = ICreditLineManager(creditManager[id]).creditLine(params, tokenId);
        pos.creditLine = line.toUint128();
        pos.creditLineExpiry = uint64(block.timestamp + CREDIT_TTL);
    }

    /// @notice Repay `assets` of debt on `tokenId`. Anyone may repay (used by SelfRepayEngine).
    function repay(MarketParams memory params, uint256 tokenId, uint256 assets)
        external
        nonReentrant
        returns (uint256 shares)
    {
        Id id = params.id();
        _accrue(id, params);
        Position storage pos = position[id][tokenId];
        if (pos.borrower == address(0)) revert MarketNotCreated();
        if (assets == 0) revert InconsistentInput();

        shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        if (shares > pos.borrowShares) {
            shares = pos.borrowShares;
            assets = uint256(shares).toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        }
        pos.borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets -= assets.toUint128();

        SafeTransferLib.safeTransferFrom(params.loanToken, msg.sender, address(this), assets);
        emit Repay(id, tokenId, pos.borrower, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Governance (keep the collateral voting so it keeps earning fees)
    // ---------------------------------------------------------------------

    /// @notice Re-cast a custodied veNFT's votes. Only the position's borrower may steer it
    ///         (they own the position). A veNFT that stops voting stops earning fees, which
    ///         would starve self-repay — so this must stay callable while a loan is open.
    function vote(MarketParams memory params, uint256 tokenId, bytes calldata voteData)
        external
        nonReentrant
    {
        Id id = params.id();
        // The borrower steers their own votes; the market's keeper may also re-vote so an idle
        // position keeps earning fees (so lender capital can't be frozen by a dark borrower).
        if (msg.sender != position[id][tokenId].borrower && msg.sender != voteKeeper[id]) {
            revert NotAuthorizedToVote();
        }
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused();
        IVeAdapter(params.veAdapter).vote(tokenId, voteData);
        emit Vote(id, tokenId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Self-repay harvest
    // ---------------------------------------------------------------------

    /// @notice Route a position's harvested rewards to the market's bound self-repay engine.
    /// @dev Callable ONLY by that engine, so rewards can never be redirected to an arbitrary
    ///      recipient. The engine swaps to loanToken and calls {repay} in a SEPARATE top-level
    ///      call (sequential, not nested), so this being nonReentrant does not deadlock the flow
    ///      while still blocking reward-token transfer-hook reentrancy during adapter.harvest.
    function harvestFor(MarketParams memory params, uint256 tokenId)
        external
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        Id id = params.id();
        address engine = selfRepayEngine[id];
        if (engine == address(0)) revert SelfRepayDisabled();
        if (msg.sender != engine) revert NotEngine();
        if (IVeAdapter(params.veAdapter).paused()) revert AdapterPaused();
        (tokens, amounts) = IVeAdapter(params.veAdapter).harvest(tokenId, engine);
        emit Harvest(id, tokenId, engine);
    }

    // ---------------------------------------------------------------------
    // Interest accrual
    // ---------------------------------------------------------------------

    function accrueInterest(MarketParams memory params) external {
        _accrue(params.id(), params);
    }

    /// @dev Linear accrual (under-charges vs continuous compounding — conservative for borrowers).
    function _accrue(Id id, MarketParams memory params) internal {
        Market storage m = market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;
        m.lastUpdate = uint128(block.timestamp);
        if (params.irm == address(0) || m.totalBorrowAssets == 0) return;

        uint256 rate = IIrm(params.irm).borrowRate(params, m); // per-second WAD
        if (rate > MAX_RATE_PER_SECOND) rate = MAX_RATE_PER_SECOND; // clamp untrusted IRM
        uint256 interest = (uint256(m.totalBorrowAssets) * rate * elapsed) / WAD;
        if (interest == 0) return;
        m.totalBorrowAssets += interest.toUint128();
        m.totalSupplyAssets += interest.toUint128();

        uint256 feeShares;
        if (m.fee != 0 && feeRecipient != address(0)) {
            uint256 feeAssets = (interest * m.fee) / WAD;
            // fee shares dilute lenders by minting against post-interest supply net of fee.
            feeShares = feeAssets.toSharesDown(
                m.totalSupplyAssets - feeAssets, m.totalSupplyShares
            );
            supplyShares[id][feeRecipient] += feeShares;
            m.totalSupplyShares += feeShares.toUint128();
        }
        emit AccrueInterest(id, interest, feeShares);
    }

    // ---------------------------------------------------------------------
    // Views / admin
    // ---------------------------------------------------------------------

    /// @dev Idle loanToken accounting: supply - borrow. int to surface over-withdraw.
    function _liquidity(Id id) internal view returns (int256) {
        return int256(uint256(market[id].totalSupplyAssets)) - int256(uint256(market[id].totalBorrowAssets));
    }

    function setFeeRecipient(address r) external onlyOwner {
        feeRecipient = r;
        emit SetFeeRecipient(r);
    }

    function setFee(MarketParams memory params, uint256 fee) external onlyOwner {
        if (fee > MAX_FEE) revert MaxFeeExceeded();
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        _accrue(id, params);
        market[id].fee = uint128(fee);
        emit SetFee(id, fee);
    }

    /// @notice 2-step ownership: the new owner must {acceptOwnership}, so a typo can't brick governance.
    function transferOwnership(address n) external onlyOwner {
        pendingOwner = n;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
