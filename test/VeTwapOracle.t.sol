// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VeTwapOracle} from "../src/oracles/VeTwapOracle.sol";
import {MockAlgebraPlugin, MockAlgebraPool} from "./mocks/OracleMocks.sol";
import {MockPyth} from "./mocks/CreditMocks.sol";

contract VeTwapOracleTest is Test {
    bytes32 constant WHYPE_FEED = bytes32(uint256(9));

    MockPyth pyth;
    MockAlgebraPlugin plugin;
    // token (NEST-like) < quote (WHYPE) by address
    address tokenLow = address(0x1111);
    address quote = address(0x2222);
    address tokenHigh = address(0x3333); // KITTEN-like, > quote

    uint32 constant WINDOW = 1800;

    function setUp() public {
        pyth = new MockPyth();
        pyth.setPrice(WHYPE_FEED, 74e8, 1e6, -8); // WHYPE = $74
        plugin = new MockAlgebraPlugin();
    }

    function _oracle(address token, address q) internal returns (VeTwapOracle) {
        MockAlgebraPool pool = new MockAlgebraPool(address(plugin), token, q);
        return new VeTwapOracle(
            address(pool), token, q, 18, 18, address(pyth), WHYPE_FEED, WINDOW, 5000, 1 days, 5000
        );
    }

    function test_tickZero_priceEqualsWhype_token0() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        plugin.setCumulatives(0, 0, 0); // long & short mean tick 0 -> WHYPE/token = 1
        assertApproxEqRel(o.priceUsd1e18(), 74e18, 1e15); // ~$74, 0.1% tol
    }

    function test_tickZero_priceEqualsWhype_token1Ordering() public {
        VeTwapOracle o = _oracle(tokenHigh, quote);
        plugin.setCumulatives(0, 0, 0);
        assertApproxEqRel(o.priceUsd1e18(), 74e18, 1e15);
    }

    function test_positiveTwapTick_priceAboveWhype() public {
        // steady mean tick +6932 (long==short) -> ratio ~2 -> token worth ~2 WHYPE -> ~$148
        VeTwapOracle o = _oracle(tokenLow, quote);
        int56 meanTick = 6932;
        int56 nowCum = meanTick * int56(uint56(WINDOW));
        int56 shortCum = nowCum - meanTick * int56(uint56(WINDOW / 4));
        plugin.setCumulatives(0, shortCum, nowCum);
        uint256 p = o.priceUsd1e18();
        assertApproxEqRel(p, 148e18, 2e16); // ~2x $74, 2% tol (tick->price rounding)
    }

    function test_shortVsLongDeviationGuard_reverts() public {
        // long mean tick 0, but short-window mean = +6000 (recent spike) -> deviation > 5000
        VeTwapOracle o = _oracle(tokenLow, quote);
        plugin.setCumulatives(0, -6000 * int56(uint56(WINDOW / 4)), 0);
        vm.expectRevert(VeTwapOracle.TickDeviationTooHigh.selector);
        o.priceUsd1e18();
    }

    function test_constructor_rejectsMismatchedTokens() public {
        // pool pair is (tokenLow, quote); deploying with tokenHigh (not in the pool) must revert
        // to prevent a silently-inverted price.
        MockAlgebraPool pool = new MockAlgebraPool(address(plugin), tokenLow, quote);
        vm.expectRevert(VeTwapOracle.BadConfig.selector);
        new VeTwapOracle(
            address(pool), tokenHigh, quote, 18, 18, address(pyth), WHYPE_FEED, WINDOW, 5000, 1 days, 5000
        );
    }

    function test_notInitialized_reverts() public {
        VeTwapOracle o = _oracle(tokenLow, quote);
        plugin.setInitialized(false);
        vm.expectRevert(VeTwapOracle.NotInitialized.selector);
        o.priceUsd1e18();
    }
}
