// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICreditLineManager} from "../interfaces/ICreditLineManager.sol";
import {IPyth} from "../interfaces/IPyth.sol";
import {PythPriceLib} from "../libraries/PythPriceLib.sol";
import {MarketParams} from "../libraries/Types.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title CreditLineManagerBase
/// @notice Shared machinery for cashflow credit lines: Pyth pricing, USD->loanToken
///         conversion, and the trailing-MIN x multiplier template. Each protocol subclass
///         supplies only `_minWeeklyFeeUsd1e18` (how it reads a veNFT's per-week fee$).
/// @dev The token->feed map is set once in the constructor and never mutated, so the manager
///      is effectively immutable. Unmapped reward tokens price to 0 => EXCLUDED from the
///      credit line (conservative; long-tail bribes become pure upside, never collateral).
abstract contract CreditLineManagerBase is ICreditLineManager {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IPyth public immutable pyth;
    bytes32 public immutable loanTokenFeed;
    uint256 public immutable loanTokenDecimals;
    /// @notice Closed epochs scanned to find the conservative (MIN) weekly fee.
    uint256 public immutable window;
    /// @notice Epochs of fee the credit line extends (the 40acres-style multiplier).
    uint256 public immutable multiplier;
    /// @notice Extra safety factor on the computed line (bps of the raw figure).
    uint256 public immutable safetyBps;
    uint256 public immutable maxAge;
    uint256 public immutable maxConfBps;

    mapping(address => bytes32) public feedOf;
    /// @notice Enumerable set of priced reward tokens (the constructor token list). Subclasses
    ///         iterate this instead of a protocol's full reward list — unmapped long-tail
    ///         tokens are excluded anyway, so this bounds the per-call loop to the majors.
    address[] public pricedTokens;

    error BadConfig();

    constructor(
        IPyth _pyth,
        bytes32 _loanTokenFeed,
        uint256 _loanTokenDecimals,
        uint256 _window,
        uint256 _multiplier,
        uint256 _safetyBps,
        uint256 _maxAge,
        uint256 _maxConfBps,
        address[] memory tokens,
        bytes32[] memory feeds
    ) {
        if (
            _window == 0 || _multiplier == 0 || _safetyBps == 0 || _safetyBps > BPS
                || _maxConfBps > BPS || _maxAge == 0 || tokens.length != feeds.length
                || address(_pyth) == address(0) || _loanTokenFeed == bytes32(0)
        ) revert BadConfig();
        pyth = _pyth;
        loanTokenFeed = _loanTokenFeed;
        loanTokenDecimals = _loanTokenDecimals;
        window = _window;
        multiplier = _multiplier;
        safetyBps = _safetyBps;
        maxAge = _maxAge;
        maxConfBps = _maxConfBps;
        for (uint256 i; i < tokens.length; ++i) {
            feedOf[tokens[i]] = feeds[i];
            pricedTokens.push(tokens[i]);
        }
    }

    function pricedTokensLength() external view returns (uint256) {
        return pricedTokens.length;
    }

    /// @dev External wrapper so callers can try/catch Pyth reverts (stale/wide confidence).
    ///      Self-call (`this.priceUsd1e18External`) is the only way to recover from a library
    ///      revert without aborting the whole credit-line read.
    function priceUsd1e18External(bytes32 feed) external view returns (uint256) {
        return PythPriceLib.priceUsd1e18(pyth, feed, maxAge, maxConfBps);
    }

    /// @inheritdoc ICreditLineManager
    function creditLine(MarketParams calldata, uint256 tokenId) external view returns (uint256) {
        uint256 minWeeklyUsd = _minWeeklyFeeUsd1e18(tokenId); // 1e18 USD
        if (minWeeklyUsd == 0) return 0;

        uint256 grossUsd = (minWeeklyUsd * multiplier * safetyBps) / BPS; // 1e18 USD
        uint256 loanUsd = PythPriceLib.priceUsd1e18(pyth, loanTokenFeed, maxAge, maxConfBps);
        if (loanUsd == 0) return 0;
        // USD(1e18) -> loanToken units.
        return (grossUsd * (10 ** loanTokenDecimals)) / loanUsd;
    }

    /// @dev Convert a raw reward-token amount to 1e18 USD; returns 0 for unmapped tokens.
    function _amountToUsd1e18(address token, uint256 rawAmount) internal view returns (uint256) {
        if (rawAmount == 0) return 0;
        bytes32 feed = feedOf[token];
        if (feed == bytes32(0)) return 0; // excluded
        // A momentarily stale / wide-confidence feed must EXCLUDE the token (price 0), not revert
        // the whole credit read — matching the unmapped-token invariant. Only the loanToken feed
        // (in {creditLine}) stays strict, since a bad loan price should block borrowing outright.
        uint256 px;
        try this.priceUsd1e18External(feed) returns (uint256 p) {
            px = p;
        } catch {
            return 0;
        }
        if (px == 0) return 0;
        uint256 dec = IDecimals(token).decimals();
        return (rawAmount * px) / (10 ** dec);
    }

    /// @notice Trailing-MIN weekly fee for `tokenId`, in 1e18 USD. Protocol-specific.
    function _minWeeklyFeeUsd1e18(uint256 tokenId) internal view virtual returns (uint256);
}
