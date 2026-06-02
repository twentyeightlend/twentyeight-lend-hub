// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReceiptWrapper} from "../src/ReceiptWrapper.sol";
import {HaircutOracle} from "../src/oracles/HaircutOracle.sol";
import {WrappedCollateralMarket} from "../src/WrappedCollateralMarket.sol";
import {MockWrapVe, MockWrapVoter} from "./mocks/WrapperMocks.sol";
import {MockVeTwap} from "./mocks/OracleMocks.sol";
import {MockPyth} from "./mocks/CreditMocks.sol";
import {MintableERC20} from "./mocks/OracleMocks.sol";

/// @notice Full "borrow against the moat" loop with the REAL ReceiptWrapper + HaircutOracle +
///         WrappedCollateralMarket composed together (only veNEST, NEST-price, Pyth are mocked).
contract EndToEndTest is Test {
    bytes32 constant USDC_FEED = bytes32(uint256(1));

    MockWrapVe ve;
    MockWrapVoter voter;
    ReceiptWrapper wrapper; // == wveNEST
    MockVeTwap nestOracle;
    MockPyth pyth;
    HaircutOracle haircut;
    WrappedCollateralMarket mkt;
    MintableERC20 usdc;
    MintableERC20 nest;

    address guardian = address(0x6);
    address keeper = address(0x7);
    address yield = address(0x8);
    address owner = address(0x9);
    address treasury = address(0xA);
    address alice = address(0x1);
    address lender = address(0x2);
    address liquidator = address(0x3);

    function setUp() public {
        // --- wrapper (wveNEST) ---
        ve = new MockWrapVe();
        voter = new MockWrapVoter();
        nest = new MintableERC20(18);
        wrapper = new ReceiptWrapper(address(ve), address(voter), address(nest), guardian, keeper, yield);

        // --- price stack: NEST=$1 via TWAP mock, USDC=$1 via Pyth, DLOM 0 for clean math ---
        nestOracle = new MockVeTwap();
        nestOracle.setPrice(1e18); // NEST $1
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8); // USDC $1
        haircut = new HaircutOracle(address(nestOracle), address(pyth), USDC_FEED, 0, 18, 6, 1 days, 5000);

        // --- market: borrow USDC against wveNEST ---
        usdc = new MintableERC20(6);
        mkt = new WrappedCollateralMarket(
            address(usdc), address(wrapper), address(haircut), address(0), 0.5e18, 1.08e18, owner, treasury
        );

        usdc.mint(lender, 1_000e6);
        vm.prank(lender);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(lender);
        mkt.supply(1_000e6, lender);
    }

    function _wrap(address user, uint256 tokenId, uint256 amount) internal {
        ve.mintLock(tokenId, user, amount, true); // permanent
        vm.prank(user);
        wrapper.deposit(tokenId);
    }

    function test_fullLoop_wrap_collateralize_borrow_repay_withdraw() public {
        _wrap(alice, 1, 100e18); // alice gets 100 wveNEST (=$100)
        assertEq(wrapper.balanceOf(alice), 100e18);

        vm.prank(alice);
        wrapper.approve(address(mkt), type(uint256).max);
        vm.prank(alice);
        mkt.supplyCollateral(100e18, alice);

        // wveNEST=$1, collateral $100, LTV 50% -> borrow up to $50
        vm.prank(alice);
        mkt.borrow(50e6, alice);
        assertEq(usdc.balanceOf(alice), 50e6);
        assertTrue(mkt.isHealthy(alice));

        // repay + reclaim collateral
        usdc.mint(alice, 50e6);
        vm.prank(alice);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(alice);
        mkt.repay(50e6, alice);
        vm.prank(alice);
        mkt.withdrawCollateral(100e18, alice);
        assertEq(wrapper.balanceOf(alice), 100e18, "collateral returned as wveNEST");
    }

    function test_fullLoop_priceDrop_liquidation() public {
        _wrap(alice, 1, 100e18);
        vm.prank(alice);
        wrapper.approve(address(mkt), type(uint256).max);
        vm.prank(alice);
        mkt.supplyCollateral(100e18, alice);
        vm.prank(alice);
        mkt.borrow(50e6, alice); // max LTV

        // NEST price drops to $0.60 -> wveNEST $0.60 -> collateral $60, maxBorrow $30 < $50
        nestOracle.setPrice(0.6e18);
        assertTrue(!mkt.isHealthy(alice));

        usdc.mint(liquidator, 100e6);
        vm.prank(liquidator);
        usdc.approve(address(mkt), type(uint256).max);
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = mkt.liquidate(alice, 30e18);

        assertGt(seized, 0);
        assertGt(repaid, 0);
        assertEq(wrapper.balanceOf(liquidator), seized, "liquidator got wveNEST collateral");
    }
}
