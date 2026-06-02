// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedCollateralMarket} from "../../src/WrappedCollateralMarket.sol";
import {MockOracle, MintableERC20} from "../mocks/OracleMocks.sol";
import {MarketHandler} from "./MarketHandler.sol";

/// @notice Solvency + accounting invariants for the wveNEST market, exercised through random
///         supply/borrow/repay/liquidate sequences and price moves (incl. bad-debt scenarios).
contract MarketInvariantsTest is Test {
    WrappedCollateralMarket mkt;
    MockOracle oracle;
    MintableERC20 usdc;
    MintableERC20 wve;
    MarketHandler handler;

    function setUp() public {
        usdc = new MintableERC20(6);
        wve = new MintableERC20(18);
        oracle = new MockOracle();
        oracle.setPrice(1e24); // $1
        mkt = new WrappedCollateralMarket(
            address(usdc), address(wve), address(oracle), address(0), 0.5e18, 1.08e18, address(this), address(0xFEE)
        );
        handler = new MarketHandler(mkt, usdc, wve, oracle);
        targetContract(address(handler));
    }

    /// Idle loanToken must always cover (supply - borrow), even after bad debt.
    function invariant_loanSolvency() public view {
        uint256 tsa = mkt.totalSupplyAssets();
        uint256 tba = mkt.totalBorrowAssets();
        uint256 owed = tsa > tba ? tsa - tba : 0;
        assertGe(usdc.balanceOf(address(mkt)), owed, "market underfunded");
    }

    /// Can never owe more than supplied.
    function invariant_supplyGeBorrow() public view {
        assertGe(mkt.totalSupplyAssets(), mkt.totalBorrowAssets(), "borrow exceeds supply");
    }

    /// Collateral held >= sum of recorded position collateral.
    function invariant_collateralBacked() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            (uint128 col,) = mkt.position(_actor(i));
            sum += col;
        }
        assertGe(wve.balanceOf(address(mkt)), sum, "collateral not backed");
    }

    function invariant_supplySharesConserved() public view {
        uint256 sum = mkt.supplyShares(address(0xFEE));
        for (uint256 i; i < 3; ++i) {
            sum += mkt.supplyShares(_actor(i));
        }
        assertEq(sum, mkt.totalSupplyShares(), "supply shares drift");
    }

    function invariant_borrowSharesConserved() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            (, uint128 bs) = mkt.position(_actor(i));
            sum += bs;
        }
        assertEq(sum, mkt.totalBorrowShares(), "borrow shares drift");
    }

    /// Bad debt is always cleared: no position has debt with zero collateral.
    function invariant_noUncollateralizedDebt() public view {
        for (uint256 i; i < 3; ++i) {
            (uint128 col, uint128 bs) = mkt.position(_actor(i));
            if (bs > 0) assertGt(col, 0, "debt with no collateral");
        }
    }

    function _actor(uint256 i) internal view returns (address) {
        return handler.actors(i);
    }
}
