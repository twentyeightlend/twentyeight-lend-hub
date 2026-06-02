// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {MarketParams, Market} from "./libraries/Types.sol";

interface IWveNestWrapper {
    function claim() external; // claims this contract's accrued wveNEST voting rewards to it
}

/// @title WrappedCollateralMarket
/// @notice Isolated money market: borrow `loanToken` (USDC) against an ERC20 collateral
///         (wveNEST). This is the "lend against the moat" leg — wveNEST is the liquid wrapper
///         of permanently-locked veNEST, priced by HaircutOracle (NEST TWAP × DLOM). Morpho-Blue
///         style: immutable params, virtual-shares accounting, LTV health + liquidation with a
///         fixed bonus and bad-debt socialisation.
contract WrappedCollateralMarket is ReentrancyGuard {
    using SharesMathLib for uint256;
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant MAX_FEE = 0.25e18;
    /// @dev Per-second borrow-rate ceiling (~3150%/yr linear); clamps an untrusted IRM.
    uint256 internal constant MAX_RATE_PER_SECOND = 1e12;

    address public immutable loanToken;
    address public immutable collateralToken;
    IOracle public immutable oracle;
    address public immutable irm; // address(0) => 0% interest
    uint256 public immutable lltv; // WAD; borrow/liquidation threshold
    uint256 public immutable liquidationBonus; // WAD, e.g. 1.08e18 = 8% bonus

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    /// @notice Owner-set fallback price (1e36) used ONLY when the primary oracle reverts, so
    ///         unhealthy positions can still be liquidated during an oracle outage. 0 = disabled.
    ///         Trust note: should be governed by a multisig+timelock; it can only enable
    ///         liquidation (never borrow), bounding abuse.
    uint256 public emergencyPrice;
    /// @notice Max total supplied assets during a guarded rollout (0 = uncapped). Owner can raise
    ///         it as confidence grows; never blocks withdraw/repay/liquidate.
    uint256 public supplyCap;
    /// @notice When true (set by owner on a NEST/KITTEN proxy-upgrade emergency), blocks new risk
    ///         (supply/collateral/borrow) but still allows repay/withdraw/liquidate so users exit.
    bool public paused;

    struct Position {
        uint128 collateral;
        uint128 borrowShares;
    }

    // aggregate market state (reuses the Types.Market shape: supplyAssets/shares, borrowAssets/shares, lastUpdate, fee)
    uint128 public totalSupplyAssets;
    uint128 public totalSupplyShares;
    uint128 public totalBorrowAssets;
    uint128 public totalBorrowShares;
    uint128 public lastUpdate;
    uint128 public fee;

    mapping(address => uint256) public supplyShares;
    mapping(address => Position) public position;

    // --- collateral voting-yield forwarding: the market holds all wveNEST collateral and is the
    //     wrapper's reward-holder, so it claims those rewards and redistributes to borrowers
    //     pro-rata to their collateral (Synthetix reward-per-collateral). loanToken is forbidden as
    //     a reward token (its balance is comingled with lender liquidity).
    uint256 public totalCollateral;
    address[] public collatRewardTokens;
    mapping(address => bool) public isCollatReward;
    mapping(address => uint256) public rewardPerCollatStored; // 1e18-scaled per collateral unit
    mapping(address => mapping(address => uint256)) public collatRewardPaid;
    mapping(address => mapping(address => uint256)) public collatRewardAccrued;

    event Supply(address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(address indexed onBehalf, address receiver, uint256 assets, uint256 shares);
    event SupplyCollateral(address indexed onBehalf, uint256 amount);
    event WithdrawCollateral(address indexed onBehalf, address receiver, uint256 amount);
    event Borrow(address indexed borrower, address receiver, uint256 assets, uint256 shares);
    event Repay(address indexed onBehalf, uint256 assets, uint256 shares);
    event Liquidate(address indexed borrower, address indexed liquidator, uint256 repaid, uint256 seized, uint256 badDebt);
    event AccrueInterest(uint256 interest, uint256 feeShares);

    error NotOwner();
    error ZeroInput();
    error ZeroAddress();
    error InsufficientLiquidity();
    error Unhealthy();
    error MarketHealthy();
    error MaxFeeExceeded();
    error MarketPaused();
    error OracleUnavailable();
    error SupplyCapExceeded();
    error BadRewardToken();

    event Paused();
    event Unpaused();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _loanToken,
        address _collateralToken,
        address _oracle,
        address _irm,
        uint256 _lltv,
        uint256 _liquidationBonus,
        address _owner,
        address _feeRecipient
    ) {
        if (_loanToken == address(0) || _collateralToken == address(0) || _oracle == address(0)) revert ZeroAddress();
        if (_lltv >= WAD || _liquidationBonus < WAD || _liquidationBonus > 1.5e18) revert ZeroInput();
        loanToken = _loanToken;
        collateralToken = _collateralToken;
        oracle = IOracle(_oracle);
        irm = _irm;
        lltv = _lltv;
        liquidationBonus = _liquidationBonus;
        owner = _owner;
        feeRecipient = _feeRecipient;
        lastUpdate = uint128(block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Lender side
    // ---------------------------------------------------------------------

    function supply(uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
        _accrue();
        if (paused) revert MarketPaused();
        if (assets == 0) revert ZeroInput();
        if (onBehalf == address(0)) revert ZeroAddress();
        if (supplyCap != 0 && uint256(totalSupplyAssets) + assets > supplyCap) revert SupplyCapExceeded();
        shares = assets.toSharesDown(totalSupplyAssets, totalSupplyShares);
        supplyShares[onBehalf] += shares;
        totalSupplyShares += shares.toUint128();
        totalSupplyAssets += assets.toUint128();
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), assets);
        emit Supply(onBehalf, assets, shares);
    }

    function withdraw(uint256 assets, address onBehalf, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _accrue();
        if (assets == 0) revert ZeroInput();
        if (receiver == address(0)) revert ZeroAddress();
        if (msg.sender != onBehalf) revert NotOwner();
        shares = assets.toSharesUp(totalSupplyAssets, totalSupplyShares);
        supplyShares[onBehalf] -= shares;
        totalSupplyShares -= shares.toUint128();
        totalSupplyAssets -= assets.toUint128();
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        SafeTransferLib.safeTransfer(loanToken, receiver, assets);
        emit Withdraw(onBehalf, receiver, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Collateral / borrow
    // ---------------------------------------------------------------------

    function supplyCollateral(uint256 amount, address onBehalf) external nonReentrant {
        if (paused) revert MarketPaused();
        if (amount == 0) revert ZeroInput();
        if (onBehalf == address(0)) revert ZeroAddress();
        _updateCollatRewards(onBehalf); // checkpoint before the collateral stake changes
        position[onBehalf].collateral += amount.toUint128();
        totalCollateral += amount;
        SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        emit SupplyCollateral(onBehalf, amount);
    }

    function withdrawCollateral(uint256 amount, address receiver) external nonReentrant {
        _accrue();
        if (amount == 0) revert ZeroInput();
        if (receiver == address(0)) revert ZeroAddress();
        _updateCollatRewards(msg.sender);
        position[msg.sender].collateral -= amount.toUint128();
        totalCollateral -= amount;
        // Only read the oracle when there is debt to check — a debt-free borrower must be able to
        // recover collateral even if the oracle is down (exit path stays oracle-independent).
        if (position[msg.sender].borrowShares != 0) {
            if (!_isHealthy(msg.sender, oracle.price())) revert Unhealthy();
        }
        SafeTransferLib.safeTransfer(collateralToken, receiver, amount);
        emit WithdrawCollateral(msg.sender, receiver, amount);
    }

    function borrow(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        _accrue();
        if (paused) revert MarketPaused();
        if (assets == 0) revert ZeroInput();
        if (receiver == address(0)) revert ZeroAddress();
        shares = assets.toSharesUp(totalBorrowAssets, totalBorrowShares);
        position[msg.sender].borrowShares += shares.toUint128();
        totalBorrowShares += shares.toUint128();
        totalBorrowAssets += assets.toUint128();
        if (!_isHealthy(msg.sender, oracle.price())) revert Unhealthy();
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        SafeTransferLib.safeTransfer(loanToken, receiver, assets);
        emit Borrow(msg.sender, receiver, assets, shares);
    }

    function repay(uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
        _accrue();
        if (assets == 0) revert ZeroInput();
        Position storage pos = position[onBehalf];
        shares = assets.toSharesDown(totalBorrowAssets, totalBorrowShares);
        if (shares > pos.borrowShares) {
            shares = pos.borrowShares;
            assets = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
        }
        pos.borrowShares -= shares.toUint128();
        totalBorrowShares -= shares.toUint128();
        totalBorrowAssets -= assets.toUint128();
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), assets);
        emit Repay(onBehalf, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------

    /// @notice Seize up to `seizeRequested` collateral from an unhealthy `borrower`, repaying the
    ///         corresponding debt (minus the liquidation bonus the liquidator keeps). Remaining
    ///         debt with no collateral left is socialised to lenders (bad debt).
    function liquidate(address borrower, uint256 seizeRequested)
        external
        nonReentrant
        returns (uint256 seized, uint256 repaid)
    {
        _accrue();
        uint256 p = _liquidationPrice(); // falls back to emergencyPrice if the oracle is down
        if (_isHealthy(borrower, p)) revert MarketHealthy();
        Position storage pos = position[borrower];

        seized = seizeRequested > pos.collateral ? pos.collateral : seizeRequested;
        // loan value of seized collateral, then liquidator pays that / bonus (keeps the bonus).
        repaid = SharesMathLib.mulDivDown(seized, p, ORACLE_SCALE);
        repaid = SharesMathLib.mulDivDown(repaid, WAD, liquidationBonus);

        uint256 debt = uint256(pos.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        if (repaid > debt) {
            repaid = debt;
            // recompute the collateral to seize for exactly this repayment (incl. bonus).
            // Round DOWN so a cap can never let the liquidator over-seize (favors the borrower).
            uint256 value = SharesMathLib.mulDivDown(repaid, liquidationBonus, WAD);
            seized = SharesMathLib.mulDivDown(value, ORACLE_SCALE, p);
            if (seized > pos.collateral) seized = pos.collateral;
        }

        // Reject dust liquidations that seize collateral while repaying ~nothing (rounding to 0).
        if (repaid == 0) revert ZeroInput();
        // Round shares burned UP (capped) so a liquidation never burns fewer shares than the
        // assets removed — keeps the borrow share price from drifting against lenders.
        uint256 repaidShares = repaid.toSharesUp(totalBorrowAssets, totalBorrowShares);
        if (repaidShares > pos.borrowShares) repaidShares = pos.borrowShares;
        pos.borrowShares -= repaidShares.toUint128();
        totalBorrowShares -= repaidShares.toUint128();
        totalBorrowAssets -= repaid.toUint128();
        _updateCollatRewards(borrower); // settle the borrower's collateral rewards before seizing
        pos.collateral -= seized.toUint128();
        totalCollateral -= seized;

        uint256 badDebt;
        if (pos.collateral == 0 && pos.borrowShares > 0) {
            uint256 badShares = pos.borrowShares;
            badDebt = uint256(badShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
            totalBorrowShares -= badShares.toUint128();
            totalBorrowAssets -= badDebt.toUint128();
            pos.borrowShares = 0;
            // Defensive clamp: supply >= borrow is invariant, so badDebt <= supply, but never
            // underflow totalSupplyAssets even if that invariant were ever broken.
            uint256 loss = badDebt > totalSupplyAssets ? totalSupplyAssets : badDebt;
            totalSupplyAssets -= loss.toUint128(); // lenders absorb the loss
        }

        SafeTransferLib.safeTransfer(collateralToken, msg.sender, seized);
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), repaid);
        emit Liquidate(borrower, msg.sender, repaid, seized, badDebt);
    }

    // ---------------------------------------------------------------------
    // Interest + health
    // ---------------------------------------------------------------------

    function accrueInterest() external {
        _accrue();
    }

    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return;
        lastUpdate = uint128(block.timestamp);
        if (irm == address(0) || totalBorrowAssets == 0) return;

        uint256 rate = IIrm(irm).borrowRate(_params(), _marketStruct());
        if (rate > MAX_RATE_PER_SECOND) rate = MAX_RATE_PER_SECOND; // clamp untrusted IRM
        uint256 interest = (uint256(totalBorrowAssets) * rate * elapsed) / WAD;
        if (interest == 0) return;
        totalBorrowAssets += interest.toUint128();
        totalSupplyAssets += interest.toUint128();

        uint256 feeShares;
        if (fee != 0 && feeRecipient != address(0)) {
            uint256 feeAssets = (interest * fee) / WAD;
            feeShares = feeAssets.toSharesDown(totalSupplyAssets - feeAssets, totalSupplyShares);
            supplyShares[feeRecipient] += feeShares;
            totalSupplyShares += feeShares.toUint128();
        }
        emit AccrueInterest(interest, feeShares);
    }

    /// @dev Liquidation-only price: primary oracle, falling back to the owner-set emergencyPrice
    ///      if (and only if) the oracle reverts. Lets unhealthy positions be cleared during an
    ///      oracle outage; reverts if no fallback configured.
    function _liquidationPrice() internal view returns (uint256) {
        try oracle.price() returns (uint256 p) {
            return p;
        } catch {
            uint256 ep = emergencyPrice;
            if (ep == 0) revert OracleUnavailable();
            return ep;
        }
    }

    // ---------------------------------------------------------------------
    // Collateral voting-yield forwarding to borrowers
    // ---------------------------------------------------------------------

    /// @notice Pull this market's accrued wveNEST voting rewards and distribute them pro-rata to
    ///         borrowers by collateral. Permissionless (keeper-poked).
    function harvestCollateralRewards() external nonReentrant {
        uint256 n = collatRewardTokens.length;
        if (n == 0 || totalCollateral == 0) return;
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = SafeTransferLib.balanceOf(collatRewardTokens[i], address(this));
        }
        IWveNestWrapper(collateralToken).claim(); // claims the market's accrued wrapper rewards
        for (uint256 i; i < n; ++i) {
            address t = collatRewardTokens[i];
            uint256 cur = SafeTransferLib.balanceOf(t, address(this));
            uint256 gained = cur > before[i] ? cur - before[i] : 0;
            if (gained != 0) rewardPerCollatStored[t] += (gained * WAD) / totalCollateral;
        }
    }

    /// @notice Claim a borrower's accrued share of the collateral voting rewards.
    function claimCollateralRewards() external nonReentrant {
        _updateCollatRewards(msg.sender);
        uint256 n = collatRewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = collatRewardTokens[i];
            uint256 owed = collatRewardAccrued[msg.sender][t];
            if (owed != 0) {
                collatRewardAccrued[msg.sender][t] = 0;
                SafeTransferLib.safeTransfer(t, msg.sender, owed);
            }
        }
    }

    function earnedCollateralReward(address user, address token) external view returns (uint256) {
        uint256 delta = rewardPerCollatStored[token] - collatRewardPaid[user][token];
        return collatRewardAccrued[user][token] + (position[user].collateral * delta) / WAD;
    }

    function _updateCollatRewards(address user) internal {
        uint256 c = position[user].collateral;
        uint256 n = collatRewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = collatRewardTokens[i];
            uint256 rpt = rewardPerCollatStored[t];
            collatRewardAccrued[user][t] += (c * (rpt - collatRewardPaid[user][t])) / WAD;
            collatRewardPaid[user][t] = rpt;
        }
    }

    function _isHealthy(address user, uint256 p) internal view returns (bool) {
        Position storage pos = position[user];
        if (pos.borrowShares == 0) return true;
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = SharesMathLib.mulDivDown(uint256(pos.collateral), p, ORACLE_SCALE);
        uint256 maxBorrow = SharesMathLib.mulDivDown(collateralValue, lltv, WAD);
        return borrowed <= maxBorrow;
    }

    function isHealthy(address user) external view returns (bool) {
        return _isHealthy(user, oracle.price());
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams(loanToken, collateralToken, address(oracle), irm, lltv);
    }

    function _marketStruct() internal view returns (Market memory) {
        return Market(totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert MaxFeeExceeded();
        _accrue();
        fee = uint128(newFee);
    }

    function setFeeRecipient(address r) external onlyOwner {
        feeRecipient = r;
    }

    /// @notice Set the liquidation-only fallback price (1e36) for oracle-outage emergencies.
    function setEmergencyPrice(uint256 p) external onlyOwner {
        emergencyPrice = p;
    }

    /// @notice Set the supply cap for a guarded rollout (0 = uncapped).
    function setSupplyCap(uint256 cap) external onlyOwner {
        supplyCap = cap;
    }

    /// @notice Allowlist a wveNEST voting-reward token to forward to borrowers. loanToken and the
    ///         collateral token are forbidden (their balances are not isolated from pool funds).
    function addCollatRewardToken(address token) external onlyOwner {
        if (token == loanToken || token == collateralToken || token == address(0)) revert BadRewardToken();
        if (!isCollatReward[token]) {
            isCollatReward[token] = true;
            collatRewardTokens.push(token);
        }
    }

    /// @notice 2-step ownership: the new owner must {acceptOwnership} (typo-safe).
    function transferOwnership(address n) external onlyOwner {
        pendingOwner = n;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
