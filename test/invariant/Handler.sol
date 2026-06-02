// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../../src/LendingCore.sol";
import {MarketParams, Id, MarketParamsLib} from "../../src/libraries/Types.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {MockERC20, MockVeAdapter, MockCreditManager} from "../mocks/Mocks.sol";

/// @notice Drives random sequences of LendingCore actions across a fixed actor/tokenId set,
///         so the invariant suite can check core accounting holds under any ordering.
contract Handler is Test {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    LendingCore public core;
    MockERC20 public usdc;
    MarketParams public params;
    Id public id;
    uint256 public constant CREDIT = 1_000e6;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256[3] public tokenIds = [uint256(1), 2, 3];

    constructor(LendingCore _core, MockERC20 _usdc, MarketParams memory _params) {
        core = _core;
        usdc = _usdc;
        params = _params;
        id = _params.id();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 3];
    }

    function _tokenId(uint256 s) internal view returns (uint256) {
        return tokenIds[s % 3];
    }

    function _debt(uint256 tokenId) internal view returns (uint256) {
        (, uint128 shares,,) = core.position(id, tokenId);
        (,, uint128 tba, uint128 tbs,,) = core.market(id);
        return uint256(shares).toAssetsUp(tba, tbs);
    }

    function _liquidity() internal view returns (uint256) {
        (uint128 tsa,, uint128 tba,,,) = core.market(id);
        return tsa >= tba ? tsa - tba : 0;
    }

    function supply(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(a, amount);
        vm.startPrank(a);
        usdc.approve(address(core), amount);
        try core.supply(params, amount, a) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        (uint128 tsa, uint128 tss,,,,) = core.market(id);
        uint256 claim = core.supplyShares(id, a).toAssetsDown(tsa, tss);
        uint256 cap = claim < _liquidity() ? claim : _liquidity();
        if (cap == 0) return;
        amount = bound(amount, 0, cap);
        if (amount == 0) return;
        vm.prank(a);
        try core.withdraw(params, amount, a, a) {} catch {}
    }

    function supplyCollateral(uint256 actorSeed, uint256 tidSeed) external {
        address a = _actor(actorSeed);
        uint256 tid = _tokenId(tidSeed);
        (address borrower,,,) = core.position(id, tid);
        if (borrower != address(0)) return;
        vm.prank(a);
        try core.supplyCollateral(params, tid, a) {} catch {}
    }

    function borrow(uint256 tidSeed, uint256 amount) external {
        uint256 tid = _tokenId(tidSeed);
        (address borrower,,,) = core.position(id, tid);
        if (borrower == address(0)) return;
        uint256 debt = _debt(tid);
        uint256 room = CREDIT > debt ? CREDIT - debt : 0;
        uint256 cap = room < _liquidity() ? room : _liquidity();
        if (cap == 0) return;
        amount = bound(amount, 0, cap);
        if (amount == 0) return;
        vm.prank(borrower);
        try core.borrow(params, tid, amount, borrower) {} catch {}
    }

    function repay(uint256 tidSeed, uint256 amount) external {
        uint256 tid = _tokenId(tidSeed);
        (address borrower,,,) = core.position(id, tid);
        if (borrower == address(0)) return;
        uint256 debt = _debt(tid);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(core), amount);
        try core.repay(params, tid, amount) {} catch {}
        vm.stopPrank();
    }

    function withdrawCollateral(uint256 tidSeed) external {
        uint256 tid = _tokenId(tidSeed);
        (address borrower, uint128 shares,,) = core.position(id, tid);
        if (borrower == address(0) || shares != 0) return;
        vm.prank(borrower);
        try core.withdrawCollateral(params, tid, borrower) {} catch {}
    }
}
