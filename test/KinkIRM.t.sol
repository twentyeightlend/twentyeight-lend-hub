// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KinkIRM} from "../src/irm/KinkIRM.sol";
import {MarketParams, Market} from "../src/libraries/Types.sol";

contract KinkIRMTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant YEAR = 365 days;

    // base 1%, kink 8% @ 90% util, max 60% @ 100% util
    KinkIRM irm;
    MarketParams params; // unused by the IRM

    function setUp() public {
        irm = new KinkIRM(0.01e18, 0.08e18, 0.60e18, 0.90e18);
    }

    function _mkt(uint128 supply, uint128 borrow) internal pure returns (Market memory m) {
        m.totalSupplyAssets = supply;
        m.totalBorrowAssets = borrow;
    }

    function testReferencePoints() public view {
        assertEq(irm.aprAtUtilization(0), 0.01e18, "u=0 -> base");
        assertEq(irm.aprAtUtilization(0.90e18), 0.08e18, "u=kink -> kinkApr");
        assertEq(irm.aprAtUtilization(1e18), 0.60e18, "u=100% -> maxApr");
        // u=95% -> 8% + (60-8)%*(0.05/0.10) = 34%
        assertEq(irm.aprAtUtilization(0.95e18), 0.34e18, "u=95% midpoint above kink");
    }

    function testPerSecondMatchesApr() public view {
        Market memory m = _mkt(1000e6, 900e6); // 90% utilization
        uint256 rate = irm.borrowRate(params, m);
        assertEq(rate, irm.borrowRateView(params, m), "view == nonview");
        assertEq(rate, uint256(0.08e18) / YEAR, "per-second = kinkApr/year at 90% util");
    }

    function testZeroSupplyIsBaseRate() public view {
        Market memory m = _mkt(0, 0);
        assertEq(irm.borrowRate(params, m), uint256(0.01e18) / YEAR, "no supply -> base apr");
    }

    function testUtilizationClampedTo100() public view {
        Market memory m = _mkt(100e6, 200e6); // borrow > supply
        assertEq(irm.borrowRate(params, m), uint256(0.60e18) / YEAR, "u>100% clamps to maxApr");
    }

    function testMonotonicInUtilization(uint128 supply, uint128 borrowA, uint128 borrowB) public view {
        supply = uint128(bound(supply, 1, type(uint128).max));
        borrowA = uint128(bound(borrowA, 0, supply));
        borrowB = uint128(bound(borrowB, 0, supply));
        if (borrowA > borrowB) (borrowA, borrowB) = (borrowB, borrowA);
        uint256 rA = irm.borrowRate(params, _mkt(supply, borrowA));
        uint256 rB = irm.borrowRate(params, _mkt(supply, borrowB));
        assertGe(rB, rA, "higher utilization -> higher or equal rate");
    }

    function testRateNeverExceedsClamp(uint128 supply, uint128 borrow) public view {
        supply = uint128(bound(supply, 1, type(uint128).max));
        borrow = uint128(bound(borrow, 0, supply));
        // markets clamp at 1e12/sec; our configured maxApr must stay under it.
        assertLe(irm.borrowRate(params, _mkt(supply, borrow)), uint256(1e12), "within market clamp");
    }

    function testConstructorRejectsNonMonotonic() public {
        vm.expectRevert(KinkIRM.NonMonotonicRates.selector);
        new KinkIRM(0.10e18, 0.08e18, 0.60e18, 0.90e18); // base > kink
    }

    function testConstructorRejectsBadOptimal() public {
        vm.expectRevert(KinkIRM.BadOptimalUtilization.selector);
        new KinkIRM(0.01e18, 0.08e18, 0.60e18, 1e18); // optimal must be < 100%
    }

    function testConstructorRejectsMaxRateTooHigh() public {
        vm.expectRevert(KinkIRM.MaxRateTooHigh.selector);
        // maxApr/year > 1e12/sec  => maxApr > ~3.15e19 (3150%/yr)
        new KinkIRM(0.01e18, 0.08e18, 40e18, 0.90e18);
    }
}
