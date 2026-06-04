// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeTwapOracle} from "../src/oracles/VeTwapOracle.sol";
import {MockAlgebraPlugin, MockAlgebraPool} from "./mocks/OracleMocks.sol";
import {AdvPyth} from "./StressPyth.t.sol";

/// @notice Offensive stress of the NEST/KITTEN TWAP oracle: tick-math overflow, the short-vs-long
///         manipulation guard, and the Pyth WHYPE leg. The attacker's goal is a wrong price; ours
///         is that the oracle either prices correctly or reverts — never silently mis-prices.
contract StressTwapTest is Test {
    bytes32 constant WHYPE = bytes32(uint256(9));
    AdvPyth pyth;
    MockAlgebraPlugin plugin;

    address tokenLow = address(0x1111); // token0 ordering (< quote)
    address quote = address(0x2222);
    address tokenHigh = address(0x3333); // token1 ordering (> quote)

    uint32 constant WINDOW = 1800;
    uint32 constant SHORT = 450; // WINDOW/4
    int24 constant MAXDEV = 5000;
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;

    function setUp() public {
        pyth = new AdvPyth();
        pyth.setNow(1_000_000);
        pyth.set(WHYPE, 74e8, 1e6, -8, 1_000_000); // WHYPE = $74, fresh, tight conf
        plugin = new MockAlgebraPlugin();
    }

    function _oracle(address token, address q) internal returns (VeTwapOracle) {
        MockAlgebraPool pool = new MockAlgebraPool(address(plugin), token, q);
        return new VeTwapOracle(address(pool), token, q, 18, 18, address(pyth), WHYPE, WINDOW, MAXDEV, 1 days, 5000);
    }

    /// @dev Set a steady mean tick T (long == short, so the deviation guard always passes).
    function _steady(int24 t) internal {
        int56 cumNow = int56(t) * int56(uint56(WINDOW));
        int56 cumShort = cumNow - int56(t) * int56(uint56(SHORT));
        plugin.setCumulatives(0, cumShort, cumNow);
    }

    /// @dev Set long mean L and short mean S independently.
    function _longShort(int24 L, int24 S) internal {
        int56 cumNow = int56(L) * int56(uint56(WINDOW));
        int56 cumShort = cumNow - int56(S) * int56(uint56(SHORT));
        plugin.setCumulatives(0, cumShort, cumNow);
    }

    // --- a steady tick across the realistic range always prices nonzero and never reverts ---
    function testFuzz_steadyTick_noRevertNoZero(int24 t) public {
        t = int24(bound(int256(t), -200_000, 200_000));
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(t);
        uint256 p = o.priceUsd1e18();
        assertGt(p, 0, "realistic tick prices nonzero");
    }

    // --- tick-math at the absolute bounds must not panic/overflow (both X192 and X128 branches) ---
    function test_extremeTicks_noOverflow() public {
        VeTwapOracle lo = _oracle(tokenLow, quote);
        VeTwapOracle hi = _oracle(tokenHigh, quote);
        _steady(MAX_TICK);
        lo.priceUsd1e18(); // token0 ordering, huge ratio
        hi.priceUsd1e18(); // token1 ordering, inverted
        _steady(MIN_TICK);
        lo.priceUsd1e18(); // may floor to 0, but MUST NOT revert
        hi.priceUsd1e18();
    }

    // --- THE manipulation guard: a recent (short-window) spike away from the long mean reverts ---
    function testFuzz_deviationGuard(int24 L, int24 S) public {
        L = int24(bound(int256(L), -100_000, 100_000));
        S = int24(bound(int256(S), -200_000, 200_000));
        VeTwapOracle o = _oracle(tokenLow, quote);
        _longShort(L, S);
        int24 dev = S > L ? S - L : L - S;
        if (dev > MAXDEV) {
            vm.expectRevert(VeTwapOracle.TickDeviationTooHigh.selector);
            o.priceUsd1e18();
        } else {
            assertGt(o.priceUsd1e18(), 0, "within tolerance prices fine");
        }
    }

    // --- classic attack: push the pool for the short window only -> guard rejects ---
    function test_attack_recentPushRejected() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        // long mean steady at NEST-like -79327; attacker spikes the last quarter-window up +50000
        _longShort(-79327, -79327 + 50_000);
        vm.expectRevert(VeTwapOracle.TickDeviationTooHigh.selector);
        o.priceUsd1e18();
    }

    // --- WHYPE Pyth leg adversarial: stale / non-positive / wide-conf must revert price() ---
    function test_whypeLeg_stale_reverts() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(-79327);
        pyth.setNow(2_000_000); // WHYPE price now ~1M s old vs 1 day maxAge
        vm.expectRevert(); // stale
        o.priceUsd1e18();
    }

    function test_whypeLeg_nonPositive_reverts() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(-79327);
        pyth.set(WHYPE, -1, 0, -8, 1_000_000);
        vm.expectRevert();
        o.priceUsd1e18();
    }

    function test_whypeLeg_wideConf_reverts() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(-79327);
        pyth.set(WHYPE, 74e8, 74e8, -8, 1_000_000); // conf == price (100%) >> 50% tol
        vm.expectRevert();
        o.priceUsd1e18();
    }

    // --- price scales linearly with the WHYPE USD leg (no hidden leverage) ---
    function test_priceLinearInWhype() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(-79327);
        uint256 p1 = o.priceUsd1e18();
        pyth.set(WHYPE, 148e8, 1e6, -8, 1_000_000); // double WHYPE
        uint256 p2 = o.priceUsd1e18();
        assertApproxEqRel(p2, p1 * 2, 1e12, "doubles with WHYPE");
    }

    function test_notInitialized_reverts() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        _steady(-79327);
        plugin.setInitialized(false);
        vm.expectRevert(VeTwapOracle.NotInitialized.selector);
        o.priceUsd1e18();
    }
}
