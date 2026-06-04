// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KittenCreditLineManager} from "../src/credit/KittenCreditLineManager.sol";
import {NestCreditLineManager} from "../src/credit/NestCreditLineManager.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MarketParams} from "../src/libraries/Types.sol";
import {
    MockPyth,
    MockDecToken,
    MockKittenVoter,
    MockKittenVotingReward,
    MockNestVoter,
    MockNestBribe
} from "./mocks/CreditMocks.sol";
import {MockVeAdapter} from "./mocks/Mocks.sol";

contract CreditLineTest is Test {
    bytes32 constant USDC_FEED = bytes32(uint256(1));
    bytes32 constant WHYPE_FEED = bytes32(uint256(2));

    MockPyth pyth;
    address whype; // 18 dec, $74
    address usdcReward; // 6 dec, $1
    MockVeAdapter adapter; // params.veAdapter: maturity-match reads isPermanentLock()/lockEnd()
    MarketParams params;

    uint256 constant WINDOW = 4;
    uint256 constant MULT = 8;
    uint256 constant SAFETY = 8_000; // 80%
    uint256 constant LOAN_DEC = 6;

    function setUp() public {
        pyth = new MockPyth();
        pyth.setPrice(USDC_FEED, 1e8, 1e5, -8); // $1
        pyth.setPrice(WHYPE_FEED, 74e8, 1e6, -8); // $74
        whype = address(new MockDecToken(18));
        usdcReward = address(new MockDecToken(6));
        // default adapter: lockEnd = max => full multiplier, so existing expectations are unchanged.
        adapter = new MockVeAdapter(address(0));
        params.veAdapter = address(adapter);
    }

    function _tokens() internal view returns (address[] memory t, bytes32[] memory f) {
        t = new address[](2);
        f = new bytes32[](2);
        t[0] = whype;
        f[0] = WHYPE_FEED;
        t[1] = usdcReward;
        f[1] = USDC_FEED;
    }

    // ---------------------------------------------------------------------
    // KITTEN
    // ---------------------------------------------------------------------

    function test_kitten_trailingMinAndConversion() public {
        MockKittenVoter voter = new MockKittenVoter();
        MockKittenVotingReward vr = new MockKittenVotingReward();
        address poolA = address(0xA);
        voter.setPeriod(100);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        voter.setPools(pools);
        voter.setGauge(poolA, address(vr));

        // periods 96..99 closed; make 98 the MIN ($50), others $100.
        for (uint256 p = 96; p <= 99; ++p) {
            if (p == 98) {
                vr.setEarned(p, usdcReward, 50e6); // $50
            } else {
                vr.setEarned(p, whype, 1e18); // $74
                vr.setEarned(p, usdcReward, 26e6); // +$26 = $100
            }
        }

        (address[] memory t, bytes32[] memory f) = _tokens();
        KittenCreditLineManager m = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );

        // MIN weekly = $50 -> 50 * 8 * 0.8 = $320 -> 320 USDC (6dp)
        uint256 line = m.creditLine(params, 1);
        assertApproxEqAbs(line, 320e6, 1e3, "credit line");
    }

    function test_kitten_excludesUnmappedToken() public {
        MockKittenVoter voter = new MockKittenVoter();
        MockKittenVotingReward vr = new MockKittenVotingReward();
        address poolA = address(0xA);
        voter.setPeriod(100);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        voter.setPools(pools);
        voter.setGauge(poolA, address(vr));

        address junk = address(new MockDecToken(18)); // NOT mapped
        for (uint256 p = 96; p <= 99; ++p) {
            vr.setEarned(p, usdcReward, 100e6); // $100 each, flat
            vr.setEarned(p, junk, 1_000_000e18); // huge but unmapped -> ignored
        }

        (address[] memory t, bytes32[] memory f) = _tokens();
        KittenCreditLineManager m = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
        // Only the $100 USDC counts: 100 * 8 * 0.8 = $640.
        assertApproxEqAbs(m.creditLine(params, 1), 640e6, 1e3, "junk excluded");
    }

    function test_kitten_grossIncludesClaimed() public {
        // Active position that already CLAIMED: earnedForPeriod=0 but claimed>0.
        // Credit must reflect gross = earned + claimed, not 0.
        MockKittenVoter voter = new MockKittenVoter();
        MockKittenVotingReward vr = new MockKittenVotingReward();
        address poolA = address(0xA);
        voter.setPeriod(100);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        voter.setPools(pools);
        voter.setGauge(poolA, address(vr));

        for (uint256 p = 96; p <= 99; ++p) {
            vr.setEarned(p, usdcReward, 0); // fully claimed
            vr.setClaimed(p, usdcReward, 100e6); // $100 gross each
        }

        (address[] memory t, bytes32[] memory f) = _tokens();
        KittenCreditLineManager m = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
        // gross $100 -> 100 * 8 * 0.8 = $640.
        assertApproxEqAbs(m.creditLine(params, 1), 640e6, 1e3, "gross includes claimed");
    }

    function test_kitten_zeroHistory_returnsZero() public {
        MockKittenVoter voter = new MockKittenVoter();
        voter.setPeriod(3); // <= window
        (address[] memory t, bytes32[] memory f) = _tokens();
        KittenCreditLineManager m = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
        assertEq(m.creditLine(params, 1), 0);
    }

    // ---------------------------------------------------------------------
    // Maturity-matched credit horizon (KITTEN expiring locks)
    // ---------------------------------------------------------------------

    /// @dev KITTEN manager earning a flat $100/week over the window (full credit = 100*8*0.8 = $640).
    function _kitten100() internal returns (KittenCreditLineManager m) {
        MockKittenVoter voter = new MockKittenVoter();
        MockKittenVotingReward vr = new MockKittenVotingReward();
        address poolA = address(0xA);
        voter.setPeriod(100);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        voter.setPools(pools);
        voter.setGauge(poolA, address(vr));
        for (uint256 p = 96; p <= 99; ++p) {
            vr.setEarned(p, usdcReward, 100e6); // $100/wk flat
        }
        (address[] memory t, bytes32[] memory f) = _tokens();
        m = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
    }

    function test_maturity_permanentLock_fullHorizon() public {
        KittenCreditLineManager m = _kitten100();
        adapter.setPermanent(true); // veNEST-style: never expires
        assertApproxEqAbs(m.creditLine(params, 1), 640e6, 1e3, "permanent => full 8 epochs");
    }

    function test_maturity_longLock_fullHorizon() public {
        KittenCreditLineManager m = _kitten100();
        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp + 52 weeks); // far past the 8-epoch horizon
        assertApproxEqAbs(m.creditLine(params, 1), 640e6, 1e3, "52wk lock => full 8 epochs");
    }

    function test_maturity_shortLock_capped() public {
        KittenCreditLineManager m = _kitten100();
        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp + 2 weeks); // only 2 epochs of life left
        // min(8,2)=2 -> 100*2*0.8 = $160 (loan can self-repay before expiry)
        assertApproxEqAbs(m.creditLine(params, 1), 160e6, 1e3, "near-expiry capped to remaining weeks");
    }

    function test_maturity_oneWeekLock_capped() public {
        KittenCreditLineManager m = _kitten100();
        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp + 1 weeks);
        assertApproxEqAbs(m.creditLine(params, 1), 80e6, 1e3, "1wk => 1 epoch = $80");
    }

    function test_maturity_expiredLock_zeroCredit() public {
        KittenCreditLineManager m = _kitten100();
        vm.warp(100 weeks);
        adapter.setPermanent(false);
        adapter.setLockEnd(block.timestamp); // already expired
        assertEq(m.creditLine(params, 1), 0, "expired lock => no credit");
    }

    /// @dev Across the whole lock-duration domain: credit is EXACTLY min(weeksLeft, multiplier)
    ///      epochs of fees, never more than the full horizon, and never reverts.
    function testFuzz_maturity_scalesAndBounded(uint256 secsLeft) public {
        KittenCreditLineManager m = _kitten100();
        adapter.setPermanent(false);
        secsLeft = bound(secsLeft, 0, 520 weeks);
        adapter.setLockEnd(block.timestamp + secsLeft);

        uint256 weeksLeft = secsLeft / 1 weeks;
        uint256 effMult = weeksLeft < MULT ? weeksLeft : MULT;
        uint256 expected = effMult * 80e6; // $100/wk * effMult * 0.8 safety, in USDC(6) at $1

        uint256 credit = m.creditLine(params, 1);
        assertEq(credit, expected, "credit == min(weeksLeft,mult) epochs exactly");
        assertLe(credit, 640e6, "never exceeds the full 8-epoch horizon");
    }

    // ---------------------------------------------------------------------
    // NEST
    // ---------------------------------------------------------------------

    function test_nest_shareWeightedTrailingMin() public {
        MockNestVoter voter = new MockNestVoter();
        MockNestBribe intB = new MockNestBribe();
        uint256 WEEK = 604_800;
        uint256 curEpoch = 100 * WEEK;
        voter.setEpoch(curEpoch);

        address poolA = address(0xA);
        address gA = address(0x6A);
        voter.setPool(poolA, gA, address(intB), address(0));

        // HISTORICAL share 25% each closed epoch; pool fee $400 except w=3 = $200 (the MIN).
        for (uint256 w = 1; w <= WINDOW; ++w) {
            uint256 e = curEpoch - w * WEEK;
            intB.setVote(e, 7, 250e18, 1_000e18); // 25%
            intB.setReward(e, usdcReward, w == 3 ? 200e6 : 400e6);
        }

        (address[] memory t, bytes32[] memory f) = _tokens();
        NestCreditLineManager m = new NestCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );

        // MIN week fee = 25% * $200 = $50 -> 50 * 8 * 0.8 = $320.
        assertApproxEqAbs(m.creditLine(params, 7), 320e6, 1e3, "nest credit line");
    }

    function test_nest_partialParticipation_scaledCredit() public {
        // Participated in 2 of 4 window epochs -> credit scaled by 2/4 (graceful, not denied).
        MockNestVoter voter = new MockNestVoter();
        MockNestBribe intB = new MockNestBribe();
        uint256 WEEK = 604_800;
        uint256 curEpoch = 100 * WEEK;
        voter.setEpoch(curEpoch);
        address poolA = address(0xA);
        voter.setPool(poolA, address(0x6A), address(intB), address(0));

        // w=1: 25% × $400 = $100 ; w=2: 25% × $200 = $50 (MIN of participated) ; w=3,4: no weight
        intB.setVote(curEpoch - 1 * WEEK, 7, 250e18, 1_000e18);
        intB.setReward(curEpoch - 1 * WEEK, usdcReward, 400e6);
        intB.setVote(curEpoch - 2 * WEEK, 7, 250e18, 1_000e18);
        intB.setReward(curEpoch - 2 * WEEK, usdcReward, 200e6);
        intB.setVote(curEpoch - 3 * WEEK, 7, 0, 1_000e18);
        intB.setVote(curEpoch - 4 * WEEK, 7, 0, 1_000e18);

        (address[] memory t, bytes32[] memory f) = _tokens();
        NestCreditLineManager m = new NestCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
        // minUsd(participated) = $50; scaled ×2/4 = $25; ×8×0.8 = $160.
        assertApproxEqAbs(m.creditLine(params, 7), 160e6, 1e3, "partial participation scaled");
    }

    function test_nest_historicalVotes_manipulationProof() public {
        // A borrower who only votes NOW has zero historical balanceOfAt at closed epochs => 0
        // credit, regardless of how the current pool set looks. This kills the share-forge attack.
        MockNestVoter voter = new MockNestVoter();
        MockNestBribe intB = new MockNestBribe();
        uint256 WEEK = 604_800;
        uint256 curEpoch = 100 * WEEK;
        voter.setEpoch(curEpoch);
        address poolA = address(0xA);
        voter.setPool(poolA, address(0x6A), address(intB), address(0)); // pool IS in current vote set
        // huge fees existed historically, but the position held NO historical weight
        for (uint256 w = 1; w <= WINDOW; ++w) {
            uint256 e = curEpoch - w * WEEK;
            intB.setVote(e, 7, 0, 1_000e18); // balanceOfAt(7)=0 historically
            intB.setReward(e, usdcReward, 1_000_000e6);
        }
        (address[] memory t, bytes32[] memory f) = _tokens();
        NestCreditLineManager m = new NestCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, LOAN_DEC, WINDOW, MULT, SAFETY, 1 days, 5_000, t, f
        );
        assertEq(m.creditLine(params, 7), 0, "no historical votes => no credit");
    }
}
