// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {KittenCreditLineManager} from "../src/credit/KittenCreditLineManager.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter} from "./mocks/Mocks.sol";
import {MockPyth, MockDecToken, MockKittenVoter, MockKittenVotingReward} from "./mocks/CreditMocks.sol";

/// @notice End-to-end: the REAL KittenCreditLineManager drives the REAL LendingCore borrow cap.
contract IntegrationTest is Test {
    using MarketParamsLib for MarketParams;

    bytes32 constant USDC_FEED = bytes32(uint256(1));

    LendingCore core;
    KittenCreditLineManager mgr;
    MockPyth pyth;
    MockERC20 usdc;
    MockVeAdapter adapter;
    MockKittenVoter voter;
    MockKittenVotingReward vr;
    address usdcReward;
    MarketParams params;
    Id id;

    address owner = address(0xA11CE);
    address treasury = address(0x7);
    address lender = address(0x1);
    address borrower = address(0x2);
    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20(); // 6 dec loanToken
        adapter = new MockVeAdapter(address(usdc));
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8); // $1
        usdcReward = address(new MockDecToken(6));

        voter = new MockKittenVoter();
        vr = new MockKittenVotingReward();
        address poolA = address(0xA);
        voter.setPeriod(100);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        voter.setPools(pools);
        voter.setGauge(poolA, address(vr));
        // flat $100/period gross over the 4-period window -> MIN $100
        for (uint256 p = 96; p <= 99; ++p) {
            vr.setClaimed(p, usdcReward, 100e6);
        }

        address[] memory t = new address[](1);
        bytes32[] memory f = new bytes32[](1);
        t[0] = usdcReward;
        f[0] = USDC_FEED;
        // window 4, multiplier 8, safety 80% -> 100*8*0.8 = $640 credit line
        mgr = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, 6, 4, 8, 8_000, 1 days, 5_000, t, f
        );

        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(mgr), address(0), address(0));

        usdc.mint(lender, 10_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(lender);
        core.supply(params, 5_000e6, lender);

        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
    }

    function test_manager_computesExpectedLine() public view {
        assertApproxEqAbs(mgr.creditLine(params, TOKEN_ID), 640e6, 1e3);
    }

    function test_borrow_upToOnChainCreditLine() public {
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 640e6, borrower);
        assertEq(usdc.balanceOf(borrower), 640e6);
    }

    function test_borrow_overOnChainCreditLine_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(LendingCore.CreditLineExceeded.selector);
        core.borrow(params, TOKEN_ID, 640e6 + 1e6, borrower);
    }

    function test_creditLine_cachedOnPosition() public {
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 100e6, borrower);
        (,, uint128 cached,) = core.position(id, TOKEN_ID);
        assertApproxEqAbs(uint256(cached), 640e6, 1e3);
    }

    /// @notice End-to-end: a near-expiry (non-permanent) lock caps the on-chain BORROW, not just
    ///         the view — the loan can never exceed what the lock can self-repay before expiry.
    function test_borrow_cappedByMaturityMatch() public {
        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp + 2 weeks); // only 2 epochs of life left
        // full would be $640; maturity-match caps to 2/8 -> ~$160
        assertApproxEqAbs(mgr.creditLine(params, TOKEN_ID), 160e6, 1e3, "maturity-capped line");
        // drawing the old full $640 now exceeds the capped line
        vm.prank(borrower);
        vm.expectRevert(LendingCore.CreditLineExceeded.selector);
        core.borrow(params, TOKEN_ID, 640e6, borrower);
        // within the capped line succeeds
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 160e6, borrower);
        assertEq(usdc.balanceOf(borrower), 160e6);
    }
}
