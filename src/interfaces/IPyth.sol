// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Pyth surface used by the credit-line managers (HyperEVM Pyth
///         0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc).
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Returns the price if it is no older than `age` seconds, else reverts.
    /// @dev Pyth is pull-based; a keeper or the borrow tx must updatePriceFeeds first.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
}
