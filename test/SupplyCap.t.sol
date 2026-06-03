// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "./mocks/Mocks.sol";

contract SupplyCapTest is Test {
    using MarketParamsLib for MarketParams;

    LendingCore core;
    MockERC20 usdc;
    MockVeAdapter adapter;
    MockCreditManager cm;
    MarketParams params;
    Id id;

    address owner = address(0xA11CE);
    address treasury = address(0x7);
    address lender = address(0x1);

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(500e6);
        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(0), address(0));

        usdc.mint(lender, 1_000_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
    }

    // --- enforcement ---

    function test_uncappedByDefault() public {
        assertEq(core.supplyCap(id), 0);
        vm.prank(lender);
        core.supply(params, 100_000e6, lender); // large supply, no cap → ok
    }

    function test_supply_revertsOverCap() public {
        vm.prank(owner);
        core.setSupplyCap(params, 1_000e6);

        vm.prank(lender);
        core.supply(params, 1_000e6, lender); // exactly at cap → ok

        vm.prank(lender);
        vm.expectRevert(LendingCore.SupplyCapExceeded.selector);
        core.supply(params, 1, lender); // 1 over → revert
    }

    // --- setter access + validation ---

    function test_setCap_onlyOwner() public {
        vm.prank(lender);
        vm.expectRevert(LendingCore.NotOwner.selector);
        core.setSupplyCap(params, 1_000e6);
    }

    function test_setCap_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendingCore.InvalidCap.selector);
        core.setSupplyCap(params, 0); // cannot return to uncapped via setter
    }

    function test_enterGuardedMode_isFree() public {
        // uncapped -> finite is a tightening; allowed with no interval wait.
        vm.prank(owner);
        core.setSupplyCap(params, 10_000e6);
        assertEq(core.supplyCap(id), 10_000e6);
    }

    // --- rate-limited raises ---

    function test_raise_tooSoon_reverts() public {
        vm.prank(owner);
        core.setSupplyCap(params, 10_000e6); // enter guarded mode, clock starts now

        vm.prank(owner);
        vm.expectRevert(LendingCore.CapRaiseTooSoon.selector);
        core.setSupplyCap(params, 20_000e6); // same block → too soon
    }

    function test_raise_tooLarge_reverts() public {
        vm.prank(owner);
        core.setSupplyCap(params, 10_000e6);

        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(LendingCore.CapRaiseTooLarge.selector);
        core.setSupplyCap(params, 20_001e6); // > 2x → revert
    }

    function test_raise_withinLimits_afterInterval() public {
        vm.prank(owner);
        core.setSupplyCap(params, 10_000e6);

        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        core.setSupplyCap(params, 20_000e6); // exactly 2x after a day → ok
        assertEq(core.supplyCap(id), 20_000e6);

        // and again must wait another interval
        vm.prank(owner);
        vm.expectRevert(LendingCore.CapRaiseTooSoon.selector);
        core.setSupplyCap(params, 21_000e6);
    }

    function test_lower_alwaysAllowed() public {
        vm.prank(owner);
        core.setSupplyCap(params, 10_000e6);

        // immediate lowering, no interval wait
        vm.prank(owner);
        core.setSupplyCap(params, 2_000e6);
        assertEq(core.supplyCap(id), 2_000e6);
    }
}
