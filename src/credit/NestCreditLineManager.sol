// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CreditLineManagerBase} from "./CreditLineManagerBase.sol";
import {IPyth} from "../interfaces/IPyth.sol";

interface INestVoter {
    function epochTimestamp() external view returns (uint256);
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
}

interface INestBribe {
    /// @dev HISTORICAL per-veNFT vote weight in this bribe at a past epoch timestamp.
    function balanceOfAt(uint256 tokenId, uint256 epochTs) external view returns (uint256);
    /// @dev HISTORICAL total vote weight in this bribe at a past epoch timestamp.
    function totalSupplyAt(uint256 epochTs) external view returns (uint256);
    /// @dev Per-token fee total for an epoch: (periodFinish, rewardsPerEpoch, lastUpdateTime).
    function rewardData(address token, uint256 epoch)
        external
        view
        returns (uint256 periodFinish, uint256 rewardsPerEpoch, uint256 lastUpdateTime);
}

/// @title NestCreditLineManager
/// @notice On-chain credit line for veNEST positions, underwritten on the position's HISTORICAL
///         trading-fee entitlement only (bribes are upside, never collateral).
/// @dev MANIPULATION-PROOF: the fee share is read from the internal-fee bribe's HISTORICAL
///      checkpoints — `balanceOfAt(tokenId, closedEpoch) / totalSupplyAt(closedEpoch)`. A
///      borrower cannot inflate this by re-voting now (a new vote yields balanceOfAt==0 at past
///      epochs). Credit = trailing-MIN over `window` closed epochs × multiplier × safetyBps.
contract NestCreditLineManager is CreditLineManagerBase {
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant MAX_POOLS = 16;

    INestVoter public immutable voter;

    constructor(
        IPyth _pyth,
        address _voter,
        bytes32 _loanTokenFeed,
        uint256 _loanTokenDecimals,
        uint256 _window,
        uint256 _multiplier,
        uint256 _safetyBps,
        uint256 _maxAge,
        uint256 _maxConfBps,
        address[] memory tokens,
        bytes32[] memory feeds
    )
        CreditLineManagerBase(
            _pyth,
            _loanTokenFeed,
            _loanTokenDecimals,
            _window,
            _multiplier,
            _safetyBps,
            _maxAge,
            _maxConfBps,
            tokens,
            feeds
        )
    {
        voter = INestVoter(_voter);
    }

    function _minWeeklyFeeUsd1e18(uint256 tokenId) internal view override returns (uint256) {
        uint256 curEpoch = voter.epochTimestamp();
        if (curEpoch < (window + 1) * WEEK) return 0;

        uint256 nVotes = voter.poolVoteLength(tokenId);
        if (nVotes == 0) return 0;
        if (nVotes > MAX_POOLS) nVotes = MAX_POOLS;

        // Resolve the internal-fee bribe for each currently-voted pool once.
        address[] memory bribes = new address[](nVotes);
        for (uint256 i; i < nVotes; ++i) {
            // Guard a killed/stale gauge (poolToGauge==0) — gaugesState(address(0)) can revert and
            // would brick the whole credit read. Mirrors the guard in NestAdapter/ReceiptWrapper.
            address gauge = voter.poolToGauge(voter.poolVote(tokenId, i));
            if (gauge == address(0)) continue; // bribes[i] stays address(0) -> skipped below
            (,, address intB,,,,,) = voter.gaugesState(gauge);
            bribes[i] = intB;
        }

        uint256 minUsd = type(uint256).max;
        uint256 counted;
        for (uint256 w = 1; w <= window; ++w) {
            uint256 epochTs = curEpoch - w * WEEK; // closed epoch
            uint256 weekUsd;
            bool participated;
            for (uint256 i; i < nVotes; ++i) {
                address ib = bribes[i];
                if (ib == address(0)) continue;
                uint256 total = INestBribe(ib).totalSupplyAt(epochTs);
                if (total == 0) continue;
                uint256 mine = INestBribe(ib).balanceOfAt(tokenId, epochTs); // HISTORICAL, unforgeable
                if (mine == 0) continue;
                participated = true;
                uint256 share = (mine * WAD) / total;
                if (share > WAD) share = WAD;
                weekUsd += (_poolFeeUsd(ib, epochTs) * share) / WAD;
            }
            if (!participated) continue;
            ++counted;
            if (weekUsd < minUsd) minUsd = weekUsd;
        }
        if (counted == 0) return 0;
        // Scale by participation ratio: a position that participated in every window epoch gets
        // the full trailing-MIN; one that participated in fewer (e.g. a single high-fee spike, or
        // a recent pool switch where older epochs aren't detected) is proportionally discounted.
        // This deters single-epoch manipulation WITHOUT hard-denying honest partial participants.
        return (minUsd * counted) / window;
    }

    /// @dev USD trading fees distributed by `bribe` in `epochTs`, priced tokens only.
    function _poolFeeUsd(address bribe, uint256 epochTs) internal view returns (uint256 usd) {
        uint256 nTok = pricedTokens.length;
        for (uint256 j; j < nTok; ++j) {
            address t = pricedTokens[j];
            (, uint256 rewardsPerEpoch,) = INestBribe(bribe).rewardData(t, epochTs);
            usd += _amountToUsd1e18(t, rewardsPerEpoch);
        }
    }
}
