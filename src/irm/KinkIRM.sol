// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIrm} from "../interfaces/IIrm.sol";
import {MarketParams, Market} from "../libraries/Types.sol";

/// @title KinkIRM
/// @notice Stateless kinked-linear interest-rate model. The borrow APR rises linearly with
///         utilization up to an optimal "kink", then climbs steeply above it to defend liquidity
///         (so lenders can always withdraw). It is a pure function of utilization — no stored
///         state, no admin, no oracle, nothing to manipulate. One instance can be shared by every
///         market. Lenders earn the accrued interest minus the market's protocol-fee cut.
contract KinkIRM is IIrm {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days; // 31_536_000
    /// @dev Matches the markets' own per-second clamp; we reject curves that could exceed it.
    uint256 internal constant MAX_RATE_PER_SECOND = 1e12;

    /// @notice Annualized borrow APRs (WAD; 0.08e18 = 8%/yr) at the three reference points.
    uint256 public immutable baseApr; // at 0% utilization
    uint256 public immutable kinkApr; // at the optimal utilization
    uint256 public immutable maxApr; // at 100% utilization
    /// @notice Optimal ("kink") utilization (WAD; 0.9e18 = 90%).
    uint256 public immutable optimalUtilization;

    error NonMonotonicRates();
    error BadOptimalUtilization();
    error MaxRateTooHigh();

    constructor(uint256 _baseApr, uint256 _kinkApr, uint256 _maxApr, uint256 _optimalUtilization) {
        if (!(_baseApr <= _kinkApr && _kinkApr <= _maxApr)) revert NonMonotonicRates();
        if (_optimalUtilization == 0 || _optimalUtilization >= WAD) revert BadOptimalUtilization();
        // keep the steepest point inside the markets' per-second clamp so the configured curve is
        // always the effective one (never silently capped).
        if (_maxApr / SECONDS_PER_YEAR > MAX_RATE_PER_SECOND) revert MaxRateTooHigh();
        baseApr = _baseApr;
        kinkApr = _kinkApr;
        maxApr = _maxApr;
        optimalUtilization = _optimalUtilization;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory, Market memory market) external view returns (uint256) {
        return _aprAtUtilization(_utilization(market)) / SECONDS_PER_YEAR;
    }

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory, Market memory market) external view returns (uint256) {
        return _aprAtUtilization(_utilization(market)) / SECONDS_PER_YEAR;
    }

    /// @notice Annual borrow APR (WAD) at a given utilization (WAD). For off-chain quoting/UI.
    function aprAtUtilization(uint256 utilization) external view returns (uint256) {
        return _aprAtUtilization(utilization > WAD ? WAD : utilization);
    }

    function _utilization(Market memory market) internal pure returns (uint256) {
        if (market.totalSupplyAssets == 0) return 0;
        uint256 u = (uint256(market.totalBorrowAssets) * WAD) / market.totalSupplyAssets;
        return u > WAD ? WAD : u; // clamp: borrow can transiently round above supply
    }

    function _aprAtUtilization(uint256 u) internal view returns (uint256) {
        if (u <= optimalUtilization) {
            return baseApr + ((kinkApr - baseApr) * u) / optimalUtilization;
        }
        uint256 excess = u - optimalUtilization;
        return kinkApr + ((maxApr - kinkApr) * excess) / (WAD - optimalUtilization);
    }
}
