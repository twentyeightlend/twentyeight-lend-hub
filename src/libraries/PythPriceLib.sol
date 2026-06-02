// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPyth} from "../interfaces/IPyth.sol";

/// @title PythPriceLib
/// @notice Fetches a fresh, confidence-checked USD price from Pyth and normalises it to 1e18.
/// @dev Guards against the two classic Pyth foot-guns: stale prices (getPriceNoOlderThan)
///      and wide confidence intervals (reject if conf/price exceeds maxConfBps).
library PythPriceLib {
    uint256 internal constant BPS = 10_000;

    error NonPositivePrice();
    error ConfidenceTooWide();
    error ExpoOutOfRange();

    /// @return usd1e18 Price of one whole token unit in USD, scaled by 1e18.
    function priceUsd1e18(IPyth pyth, bytes32 feedId, uint256 maxAge, uint256 maxConfBps)
        internal
        view
        returns (uint256 usd1e18)
    {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(feedId, maxAge); // reverts if stale
        if (p.price <= 0) revert NonPositivePrice();

        uint256 price = uint256(uint64(p.price));
        // conf/price must be within tolerance (both share the same expo, so compare raw).
        if (uint256(p.conf) * BPS > price * maxConfBps) revert ConfidenceTooWide();

        // Normalise mantissa*10^expo to 1e18.
        int256 expo = int256(p.expo);
        if (expo <= 0) {
            uint256 d = uint256(-expo);
            if (d > 36) revert ExpoOutOfRange();
            usd1e18 = (price * 1e18) / (10 ** d);
        } else {
            uint256 e = uint256(expo);
            if (e > 18) revert ExpoOutOfRange();
            usd1e18 = price * 1e18 * (10 ** e);
        }
    }
}
