// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KittenCreditLineManager} from "../src/credit/KittenCreditLineManager.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MarketParams} from "../src/libraries/Types.sol";
import {MockKittenVoter, MockKittenVotingReward, MockDecToken} from "./mocks/CreditMocks.sol";
import {AdvPyth} from "./StressPyth.t.sol";

/// @notice Offensive stress of the LIVE credit-line USD sizing. The credit numerator is REAL
///         on-chain fee data (earnedForPeriod, unforgeable), so the only attacker lever is the
///         external Pyth price. We prove: credit is EXACTLY the formula (no inflation), scales
///         linearly (no hidden leverage), survives decimal/amount extremes, and a stale reward
///         feed EXCLUDES that token instead of reverting (the M2 fix).
contract StressCreditTest is Test {
    AdvPyth pyth;
    MockKittenVoter voter;
    MockKittenVotingReward vr;
    KittenCreditLineManager mgr;

    address pool = address(0xF00);
    address rewardA;
    address rewardB;
    bytes32 constant USDC_FEED = bytes32(uint256(1));
    bytes32 constant FEED_A = bytes32(uint256(2));
    bytes32 constant FEED_B = bytes32(uint256(3));

    uint256 constant WINDOW = 4;
    uint256 constant MULT = 8;
    uint256 constant SAFETY = 8000; // 80%
    uint256 constant CUR = 10; // current period (> window)

    MarketParams params;

    function setUp() public {
        pyth = new AdvPyth();
        pyth.setNow(1_000_000);
        pyth.set(USDC_FEED, 1e8, 1e5, -8, 1_000_000); // USDC = $1
        rewardA = address(new MockDecToken(18));
        rewardB = address(new MockDecToken(18));

        voter = new MockKittenVoter();
        vr = new MockKittenVotingReward();
        voter.setPeriod(CUR);
        address[] memory pools = new address[](1);
        pools[0] = pool;
        voter.setPools(pools);
        voter.setGauge(pool, address(vr));

        address[] memory toks = new address[](1);
        toks[0] = rewardA;
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = FEED_A;
        mgr = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, 6, WINDOW, MULT, SAFETY, 600, 10_000, toks, feeds
        );
        params = MarketParams(address(0xDEAD), address(0), address(0), address(0), 0);
    }

    function _earnEachPeriod(address token, uint256 g) internal {
        for (uint256 p = CUR - WINDOW; p < CUR; ++p) {
            vr.setEarned(p, token, g);
        }
    }

    function _expected(uint256 g, uint64 pxRaw) internal pure returns (uint256) {
        uint256 px1e18 = uint256(pxRaw) * 1e18 / 1e8; // expo -8
        uint256 usd = g * px1e18 / 1e18; // 18-dec reward
        uint256 grossUsd = usd * MULT * SAFETY / 10_000;
        return grossUsd * 1e6 / 1e18; // USD -> USDC(6), loan feed = $1 (1e18)
    }

    // --- credit is EXACTLY the formula: cannot be inflated beyond minWeekly x mult x safety ---
    function testFuzz_creditEqualsFormula_noInflation(uint256 g, uint64 pxRaw) public {
        g = bound(g, 1e6, 1e30);
        pxRaw = uint64(bound(pxRaw, 1, 1e14));
        pyth.set(FEED_A, int64(pxRaw), 0, -8, 1_000_000);
        _earnEachPeriod(rewardA, g);

        uint256 credit = mgr.creditLine(params, 1);
        assertEq(credit, _expected(g, pxRaw), "credit == formula, no inflation/overflow");
    }

    // --- linear in price: doubling the Pyth price doubles credit (no leverage explosion) ---
    function test_doublingPrice_doublesCredit() public {
        _earnEachPeriod(rewardA, 1_000e18);
        pyth.set(FEED_A, 5e6, 0, -8, 1_000_000); // $0.05
        uint256 c1 = mgr.creditLine(params, 1);
        pyth.set(FEED_A, 10e6, 0, -8, 1_000_000); // $0.10
        uint256 c2 = mgr.creditLine(params, 1);
        assertApproxEqRel(c2, c1 * 2, 1e12, "credit linear in price");
    }

    // --- M2: a STALE reward feed must EXCLUDE that token, not revert the whole read ---
    function test_staleRewardFeed_excludesNotReverts() public {
        // two priced tokens; A fresh, B stale
        address[] memory toks = new address[](2);
        toks[0] = rewardA;
        toks[1] = rewardB;
        bytes32[] memory feeds = new bytes32[](2);
        feeds[0] = FEED_A;
        feeds[1] = FEED_B;
        KittenCreditLineManager m2 = new KittenCreditLineManager(
            IPyth(address(pyth)), address(voter), USDC_FEED, 6, WINDOW, MULT, SAFETY, 600, 10_000, toks, feeds
        );

        pyth.set(FEED_A, 5e6, 0, -8, 1_000_000); // fresh
        pyth.set(FEED_B, 5e6, 0, -8, 1); // ancient -> stale vs maxAge 600 (now 1_000_000)
        _earnEachPeriod(rewardA, 1_000e18);
        _earnEachPeriod(rewardB, 1_000e18);

        // must NOT revert; credit reflects ONLY the fresh token A (B excluded)
        uint256 credit = m2.creditLine(params, 1);
        assertEq(credit, _expected(1_000e18, 5e6), "stale token B excluded, A still counts");
        assertGt(credit, 0, "no DoS");
    }

    // --- decimal/amount extremes: no overflow at tiny and huge fee volumes ---
    function test_decimalExtremes() public {
        pyth.set(FEED_A, 1e8, 0, -8, 1_000_000); // $1
        _earnEachPeriod(rewardA, 1); // 1 wei of an 18-dec token
        assertEq(mgr.creditLine(params, 1), _expected(1, 1e8), "tiny");

        _earnEachPeriod(rewardA, 1e30); // absurdly large
        assertEq(mgr.creditLine(params, 1), _expected(1e30, 1e8), "huge, no overflow");
    }

    // --- no participation history -> zero credit (never a spurious nonzero line) ---
    function test_noHistory_zeroCredit() public {
        // period 5 (<= window+? ) -> cur<=window path. Set cur to exactly window.
        voter.setPeriod(WINDOW);
        pyth.set(FEED_A, 5e6, 0, -8, 1_000_000);
        _earnEachPeriod(rewardA, 1_000e18);
        assertEq(mgr.creditLine(params, 1), 0, "insufficient closed history => 0");
    }

    // --- gross-fee correctness: earned + claimed (net-of-claim add-back) can't be gamed to 0 ---
    function test_grossIncludesClaimed() public {
        pyth.set(FEED_A, 1e8, 0, -8, 1_000_000); // $1
        // position already claimed everything -> earnedForPeriod reads 0, claimed holds the truth
        for (uint256 p = CUR - WINDOW; p < CUR; ++p) {
            vr.setEarned(p, rewardA, 0);
            vr.setClaimed(p, rewardA, 500e18);
        }
        uint256 credit = mgr.creditLine(params, 1);
        assertEq(credit, _expected(500e18, 1e8), "gross uses claimed add-back, not the net 0");
    }
}
