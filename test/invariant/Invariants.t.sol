// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../../src/LendingCore.sol";
import {MarketParams, Id, MarketParamsLib} from "../../src/libraries/Types.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "../mocks/Mocks.sol";
import {Handler} from "./Handler.sol";

/// @notice Property tests: core accounting must hold under any random action ordering.
contract InvariantsTest is Test {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    LendingCore core;
    MockERC20 usdc;
    MockVeAdapter adapter;
    MockCreditManager cm;
    Handler handler;
    MarketParams params;
    Id id;

    function setUp() public {
        core = new LendingCore(address(this), address(0xFEE));
        usdc = new MockERC20();
        adapter = new MockVeAdapter(address(usdc));
        cm = new MockCreditManager(1_000e6); // constant credit line
        params = MarketParams({
            loanToken: address(usdc),
            veAdapter: address(adapter),
            oracle: address(0),
            irm: address(0), // 0% interest -> debt never grows post-borrow
            lltv: 0
        });
        id = params.id();
        core.createMarket(params, address(cm), address(0), address(0));

        handler = new Handler(core, usdc, params);
        targetContract(address(handler));
    }

    function _market()
        internal
        view
        returns (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs)
    {
        (tsa, tss, tba, tbs,,) = core.market(id);
    }

    /// Idle loanToken in the core must cover (supply - borrow). Solvency floor.
    function invariant_loanTokenSolvency() public view {
        (uint128 tsa,, uint128 tba,) = _market();
        uint256 owed = tsa >= tba ? tsa - tba : 0;
        assertGe(usdc.balanceOf(address(core)), owed, "core underfunded vs idle liability");
    }

    /// Can never owe more than was supplied.
    function invariant_supplyCoversBorrow() public view {
        (uint128 tsa,, uint128 tba,) = _market();
        assertGe(tsa, tba, "borrow exceeds supply");
    }

    /// Sum of lender shares (+ fee recipient) == totalSupplyShares.
    function invariant_supplySharesConserved() public view {
        (, uint128 tss,,) = _market();
        uint256 sum = core.supplyShares(id, address(0xA1)) + core.supplyShares(id, address(0xA2))
            + core.supplyShares(id, address(0xA3)) + core.supplyShares(id, address(0xFEE));
        assertEq(sum, tss, "supply shares not conserved");
    }

    /// Sum of position borrow shares == totalBorrowShares.
    function invariant_borrowSharesConserved() public view {
        (,,, uint128 tbs) = _market();
        uint256 sum;
        for (uint256 t = 1; t <= 3; ++t) {
            (, uint128 s,,) = core.position(id, t);
            sum += s;
        }
        assertEq(sum, tbs, "borrow shares not conserved");
    }

    /// No position may owe more than its (constant) credit line, and debt implies a borrower.
    function invariant_debtWithinCreditLineAndOwned() public view {
        (,, uint128 tba, uint128 tbs) = _market();
        for (uint256 t = 1; t <= 3; ++t) {
            (address borrower, uint128 s,,) = core.position(id, t);
            uint256 debt = uint256(s).toAssetsUp(tba, tbs);
            if (s > 0) assertTrue(borrower != address(0), "debt without borrower");
            assertLe(debt, 1_000e6 + 1, "debt exceeds credit line");
        }
    }
}
