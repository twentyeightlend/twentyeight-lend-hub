// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @dev veNEST surface used by the wrapper.
interface IWrapVe {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanentLocked;
    }

    struct TokenState {
        LockedBalance locked;
        bool isVoted;
        bool isAttached;
        uint256 lastTranferBlock;
        uint256 pointEpoch;
    }

    function getNftState(uint256 tokenId) external view returns (TokenState memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function isTransferable(uint256 tokenId) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function merge(uint256 from, uint256 to) external;
}

interface IWrapVoter {
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;
    function poolVoteLength(uint256 tokenId) external view returns (uint256);
    function poolVote(uint256 tokenId, uint256 index) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
    function gaugesState(address gauge)
        external
        view
        returns (bool, bool, address internalBribe, address externalBribe, address, uint256, uint256, uint256);
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;
}

interface IWrapBribe {
    function rewardsList() external view returns (address[] memory);
}

/// @title ReceiptWrapper (wveNEST)
/// @notice Turns illiquid PERMANENT veNEST into a fungible, liquid ERC20. ~97% of locked NEST
///         is permanently locked with no exit — nobody else serves that segment. Depositors
///         get wveNEST 1:1 with their locked NEST; all deposits are merged into one master
///         veNEST the wrapper votes + harvests. Liquidity comes from the wveNEST secondary
///         market (the wrapper is deposit-only by design, like iAERO).
/// @dev Deposit-only: permanent locks have no native exit, so there is no redeem; holders exit
///      by selling wveNEST. Guardian can pause on a proxy-upgrade emergency.
contract ReceiptWrapper is ERC20, ReentrancyGuard {
    using SafeTransferLib for address;

    IWrapVe public immutable ve;
    IWrapVoter public immutable voter;
    address public immutable underlying; // NEST
    address public immutable guardian;
    address public keeper;
    address public yieldReceiver;

    /// @notice The consolidated master veNEST that holds all deposited locks. 0 until first deposit.
    uint256 public masterId;
    bool public masterSet; // distinct from masterId==0 so a legitimate tokenId 0 works
    uint256 public totalLocked;
    bool public paused;

    // --- pro-rata multi-reward distribution (Synthetix reward-per-token) ---
    /// @notice Guardian-curated allowlist of reward tokens distributed to holders. Kept small
    ///         (majors) so the per-transfer checkpoint loop stays gas-bounded; non-allowlisted
    ///         harvest proceeds go to yieldReceiver.
    address[] public rewardTokens;
    mapping(address => bool) public isReward;
    mapping(address => uint256) public rewardPerTokenStored; // scaled 1e18
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewardsAccrued;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_VOTES = 32;

    event Deposit(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Harvested(address indexed caller, address to);
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event RewardTokenAdded(address token);
    event Paused();
    event Unpaused();
    event KeeperSet(address keeper);
    event YieldReceiverSet(address receiver);

    error OnlyGuardian();
    error OnlyKeeper();
    error PausedError();
    error NotPermanent();
    error NotTransferable();
    error NotOwner();
    error EmptyLock();
    error OnlySelf();
    error SelfTransfer();

    constructor(address _ve, address _voter, address _underlying, address _guardian, address _keeper, address _yieldReceiver) {
        ve = IWrapVe(_ve);
        voter = IWrapVoter(_voter);
        underlying = _underlying;
        guardian = _guardian;
        keeper = _keeper;
        yieldReceiver = _yieldReceiver;
    }

    function name() public pure override returns (string memory) {
        return "Wrapped veNEST";
    }

    function symbol() public pure override returns (string memory) {
        return "wveNEST";
    }

    // --- deposit (mint liquid receipt) ---

    /// @notice Deposit a PERMANENT veNEST and receive wveNEST 1:1 with its locked NEST.
    function deposit(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        if (paused) revert PausedError();
        IWrapVe.TokenState memory s = ve.getNftState(tokenId);
        if (!s.locked.isPermanentLocked) revert NotPermanent();
        if (s.isAttached) revert NotPermanent(); // attached/managed not accepted
        if (!ve.isTransferable(tokenId)) revert NotTransferable();
        if (s.locked.amount <= 0) revert EmptyLock();
        if (ve.ownerOf(tokenId) != msg.sender) revert NotOwner();

        amount = uint256(uint128(s.locked.amount));

        ve.safeTransferFrom(msg.sender, address(this), tokenId);
        ve.approve(address(0), tokenId); // strip approvals on intake

        if (!masterSet) {
            masterId = tokenId; // first deposit becomes the master (tokenId 0 is valid)
            masterSet = true;
        } else {
            ve.merge(tokenId, masterId); // consolidate into the master permanent lock
        }

        totalLocked += amount;
        _mint(msg.sender, amount);
        emit Deposit(msg.sender, tokenId, amount);
    }

    // --- voting / harvest on the master ---

    /// @notice Keeper steers the master's votes to maximise fees for wveNEST holders.
    function vote(address[] calldata pools, uint256[] calldata weights) external {
        if (msg.sender != keeper) revert OnlyKeeper();
        if (paused) revert PausedError();
        voter.vote(masterId, pools, weights);
    }

    /// @notice Permissionless: claim the master's fees+bribes to the yield receiver.
    /// @dev Distribution to holders (reward-per-token or auto-compound) is layered on top of
    ///      the yieldReceiver in a later iteration.
    function harvest() external nonReentrant {
        if (paused) revert PausedError();
        uint256 mId = masterId;
        uint256 nVotes = voter.poolVoteLength(mId);
        if (nVotes > MAX_VOTES) nVotes = MAX_VOTES;

        address[] memory bribes = new address[](nVotes * 2);
        address[][] memory tokens = new address[][](nVotes * 2);
        uint256 k;
        for (uint256 i; i < nVotes; ++i) {
            address gauge = voter.poolToGauge(voter.poolVote(mId, i));
            if (gauge == address(0)) continue;
            (,, address intB, address extB,,,,) = voter.gaugesState(gauge);
            if (intB != address(0)) {
                bribes[k] = intB;
                tokens[k] = IWrapBribe(intB).rewardsList();
                ++k;
            }
            if (extB != address(0)) {
                bribes[k] = extB;
                tokens[k] = IWrapBribe(extB).rewardsList();
                ++k;
            }
        }

        // unique reward token set — size by ACTUAL total token count (NEST bribes expose up to
        // ~14 each), else tokens beyond the buffer are silently dropped and stranded.
        uint256 slots;
        for (uint256 i; i < k; ++i) {
            slots += tokens[i].length;
        }
        address[] memory uniq = new address[](slots);
        uint256 u;
        for (uint256 i; i < k; ++i) {
            for (uint256 j; j < tokens[i].length; ++j) {
                address t = tokens[i][j];
                bool seen;
                for (uint256 x; x < u; ++x) {
                    if (uniq[x] == t) {
                        seen = true;
                        break;
                    }
                }
                if (!seen && u < uniq.length) uniq[u++] = t;
            }
        }

        // trim arrays to k for the external call
        assembly {
            mstore(bribes, k)
            mstore(tokens, k)
        }

        uint256[] memory before = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            before[i] = uniq[i].balanceOf(address(this));
        }
        if (k != 0) voter.claimBribes(bribes, tokens, mId);

        uint256 supply = totalSupply();
        for (uint256 i; i < u; ++i) {
            address t = uniq[i];
            uint256 cur = t.balanceOf(address(this));
            uint256 gained = cur > before[i] ? cur - before[i] : 0; // never underflow on weird tokens
            if (gained == 0) continue;
            if (isReward[t] && supply != 0) {
                // distribute pro-rata to wveNEST holders (tokens stay here until claimed)
                rewardPerTokenStored[t] += (gained * WAD) / supply;
            } else {
                // non-allowlisted, or no holders yet -> send to the yield sink
                t.safeTransfer(yieldReceiver, gained);
            }
        }
        emit Harvested(msg.sender, yieldReceiver);
    }

    // --- reward claiming ---

    /// @notice Settle and transfer all of `msg.sender`'s accrued rewards. Resilient: one
    ///         misbehaving (blacklisting/paused) reward token can no longer brick the others —
    ///         it's skipped and its accrual restored for a later {claimToken}.
    function claim() external nonReentrant {
        _updateAccount(msg.sender);
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            _claimOne(rewardTokens[i]);
        }
    }

    /// @notice Claim a SINGLE reward token — escape hatch so a holder can still extract the good
    ///         tokens when one allowlisted token is blocking the batch {claim}.
    function claimToken(address token) external nonReentrant {
        _updateAccount(msg.sender);
        _claimOne(token);
    }

    function _claimOne(address t) internal {
        uint256 owed = rewardsAccrued[msg.sender][t];
        if (owed == 0) return;
        rewardsAccrued[msg.sender][t] = 0;
        try this.sweepReward(t, msg.sender, owed) {
            emit Claimed(msg.sender, t, owed);
        } catch {
            rewardsAccrued[msg.sender][t] = owed; // transiently blocked: restore, don't lose it
        }
    }

    /// @dev Self-only external transfer so {claim}/{claimToken} can isolate a reverting token.
    function sweepReward(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        token.safeTransfer(to, amount);
    }

    /// @notice Total rewards of `token` claimable by `account` (settled + pending).
    function earned(address account, address token) public view returns (uint256) {
        uint256 delta = rewardPerTokenStored[token] - userRewardPerTokenPaid[account][token];
        return rewardsAccrued[account][token] + (balanceOf(account) * delta) / WAD;
    }

    function _updateAccount(address account) internal {
        uint256 bal = balanceOf(account);
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            uint256 rpt = rewardPerTokenStored[t];
            rewardsAccrued[account][t] += (bal * (rpt - userRewardPerTokenPaid[account][t])) / WAD;
            userRewardPerTokenPaid[account][t] = rpt;
        }
    }

    /// @dev Checkpoint reward accounting before any balance change (mint/transfer/burn). Also
    ///      blocks transfers to this contract: self-held wveNEST would sit in the distribution
    ///      denominator (totalSupply) yet never claim, silently stranding a pro-rata slice of
    ///      every future harvest.
    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        if (to == address(this)) revert SelfTransfer();
        if (from != address(0)) _updateAccount(from);
        if (to != address(0)) _updateAccount(to);
    }

    // --- admin ---

    function pause() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        paused = true;
        emit Paused();
    }

    function unpause() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        paused = false;
        emit Unpaused();
    }

    /// @notice Allowlist a reward token for pro-rata distribution to holders. Keep the set
    ///         small (majors) — it's iterated on every wveNEST balance change.
    function addRewardToken(address token) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        if (!isReward[token] && token != address(0)) {
            isReward[token] = true;
            rewardTokens.push(token);
            emit RewardTokenAdded(token);
        }
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    function setKeeper(address k) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        keeper = k;
        emit KeeperSet(k);
    }

    function setYieldReceiver(address r) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        yieldReceiver = r;
        emit YieldReceiverSet(r);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
