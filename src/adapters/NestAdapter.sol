// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IVeAdapter} from "../interfaces/IVeAdapter.sol";

/// @dev veNEST escrow surface (Dromos MetaDEX, heavily customised — verified on-chain).
///      There is NO standard locked(); lock data comes from getNftState.
interface INestVe {
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
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function isTransferable(uint256 tokenId) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
}

/// @dev NEST Voter (Dromos, verified getters).
interface INestVoter {
    function poolVoteLength(uint256 tokenId) external view returns (uint256);
    function poolVote(uint256 tokenId, uint256 index) external view returns (address);
    function poolToGauge(address pool) external view returns (address);
    function gaugesState(address gauge)
        external
        view
        returns (
            bool isGauge,
            bool isAlive,
            address internalBribe,
            address externalBribe,
            address pool,
            uint256 claimable,
            uint256 index,
            uint256 lastDistributionTimestamp
        );
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;
    function vote(uint256 tokenId, address[] calldata poolsVotes, uint256[] calldata weights) external;
}

interface INestBribe {
    function rewardsList() external view returns (address[] memory);
    function earned(address token, address account) external view returns (uint256);
}

/// @title NestAdapter
/// @notice IVeAdapter for veNEST. ~97% of locked NEST is PERMANENT (no maturity), so only
///         the self-repaying tier applies. Harvests trading fees (internalBribe) + bribes
///         (externalBribe) through the Dromos Voter.
/// @dev Rebase is push-distributed (distributeVeNest) and auto-accrues to the lock — it is
///      NOT pull-claimable per token, so cashflow underwriting uses fees+bribes only.
contract NestAdapter is IVeAdapter {
    using SafeTransferLib for address;

    address public immutable core;
    INestVe public immutable ve;
    INestVoter public immutable voter;
    address public immutable underlying;
    /// @notice Off-chain monitor / multisig that pauses on an unexpected proxy upgrade.
    address public immutable guardian;
    bool public paused;

    uint256 public constant MIN_LOCK_BUFFER = 7 days;
    uint256 internal constant MAX_VOTES = 32;

    error OnlyCore();
    error OnlyGuardian();
    error NotOwnedByAdapter();

    event Paused();
    event Unpaused();

    modifier onlyCore() {
        if (msg.sender != core) revert OnlyCore();
        _;
    }

    constructor(address _core, address _ve, address _voter, address _underlying, address _guardian) {
        core = _core;
        ve = INestVe(_ve);
        voter = INestVoter(_voter);
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
        ve.approve(address(0), tokenId);
    }

    function recoverUnderlying(uint256 tokenId, address to) external onlyCore {
        ve.safeTransferFrom(address(this), to, tokenId);
    }

    // --- assessment ---

    function isPermanentLock(uint256 tokenId) external view returns (bool) {
        return ve.getNftState(tokenId).locked.isPermanentLocked;
    }

    function lockEnd(uint256 tokenId) external view returns (uint256) {
        INestVe.TokenState memory s = ve.getNftState(tokenId);
        return s.locked.isPermanentLocked ? type(uint256).max : s.locked.end;
    }

    function lockedAmount(uint256 tokenId) public view returns (uint256) {
        int128 a = ve.getNftState(tokenId).locked.amount;
        return a > 0 ? uint256(uint128(a)) : 0;
    }

    function currentVotingPower(uint256 tokenId) external view returns (uint256) {
        return ve.balanceOfNFT(tokenId);
    }

    /// @dev Rejects attached/managed NFTs (Debita #535 CRITICAL), non-transferable NFTs,
    ///      empty locks, and decaying locks too close to expiry.
    function isAcceptableCollateral(uint256 tokenId) public view returns (bool ok, string memory reason) {
        INestVe.TokenState memory s = ve.getNftState(tokenId);
        if (s.isAttached) return (false, "attached/managed NFT");
        if (!ve.isTransferable(tokenId)) return (false, "non-transferable");
        if (s.locked.amount <= 0) return (false, "no locked amount");
        if (!s.locked.isPermanentLocked && s.locked.end <= block.timestamp + MIN_LOCK_BUFFER) {
            return (false, "lock near/at expiry");
        }
        return (true, "");
    }

    // --- cashflow ---

    /// @dev Collect (internalBribe, externalBribe) for every gauge this veNFT voted, plus
    ///      each bribe's reward-token list. Bounded by MAX_VOTES.
    function _votedBribes(uint256 tokenId)
        internal
        view
        returns (address[] memory bribes, address[][] memory tokens)
    {
        uint256 nVotes = voter.poolVoteLength(tokenId);
        if (nVotes > MAX_VOTES) nVotes = MAX_VOTES;

        address[] memory bBuf = new address[](nVotes * 2);
        address[][] memory tBuf = new address[][](nVotes * 2);
        uint256 k;
        for (uint256 i; i < nVotes; ++i) {
            address pool = voter.poolVote(tokenId, i);
            address gauge = voter.poolToGauge(pool);
            if (gauge == address(0)) continue;
            (,, address intB, address extB,,,,) = voter.gaugesState(gauge);
            if (intB != address(0)) {
                bBuf[k] = intB;
                tBuf[k] = INestBribe(intB).rewardsList();
                ++k;
            }
            if (extB != address(0)) {
                bBuf[k] = extB;
                tBuf[k] = INestBribe(extB).rewardsList();
                ++k;
            }
        }
        bribes = new address[](k);
        tokens = new address[][](k);
        for (uint256 i; i < k; ++i) {
            bribes[i] = bBuf[i];
            tokens[i] = tBuf[i];
        }
    }

    function harvestableYield(uint256 tokenId)
        external
        view
        returns (address[] memory outTokens, uint256[] memory outAmounts)
    {
        (address[] memory bribes, address[][] memory tokens) = _votedBribes(tokenId);
        // Flatten unique reward tokens, summing earned() for this adapter (the veNFT owner).
        uint256 slots;
        for (uint256 i; i < bribes.length; ++i) {
            slots += tokens[i].length;
        }
        address[] memory uBuf = new address[](slots);
        uint256[] memory aBuf = new uint256[](slots);
        uint256 u;
        for (uint256 i; i < bribes.length; ++i) {
            for (uint256 j; j < tokens[i].length; ++j) {
                address t = tokens[i][j];
                uint256 e = INestBribe(bribes[i]).earned(t, address(this));
                if (e == 0) continue;
                uint256 idx = type(uint256).max;
                for (uint256 x; x < u; ++x) {
                    if (uBuf[x] == t) {
                        idx = x;
                        break;
                    }
                }
                if (idx == type(uint256).max && u < uBuf.length) {
                    uBuf[u] = t;
                    aBuf[u] = e;
                    ++u;
                } else if (idx != type(uint256).max) {
                    aBuf[idx] += e;
                }
            }
        }
        outTokens = new address[](u);
        outAmounts = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            outTokens[i] = uBuf[i];
            outAmounts[i] = aBuf[i];
        }
    }

    function harvest(uint256 tokenId, address to)
        external
        onlyCore
        returns (address[] memory outTokens, uint256[] memory outAmounts)
    {
        (address[] memory bribes, address[][] memory tokens) = _votedBribes(tokenId);

        // Unique reward token set to sweep after claim. Size by the ACTUAL total reward-token
        // count (NEST bribes expose up to ~14 each) — a fixed multiple would silently DROP and
        // permanently strand tokens beyond the buffer.
        uint256 slots;
        for (uint256 i; i < bribes.length; ++i) {
            slots += tokens[i].length;
        }
        address[] memory uniq = new address[](slots);
        uint256 u;
        for (uint256 i; i < bribes.length; ++i) {
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

        // Snapshot before claim so we sweep only this harvest's delta, never another
        // custodied position's funds.
        uint256[] memory before = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            before[i] = uniq[i].balanceOf(address(this));
        }

        if (bribes.length != 0) voter.claimBribes(bribes, tokens, tokenId); // claims to this adapter

        outTokens = new address[](u);
        outAmounts = new uint256[](u);
        for (uint256 i; i < u; ++i) {
            address t = uniq[i];
            uint256 cur = t.balanceOf(address(this));
            uint256 gained = cur > before[i] ? cur - before[i] : 0; // never underflow on weird tokens
            outTokens[i] = t;
            outAmounts[i] = gained;
            if (gained != 0) t.safeTransfer(to, gained);
        }
    }

    /// @param voteData abi.encode(address[] poolsVotes, uint256[] weights).
    function vote(uint256 tokenId, bytes calldata voteData) external onlyCore {
        (address[] memory pools, uint256[] memory weights) = abi.decode(voteData, (address[], uint256[]));
        voter.vote(tokenId, pools, weights);
    }

    /// @dev Required so the escrow's safeTransferFrom into this adapter (custody) succeeds.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
