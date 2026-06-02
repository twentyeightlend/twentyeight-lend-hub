// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {SelfRepayEngine} from "../src/SelfRepayEngine.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager, MockSwapRouter} from "./mocks/Mocks.sol";
import {MockPyth} from "./mocks/CreditMocks.sol";

contract SelfRepayTest is Test {
    using MarketParamsLib for MarketParams;

    LendingCore core;
    SelfRepayEngine engine;
    MockSwapRouter router;
    MockERC20 usdc;
    MockERC20 reward;
    MockVeAdapter adapter;
    MockCreditManager cm;
    MarketParams params;
    Id id;

    address owner = address(0xA11CE);
    address treasury = address(0x7);
    address lender = address(0x1);
    address borrower = address(0x2);
    uint256 constant TOKEN_ID = 42;
    uint256 constant CREDIT = 500e6;
    uint256 constant TREASURY_BPS = 500; // 5%

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        reward = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(CREDIT);
        router = new MockSwapRouter(1, 1, true); // reward -> usdc 1:1
        // reward + usdc priced at $1 so the oracle floor is active (engine only swaps priced tokens).
        MockPyth pyth = new MockPyth();
        bytes32 REWARD_FEED = bytes32(uint256(11));
        bytes32 USDC_FEED = bytes32(uint256(12));
        pyth.setPrice(REWARD_FEED, 1e8, 1e5, -8);
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8);
        address[] memory ft = new address[](2);
        bytes32[] memory ff = new bytes32[](2);
        ft[0] = address(reward);
        ff[0] = REWARD_FEED;
        ft[1] = address(usdc);
        ff[1] = USDC_FEED;
        engine = new SelfRepayEngine(
            address(core), address(router), treasury, TREASURY_BPS,
            address(pyth), 200, 1 days, 10_000, ft, ff
        );

        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(engine), address(0));

        // liquidity
        usdc.mint(lender, 10_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);

        // borrower draws full credit line
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, CREDIT, borrower);

        // router must hold usdc to pay swaps; adapter holds reward to harvest
        usdc.mint(address(router), 1_000e6);
        reward.mint(address(adapter), 100e6);
        adapter.setReward(address(reward));
    }

    function _debt() internal view returns (uint256) {
        (, uint128 shares,,) = core.position(id, TOKEN_ID);
        (,, uint128 tba, uint128 tbs,,) = core.market(id);
        if (tbs == 0) return 0;
        // toAssetsUp: shares*(tba+VIRTUAL_ASSETS)/(tbs+VIRTUAL_SHARES), rounded up.
        uint256 num = uint256(shares) * (uint256(tba) + 1);
        uint256 den = uint256(tbs) + 1e6;
        return (num + den - 1) / den;
    }

    function test_selfRepay_reducesDebtAndPaysTreasury() public {
        uint256 debtBefore = _debt();
        assertApproxEqAbs(debtBefore, CREDIT, 2);

        SelfRepayEngine.Swap[] memory swaps = new SelfRepayEngine.Swap[](1);
        swaps[0] = SelfRepayEngine.Swap({tokenIn: address(reward), minOut: 95e6, data: ""});

        engine.selfRepay(params, TOKEN_ID, swaps);

        // 100 reward -> 100 usdc; 5% treasury = 5; 95 repays debt.
        assertEq(usdc.balanceOf(treasury), 5e6, "treasury cut");
        uint256 debtAfter = _debt();
        assertApproxEqAbs(debtBefore - debtAfter, 95e6, 2, "debt reduced by repay");
        assertEq(reward.balanceOf(address(engine)), 0, "no stuck reward");
        assertEq(usdc.balanceOf(address(engine)), 0, "no stuck loanToken");
    }

    function test_selfRepay_surplusRefundsBorrower() public {
        // give a big harvest so it exceeds debt and refunds the borrower
        reward.mint(address(adapter), 900e6); // total 1000 reward
        usdc.mint(address(router), 2_000e6);

        SelfRepayEngine.Swap[] memory swaps = new SelfRepayEngine.Swap[](1);
        swaps[0] = SelfRepayEngine.Swap({tokenIn: address(reward), minOut: 0, data: ""});

        uint256 debtBefore = _debt();
        engine.selfRepay(params, TOKEN_ID, swaps);

        assertEq(_debt(), 0, "debt cleared");
        // 1000 usdc out; 5% = 50 treasury; 950 available; debt ~500 repaid; ~450 refunded.
        assertEq(usdc.balanceOf(treasury), 50e6, "treasury cut");
        assertGt(usdc.balanceOf(borrower), CREDIT, "borrower got refund on top of borrow");
        assertApproxEqAbs(usdc.balanceOf(borrower), CREDIT + (950e6 - debtBefore), 3, "refund amount");
    }

    function test_harvestFor_onlyEngine() public {
        vm.expectRevert(LendingCore.NotEngine.selector);
        core.harvestFor(params, TOKEN_ID);
    }

    function test_selfRepay_noDebtReverts() public {
        // clear the debt first
        usdc.mint(borrower, CREDIT + 10e6);
        vm.startPrank(borrower);
        usdc.approve(address(core), type(uint256).max);
        core.repay(params, TOKEN_ID, CREDIT + 10e6); // core caps to actual debt -> 0 left
        vm.stopPrank();
        (, uint128 sh,,) = core.position(id, TOKEN_ID);
        assertEq(sh, 0);

        SelfRepayEngine.Swap[] memory swaps = new SelfRepayEngine.Swap[](0);
        vm.expectRevert(SelfRepayEngine.NoDebt.selector);
        engine.selfRepay(params, TOKEN_ID, swaps);
    }
}
