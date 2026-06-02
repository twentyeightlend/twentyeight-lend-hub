// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AlgebraRouterAdapter, IAlgebraSwapRouter} from "../src/periphery/AlgebraRouterAdapter.sol";
import {MintableERC20} from "./mocks/OracleMocks.sol";

/// @dev Mock Algebra SwapRouter: pulls amountIn from caller, pays out amountIn*num/den of tokenOut.
contract MockAlgebraSwapRouter is IAlgebraSwapRouter {
    address public tokenIn;
    address public tokenOut;
    uint256 public num;
    uint256 public den;

    function config(address _in, address _out, uint256 _num, uint256 _den) external {
        tokenIn = _in;
        tokenOut = _out;
        num = _num;
        den = _den;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        MintableERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * num) / den;
        require(out >= p.amountOutMinimum, "minOut");
        MintableERC20(tokenOut).mint(p.recipient, out);
    }
}

contract AlgebraRouterAdapterTest is Test {
    AlgebraRouterAdapter adapter;
    MockAlgebraSwapRouter router;
    MintableERC20 reward;
    MintableERC20 usdc;
    address engine = address(0xE);

    function setUp() public {
        router = new MockAlgebraSwapRouter();
        adapter = new AlgebraRouterAdapter(address(router));
        reward = new MintableERC20(18);
        usdc = new MintableERC20(6);
        router.config(address(reward), address(usdc), 1, 1); // 1:1 in 18->6 dec terms (mock)
    }

    function test_swap_forwardsAndReturnsToCaller() public {
        // engine holds reward, approves adapter, calls swap; output must land on the engine
        reward.mint(engine, 100e18);
        vm.startPrank(engine);
        reward.approve(address(adapter), type(uint256).max);
        uint256 out = adapter.swap(address(reward), 100e18, address(usdc), 90e18, "");
        vm.stopPrank();
        assertEq(out, 100e18);
        assertEq(usdc.balanceOf(engine), 100e18, "output to caller");
        assertEq(reward.balanceOf(address(adapter)), 0, "no stuck input");
    }

    function test_swap_respectsMinOut() public {
        router.config(address(reward), address(usdc), 1, 2); // pays only half
        reward.mint(engine, 100e18);
        vm.startPrank(engine);
        reward.approve(address(adapter), type(uint256).max);
        vm.expectRevert(bytes("minOut"));
        adapter.swap(address(reward), 100e18, address(usdc), 90e18, ""); // expects >=90, gets 50
        vm.stopPrank();
    }
}
