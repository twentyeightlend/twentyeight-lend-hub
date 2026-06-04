// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedCollateralMarket} from "../src/WrappedCollateralMarket.sol";
import {MockOracle, MintableERC20} from "./mocks/OracleMocks.sol";

/// @dev ERC20 collateral that pays out reward tokens to caller on claim() (mock wveNEST wrapper).
contract MockWrapperToken {
    string public name = "wveNEST";
    string public symbol = "wveNEST";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public reward;
    uint256 public rewardAmt;

    function setReward(address r, uint256 a) external {
        reward = r;
        rewardAmt = a;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function claim() external {
        if (rewardAmt != 0) MintableERC20(reward).mint(msg.sender, rewardAmt);
    }
}

contract CollateralYieldTest is Test {
    WrappedCollateralMarket mkt;
    MockOracle oracle;
    MintableERC20 usdc;
    MintableERC20 reward;
    MockWrapperToken wve;

    address owner = address(0x9);
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        usdc = new MintableERC20(6);
        reward = new MintableERC20(18);
        wve = new MockWrapperToken();
        oracle = new MockOracle();
        oracle.setPrice(1e24);
        mkt = new WrappedCollateralMarket(
            address(usdc), address(wve), address(oracle), address(0), 0.5e18, 1.08e18, owner, address(0x7)
        );
        vm.prank(owner);
        mkt.addCollatRewardToken(address(reward));

        _supply(alice, 400e18);
        _supply(bob, 100e18); // total 500
        wve.setReward(address(reward), 100e18); // claim() pays 100 reward to the market
    }

    function _supply(address who, uint256 amt) internal {
        wve.mint(who, amt);
        vm.startPrank(who);
        wve.approve(address(mkt), type(uint256).max);
        mkt.supplyCollateral(amt, who);
        vm.stopPrank();
    }

    function test_addCollatReward_rejectsLoanToken() public {
        vm.prank(owner);
        vm.expectRevert(WrappedCollateralMarket.BadRewardToken.selector);
        mkt.addCollatRewardToken(address(usdc)); // loanToken comingled with lender liquidity
    }

    function test_yield_proRataAndClaim() public {
        mkt.harvestCollateralRewards(); // market claims 100 reward, STREAMS over REWARD_DURATION
        // nothing earned instantly any more (streaming defeats flash-sandwich)
        assertEq(mkt.earnedCollateralReward(alice, address(reward)), 0, "no instant lump");
        // after the full stream, the 100 is split pro-rata (minus rounding dust)
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(mkt.earnedCollateralReward(alice, address(reward)), 80e18, 1e9, "alice ~80%");
        assertApproxEqAbs(mkt.earnedCollateralReward(bob, address(reward)), 20e18, 1e9, "bob ~20%");

        vm.prank(alice);
        mkt.claimCollateralRewards();
        assertApproxEqAbs(reward.balanceOf(alice), 80e18, 1e9);
        assertEq(mkt.earnedCollateralReward(alice, address(reward)), 0);
    }

    function test_yield_checkpointOnWithdraw() public {
        mkt.harvestCollateralRewards();
        vm.warp(block.timestamp + 7 days); // let the stream complete; alice~80, bob~20
        // bob's collateral changes (withdraw) -> his ~20 must be checkpointed, not lost
        vm.prank(bob);
        mkt.withdrawCollateral(100e18, bob);
        vm.prank(bob);
        mkt.claimCollateralRewards();
        assertApproxEqAbs(reward.balanceOf(bob), 20e18, 1e9, "bob keeps pre-withdraw rewards");
    }

    /// @notice The M1 fix: a flash depositor who deposits, harvests, and exits in one block can no
    ///         longer steal borrowers' accrued voting yield — streaming caps them to ~one block.
    function test_yield_streamingBlocksFlashSandwich() public {
        address attacker = address(0xA);
        // attacker flash-deposits a huge collateral stake, then triggers the harvest
        _supply(attacker, 100_000e18); // dwarfs alice+bob's 500
        mkt.harvestCollateralRewards();
        // same block: attacker immediately tries to claim the lump
        uint256 stolen = mkt.earnedCollateralReward(attacker, address(reward));
        assertEq(stolen, 0, "attacker captures nothing instantly");
        // even one block later, the attacker only gets a stream sliver, not the whole 100
        vm.warp(block.timestamp + 12);
        uint256 sliver = mkt.earnedCollateralReward(attacker, address(reward));
        assertLt(sliver, 1e18, "attacker gets at most a tiny stream slice, not the lump");
    }

    function test_yield_newDepositorNoRetroactive() public {
        mkt.harvestCollateralRewards(); // distributed over alice+bob (500)
        // carol deposits AFTER the harvest -> no share of it
        _supply(address(0x3), 100e18);
        assertEq(mkt.earnedCollateralReward(address(0x3), address(reward)), 0, "no retroactive");
    }
}
