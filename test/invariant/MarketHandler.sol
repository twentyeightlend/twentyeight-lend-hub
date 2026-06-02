// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedCollateralMarket} from "../../src/WrappedCollateralMarket.sol";
import {MockOracle, MintableERC20} from "../mocks/OracleMocks.sol";

/// @notice Random supply/borrow/repay/liquidate + price-move sequences against the wveNEST market,
///         so invariants can assert solvency holds even through liquidations and bad debt.
contract MarketHandler is Test {
    WrappedCollateralMarket public mkt;
    MintableERC20 public usdc;
    MintableERC20 public wve;
    MockOracle public oracle;

    address[3] public actors = [address(0xB1), address(0xB2), address(0xB3)];
    uint256 constant BASE_PRICE = 1e24; // wveNEST = $1

    constructor(WrappedCollateralMarket _mkt, MintableERC20 _usdc, MintableERC20 _wve, MockOracle _oracle) {
        mkt = _mkt;
        usdc = _usdc;
        wve = _wve;
        oracle = _oracle;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 3];
    }

    function _debt(address a) internal view returns (uint256) {
        (, uint128 bs) = mkt.position(a);
        uint256 tba = mkt.totalBorrowAssets();
        uint256 tbs = mkt.totalBorrowShares();
        if (tbs == 0) return 0;
        return (uint256(bs) * (tba + 1) + (tbs + 1e6) - 1) / (tbs + 1e6);
    }

    function _liquidity() internal view returns (uint256) {
        uint256 tsa = mkt.totalSupplyAssets();
        uint256 tba = mkt.totalBorrowAssets();
        return tsa > tba ? tsa - tba : 0;
    }

    function setPrice(uint256 seed) external {
        uint256 p = bound(seed, BASE_PRICE / 5, BASE_PRICE * 3); // $0.20 .. $3
        oracle.setPrice(p);
    }

    function supply(uint256 s, uint256 amt) external {
        address a = _actor(s);
        amt = bound(amt, 1e6, 1_000_000e6);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(mkt), amt);
        try mkt.supply(amt, a) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 s, uint256 amt) external {
        address a = _actor(s);
        uint256 cap = _liquidity();
        if (cap == 0) return;
        amt = bound(amt, 0, cap);
        if (amt == 0) return;
        vm.prank(a);
        try mkt.withdraw(amt, a, a) {} catch {}
    }

    function supplyCollateral(uint256 s, uint256 amt) external {
        address a = _actor(s);
        amt = bound(amt, 1e18, 1_000_000e18);
        wve.mint(a, amt);
        vm.startPrank(a);
        wve.approve(address(mkt), amt);
        try mkt.supplyCollateral(amt, a) {} catch {}
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 s, uint256 amt) external {
        address a = _actor(s);
        (uint128 col,) = mkt.position(a);
        if (col == 0) return;
        amt = bound(amt, 1, col);
        vm.prank(a);
        try mkt.withdrawCollateral(amt, a) {} catch {}
    }

    function borrow(uint256 s, uint256 amt) external {
        address a = _actor(s);
        uint256 cap = _liquidity();
        if (cap == 0) return;
        amt = bound(amt, 1, cap);
        vm.prank(a);
        try mkt.borrow(amt, a) {} catch {}
    }

    function repay(uint256 s, uint256 amt) external {
        address a = _actor(s);
        uint256 d = _debt(a);
        if (d == 0) return;
        amt = bound(amt, 1, d);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(mkt), amt);
        try mkt.repay(amt, a) {} catch {}
        vm.stopPrank();
    }

    function liquidate(uint256 liqS, uint256 borS, uint256 seize) external {
        address liq = _actor(liqS);
        address bor = _actor(borS);
        (uint128 col,) = mkt.position(bor);
        if (col == 0) return;
        seize = bound(seize, 1, col);
        usdc.mint(liq, 1_000_000e6);
        vm.startPrank(liq);
        usdc.approve(address(mkt), type(uint256).max);
        try mkt.liquidate(bor, seize) {} catch {}
        vm.stopPrank();
    }
}
