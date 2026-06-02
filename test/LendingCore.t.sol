// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "./mocks/Mocks.sol";

contract LendingCoreTest is Test {
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
    address borrower = address(0x2);
    uint256 constant TOKEN_ID = 42;
    uint256 constant CREDIT = 500e6; // 500 USDC

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(CREDIT);
        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(0), address(0));

        usdc.mint(lender, 10_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
    }

    function test_createMarket_setsState() public view {
        (,,,, uint128 lastUpdate,) = core.market(id);
        assertGt(lastUpdate, 0);
        assertEq(core.creditManager(id), address(cm));
    }

    function test_supply_mintsShares() public {
        vm.prank(lender);
        uint256 shares = core.supply(params, 1_000e6, lender);
        assertGt(shares, 0);
        assertEq(usdc.balanceOf(address(core)), 1_000e6);
        assertEq(core.supplyShares(id, lender), shares);
    }

    function test_borrow_withinCreditLine() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);

        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower);
        assertEq(usdc.balanceOf(borrower), CREDIT);
    }

    function test_borrow_overCreditLine_reverts() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        vm.prank(borrower);
        vm.expectRevert(LendingCore.CreditLineExceeded.selector);
        core.borrow(params, TOKEN_ID, CREDIT + 1, borrower);
    }

    function test_borrow_notPositionOwner_reverts() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        vm.prank(lender);
        vm.expectRevert(LendingCore.NotPositionOwner.selector);
        core.borrow(params, TOKEN_ID, 1e6, lender);
    }

    function test_repay_thenWithdrawCollateral() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower);

        // borrower repays full
        vm.prank(borrower);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(borrower);
        core.repay(params, TOKEN_ID, CREDIT);

        (, uint128 borrowShares,,) = core.position(id, TOKEN_ID);
        assertEq(borrowShares, 0);

        vm.prank(borrower);
        core.withdrawCollateral(params, TOKEN_ID, borrower);
        (address b,,,) = core.position(id, TOKEN_ID);
        assertEq(b, address(0));
    }

    function test_withdrawCollateral_withDebt_reverts() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 100e6, borrower);

        vm.prank(borrower);
        vm.expectRevert(LendingCore.PositionNotEmpty.selector);
        core.withdrawCollateral(params, TOKEN_ID, borrower);
    }

    function test_vote_borrowerCanSteer() public {
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        bytes memory voteData = abi.encode(new address[](0), new uint256[](0));
        vm.prank(borrower);
        core.vote(params, TOKEN_ID, voteData);
        assertEq(adapter.voteCount(), 1);
        assertEq(adapter.lastVoteData(), voteData);
    }

    function test_keeperCanVote() public {
        address keeper = address(0xCAFE);
        MarketParams memory p2 = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(1), // distinct id
            lltv: 0
        });
        core.createMarket(p2, address(cm), address(0), keeper);
        vm.prank(borrower);
        core.supplyCollateral(p2, TOKEN_ID, borrower);

        vm.prank(keeper);
        core.vote(p2, TOKEN_ID, abi.encode(new address[](0), new uint256[](0)));
        assertEq(adapter.voteCount(), 1);
    }

    function test_vote_nonBorrowerReverts() public {
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        vm.prank(lender);
        vm.expectRevert(LendingCore.NotAuthorizedToVote.selector);
        core.vote(params, TOKEN_ID, abi.encode(new address[](0), new uint256[](0)));
    }

    function test_borrow_rejectsNearExpiryLock() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp + 1 days); // inside the 7-day maturity buffer

        vm.prank(borrower);
        vm.expectRevert(LendingCore.LockTooCloseToExpiry.selector);
        core.borrow(params, TOKEN_ID, 100e6, borrower);
    }

    function test_borrow_permanentLockExempt() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);

        adapter.setPermanent(true);
        adapter.setLockEnd(0); // permanent => maturity guard skipped

        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 100e6, borrower);
        assertEq(usdc.balanceOf(borrower), 100e6);
    }

    function test_refreshCreditLine_caches() public {
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        core.refreshCreditLine(params, TOKEN_ID);
        (,, uint128 line, uint64 expiry) = core.position(id, TOKEN_ID);
        assertEq(uint256(line), CREDIT);
        assertGt(uint256(expiry), block.timestamp);
    }

    function test_paused_blocksSupply() public {
        adapter.setPaused(true);
        vm.prank(lender);
        vm.expectRevert(LendingCore.AdapterPaused.selector);
        core.supply(params, 100e6, lender);
    }

    function test_paused_blocksNewRiskButAllowsExit() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower);

        adapter.setPaused(true);

        // new debt blocked
        vm.prank(borrower);
        vm.expectRevert(LendingCore.AdapterPaused.selector);
        core.borrow(params, TOKEN_ID, 1e6, borrower);

        // exit still works: repay + withdraw collateral + lender withdraw
        vm.prank(borrower);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(borrower);
        core.repay(params, TOKEN_ID, CREDIT);
        vm.prank(borrower);
        core.withdrawCollateral(params, TOKEN_ID, borrower);
        (address b,,,) = core.position(id, TOKEN_ID);
        assertEq(b, address(0));

        vm.prank(lender);
        core.withdraw(params, 500e6, lender, lender);
    }

    function test_twoStepOwnership() public {
        address newOwner = address(0xBEEF);
        vm.prank(owner);
        core.transferOwnership(newOwner);
        assertEq(core.owner(), owner, "owner unchanged until accepted");
        assertEq(core.pendingOwner(), newOwner);
        // wrong acceptor reverts
        vm.prank(lender);
        vm.expectRevert(LendingCore.NotOwner.selector);
        core.acceptOwnership();
        // pending owner accepts
        vm.prank(newOwner);
        core.acceptOwnership();
        assertEq(core.owner(), newOwner);
        assertEq(core.pendingOwner(), address(0));
    }

    function test_withdraw_overLiquidity_reverts() public {
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower);

        // 1000 supplied, 500 borrowed => only 500 idle; withdrawing 600 must revert.
        vm.prank(lender);
        vm.expectRevert(LendingCore.InsufficientLiquidity.selector);
        core.withdraw(params, 600e6, lender, lender);
    }
}
