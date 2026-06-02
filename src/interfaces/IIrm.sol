// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketParams, Market} from "../libraries/Types.sol";

/// @title IIrm
/// @notice Interest rate model. Returns the per-second borrow rate (WAD).
/// @dev irm == address(0) => 0% interest (pure self-repay market).
interface IIrm {
    /// @notice Borrow rate per second (WAD) given current market state. View variant.
    function borrowRateView(MarketParams memory marketParams, Market memory market)
        external
        view
        returns (uint256);

    /// @notice Borrow rate per second (WAD); may update internal IRM state.
    function borrowRate(MarketParams memory marketParams, Market memory market)
        external
        returns (uint256);
}
