// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KittenAdapter} from "../src/adapters/KittenAdapter.sol";
import {MintableERC20} from "./mocks/OracleMocks.sol";

/// @dev Reward token whose transfer ALWAYS reverts (blacklist/hostile token simulation).
contract RevertingERC20 {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev Mock KittenSwap votingReward: exposes a reward-token list and mints them on claim.
contract MockVotingReward {
    address[] public rewards;
    mapping(address => uint256) public amt;

    function setRewards(address[] memory r, uint256[] memory a) external {
        rewards = r;
        for (uint256 i; i < r.length; ++i) {
            amt[r[i]] = a[i];
        }
    }

    function getRewardList() external view returns (address[] memory) {
        return rewards;
    }

    /// @dev Pays every reward token to `to` (mimics Voter pulling fees to the veNFT owner).
    function claimTo(address to) external {
        for (uint256 i; i < rewards.length; ++i) {
            uint256 a = amt[rewards[i]];
            if (a != 0) RevertingERC20(rewards[i]).mint(to, a); // mint() shares the same selector
        }
    }
}

contract MockKittenVoter {
    address public pool = address(0xBEEF);
    address public votingReward;

    function setVotingReward(address vr) external {
        votingReward = vr;
    }

    function getCurrentPeriod() external pure returns (uint256) {
        return 2;
    }

    function getTokenIdVotes(uint256, uint256)
        external
        view
        returns (address[] memory pools, uint256[] memory votes)
    {
        pools = new address[](1);
        votes = new uint256[](1);
        pools[0] = pool;
        votes[0] = 1;
    }

    function getGauge(address)
        external
        view
        returns (address, bool, address, bool, address)
    {
        return (pool, true, votingReward, true, pool);
    }

    function claimVotingRewardBatch(address[] calldata vrs, uint256) external {
        for (uint256 i; i < vrs.length; ++i) {
            MockVotingReward(vrs[i]).claimTo(msg.sender); // mints to the adapter (caller)
        }
    }
}

/// @notice Regression for audit H1: a voted gauge exposing MORE reward tokens than the old fixed
///         `vrs.length*4` buffer must still forward EVERY token (no silent stranding), plus the
///         try/catch sweep + guardian rescue hardening.
contract KittenHarvestTest is Test {
    KittenAdapter adapter;
    MockKittenVoter voter;
    MockVotingReward vr;
    address recipient = address(0xCAFE);
    address guardian = address(0x6);

    function setUp() public {
        voter = new MockKittenVoter();
        vr = new MockVotingReward();
        voter.setVotingReward(address(vr));
        // core = this test contract so we can call onlyCore harvest()
        adapter = new KittenAdapter(address(this), address(0x2), address(voter), address(0x3), guardian);
    }

    function test_harvest_forwardsAllRewardTokens_noStranding() public {
        // 6 reward tokens on ONE voted gauge — old buffer (1*4=4) would strand 2.
        uint256 n = 6;
        address[] memory toks = new address[](n);
        uint256[] memory amts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            toks[i] = address(new MintableERC20(18));
            amts[i] = (i + 1) * 1e18;
        }
        vr.setRewards(toks, amts);

        (address[] memory outT, uint256[] memory outA) = adapter.harvest(1, recipient);

        assertEq(outT.length, n, "all 6 tokens reported");
        for (uint256 i; i < n; ++i) {
            assertEq(MintableERC20(toks[i]).balanceOf(recipient), amts[i], "token forwarded");
            assertEq(outA[i], amts[i], "amount reported");
        }
    }

    function test_harvest_revertingTokenDoesNotBrick() public {
        // 5 good tokens + 1 hostile (reverts on transfer): good ones still forwarded, no revert.
        address[] memory toks = new address[](6);
        uint256[] memory amts = new uint256[](6);
        for (uint256 i; i < 5; ++i) {
            toks[i] = address(new MintableERC20(18));
            amts[i] = 1e18;
        }
        address bad = address(new RevertingERC20());
        toks[5] = bad;
        amts[5] = 7e18;
        vr.setRewards(toks, amts);

        adapter.harvest(1, recipient); // must NOT revert despite the hostile token

        for (uint256 i; i < 5; ++i) {
            assertEq(MintableERC20(toks[i]).balanceOf(recipient), 1e18, "good token forwarded");
        }
        // hostile token stranded in the adapter (transfer-out reverts), recipient got none
        assertEq(RevertingERC20(bad).balanceOf(recipient), 0, "hostile not forwarded");
        assertEq(RevertingERC20(bad).balanceOf(address(adapter)), 7e18, "hostile stranded, rescuable");
    }

    function test_rescueERC20_guardianOnly() public {
        MintableERC20 stray = new MintableERC20(18);
        stray.mint(address(adapter), 5e18);

        vm.expectRevert(KittenAdapter.OnlyGuardian.selector);
        adapter.rescueERC20(address(stray), recipient, 5e18);

        vm.prank(guardian);
        adapter.rescueERC20(address(stray), recipient, 5e18);
        assertEq(stray.balanceOf(recipient), 5e18, "guardian rescued stray token");
    }
}
