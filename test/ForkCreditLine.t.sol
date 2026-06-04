// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {KittenCreditLineManager} from "../src/credit/KittenCreditLineManager.sol";
import {NestCreditLineManager} from "../src/credit/NestCreditLineManager.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MarketParams} from "../src/libraries/Types.sol";

/// @notice Live-state validation: deploy KittenCreditLineManager against the REAL HyperEVM
///         KITTEN Voter + Pyth and compute a real veNFT's credit line. Confirms the gross
///         (earned + claimed) fix yields a sane, nonzero line matching Phase 0 magnitudes.
/// @dev Run: forge test --match-path test/ForkCreditLine.t.sol -vv  (needs hyperevm RPC).
contract ForkCreditLineTest is Test {
    address constant PYTH = 0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc;
    address constant KITTEN_VOTER = 0xb7F7053F7e6c210e6777D5BA758E4b3ECa6C88A0;
    address constant NEST_VOTER = 0x566bdc5444fd5fe5d93ec379Bd66eC861ddbA901;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant UETH = 0xBe6727B535545C67d5cAa73dEa54865B92CF7907;

    bytes32 constant HYPE_FEED = 0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b;
    bytes32 constant USDC_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant USDT_FEED = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
    bytes32 constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // deployed adapters (read isPermanentLock()/lockEnd() for the maturity-matched horizon)
    address constant NEST_ADAPTER = 0x63BA0cf6b4bf32A1c4E3C1C9076a5dadB7F216c1;
    address constant KITTEN_ADAPTER = 0x295D025258E72dA9203F3aAA777Fe61B297af415;

    KittenCreditLineManager mgr;
    NestCreditLineManager nestMgr;
    MarketParams nestParams;
    MarketParams kittenParams;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("hyperevm"), 36_930_600);
        nestParams.veAdapter = NEST_ADAPTER; // permanent veNEST -> full horizon
        kittenParams.veAdapter = KITTEN_ADAPTER; // long veKITTEN whale locks -> full horizon

        address[] memory t = new address[](4);
        bytes32[] memory f = new bytes32[](4);
        t[0] = WHYPE;
        f[0] = HYPE_FEED;
        t[1] = USDC;
        f[1] = USDC_FEED;
        t[2] = USDT0;
        f[2] = USDT_FEED;
        t[3] = UETH;
        f[3] = ETH_FEED;

        // generous staleness/confidence for a read-only sanity check on a forked block
        mgr = new KittenCreditLineManager(
            IPyth(PYTH), KITTEN_VOTER, USDC_FEED, 6, 4, 8, 8_000, 30 days, 10_000, t, f
        );
        // NEST: window 2 keeps the (18-pool) fork loop fast.
        nestMgr = new NestCreditLineManager(
            IPyth(PYTH), NEST_VOTER, USDC_FEED, 6, 2, 8, 8_000, 30 days, 10_000, t, f
        );
    }

    function test_fork_nest_realWhaleCreditLine() public view {
        uint256 line2 = nestMgr.creditLine(nestParams, 2);
        uint256 line5 = nestMgr.creditLine(nestParams, 5);
        console2.log("veNEST #2 credit line (USDC, 6dp):", line2);
        console2.log("veNEST #5 credit line (USDC, 6dp):", line5);
        assertGt(line2, 0, "veNEST #2 must have a nonzero on-chain credit line");
        assertLt(line2, 50_000_000e6, "credit line implausibly large");
    }

    function test_fork_realWhaleCreditLine() public view {
        // veKITTEN #2 and #3 are active whale voters (Phase 0).
        uint256 line2 = mgr.creditLine(kittenParams, 2);
        uint256 line3 = mgr.creditLine(kittenParams, 3);
        console2.log("veKITTEN #2 credit line (USDC, 6dp):", line2);
        console2.log("veKITTEN #3 credit line (USDC, 6dp):", line3);
        assertGt(line2, 0, "whale #2 must have a nonzero on-chain credit line");
        assertGt(line3, 0, "whale #3 must have a nonzero on-chain credit line");
        // sanity ceiling: a single position shouldn't exceed a few million USDC here.
        assertLt(line2, 5_000_000e6, "credit line implausibly large");
    }
}
