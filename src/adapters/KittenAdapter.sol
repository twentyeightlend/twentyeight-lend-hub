// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IVeAdapter} from "../interfaces/IVeAdapter.sol";

/// @dev Minimal veKITTEN escrow surface (Velodrome-v1-style, verified on-chain).
interface IVeKitten {
    function ownerOf(uint256 tokenId) external view returns (address);
    function locked(uint256 tokenId) external view returns (int128 amount, uint256 end);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function voted(uint256 tokenId) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
}

/// @dev KittenSwap Voter (custom Algebra fork, verified getters).
interface IKittenVoter {
    function getCurrentPeriod() external view returns (uint256);
    function getTokenIdVotes(uint256 period, uint256 tokenId)
        external
        view
        returns (address[] memory pools, uint256[] memory votes);
    function getGauge(address pool)
        external
        view
        returns (address gauge, bool isAlgebra, address votingReward, bool isAlive, address vault);
    function claimVotingRewardBatch(address[] calldata votingRewardList, uint256 tokenId) external;
    function vote(uint256 tokenId, address[] calldata poolList, uint256[] calldata weightList) external;
}

interface IKittenVotingReward {
    function getRewardList() external view returns (address[] memory);
    function earnedForPeriod(uint256 period, uint256 tokenId, address token) external view returns (uint256);
}

/// @title KittenAdapter
/// @notice IVeAdapter for veKITTEN. Custodies the veNFT and harvests trading fees + bribes
///         through KittenSwap's custom per-gauge votingReward contracts.
/// @dev Wiring verified 2026-06-02: getGauge(pool).votingReward holds per-pool fees paid in
///      the pool's own tokens; harvest routes through Voter.claimVotingRewardBatch.
contract KittenAdapter is IVeAdapter {
    using SafeTransferLib for address;

    address public immutable core;
    IVeKitten public immutable ve;
    IKittenVoter public immutable voter;
    address public immutable underlying;
    /// @notice Off-chain monitor / multisig that pauses on an unexpected proxy upgrade.
    address public immutable guardian;
    bool public paused;

    /// @dev Min remaining lock at deposit so a position can't be drawn against a lock about to expire.
    uint256 public constant MIN_LOCK_BUFFER = 7 days;
    /// @dev Bound harvest/estimate loops (KITTEN has ~54 pools; a veNFT votes a handful).
    uint256 internal constant MAX_VOTES = 32;

    error OnlyCore();
    error OnlyGuardian();
    error OnlySelf();
    error NotOwnedByAdapter();

    event Paused();
    event Unpaused();

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    constructor(address _core, address _ve, address _voter, address _underlying, address _guardian) {
        core = _core;
        ve = IVeKitten(_ve);
        voter = IKittenVoter(_voter);
        underlying = _underlying;
        guardian = _guardian;
    }

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

    function underlyingToken() external view returns (address) {
        return underlying;
    }

    function votingEscrow() external view returns (address) {
        return address(ve);
    }

    // --- intake / recovery ---

    function custody(uint256 tokenId, address from) external onlyCore {
        (bool ok,) = isAcceptableCollateral(tokenId);
        require(ok, "unacceptable collateral");
        ve.safeTransferFrom(from, address(this), tokenId);
        if (ve.ownerOf(tokenId) != address(this)) revert NotOwnedByAdapter();
        ve.approve(address(0), tokenId); // strip any lingering approval on intake
    }

    function recoverUnderlying(uint256 tokenId, address to) external onlyCore {
        ve.safeTransferFrom(address(this), to, tokenId);
    }

    // --- assessment ---

    function isPermanentLock(uint256) external pure returns (bool) {
        return false; // veKITTEN locks have real 2yr-max expiry; no permanent class.
    }

    function lockEnd(uint256 tokenId) external view returns (uint256) {
        (, uint256 end) = ve.locked(tokenId);
        return end;
    }

    function lockedAmount(uint256 tokenId) public view returns (uint256) {
        (int128 amount,) = ve.locked(tokenId);
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }

    function currentVotingPower(uint256 tokenId) external view returns (uint256) {
        return ve.balanceOfNFT(tokenId);
    }

    function isAcceptableCollateral(uint256 tokenId) public view returns (bool ok, string memory reason) {
        (int128 amount, uint256 end) = ve.locked(tokenId);
        if (amount <= 0) return (false, "no locked amount");
        if (end != 0 && end <= block.timestamp + MIN_LOCK_BUFFER) return (false, "lock near/at expiry");
        return (true, "");
    }

    // --- cashflow ---

    function _votedVotingRewards(uint256 tokenId) internal view returns (address[] memory vrs) {
        uint256 period = voter.getCurrentPeriod();
        // Use the just-closed period's votes; current period may still be accruing.
        uint256 src = period == 0 ? 0 : period - 1;
        (address[] memory pools,) = voter.getTokenIdVotes(src, tokenId);
        uint256 n = pools.length < MAX_VOTES ? pools.length : MAX_VOTES;
        vrs = new address[](n);
        for (uint256 i; i < n; ++i) {
            (,, address vr,,) = voter.getGauge(pools[i]);
            vrs[i] = vr;
        }
    }

    function harvestableYield(uint256 tokenId)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        address[] memory vrs = _votedVotingRewards(tokenId);
        uint256 period = voter.getCurrentPeriod();
        uint256 src = period == 0 ? 0 : period - 1;
        // Size by the ACTUAL summed reward-token count (a fixed multiple silently truncates), and
        // dedup-sum a token earned across multiple voted gauges.
        uint256 slots;
        for (uint256 i; i < vrs.length; ++i) {
            if (vrs[i] != address(0)) slots += IKittenVotingReward(vrs[i]).getRewardList().length;
        }
        address[] memory tBuf = new address[](slots);
        uint256[] memory aBuf = new uint256[](slots);
        uint256 k;
        for (uint256 i; i < vrs.length; ++i) {
            if (vrs[i] == address(0)) continue;
            address[] memory rl = IKittenVotingReward(vrs[i]).getRewardList();
            for (uint256 j; j < rl.length; ++j) {
                uint256 e = IKittenVotingReward(vrs[i]).earnedForPeriod(src, tokenId, rl[j]);
                if (e == 0) continue;
                bool seen;
                for (uint256 x; x < k; ++x) {
                    if (tBuf[x] == rl[j]) {
                        aBuf[x] += e;
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    tBuf[k] = rl[j];
                    aBuf[k] = e;
                    ++k;
                }
            }
        }
        tokens = new address[](k);
        amounts = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            tokens[i] = tBuf[i];
            amounts[i] = aBuf[i];
        }
    }

    function harvest(uint256 tokenId, address to)
        external
        onlyCore
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        address[] memory vrs = _votedVotingRewards(tokenId);
        // Collect unique reward tokens before claiming so we can sweep deltas. Size by the ACTUAL
        // summed reward-token count: claimVotingRewardBatch pulls EVERY token in each gauge's
        // getRewardList(), so a fixed `vrs.length*4` would silently DROP and permanently strand
        // tokens beyond the buffer (matches the NestAdapter sizing + its warning).
        uint256 slots;
        for (uint256 i; i < vrs.length; ++i) {
            if (vrs[i] != address(0)) slots += IKittenVotingReward(vrs[i]).getRewardList().length;
        }
        address[] memory uniq = new address[](slots);
        uint256 u;
        for (uint256 i; i < vrs.length; ++i) {
            if (vrs[i] == address(0)) continue;
            address[] memory rl = IKittenVotingReward(vrs[i]).getRewardList();
            for (uint256 j; j < rl.length; ++j) {
                bool seen;
                for (uint256 x; x < u; ++x) {
                    if (uniq[x] == rl[j]) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) uniq[u++] = rl[j];
            }
        }

        // Snapshot balances BEFORE claiming so we sweep only this harvest's proceeds
        // (delta), never funds belonging to another custodied position.
        uint256[] memory before = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            before[i] = uniq[i].balanceOf(address(this));
        }

        // Claim each votingReward in isolation: one hostile/reverting reward token in a gauge the
        // borrower voted must not brick the whole harvest (and thus the position's self-repay).
        for (uint256 i; i < vrs.length; ++i) {
            if (vrs[i] == address(0)) continue;
            address[] memory one = new address[](1);
            one[0] = vrs[i];
            try voter.claimVotingRewardBatch(one, tokenId) {} catch {}
        }

        tokens = new address[](u);
        amounts = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            address t = uniq[i];
            uint256 cur = t.balanceOf(address(this));
            uint256 gained = cur > before[i] ? cur - before[i] : 0; // never underflow on weird tokens
            tokens[i] = t;
            // Sweep in a try/catch: a reward token that reverts on transfer-out is left in the
            // adapter (rescuable by the guardian) instead of bricking harvest. amounts[] reflects
            // only what was actually forwarded to `to`.
            if (gained != 0) {
                try this.sweepReward(t, to, gained) {
                    amounts[i] = gained;
                } catch {}
            }
        }
    }

    /// @dev Self-only external sweep so {harvest} can isolate a reverting reward-token transfer.
    function sweepReward(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        token.safeTransfer(to, amount);
    }

    /// @notice Guardian rescue for reward tokens stranded by a failed sweep or a malicious token.
    ///         Cannot touch custodied veNFTs (ERC721, recovered only via {recoverUnderlying}).
    function rescueERC20(address token, address to, uint256 amount) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        token.safeTransfer(to, amount);
    }

    /// @param voteData abi.encode(address[] poolList, uint256[] weightList).
    function vote(uint256 tokenId, bytes calldata voteData) external onlyCore {
        (address[] memory poolList, uint256[] memory weightList) =
            abi.decode(voteData, (address[], uint256[]));
        voter.vote(tokenId, poolList, weightList);
    }

    /// @dev Required so the escrow's safeTransferFrom into this adapter (custody) succeeds.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
