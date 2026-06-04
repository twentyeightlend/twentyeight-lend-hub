// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {LenderVault} from "../src/LenderVault.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "./mocks/Mocks.sol";

contract LenderVaultTest is Test {
    using MarketParamsLib for MarketParams;

    LendingCore core;
    LenderVault vault;
    MockERC20 usdc;
    MockVeAdapter adapter;
    MockCreditManager cm;
    MarketParams params;
    Id id;

    address owner = address(0xA11CE);
    address treasury = address(0x7);
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(0);
        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(0), address(0));
        vault = new LenderVault(address(core), params, "28 USDC Lender", "28-lUSDC");

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_decimals_matchUnderlying() public view {
        // Audit L7: the share token must report the underlying's real decimals (6 for USDC),
        // not a misleading default of 18, to avoid 1e12 normalization errors in integrators.
        assertEq(vault.decimals(), 6);
    }

    function test_deposit_routesToCore() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(500e6, alice);
        assertGt(shares, 0);
        // vault holds no idle asset; it's all in the core.
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(core)), 500e6);
        assertEq(vault.totalAssets(), 500e6);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_redeem_pullsFromCore() public {
        vm.prank(alice);
        vault.deposit(500e6, alice);

        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(bal, alice, alice);
        assertApproxEqAbs(assets, 500e6, 1);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 1);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_twoDepositors_shareProRata() public {
        vm.prank(alice);
        vault.deposit(400e6, alice);
        vm.prank(bob);
        vault.deposit(600e6, bob);

        assertEq(vault.totalAssets(), 1_000e6);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 400e6, 1);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 600e6, 1);
    }
}
