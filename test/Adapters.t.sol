// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KittenAdapter} from "../src/adapters/KittenAdapter.sol";
import {NestAdapter} from "../src/adapters/NestAdapter.sol";

/// @notice Guards the CRITICAL fix: adapters MUST implement onERC721Received or the escrow's
///         safeTransferFrom into them (custody) reverts and the protocol is inoperable.
contract AdaptersTest is Test {
    bytes4 constant MAGIC = 0x150b7a02; // IERC721Receiver.onERC721Received.selector

    function test_kittenAdapter_isERC721Receiver() public {
        KittenAdapter a =
            new KittenAdapter(address(1), address(2), address(3), address(4), address(5));
        assertEq(a.onERC721Received(address(0), address(0), 0, ""), MAGIC);
    }

    function test_nestAdapter_isERC721Receiver() public {
        NestAdapter a = new NestAdapter(address(1), address(2), address(3), address(4), address(5));
        assertEq(a.onERC721Received(address(0), address(0), 0, ""), MAGIC);
    }
}
