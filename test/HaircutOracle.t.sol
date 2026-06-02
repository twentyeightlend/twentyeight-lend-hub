// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HaircutOracle} from "../src/oracles/HaircutOracle.sol";
import {MockVeTwap, MockOracle} from "./mocks/OracleMocks.sol";
import {MockPyth} from "./mocks/CreditMocks.sol";

contract HaircutOracleTest is Test {
    bytes32 constant USDC_FEED = bytes32(uint256(1));
    MockVeTwap nest;
    MockPyth pyth;

    function setUp() public {
        nest = new MockVeTwap();
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8); // USDC = $1
    }

    function _oracle(uint256 dlomBps) internal returns (HaircutOracle) {
        // collateral 18 dec (wveNEST), loan 6 dec (USDC)
        return new HaircutOracle(address(nest), address(pyth), USDC_FEED, dlomBps, 18, 6, 1 days, 5000);
    }

    function test_noDiscount_dollarParity() public {
        nest.setPrice(1e18); // NEST = $1 -> wveNEST = $1
        HaircutOracle o = _oracle(0);
        // 1e36 price s.t. 1 wveNEST (1e18) = 1 USDC (1e6): price = 1e24
        assertEq(o.price(), 1e24);
    }

    function test_dlom50_halvesValue() public {
        nest.setPrice(1e18);
        HaircutOracle o = _oracle(5000); // 50%
        assertEq(o.price(), 5e23); // half of 1e24
    }

    function test_realNestPrice_withDlom40() public {
        nest.setPrice(0.0257e18); // ~ real NEST
        HaircutOracle o = _oracle(4000); // 40%
        // collat USD = 0.0257 * 0.6 = 0.01542 ; 1 wveNEST = 0.01542 USDC
        // price = 0.01542 * 1e24 = 1.542e22
        assertApproxEqRel(o.price(), 1.542e22, 1e12);
    }
}
