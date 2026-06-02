// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {KinkIRM} from "../src/irm/KinkIRM.sol";
import {MarketParams, Market, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "./mocks/Mocks.sol";

/// @notice End-to-end interest accrual on a LendingCore credit-line market wired to the real KinkIRM.
///         Proves: lenders' redeemable value rises by exactly the borrow-side interest; the protocol
///         fee mints supply shares to the treasury; and the curve produces the expected APR.
contract InterestAccrualTest is Test {
    using MarketParamsLib for MarketParams;

    LendingCore core;
    MockERC20 usdc;
    MockVeAdapter adapter;
    MockCreditManager cm;
    KinkIRM irm;
    MarketParams params;
    Id id;

    address owner = address(0xA11CE);
    address treasury = address(0x7);
    address lender = address(0x1);
    address borrower = address(0x2);
    uint256 constant TOKEN_ID = 42;
    uint256 constant CREDIT = 500e6;

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(CREDIT);
        // launch curve: base 2%, kink 14% @ 90% util, max 100% @ 100%
        irm = new KinkIRM(0.02e18, 0.14e18, 1.0e18, 0.90e18);
        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(0), address(0));

        usdc.mint(lender, 10_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
    }

    function _mkt() internal view returns (Market memory m) {
        (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee) =
            core.market(id);
    }

    function _setup1yrLoan() internal returns (uint256 borrowed) {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower); // 500/1000 = 50% utilization
        return CREDIT;
    }

    function test_lenderEarnsExactlyBorrowInterest() public {
        _setup1yrLoan();
        Market memory before = _mkt();
        uint256 rate = irm.borrowRate(params, before); // per-second WAD at 50% util
        uint256 elapsed = 365 days;
        uint256 expectedInterest = (uint256(before.totalBorrowAssets) * rate * elapsed) / 1e18;
        assertGt(expectedInterest, 0, "rate must be > 0");

        vm.warp(block.timestamp + elapsed);
        core.accrueInterest(params);

        Market memory aft = _mkt();
        // borrow and supply both grow by exactly the interest (fee == 0 at launch)
        assertEq(aft.totalBorrowAssets, before.totalBorrowAssets + expectedInterest, "borrow += interest");
        assertEq(aft.totalSupplyAssets, before.totalSupplyAssets + expectedInterest, "supply += interest");
        assertEq(aft.totalSupplyShares, before.totalSupplyShares, "no fee -> no new shares");
    }

    function test_realizedAprMatchesCurve() public {
        _setup1yrLoan();
        Market memory before = _mkt();
        vm.warp(block.timestamp + 365 days);
        core.accrueInterest(params);
        uint256 interest = _mkt().totalBorrowAssets - before.totalBorrowAssets;
        // 50% util on (2% base, 14% kink @ 90%) => 2% + 12%*(0.5/0.9) = 8.666% APR
        // interest/borrowed should be ~0.08666 (allow 0.1% for per-second integer rounding)
        uint256 aprBps = (interest * 10_000) / before.totalBorrowAssets;
        assertApproxEqAbs(aprBps, 866, 5, "realized ~8.66% APR at 50% util");
    }

    function test_protocolFeeMintsToTreasury() public {
        vm.prank(owner);
        core.setFee(params, 0.10e18); // 10% of interest to treasury
        _setup1yrLoan();
        vm.warp(block.timestamp + 365 days);
        core.accrueInterest(params);
        assertGt(core.supplyShares(id, treasury), 0, "treasury earns fee shares");
    }
}
