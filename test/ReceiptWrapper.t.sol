// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReceiptWrapper} from "../src/ReceiptWrapper.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {MockWrapVe, MockWrapVoter, MockWrapBribe} from "./mocks/WrapperMocks.sol";

/// @dev Reward token that mints fine but reverts on transfer (blacklist/pause simulation).
contract BlacklistERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("blacklisted");
    }
}

contract ReceiptWrapperTest is Test {
    ReceiptWrapper w;
    MockWrapVe ve;
    MockWrapVoter voter;
    MockERC20 nest;
    MockERC20 reward;

    address guardian = address(0x6);
    address keeper = address(0x7);
    address yield = address(0x8);
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        ve = new MockWrapVe();
        voter = new MockWrapVoter();
        nest = new MockERC20();
        reward = new MockERC20();
        w = new ReceiptWrapper(address(ve), address(voter), address(nest), guardian, keeper, yield);
    }

    function test_deposit_mints1to1_andSetsMaster() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        uint256 minted = w.deposit(1);
        assertEq(minted, 400e18);
        assertEq(w.balanceOf(alice), 400e18);
        assertEq(w.masterId(), 1);
        assertEq(w.totalLocked(), 400e18);
        assertEq(ve.ownerOf(1), address(w));
    }

    function test_secondDeposit_mergesIntoMaster() public {
        ve.mintLock(1, alice, 400e18, true);
        ve.mintLock(2, bob, 100e18, true);
        vm.prank(alice);
        w.deposit(1);
        vm.prank(bob);
        uint256 minted = w.deposit(2);

        assertEq(minted, 100e18);
        assertEq(w.balanceOf(bob), 100e18);
        assertEq(w.masterId(), 1, "master unchanged");
        assertEq(w.totalLocked(), 500e18);
        // token 2 merged into master 1
        assertEq(ve.ownerOf(2), address(0));
    }

    function test_deposit_tokenIdZero_becomesMaster() public {
        // tokenId 0 is legitimate; the wrapper must treat the first deposit as master via a flag.
        ve.mintLock(0, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(0);
        assertTrue(w.masterSet());
        assertEq(w.masterId(), 0);
        assertEq(w.balanceOf(alice), 400e18);

        ve.mintLock(5, bob, 100e18, true);
        vm.prank(bob);
        w.deposit(5); // must merge into master 0, not overwrite
        assertEq(w.totalLocked(), 500e18);
        assertEq(ve.ownerOf(5), address(0), "merged into master");
        assertEq(w.masterId(), 0, "master unchanged");
    }

    function test_deposit_rejectsNonPermanent() public {
        ve.mintLock(1, alice, 400e18, false);
        vm.prank(alice);
        vm.expectRevert(ReceiptWrapper.NotPermanent.selector);
        w.deposit(1);
    }

    function test_deposit_rejectsAttached() public {
        ve.mintLock(1, alice, 400e18, true);
        ve.setAttached(1, true);
        vm.prank(alice);
        vm.expectRevert(ReceiptWrapper.NotPermanent.selector);
        w.deposit(1);
    }

    function test_deposit_rejectsNonOwner() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(bob);
        vm.expectRevert(ReceiptWrapper.NotOwner.selector);
        w.deposit(1);
    }

    function test_pause_blocksDeposit() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(guardian);
        w.pause();
        vm.prank(alice);
        vm.expectRevert(ReceiptWrapper.PausedError.selector);
        w.deposit(1);
    }

    function test_keeperVotes_routesToMaster() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);

        vm.prank(keeper);
        w.vote(new address[](0), new uint256[](0));
        assertEq(voter.voteCount(), 1);
        assertEq(voter.lastVotedToken(), 1);
    }

    function test_vote_onlyKeeper() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);
        vm.prank(alice);
        vm.expectRevert(ReceiptWrapper.OnlyKeeper.selector);
        w.vote(new address[](0), new uint256[](0));
    }

    function test_harvest_sweepsNonAllowlistedToYieldReceiver() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);

        MockWrapBribe bribe = new MockWrapBribe(address(reward));
        voter.config(address(0xA), address(0x6A), address(bribe), address(reward), 123e18);

        // reward NOT allowlisted -> swept to yield sink.
        w.harvest();
        assertEq(reward.balanceOf(yield), 123e18, "non-allowlisted swept");
        assertEq(reward.balanceOf(address(w)), 0, "nothing stuck");
    }

    function _setupReward(uint256 amt) internal returns (MockWrapBribe bribe) {
        bribe = new MockWrapBribe(address(reward));
        voter.config(address(0xA), address(0x6A), address(bribe), address(reward), amt);
        vm.prank(guardian);
        w.addRewardToken(address(reward));
    }

    function test_harvest_distributesAndClaim() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);
        _setupReward(100e18);

        w.harvest(); // 100 reward, supply 400 -> alice earns all
        assertEq(w.earned(alice, address(reward)), 100e18);

        vm.prank(alice);
        w.claim();
        assertEq(reward.balanceOf(alice), 100e18);
        assertEq(w.earned(alice, address(reward)), 0);
    }

    function test_distribution_proRata() public {
        ve.mintLock(1, alice, 400e18, true);
        ve.mintLock(2, bob, 100e18, true);
        vm.prank(alice);
        w.deposit(1);
        vm.prank(bob);
        w.deposit(2); // total 500
        _setupReward(100e18);

        w.harvest(); // 100 / 500
        assertEq(w.earned(alice, address(reward)), 80e18, "alice 80%");
        assertEq(w.earned(bob, address(reward)), 20e18, "bob 20%");
    }

    function test_newHolder_noRetroactiveRewards() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);
        _setupReward(100e18);

        w.harvest(); // alice (sole holder) earns 100
        assertEq(w.earned(alice, address(reward)), 100e18);

        // bob joins AFTER the first harvest -> no retroactive share
        ve.mintLock(2, bob, 100e18, true);
        vm.prank(bob);
        w.deposit(2);
        assertEq(w.earned(bob, address(reward)), 0, "no retroactive");

        w.harvest(); // second 100, now split 400:100 over total 500
        assertEq(w.earned(alice, address(reward)), 180e18, "alice 100 + 80");
        assertEq(w.earned(bob, address(reward)), 20e18, "bob 20");
    }

    function test_transfer_checkpointsRewards() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);
        _setupReward(100e18);

        w.harvest(); // alice earns 100 on her 400
        // alice sends 200 wveNEST to bob; her earned-so-far must be preserved
        vm.prank(alice);
        w.transfer(bob, 200e18);
        assertEq(w.earned(alice, address(reward)), 100e18, "alice keeps pre-transfer rewards");
        assertEq(w.earned(bob, address(reward)), 0, "bob earns only going forward");

        w.harvest(); // another 100 split 200:200
        assertEq(w.earned(alice, address(reward)), 150e18);
        assertEq(w.earned(bob, address(reward)), 50e18);
    }

    /// @notice Audit L2: wveNEST sent to the wrapper itself would sit in the distribution
    ///         denominator forever; the transfer must be rejected.
    function test_transferToSelf_reverts() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);
        vm.prank(alice);
        vm.expectRevert(ReceiptWrapper.SelfTransfer.selector);
        w.transfer(address(w), 1e18);
    }

    /// @notice Audit L1: one blacklisting/paused allowlisted reward token must NOT brick claims of
    ///         the others; its accrual is preserved and recoverable via claimToken later.
    function test_claim_resilientToBlacklistingToken() public {
        ve.mintLock(1, alice, 400e18, true);
        vm.prank(alice);
        w.deposit(1);

        // good token: alice earns 100
        _setupReward(100e18);
        w.harvest();

        // bad token (transfer reverts): allowlist + harvest so alice also accrues it
        BlacklistERC20 bad = new BlacklistERC20();
        voter.config(address(0xA), address(0x6A), address(new MockWrapBribe(address(bad))), address(bad), 50e18);
        vm.prank(guardian);
        w.addRewardToken(address(bad));
        w.harvest();
        assertEq(w.earned(alice, address(bad)), 50e18, "accrued the bad token");

        // batch claim must not revert; good token paid, bad token accrual restored
        vm.prank(alice);
        w.claim();
        assertEq(reward.balanceOf(alice), 100e18, "good token still claimable");
        assertEq(w.earned(alice, address(bad)), 50e18, "bad token preserved, not lost");

        // single-token escape hatch for the good token works independently
        assertEq(w.earned(alice, address(reward)), 0, "good fully settled");
    }
}
