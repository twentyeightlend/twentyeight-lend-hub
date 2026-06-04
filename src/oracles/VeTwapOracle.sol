// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {IPyth} from "../interfaces/IPyth.sol";
import {PythPriceLib} from "../libraries/PythPriceLib.sol";

interface IAlgebraPool {
    function plugin() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function globalState()
        external
        view
        returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked);
}

interface IAlgebraOraclePlugin {
    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint88[] memory volatilityCumulatives);
    function isInitialized() external view returns (bool);
}

/// @title VeTwapOracle
/// @notice Robust USD price for NEST/KITTEN: Algebra-Integral TWAP (TOKEN/WHYPE) routed through
///         the Pyth WHYPE/USD feed. NEST & KITTEN have no Pyth feed, and their deepest liquidity
///         is the TOKEN/WHYPE pool — so TOKEN_USD = TWAP(TOKEN/WHYPE) × Pyth(WHYPE/USD).
/// @dev Manipulation resistance: (1) an N-second arithmetic-mean-tick TWAP (costly to bend over
///      the window vs the pool's liquidity); (2) a spot-vs-TWAP tick deviation guard that reverts
///      if the live tick has been pushed far from the TWAP; (3) Pyth staleness + confidence guard
///      on the WHYPE leg. Returns USD scaled by 1e18.
contract VeTwapOracle {
    using FixedPointMathLib for uint256;

    IAlgebraPool public immutable pool;
    IAlgebraOraclePlugin public immutable plugin;
    address public immutable token; // NEST or KITTEN
    address public immutable quote; // WHYPE
    uint256 public immutable tokenDecimals;
    uint256 public immutable quoteDecimals;

    IPyth public immutable pyth;
    bytes32 public immutable quoteUsdFeed; // WHYPE/USD
    uint32 public immutable twapWindow; // seconds (long)
    uint32 public immutable shortWindow; // seconds (= twapWindow/4); short-vs-long deviation guard
    int24 public immutable maxTickDeviation; // max |shortMeanTick - longMeanTick|
    uint256 public immutable maxAge;
    uint256 public immutable maxConfBps;

    /// @dev Minimum TWAP window: a long window makes a SUSTAINED multi-block price push expensive
    ///      (arbitrage fights it the whole time); the short-vs-long deviation guard catches cheaper
    ///      recent spikes. Together they replace the old single-block spot-vs-TWAP check.
    uint32 internal constant MIN_TWAP_WINDOW = 1800; // 30 min

    error NotInitialized();
    error TickDeviationTooHigh();
    error BadConfig();

    constructor(
        address _pool,
        address _token,
        address _quote,
        uint256 _tokenDecimals,
        uint256 _quoteDecimals,
        address _pyth,
        bytes32 _quoteUsdFeed,
        uint32 _twapWindow,
        int24 _maxTickDeviation,
        uint256 _maxAge,
        uint256 _maxConfBps
    ) {
        if (_twapWindow < MIN_TWAP_WINDOW || _maxTickDeviation <= 0 || _pool == address(0)) revert BadConfig();
        if (_tokenDecimals > 18 || _quoteDecimals > 18) revert BadConfig(); // 10**dec must fit uint128 baseAmount
        // Pyth config parity with CreditLineManagerBase: maxAge==0 would make getPriceNoOlderThan
        // always revert (bricking price()); maxConfBps>BPS would disable the confidence guard.
        if (_maxAge == 0 || _maxConfBps > 10_000 || _pyth == address(0) || _quoteUsdFeed == bytes32(0)) {
            revert BadConfig();
        }
        pool = IAlgebraPool(_pool);
        // token/quote MUST be this pool's pair, else getQuoteAtTick silently inverts the price.
        address t0 = IAlgebraPool(_pool).token0();
        address t1 = IAlgebraPool(_pool).token1();
        if (!((_token == t0 && _quote == t1) || (_token == t1 && _quote == t0))) revert BadConfig();
        address p = IAlgebraPool(_pool).plugin();
        if (p == address(0)) revert BadConfig();
        plugin = IAlgebraOraclePlugin(p);
        token = _token;
        quote = _quote;
        tokenDecimals = _tokenDecimals;
        quoteDecimals = _quoteDecimals;
        pyth = IPyth(_pyth);
        quoteUsdFeed = _quoteUsdFeed;
        twapWindow = _twapWindow;
        shortWindow = _twapWindow / 4;
        maxTickDeviation = _maxTickDeviation;
        maxAge = _maxAge;
        maxConfBps = _maxConfBps;
    }

    /// @notice USD price of one whole `token`, scaled by 1e18.
    function priceUsd1e18() external view returns (uint256) {
        int24 meanTick = _twapTick(); // long-window mean, guarded against recent manipulation

        // WHYPE per 1 token (in quote decimals), from the mean tick.
        uint256 quotePerToken = _getQuoteAtTick(meanTick, uint128(10 ** tokenDecimals), token, quote);
        uint256 whypeUsd1e18 = PythPriceLib.priceUsd1e18(pyth, quoteUsdFeed, maxAge, maxConfBps);
        // (WHYPE amount / 10^quoteDec) * (USD per WHYPE, 1e18) = USD per token, 1e18.
        return FixedPointMathLib.fullMulDiv(quotePerToken, whypeUsd1e18, 10 ** quoteDecimals);
    }

    /// @dev Returns the long-window mean tick, reverting if the short-window mean has deviated from
    ///      it by more than maxTickDeviation (a recent manipulation spike). Pure TWAP, no spot read.
    function _twapTick() internal view returns (int24 longMean) {
        if (!plugin.isInitialized()) revert NotInitialized();
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = shortWindow;
        secondsAgos[2] = 0;
        (int56[] memory tc,) = plugin.getTimepoints(secondsAgos); // reverts if history < twapWindow
        longMean = _meanTick(tc[2] - tc[0], twapWindow);
        int24 shortMean = _meanTick(tc[2] - tc[1], shortWindow);
        int24 d = shortMean > longMean ? shortMean - longMean : longMean - shortMean;
        if (d > maxTickDeviation) revert TickDeviationTooHigh();
    }

    /// @dev Arithmetic-mean tick over `window`, floored toward -inf (Uniswap convention).
    function _meanTick(int56 delta, uint32 window) internal pure returns (int24 meanTick) {
        int56 w = int56(uint56(window));
        meanTick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) meanTick--;
    }

    /// @dev Uniswap OracleLibrary.getQuoteAtTick, using solady fullMulDiv for the 512-bit math.
    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FixedPointMathLib.fullMulDiv(ratioX192, baseAmount, 1 << 192)
                : FixedPointMathLib.fullMulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FixedPointMathLib.fullMulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FixedPointMathLib.fullMulDiv(ratioX128, baseAmount, 1 << 128)
                : FixedPointMathLib.fullMulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
