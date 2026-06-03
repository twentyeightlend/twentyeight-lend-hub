// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SharesMathLib} from "../src/libraries/SharesMathLib.sol";

/// @title HalmosSharesMath
/// @notice Symbolic harness (Halmos) for the Morpho-style virtual-shares accounting.
/// @dev HONEST STATUS: with stock Halmos/Z3 these checks TIME OUT — symbolic reasoning over the
///      nonlinear mulDiv (symbolic x*y AND symbolic division) is intractable here, even at uint64
///      width. Crucially, NO COUNTEREXAMPLE is ever produced (timeout != violation). These same
///      properties are proven empirically by the 12,800-call Foundry fuzz suite in test/invariant/.
///      This file is kept as a ready harness for a more capable backend (Certora / bitwuzla) — it
///      is intentionally NOT wired into CI, which runs `forge test` + Slither instead.
///      Run: `halmos --contract HalmosSharesMath` (expect TIMEOUT, not PASS, on a stock setup).
contract HalmosSharesMath is Test {
    /// Up-rounding conversion is never below down-rounding, and differs by at most 1 wei.
    function check_sharesUp_ge_sharesDown(uint64 assets, uint64 ta, uint64 ts) public pure {
        uint256 up = SharesMathLib.toSharesUp(assets, ta, ts);
        uint256 down = SharesMathLib.toSharesDown(assets, ta, ts);
        assert(up >= down);
        assert(up - down <= 1);
    }

    function check_assetsUp_ge_assetsDown(uint64 shares, uint64 ta, uint64 ts) public pure {
        uint256 up = SharesMathLib.toAssetsUp(shares, ta, ts);
        uint256 down = SharesMathLib.toAssetsDown(shares, ta, ts);
        assert(up >= down);
        assert(up - down <= 1);
    }

    /// Core anti-inflation property: deposit assets -> shares (down) -> assets (down) can NEVER
    /// return more than was put in. If violated, a depositor could mint value from rounding — the
    /// classic vault donation/inflation exploit. Virtual shares must prevent it.
    function check_roundTrip_noAssetGain(uint64 assets, uint64 ta, uint64 ts) public pure {
        uint256 shares = SharesMathLib.toSharesDown(assets, ta, ts);
        uint256 back = SharesMathLib.toAssetsDown(shares, ta, ts);
        assert(back <= assets);
    }
}
