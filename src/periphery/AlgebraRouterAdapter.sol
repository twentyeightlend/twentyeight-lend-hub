// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ISwapRouter} from "../SelfRepayEngine.sol";

/// @dev KittenSwap Algebra-Integral SwapRouter (0x4e73E421480a7E0C24fB3c11019254edE194f736).
interface IAlgebraSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title AlgebraRouterAdapter
/// @notice Bridges SelfRepayEngine's generic `swap(tokenIn,amountIn,tokenOut,minOut,data)` to the
///         KittenSwap Algebra-Integral SwapRouter. `data` is the Algebra path
///         (abi.encodePacked(tokenA,tokenB[,tokenC...]) — no fee bytes); empty `data` => direct
///         tokenIn->tokenOut hop. The engine already enforces its oracle-derived `minOut`, which is
///         passed through as `amountOutMinimum` for defense-in-depth.
contract AlgebraRouterAdapter is ISwapRouter {
    using SafeTransferLib for address;

    IAlgebraSwapRouter public immutable router;

    error NoOutput();

    constructor(address _router) {
        router = IAlgebraSwapRouter(_router);
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes calldata data)
        external
        returns (uint256 out)
    {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.safeApproveWithRetry(address(router), amountIn);

        bytes memory path = data.length != 0 ? data : abi.encodePacked(tokenIn, tokenOut);
        out = router.exactInput(
            IAlgebraSwapRouter.ExactInputParams({
                path: path,
                recipient: msg.sender, // proceeds go straight back to the caller (the engine)
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        if (out == 0) revert NoOutput();
    }
}
