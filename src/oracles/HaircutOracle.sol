// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPyth} from "../interfaces/IPyth.sol";
import {PythPriceLib} from "../libraries/PythPriceLib.sol";

interface IVeTwapOracle {
    function priceUsd1e18() external view returns (uint256);
}

/// @title HaircutOracle
/// @notice Prices wveNEST collateral for the lending market. wveNEST is 1:1 backed by permanently
///         locked NEST, so its fair value is NEST's TWAP price discounted for illiquidity (DLOM —
///         permanent locks can't be redeemed, only sold). Output is the Morpho 1e36 convention:
///         loan-token-wei per collateral-wei, scaled by 1e36.
/// @dev price = (collatUsdPerWei / loanUsdPerWei) * 1e36, with collatUsd = NEST_USD * (1 - dlom).
contract HaircutOracle is IOracle {
    uint256 internal constant BPS = 10_000;

    IVeTwapOracle public immutable nestOracle;
    IPyth public immutable pyth;
    bytes32 public immutable loanUsdFeed;
    uint256 public immutable dlomBps; // illiquidity discount, e.g. 4000 = 40%
    uint256 public immutable collatScale; // 10^collateralDecimals
    uint256 public immutable loanScale; // 10^loanDecimals
    uint256 public immutable maxAge;
    uint256 public immutable maxConfBps;

    error BadConfig();

    constructor(
        address _nestOracle,
        address _pyth,
        bytes32 _loanUsdFeed,
        uint256 _dlomBps,
        uint256 _collateralDecimals,
        uint256 _loanDecimals,
        uint256 _maxAge,
        uint256 _maxConfBps
    ) {
        if (_dlomBps >= BPS || _collateralDecimals > 36 || _loanDecimals > 36) revert BadConfig();
        nestOracle = IVeTwapOracle(_nestOracle);
        pyth = IPyth(_pyth);
        loanUsdFeed = _loanUsdFeed;
        dlomBps = _dlomBps;
        collatScale = 10 ** _collateralDecimals;
        loanScale = 10 ** _loanDecimals;
        maxAge = _maxAge;
        maxConfBps = _maxConfBps;
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        uint256 collatUsd1e18 = (nestOracle.priceUsd1e18() * (BPS - dlomBps)) / BPS;
        uint256 loanUsd1e18 = PythPriceLib.priceUsd1e18(pyth, loanUsdFeed, maxAge, maxConfBps);
        // (collatUsd1e18 / collatScale) / (loanUsd1e18 / loanScale) * 1e36
        return FixedPointMathLib.fullMulDiv(collatUsd1e18 * loanScale, 1e36, loanUsd1e18 * collatScale);
    }
}
