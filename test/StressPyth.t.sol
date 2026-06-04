// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceLib} from "../src/libraries/PythPriceLib.sol";

/// @dev Adversarial Pyth mock: models publishTime+age (real staleness) and arbitrary fields.
contract AdvPyth is IPyth {
    mapping(bytes32 => Price) internal _p;
    mapping(bytes32 => bool) internal _set;
    uint256 public nowTime = 1_000_000;

    function setNow(uint256 t) external {
        nowTime = t;
    }

    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 pubTime) external {
        _p[id] = Price(price, conf, expo, pubTime);
        _set[id] = true;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory) {
        require(_set[id], "no price");
        Price memory pr = _p[id];
        require(nowTime <= pr.publishTime + age, "stale"); // real Pyth reverts when too old
        return pr;
    }
}

/// @dev Harness so the library can be exercised directly with adversarial inputs.
contract PythLibHarness {
    function price(IPyth pyth, bytes32 id, uint256 maxAge, uint256 maxConfBps) external view returns (uint256) {
        return PythPriceLib.priceUsd1e18(pyth, id, maxAge, maxConfBps);
    }
}

/// @notice Offensive stress of the LIVE USD price path (PythPriceLib feeds both the credit-line
///         managers and the self-repay swap floor). Goal: prove it never returns garbage — it
///         either yields a correct 1e18 USD price or reverts cleanly; never silently wrong.
contract StressPythTest is Test {
    AdvPyth pyth;
    PythLibHarness lib;
    bytes32 constant ID = bytes32(uint256(1));

    function setUp() public {
        pyth = new AdvPyth();
        lib = new PythLibHarness();
    }

    // --- staleness: a price older than maxAge MUST revert (no stale-price borrow/credit) ---
    function test_stale_reverts() public {
        pyth.setNow(2_000_000);
        pyth.set(ID, 1e8, 1e5, -8, 1_000_000); // 1M seconds old
        vm.expectRevert(); // "stale"
        lib.price(pyth, ID, 600, 100);
    }

    function test_fresh_ok() public {
        pyth.setNow(2_000_000);
        pyth.set(ID, 1e8, 1e5, -8, 2_000_000 - 300); // 300s old, within 600
        assertEq(lib.price(pyth, ID, 600, 100), 1e18, "$1");
    }

    // --- non-positive price MUST revert (Pyth price is a signed int64) ---
    function testFuzz_nonPositivePrice_reverts(int64 p) public {
        vm.assume(p <= 0);
        pyth.set(ID, p, 0, -8, 1_000_000);
        pyth.setNow(1_000_000);
        vm.expectRevert(PythPriceLib.NonPositivePrice.selector);
        lib.price(pyth, ID, 600, 10_000);
    }

    // --- confidence interval: wide conf (manipulation/illiquid) MUST revert at the boundary ---
    function test_confidence_boundary() public {
        pyth.setNow(1_000_000);
        // price 1e8, maxConfBps 100 (1%). conf*BPS > price*maxConfBps  <=> conf > price*100/10000 = price/100.
        pyth.set(ID, 1e8, uint64(1e8 / 100), -8, 1_000_000); // exactly 1% -> NOT wider, passes
        assertGt(lib.price(pyth, ID, 600, 100), 0, "at-threshold conf ok");

        pyth.set(ID, 1e8, uint64(1e8 / 100 + 1), -8, 1_000_000); // a hair wider -> reject
        vm.expectRevert(PythPriceLib.ConfidenceTooWide.selector);
        lib.price(pyth, ID, 600, 100);
    }

    function testFuzz_wideConfidence_reverts(uint64 conf) public {
        pyth.setNow(1_000_000);
        uint256 priceRaw = 1e8;
        uint256 maxConfBps = 100;
        // pick confs strictly above the tolerance
        vm.assume(uint256(conf) * 10_000 > priceRaw * maxConfBps);
        pyth.set(ID, int64(uint64(priceRaw)), conf, -8, 1_000_000);
        vm.expectRevert(PythPriceLib.ConfidenceTooWide.selector);
        lib.price(pyth, ID, 600, maxConfBps);
    }

    // --- exponent bounds: in-range expo normalizes, out-of-range reverts (no silent mis-scale) ---
    function test_expo_negativeRange() public {
        pyth.setNow(1_000_000);
        // expo -36 ok, -37 reverts
        pyth.set(ID, 1e8, 0, -36, 1_000_000);
        lib.price(pyth, ID, 600, 10_000); // no revert
        pyth.set(ID, 1e8, 0, -37, 1_000_000);
        vm.expectRevert(PythPriceLib.ExpoOutOfRange.selector);
        lib.price(pyth, ID, 600, 10_000);
    }

    function test_expo_positiveRange() public {
        pyth.setNow(1_000_000);
        pyth.set(ID, 1e8, 0, 18, 1_000_000); // +18 ok
        lib.price(pyth, ID, 600, 10_000);
        pyth.set(ID, 1e8, 0, 19, 1_000_000); // +19 reverts
        vm.expectRevert(PythPriceLib.ExpoOutOfRange.selector);
        lib.price(pyth, ID, 600, 10_000);
    }

    function test_expoZero() public {
        pyth.setNow(1_000_000);
        pyth.set(ID, 5, 0, 0, 1_000_000); // price 5, expo 0 -> $5 *1e18
        assertEq(lib.price(pyth, ID, 600, 10_000), 5e18);
    }

    // --- overflow safety: across the WHOLE valid (price, expo) domain it must never panic ---
    function testFuzz_noOverflowOrPanic(int64 p, int32 expo) public {
        vm.assume(p > 0);
        expo = int32(bound(int256(expo), -36, 18));
        pyth.setNow(1_000_000);
        pyth.set(ID, p, 0, expo, 1_000_000);
        // conf 0 so confidence check always passes; must return without arithmetic panic.
        uint256 out = lib.price(pyth, ID, 600, 10_000);
        // a positive mantissa with in-range expo yields a finite price (may be 0 only via flooring
        // for extreme negative expo + tiny price, which is acceptable — never a wrong large value).
        out; // no panic == pass
    }

    // --- monotonicity: a higher mantissa never yields a LOWER usd price (no wraparound) ---
    function testFuzz_monotonicInMantissa(int64 a, int64 b) public {
        a = int64(bound(int256(a), 1, type(int64).max));
        b = int64(bound(int256(b), int256(a), type(int64).max));
        pyth.setNow(1_000_000);
        pyth.set(ID, a, 0, -8, 1_000_000);
        uint256 pa = lib.price(pyth, ID, 600, 10_000);
        pyth.set(ID, b, 0, -8, 1_000_000);
        uint256 pb = lib.price(pyth, ID, 600, 10_000);
        assertGe(pb, pa, "price monotonic in mantissa");
    }
}
