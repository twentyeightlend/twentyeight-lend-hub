// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedCollateralMarket} from "../src/WrappedCollateralMarket.sol";
import {MockOracle, MintableERC20} from "./mocks/OracleMocks.sol";

contract WrappedCollateralMarketTest is Test {
    WrappedCollateralMarket mkt;
    MockOracle oracle;
    MintableERC20 usdc; // 6 dec loan
    MintableERC20 wve; // 18 dec collateral

    address owner = address(0x9);
    address treasury = address(0x8);
    address lender = address(0x1);
    address borrower = address(0x2);
    address liquidator = address(0x3);

    uint256 constant LLTV = 0.5e18; // 50%
    uint256 constant BONUS = 1.08e18; // 8%
    // price (1e36) for wveNEST=$1, USDC=$1, collat 18dec / loan 6dec => 1e24
    uint256 constant PRICE_1USD = 1e24;

    function setUp() public {
        usdc = new MintableERC20(6);
        wve = new MintableERC20(18);
        oracle = new MockOracle();
        oracle.setPrice(PRICE_1USD);
        mkt = new WrappedCollateralMarket(
            address(usdc), address(wve), address(oracle), address(0), LLTV, BONUS, owner, treasury
        );

        usdc.mint(lender, 1_000e6);
        vm.prank(lender);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(lender);
        mkt.supply(1_000e6, lender);

        wve.mint(borrower, 100e18);
        vm.prank(borrower);
        wve.approve(address(mkt), type(uint256).max);
        vm.prank(borrower);
        mkt.supplyCollateral(100e18, borrower); // $100 collateral
    }

    function test_borrow_withinLtv() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower); // 50% of $100
        assertEq(usdc.balanceOf(borrower), 50e6);
        assertTrue(mkt.isHealthy(borrower));
    }

    function test_borrow_overLtv_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(WrappedCollateralMarket.Unhealthy.selector);
        mkt.borrow(50e6 + 1e6, borrower);
    }

    function test_withdrawCollateral_breakingHealth_reverts() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower);
        vm.prank(borrower);
        vm.expectRevert(WrappedCollateralMarket.Unhealthy.selector);
        mkt.withdrawCollateral(1e18, borrower); // would drop collateral below requirement
    }

    function test_repay_thenWithdraw() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower);
        usdc.mint(borrower, 50e6);
        vm.prank(borrower);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(borrower);
        mkt.repay(50e6, borrower);
        vm.prank(borrower);
        mkt.withdrawCollateral(100e18, borrower);
        (uint128 col, uint128 bs) = mkt.position(borrower);
        assertEq(col, 0);
        assertEq(bs, 0);
    }

    function test_liquidate_seizesWithBonus() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower); // at max LTV
        // price drops 30% -> $0.70 collateral -> value $70, maxBorrow $35 < $50 => unhealthy
        oracle.setPrice((PRICE_1USD * 70) / 100);
        assertTrue(!mkt.isHealthy(borrower));

        usdc.mint(liquidator, 100e6);
        vm.prank(liquidator);
        usdc.approve(address(mkt), type(uint256).max);

        (uint128 colBefore,) = mkt.position(borrower);
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = mkt.liquidate(borrower, 20e18); // seize 20 wveNEST

        // liquidator paid `repaid` USDC and received `seized` collateral worth more (the bonus)
        assertEq(wve.balanceOf(liquidator), seized);
        uint256 seizedValue = (seized * ((PRICE_1USD * 70) / 100)) / 1e36; // loan-wei value
        assertApproxEqRel(seizedValue, (repaid * BONUS) / 1e18, 1e15, "bonus applied");
        (uint128 colAfter, uint128 bsAfter) = mkt.position(borrower);
        assertEq(colAfter, colBefore - uint128(seized));
        assertGt(bsAfter, 0); // partial liquidation left some debt
    }

    function test_liquidate_badDebtSocialized() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower);
        // price crashes 70% -> collateral $30, far below $50 debt
        oracle.setPrice((PRICE_1USD * 30) / 100);
        assertTrue(!mkt.isHealthy(borrower));

        usdc.mint(liquidator, 100e6);
        vm.prank(liquidator);
        usdc.approve(address(mkt), type(uint256).max);

        uint128 supplyBefore = mkt.totalSupplyAssets();
        vm.prank(liquidator);
        (, uint256 repaid) = mkt.liquidate(borrower, type(uint256).max); // seize all

        (uint128 colAfter, uint128 bsAfter) = mkt.position(borrower);
        assertEq(colAfter, 0, "all collateral seized");
        assertEq(bsAfter, 0, "remaining debt written off");
        // lenders absorbed the shortfall: supply dropped by the bad debt (debt - repaid)
        assertLt(mkt.totalSupplyAssets(), supplyBefore, "bad debt socialized to lenders");
        assertLt(repaid, 50e6, "repaid less than original debt");
    }

    function test_pause_blocksNewRiskAllowsExit() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower);

        vm.prank(owner);
        mkt.pause();

        // new risk blocked
        vm.prank(borrower);
        vm.expectRevert(WrappedCollateralMarket.MarketPaused.selector);
        mkt.borrow(1e6, borrower);
        vm.prank(lender);
        usdc.mint(lender, 1e6);
        vm.prank(lender);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(WrappedCollateralMarket.MarketPaused.selector);
        mkt.supply(1e6, lender);

        // exit still works
        usdc.mint(borrower, 50e6);
        vm.prank(borrower);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(borrower);
        mkt.repay(50e6, borrower);
        vm.prank(borrower);
        mkt.withdrawCollateral(100e18, borrower);
        (uint128 col,) = mkt.position(borrower);
        assertEq(col, 0);
    }

    function test_pause_onlyOwner() public {
        vm.prank(borrower);
        vm.expectRevert(WrappedCollateralMarket.NotOwner.selector);
        mkt.pause();
    }

    function test_liquidate_oracleDown_usesEmergencyPrice() public {
        vm.prank(borrower);
        mkt.borrow(50e6, borrower);
        oracle.setReverts(true); // primary oracle down

        // no emergency price -> liquidation can't proceed
        usdc.mint(liquidator, 100e6);
        vm.prank(liquidator);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(liquidator);
        vm.expectRevert(WrappedCollateralMarket.OracleUnavailable.selector);
        mkt.liquidate(borrower, 20e18);

        // owner sets a fallback price that makes the position unhealthy -> liquidation proceeds
        vm.prank(owner);
        mkt.setEmergencyPrice((PRICE_1USD * 60) / 100); // $0.60
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = mkt.liquidate(borrower, 20e18);
        assertGt(seized, 0);
        assertGt(repaid, 0);
    }

    function test_debtFreeWithdrawCollateral_worksWhenOracleDown() public {
        // borrower has collateral but NO debt; oracle down must not block collateral recovery
        oracle.setReverts(true);
        vm.prank(borrower);
        mkt.withdrawCollateral(100e18, borrower);
        (uint128 col,) = mkt.position(borrower);
        assertEq(col, 0);
    }

    function test_liquidate_healthy_reverts() public {
        vm.prank(borrower);
        mkt.borrow(40e6, borrower); // healthy (under 50%)
        vm.prank(liquidator);
        vm.expectRevert(WrappedCollateralMarket.MarketHealthy.selector);
        mkt.liquidate(borrower, 10e18);
    }
}
