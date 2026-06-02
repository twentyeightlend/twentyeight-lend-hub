// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {LendingCore} from "./LendingCore.sol";
import {MarketParams, Id, MarketParamsLib} from "./libraries/Types.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {PythPriceLib} from "./libraries/PythPriceLib.sol";

interface ISwapRouter {
    /// @notice Swap `amountIn` of `tokenIn` to `tokenOut`, reverting if output < `minOut`.
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes calldata data)
        external
        returns (uint256 out);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title SelfRepayEngine
/// @notice Turns a position's harvested fees+bribes into loan-token repayment.
/// @dev Permissionless: anyone can poke {selfRepay} for a position (keeper or borrower).
///      Flow per call: core.harvestFor -> rewards land here -> swap each to loanToken ->
///      take treasury cut -> repay debt -> refund any surplus to the borrower.
///      Sandwich protection (Alchemix #30682): for tokens with a Pyth feed, the engine
///      ENFORCES an oracle-derived output floor, so a malicious keeper cannot set minOut=0.
///      Unmapped tokens fall back to the caller-supplied minOut.
contract SelfRepayEngine is ReentrancyGuard {
    using SafeTransferLib for address;
    using MarketParamsLib for MarketParams;

    uint256 internal constant BPS = 10_000;

    LendingCore public immutable core;
    ISwapRouter public immutable router;
    address public immutable treasury;
    /// @dev Treasury share of each harvest, in bps. Lenders are compensated via interest.
    uint256 public immutable treasuryBps;

    IPyth public immutable pyth;
    /// @dev Max tolerated slippage below the oracle-implied output, in bps.
    uint256 public immutable maxSlippageBps;
    uint256 public immutable maxAge;
    uint256 public immutable maxConfBps;
    mapping(address => bytes32) public feedOf;

    struct Swap {
        address tokenIn;
        uint256 minOut;
        bytes data;
    }

    event SelfRepay(Id indexed id, uint256 indexed tokenId, uint256 repaid, uint256 treasuryCut, uint256 refund);

    error TooLowOutput();
    error BadConfig();
    error NoDebt();

    constructor(
        address _core,
        address _router,
        address _treasury,
        uint256 _treasuryBps,
        address _pyth,
        uint256 _maxSlippageBps,
        uint256 _maxAge,
        uint256 _maxConfBps,
        address[] memory tokens,
        bytes32[] memory feeds
    ) {
        if (_treasuryBps > BPS || _maxSlippageBps > BPS || tokens.length != feeds.length) revert BadConfig();
        core = LendingCore(_core);
        router = ISwapRouter(_router);
        treasury = _treasury;
        treasuryBps = _treasuryBps;
        pyth = IPyth(_pyth);
        maxSlippageBps = _maxSlippageBps;
        maxAge = _maxAge;
        maxConfBps = _maxConfBps;
        for (uint256 i; i < tokens.length; ++i) {
            feedOf[tokens[i]] = feeds[i];
        }
    }

    /// @notice Harvest `tokenId`'s rewards and apply them to its debt.
    /// @param swaps One entry per non-loanToken reward, supplying the minOut floor.
    function selfRepay(MarketParams calldata params, uint256 tokenId, Swap[] calldata swaps)
        external
        nonReentrant
    {
        Id id = params.id();
        address loanToken = params.loanToken;

        // Don't harvest (and tax) a position with no debt — nothing to self-repay.
        (, uint128 borrowShares,,) = core.position(id, tokenId);
        if (borrowShares == 0) revert NoDebt();

        // Snapshot pre-existing loanToken so only THIS harvest's proceeds are taxed/repaid/refunded
        // (a donation or leftover dust must not be misrouted).
        uint256 startBal = loanToken.balanceOf(address(this));

        (address[] memory tokens,) = core.harvestFor(params, tokenId);

        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            if (t == loanToken) continue;
            uint256 bal = t.balanceOf(address(this));
            if (bal == 0) continue;
            // Only swap tokens we can price: an unpriced token has no oracle floor, so a
            // permissionless caller could set minOut=0 and sandwich it. Skip it (it stays in the
            // engine for a guardian to handle) — never swap without oracle protection.
            uint256 floor = _oracleFloor(t, loanToken, bal);
            if (floor == 0) continue;
            uint256 minOut = _minOutFor(swaps, t);
            if (floor > minOut) minOut = floor;
            bytes memory data = _dataFor(swaps, t);
            t.safeApproveWithRetry(address(router), bal); // handles approve-from-nonzero (USDT-style)
            uint256 out = router.swap(t, bal, loanToken, minOut, data);
            if (out < minOut) revert TooLowOutput();
        }

        uint256 total = loanToken.balanceOf(address(this)) - startBal; // this harvest's proceeds only
        if (total == 0) {
            emit SelfRepay(id, tokenId, 0, 0, 0);
            return;
        }

        uint256 treasuryCut = (total * treasuryBps) / BPS;
        if (treasuryCut != 0) loanToken.safeTransfer(treasury, treasuryCut);

        uint256 toRepay = total - treasuryCut;
        loanToken.safeApproveWithRetry(address(core), toRepay);
        core.repay(params, tokenId, toRepay); // core caps to outstanding debt

        // Refund any surplus from THIS harvest (debt fully cleared) to the borrower; the
        // pre-existing startBal is left untouched.
        uint256 refund = loanToken.balanceOf(address(this)) - startBal;
        if (refund != 0) {
            (address borrower,,,) = core.position(id, tokenId);
            address to = borrower == address(0) ? msg.sender : borrower;
            loanToken.safeTransfer(to, refund);
        }
        loanToken.safeApprove(address(core), 0);

        emit SelfRepay(id, tokenId, toRepay - refund, treasuryCut, refund);
    }

    /// @dev Oracle-implied minimum output for swapping `amountIn` of `tokenIn` into
    ///      `tokenOut`, minus tolerated slippage. Returns 0 if either side is unpriced
    ///      (then only the caller's minOut applies).
    function _oracleFloor(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        bytes32 inFeed = feedOf[tokenIn];
        bytes32 outFeed = feedOf[tokenOut];
        if (inFeed == bytes32(0) || outFeed == bytes32(0)) return 0;

        uint256 inUsd1e18 = (amountIn * PythPriceLib.priceUsd1e18(pyth, inFeed, maxAge, maxConfBps))
            / (10 ** IDecimals(tokenIn).decimals());
        uint256 outPx = PythPriceLib.priceUsd1e18(pyth, outFeed, maxAge, maxConfBps);
        if (outPx == 0) return 0;
        uint256 expectedOut = (inUsd1e18 * (10 ** IDecimals(tokenOut).decimals())) / outPx;
        return (expectedOut * (BPS - maxSlippageBps)) / BPS;
    }

    function _minOutFor(Swap[] calldata swaps, address t) internal pure returns (uint256) {
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn == t) return swaps[i].minOut;
        }
        return 0;
    }

    function _dataFor(Swap[] calldata swaps, address t) internal pure returns (bytes memory) {
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn == t) return swaps[i].data;
        }
        return "";
    }
}
