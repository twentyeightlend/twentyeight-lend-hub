// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IOracle
/// @notice Prices a market's collateral in loan-token units for the principal tier.
/// @dev Yield-only markets set oracle == address(0) and never call this.
interface IOracle {
    /// @notice Price of one whole unit of the veNFT's underlying, in loan-token units,
    ///         scaled by 1e36 (Morpho convention). For the term tier this is the
    ///         haircut/redemption-floor-adjusted value, NOT raw spot.
    function price() external view returns (uint256);
}
