// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CreditLineManagerBase} from "./CreditLineManagerBase.sol";
import {IPyth} from "../interfaces/IPyth.sol";

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
}

interface IKittenVotingReward {
    /// @dev NET-of-claim: drops to 0 once the position claims.
    function earnedForPeriod(uint256 period, uint256 tokenId, address token) external view returns (uint256);
    /// @dev Cumulative claimed for the period. gross = earnedForPeriod + this.
    function tokenIdRewardClaimedInPeriod(uint256 period, uint256 tokenId, address token)
        external
        view
        returns (uint256);
}

/// @title KittenCreditLineManager
/// @notice On-chain credit line for veKITTEN positions. Reads the EXACT per-veNFT fee
///         entitlement via votingReward.earnedForPeriod (no vote-share approximation, no
///         off-chain relayer) over the last `window` CLOSED periods and takes the MIN.
contract KittenCreditLineManager is CreditLineManagerBase {
    uint256 internal constant MAX_POOLS = 24;

    IKittenVoter public immutable voter;

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
        voter = IKittenVoter(_voter);
    }

    function _minWeeklyFeeUsd1e18(uint256 tokenId) internal view override returns (uint256) {
        uint256 cur = voter.getCurrentPeriod();
        if (cur <= window) return 0; // not enough closed history

        uint256 minUsd = type(uint256).max;
        uint256 counted;
        for (uint256 p = cur - window; p < cur; ++p) {
            (address[] memory pools,) = voter.getTokenIdVotes(p, tokenId);
            if (pools.length == 0) continue; // position didn't vote this period
            ++counted;

            uint256 weekUsd;
            uint256 n = pools.length < MAX_POOLS ? pools.length : MAX_POOLS;
            uint256 nTok = pricedTokens.length;
            for (uint256 i; i < n; ++i) {
                (,, address vr,,) = voter.getGauge(pools[i]);
                if (vr == address(0)) continue;
                for (uint256 j; j < nTok; ++j) {
                    address t = pricedTokens[j];
                    // GROSS per-period fee: earnedForPeriod is net-of-claim, so add back
                    // what was already claimed for this (period, tokenId, token).
                    uint256 gross = IKittenVotingReward(vr).earnedForPeriod(p, tokenId, t)
                        + IKittenVotingReward(vr).tokenIdRewardClaimedInPeriod(p, tokenId, t);
                    weekUsd += _amountToUsd1e18(t, gross);
                }
            }
            if (weekUsd < minUsd) minUsd = weekUsd;
        }
        if (counted == 0) return 0;
        // Scale by participation ratio (see NestCreditLineManager): full credit for participation
        // in every window period, proportionally discounted otherwise. Deters single-period spikes
        // without hard-denying honest partial participants.
        return (minUsd * counted) / window;
    }
}
