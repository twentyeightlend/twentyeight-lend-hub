// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {VeTwapOracle} from "../src/oracles/VeTwapOracle.sol";

/// @notice Live-state validation of the NEST/KITTEN TWAP oracle against the real Algebra pools.
/// @dev Run: forge test --match-path test/ForkOracle.t.sol -vv (needs hyperevm RPC; pinned block
///      ages out of the non-archive node — bump it when re-running).
contract ForkOracleTest is Test {
    address constant PYTH = 0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant NEST = 0x07c57E32a3C29D5659bda1d3EFC2E7BF004E3035;
    address constant KITTEN = 0x618275F8EFE54c2afa87bfB9F210A52F0fF89364;
    address constant NEST_WHYPE_POOL = 0x535F30F50eBDa33575242C38B976E681D13db6Fa;
    address constant KITTEN_WHYPE_POOL = 0x71d1FDE797e1810711E4C9abcFcA6Ef04C266196;
    bytes32 constant HYPE_FEED = 0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("hyperevm"), 36_930_600);
    }

    function test_fork_nestPrice() public {
        VeTwapOracle o = new VeTwapOracle(
            NEST_WHYPE_POOL, NEST, WHYPE, 18, 18, PYTH, HYPE_FEED, 1800, 20_000, 30 days, 10_000
        );
        uint256 p = o.priceUsd1e18();
        console2.log("NEST USD (1e18):", p);
        // expect roughly $0.005 .. $0.20
        assertGt(p, 0.005e18, "NEST too low");
        assertLt(p, 0.20e18, "NEST too high");
    }

    function test_fork_kittenPrice() public {
        VeTwapOracle o = new VeTwapOracle(
            KITTEN_WHYPE_POOL, KITTEN, WHYPE, 18, 18, PYTH, HYPE_FEED, 1800, 20_000, 30 days, 10_000
        );
        uint256 p = o.priceUsd1e18();
        console2.log("KITTEN USD (1e18):", p);
        // expect roughly $0.0002 .. $0.02
        assertGt(p, 0.0002e18, "KITTEN too low");
        assertLt(p, 0.02e18, "KITTEN too high");
    }
}
