// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Fund with output tokens before use. Exercises the ordinary approve-and-call router flow.
contract SwapRouterStub {
    using SafeERC20 for IERC20;

    address public caller;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSuccess;
    bytes public callbackResult;

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        caller = msg.sender;
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(recipient, amountOut);
        if (callbackTarget != address(0)) (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
    }

    function fail() external pure {
        revert("SWAP_FAILED");
    }
}
