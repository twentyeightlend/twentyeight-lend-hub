// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {SelfRepayEngine} from "../src/SelfRepayEngine.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {MockERC20, MockVeAdapter, MockCreditManager, MockSwapRouter} from "./mocks/Mocks.sol";
import {MockPyth} from "./mocks/CreditMocks.sol";

/// @notice Proves H1 fix: the engine enforces a Pyth-derived output floor, so a sandwiching
///         router (ignores minOut) cannot drain a harvest even when the caller passes minOut=0.
contract SelfRepayOracleTest is Test {
    using MarketParamsLib for MarketParams;

    bytes32 constant USDC_FEED = bytes32(uint256(1));
    bytes32 constant REWARD_FEED = bytes32(uint256(2));

    LendingCore core;
    SelfRepayEngine engine;
    MockSwapRouter badRouter; // returns half, ignores minOut
    MockPyth pyth;
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

    function setUp() public {
        core = new LendingCore(owner, treasury);
        usdc = new MockERC20();
        reward = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(500e6);
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8); // $1
        pyth.setPrice(REWARD_FEED, 1e8, 1e5, -8); // $1

        badRouter = new MockSwapRouter(1, 2, false); // returns 50%, ignores minOut (sandwich)

        address[] memory t = new address[](2);
        bytes32[] memory f = new bytes32[](2);
        t[0] = address(reward);
        f[0] = REWARD_FEED;
        t[1] = address(usdc);
        f[1] = USDC_FEED;
        // 1% max slippage; both tokens priced -> floor enforced.
        engine = new SelfRepayEngine(
            address(core), address(badRouter), treasury, 500, address(pyth), 100, 1 days, 5_000, t, f
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

        usdc.mint(lender, 10_000e6);
        vm.prank(lender);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(lender);
        core.supply(params, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(params, TOKEN_ID, borrower);
        vm.prank(borrower);
        core.borrow(params, TOKEN_ID, 500e6, borrower);

        usdc.mint(address(badRouter), 1_000e6);
        reward.mint(address(adapter), 100e6);
        adapter.setReward(address(reward));
    }

    function test_oracleFloor_blocksSandwichEvenWithZeroCallerMinOut() public {
        // 100 reward @ $1 -> oracle expects ~100 USDC; floor = 99 (1% slip). Bad router pays 50.
        SelfRepayEngine.Swap[] memory swaps = new SelfRepayEngine.Swap[](1);
        swaps[0] = SelfRepayEngine.Swap({tokenIn: address(reward), minOut: 0, data: ""}); // attacker sets 0

        vm.expectRevert(SelfRepayEngine.TooLowOutput.selector);
        engine.selfRepay(params, TOKEN_ID, swaps);
    }

    function test_oracleFloor_allowsFairSwap() public {
        // Swap in a fair router (1:1) bound to a fresh market+engine.
        MockSwapRouter fair = new MockSwapRouter(1, 1, false);
        address[] memory t = new address[](2);
        bytes32[] memory f = new bytes32[](2);
        t[0] = address(reward);
        f[0] = REWARD_FEED;
        t[1] = address(usdc);
        f[1] = USDC_FEED;
        SelfRepayEngine eng2 = new SelfRepayEngine(
            address(core), address(fair), treasury, 500, address(pyth), 100, 1 days, 5_000, t, f
        );
        MarketParams memory p2 = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(1), // distinct param -> distinct market id
            lltv: 0
        });
        core.createMarket(p2, address(cm), address(eng2), address(0));
        // fund + position in the new market
        vm.prank(lender);
        core.supply(p2, 1_000e6, lender);
        vm.prank(borrower);
        core.supplyCollateral(p2, 99, borrower);
        vm.prank(borrower);
        core.borrow(p2, 99, 500e6, borrower);
        usdc.mint(address(fair), 1_000e6);
        // adapter already holds 100e6 reward from setUp; harvest sweeps it to eng2.

        SelfRepayEngine.Swap[] memory swaps = new SelfRepayEngine.Swap[](1);
        swaps[0] = SelfRepayEngine.Swap({tokenIn: address(reward), minOut: 0, data: ""});
        eng2.selfRepay(p2, 99, swaps); // fair 1:1 swap clears the oracle floor
        assertEq(usdc.balanceOf(treasury), 5e6); // 5% treasury cut of $100
    }
}
