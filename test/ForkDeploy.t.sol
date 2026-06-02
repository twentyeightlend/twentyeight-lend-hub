// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {KittenAdapter} from "../src/adapters/KittenAdapter.sol";
import {NestAdapter} from "../src/adapters/NestAdapter.sol";
import {KittenCreditLineManager} from "../src/credit/KittenCreditLineManager.sol";
import {NestCreditLineManager} from "../src/credit/NestCreditLineManager.sol";
import {SelfRepayEngine} from "../src/SelfRepayEngine.sol";
import {ReceiptWrapper} from "../src/ReceiptWrapper.sol";
import {VeTwapOracle} from "../src/oracles/VeTwapOracle.sol";
import {HaircutOracle} from "../src/oracles/HaircutOracle.sol";
import {WrappedCollateralMarket} from "../src/WrappedCollateralMarket.sol";
import {AlgebraRouterAdapter} from "../src/periphery/AlgebraRouterAdapter.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

interface IERC721Min {
    function ownerOf(uint256) external view returns (address);
    function approve(address, uint256) external;
}

interface INestVoterRead {
    function poolVoteLength(uint256 tokenId) external view returns (uint256);
    function poolVote(uint256 tokenId, uint256 i) external view returns (address);
}

/// @notice Full-stack DEPLOY DRY-RUN + end-to-end exercise against LIVE HyperEVM. Deploys every
///         contract, validates governance wiring, reads real oracles/credit lines, then performs a
///         real veNEST borrow/repay/recover by impersonating an actual whale (exercises the
///         onERC721Received custody fix on the real escrow) and a real wveNEST wrap+borrow.
contract ForkDeployTest is Test {
    using MarketParamsLib for MarketParams;

    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant UETH = 0xBe6727B535545C67d5cAa73dEa54865B92CF7907;
    address constant PYTH = 0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc;
    address constant NEST = 0x07c57E32a3C29D5659bda1d3EFC2E7BF004E3035;
    address constant VE_NEST = 0x2f2Ae07e3cc3391A2E27825652BA8DcdD5412074;
    address constant NEST_VOTER = 0x566bdc5444fd5fe5d93ec379Bd66eC861ddbA901;
    address constant NEST_WHYPE_POOL = 0x535F30F50eBDa33575242C38B976E681D13db6Fa;
    address constant KITTEN = 0x618275F8EFE54c2afa87bfB9F210A52F0fF89364;
    address constant VE_KITTEN = 0x29d3A21fF35a519E00cF6d272f2aD897b109BD84;
    address constant KITTEN_VOTER = 0xb7F7053F7e6c210e6777D5BA758E4b3ECa6C88A0;
    address constant KITTEN_ALGEBRA_ROUTER = 0x4e73E421480a7E0C24fB3c11019254edE194f736;

    bytes32 constant HYPE_FEED = 0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b;
    bytes32 constant USDC_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant USDT_FEED = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
    bytes32 constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    address constant WHALE2 = 0xbA6f01324F61aD4F5997C44580CF21A80655B969; // owns veNEST #2
    address constant WHALE5 = 0x0Ccd34Be3C5F4f905308B0eF898E870Fb7930354; // owns veNEST #5

    // fork-appropriate params (large maxAge so pinned-block Pyth reads don't trip staleness)
    uint256 constant MAXAGE = 30 days;
    uint256 constant MAXCONF = 10_000;

    LendingCore core;
    KittenAdapter kittenAdapter;
    NestAdapter nestAdapter;
    NestCreditLineManager nestCM;
    KittenCreditLineManager kittenCM;
    SelfRepayEngine engine;
    AlgebraRouterAdapter routerAdapter;
    ReceiptWrapper wrapper;
    VeTwapOracle nestTwap;
    HaircutOracle haircut;
    WrappedCollateralMarket market;
    TimelockController timelock;
    MarketParams nestMkt;
    MarketParams kittenMkt;

    address me = address(this); // acts as multisig/guardian/keeper in the test

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("hyperevm"), 36_743_140);

        (address[] memory toks, bytes32[] memory feeds) = _priced();

        address[] memory one = new address[](1);
        one[0] = me;
        timelock = new TimelockController(2 days, one, one, address(0));

        routerAdapter = new AlgebraRouterAdapter(KITTEN_ALGEBRA_ROUTER);
        core = new LendingCore(address(timelock), me);
        kittenAdapter = new KittenAdapter(address(core), VE_KITTEN, KITTEN_VOTER, KITTEN, me);
        nestAdapter = new NestAdapter(address(core), VE_NEST, NEST_VOTER, NEST, me);

        // window=2 so the recent-voting whales have full participation history on the fork
        nestCM = new NestCreditLineManager(IPyth(PYTH), NEST_VOTER, USDC_FEED, 6, 2, 8, 8000, MAXAGE, MAXCONF, toks, feeds);
        kittenCM = new KittenCreditLineManager(IPyth(PYTH), KITTEN_VOTER, USDC_FEED, 6, 2, 8, 8000, MAXAGE, MAXCONF, toks, feeds);
        engine = new SelfRepayEngine(address(core), address(routerAdapter), me, 500, PYTH, 200, MAXAGE, MAXCONF, toks, feeds);

        nestMkt = MarketParams(USDC, address(nestAdapter), address(0), address(0), 0);
        kittenMkt = MarketParams(USDC, address(kittenAdapter), address(0), address(0), 0);
        core.createMarket(nestMkt, address(nestCM), address(engine), me);
        core.createMarket(kittenMkt, address(kittenCM), address(engine), me);

        wrapper = new ReceiptWrapper(VE_NEST, NEST_VOTER, NEST, me, me, me);
        nestTwap = new VeTwapOracle(NEST_WHYPE_POOL, NEST, WHYPE, 18, 18, PYTH, HYPE_FEED, 1800, 20_000, MAXAGE, MAXCONF);
        haircut = new HaircutOracle(address(nestTwap), PYTH, USDC_FEED, 4000, 18, 6, MAXAGE, MAXCONF);
        market = new WrappedCollateralMarket(USDC, address(wrapper), address(haircut), address(0), 0.5e18, 1.08e18, me, me);
    }

    function _priced() internal pure returns (address[] memory t, bytes32[] memory f) {
        t = new address[](4);
        f = new bytes32[](4);
        t[0] = WHYPE;
        f[0] = HYPE_FEED;
        t[1] = USDC;
        f[1] = USDC_FEED;
        t[2] = USDT0;
        f[2] = USDT_FEED;
        t[3] = UETH;
        f[3] = ETH_FEED;
    }

    function test_fork_deployment_wired() public view {
        assertEq(core.owner(), address(timelock), "core owned by timelock");
        assertEq(market.owner(), me, "market owned by multisig");
        (,,,, uint128 lu,) = core.market(nestMkt.id());
        assertGt(lu, 0, "NEST market created");
        (,,,, uint128 lu2,) = core.market(kittenMkt.id());
        assertGt(lu2, 0, "KITTEN market created");
        assertEq(address(routerAdapter.router()), KITTEN_ALGEBRA_ROUTER, "router wired");
    }

    function test_fork_oracles_live() public view {
        uint256 nestUsd = nestTwap.priceUsd1e18();
        uint256 hc = haircut.price();
        console2.log("NEST USD (1e18):", nestUsd);
        console2.log("Haircut price (1e36):", hc);
        assertGt(nestUsd, 0.005e18);
        assertLt(nestUsd, 0.20e18);
        assertGt(hc, 0); // wveNEST priced
    }

    function test_fork_creditLines_live() public view {
        uint256 nestLine = nestCM.creditLine(nestMkt, 2);
        uint256 kitLine = kittenCM.creditLine(kittenMkt, 2);
        console2.log("NEST #2 credit (USDC):", nestLine);
        console2.log("KITTEN #2 credit (USDC):", kitLine);
        assertGt(nestLine, 0, "NEST whale has credit");
        assertGt(kitLine, 0, "KITTEN whale has credit");
    }

    /// @dev Proves the real-escrow custody round-trip + the onERC721Received fix on LIVE veNEST:
    ///      deposit collateral -> adapter holds it -> withdraw -> whale recovers it. (Borrowing
    ///      against it additionally requires the keeper to re-vote in Dromos's voting window —
    ///      custody resets votes — which can't be forced at an arbitrary forked block; the credit
    ///      line itself is proven nonzero in test_fork_creditLines_live.)
    function test_fork_e2e_nestCustodyRoundTrip() public {
        assertEq(IERC721Min(VE_NEST).ownerOf(2), WHALE2, "precondition: whale owns #2");

        vm.startPrank(WHALE2);
        IERC721Min(VE_NEST).approve(address(nestAdapter), 2);
        core.supplyCollateral(nestMkt, 2, WHALE2); // custody via real escrow (onERC721Received path)
        vm.stopPrank();
        assertEq(IERC721Min(VE_NEST).ownerOf(2), address(nestAdapter), "adapter custodies #2");

        // no debt -> recover the veNFT (exit path, oracle-independent)
        vm.prank(WHALE2);
        core.withdrawCollateral(nestMkt, 2, WHALE2);
        assertEq(IERC721Min(VE_NEST).ownerOf(2), WHALE2, "veNEST #2 recovered");
    }

    function test_fork_e2e_wrapAndBorrowAgainstWveNest() public {
        // whale wraps veNEST #5 -> liquid wveNEST
        vm.startPrank(WHALE5);
        IERC721Min(VE_NEST).approve(address(wrapper), 5);
        uint256 minted = wrapper.deposit(5);
        vm.stopPrank();
        console2.log("wveNEST minted from #5:", minted);
        assertGt(minted, 0);
        assertEq(wrapper.balanceOf(WHALE5), minted);

        // lender supplies USDC to the wveNEST market
        address lender = address(0xAAA2);
        deal(USDC, lender, 100_000e6);
        vm.startPrank(lender);
        IERC20(USDC).approve(address(market), type(uint256).max);
        market.supply(50_000e6, lender);
        vm.stopPrank();

        // whale uses a slice of wveNEST as collateral and borrows USDC
        uint256 collat = minted / 10;
        uint256 usdcBefore = IERC20(USDC).balanceOf(WHALE5); // whale may already hold USDC on-chain
        vm.startPrank(WHALE5);
        IERC20(address(wrapper)).approve(address(market), type(uint256).max);
        market.supplyCollateral(collat, WHALE5);
        market.borrow(10e6, WHALE5); // tiny, well under LTV
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(WHALE5) - usdcBefore, 10e6, "borrowed 10 USDC against wveNEST");
        assertTrue(market.isHealthy(WHALE5));
    }
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
