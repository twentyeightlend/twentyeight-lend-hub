// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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
import {MarketParams} from "../src/libraries/Types.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Deploys the full twentyeight-lend stack on HyperEVM (chainId 999).
/// @dev DEPLOYMENT NOTES:
///   - HyperEVM requires BIG BLOCKS for large deploys: before running, the deployer EOA must
///     enable big blocks via the HyperCore `evmUserModify(usingBigBlocks=true)` action (off-chain).
///   - Governance addresses come from env and MUST be multisigs (ideally behind a Timelock):
///       OWNER, GUARDIAN, KEEPER, TREASURY, YIELD_RECEIVER, ROUTER (the swap router for self-repay).
///   - Tunable risk params are constants below; review before mainnet.
///   - Run: forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast --slow
contract Deploy is Script {
    // --- verified on-chain addresses (HyperEVM 999) ---
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // native Circle USDC, 6 dec
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
    // KittenSwap Algebra-Integral SwapRouter (verified on-chain) — our pools are Algebra Integral.
    address constant KITTEN_ALGEBRA_ROUTER = 0x4e73E421480a7E0C24fB3c11019254edE194f736;

    // --- Pyth feed IDs (verified live) ---
    bytes32 constant HYPE_FEED = 0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b;
    bytes32 constant USDC_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant USDT_FEED = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
    bytes32 constant ETH_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // --- tunable risk params (review before mainnet) ---
    uint256 constant CREDIT_WINDOW = 8; // closed epochs for trailing-MIN
    uint256 constant CREDIT_MULTIPLIER = 8; // epochs of fee the line extends
    uint256 constant CREDIT_SAFETY_BPS = 8000; // 80%
    uint256 constant MAX_AGE = 600; // Pyth staleness window (s)
    uint256 constant MAX_CONF_BPS = 200; // 2% Pyth confidence tolerance
    uint256 constant TREASURY_BPS = 500; // 5% self-repay treasury cut
    uint256 constant SELF_REPAY_SLIPPAGE_BPS = 200; // 2% swap floor
    uint32 constant TWAP_WINDOW = 1800; // 30 min
    int24 constant MAX_TICK_DEVIATION = 5000;
    uint256 constant DLOM_BPS = 4000; // 40% illiquidity haircut on wveNEST
    uint256 constant LLTV = 0.5e18; // 50%
    uint256 constant LIQUIDATION_BONUS = 1.08e18; // 8%
    // guarded rollout caps (USDC, 6dec). Raised gradually post-launch (≤2x/day per market).
    uint256 constant LENDING_SUPPLY_CAP = 15_000e6; // veNFT yield markets (KITTEN/NEST) — launch cap
    uint256 constant WVENEST_SUPPLY_CAP = 15_000e6; // wveNEST principal market (Phase 3) — applied when it goes live

    function run() external {
        address multisig = vm.envAddress("MULTISIG"); // Gnosis Safe (proposer/executor + fast roles)
        address guardian = vm.envAddress("GUARDIAN"); // multisig for instant emergency pause
        address keeper = vm.envAddress("KEEPER");
        address treasury = vm.envAddress("TREASURY");
        address yieldReceiver = vm.envAddress("YIELD_RECEIVER");
        uint256 timelockDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));

        (address[] memory tokens, bytes32[] memory feeds) = _priced();

        // The broadcasting EOA. It owns the core just long enough to set the guarded caps atomically,
        // then hands governance to the Timelock — so the markets can never be live uncapped.
        address deployer = msg.sender;

        vm.startBroadcast();

        // 0) Timelock governs slow/parameter actions (fee changes). The multisig is the only
        //    proposer+executor; admin renounced (address(0)) so the timelock self-governs.
        //    Emergency PAUSE stays instant via the separate `guardian` (adapters/wrapper) and the
        //    market `owner=multisig` (so pause/emergencyPrice/supplyCap aren't delayed when it
        //    matters). Future ownership rotations are typo-safe via 2-step acceptOwnership.
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = multisig;
        executors[0] = multisig;
        TimelockController timelock = new TimelockController(timelockDelay, proposers, executors, address(0));

        // swap-router adapter: bridges SelfRepayEngine's generic swap() to the Algebra router
        AlgebraRouterAdapter routerAdapter = new AlgebraRouterAdapter(KITTEN_ALGEBRA_ROUTER);
        address router = address(routerAdapter);

        // 1) immutable core (veNFT cashflow lending). Owned by the deployer for the duration of this
        //    script only, so the guarded supply caps are set BEFORE the core can accept any deposit;
        //    ownership is then transferred to the Timelock (step 7).
        LendingCore core = new LendingCore(deployer, treasury);

        // 2) adapters (guardian can pause on a NEST/KITTEN proxy-upgrade emergency)
        KittenAdapter kittenAdapter = new KittenAdapter(address(core), VE_KITTEN, KITTEN_VOTER, KITTEN, guardian);
        NestAdapter nestAdapter = new NestAdapter(address(core), VE_NEST, NEST_VOTER, NEST, guardian);

        // 3) on-chain credit-line managers (USDC-denominated lines from voting-fee history)
        KittenCreditLineManager kittenCM = new KittenCreditLineManager(
            IPyth(PYTH), KITTEN_VOTER, USDC_FEED, 6, CREDIT_WINDOW, CREDIT_MULTIPLIER, CREDIT_SAFETY_BPS, MAX_AGE, MAX_CONF_BPS, tokens, feeds
        );
        NestCreditLineManager nestCM = new NestCreditLineManager(
            IPyth(PYTH), NEST_VOTER, USDC_FEED, 6, CREDIT_WINDOW, CREDIT_MULTIPLIER, CREDIT_SAFETY_BPS, MAX_AGE, MAX_CONF_BPS, tokens, feeds
        );

        // 4) self-repay engine (oracle-floored swaps -> repay)
        SelfRepayEngine engine = new SelfRepayEngine(
            address(core), router, treasury, TREASURY_BPS, PYTH, SELF_REPAY_SLIPPAGE_BPS, MAX_AGE, MAX_CONF_BPS, tokens, feeds
        );

        // 5) create the veNFT markets (loanToken = USDC; oracle/irm unused in the yield tier)
        MarketParams memory kittenMkt =
            MarketParams({loanToken: USDC, veAdapter: address(kittenAdapter), oracle: address(0), irm: address(0), lltv: 0});
        MarketParams memory nestMkt =
            MarketParams({loanToken: USDC, veAdapter: address(nestAdapter), oracle: address(0), irm: address(0), lltv: 0});
        core.createMarket(kittenMkt, address(kittenCM), address(engine), keeper);
        core.createMarket(nestMkt, address(nestCM), address(engine), keeper);

        // 5a) GUARDED ROLLOUT: cap both markets at $15k while still deployer-owned, so neither market
        //     is ever live uncapped. The cap is enforced in supply(); raises later go through the
        //     Timelock (≤2x/day, never removable in one tx). Emergency inflow-stop is separately
        //     covered instantly by the guardian adapter-pause (no need to lower the cap fast).
        core.setSupplyCap(kittenMkt, LENDING_SUPPLY_CAP);
        core.setSupplyCap(nestMkt, LENDING_SUPPLY_CAP);

        // 6) permanent-veNEST liquid wrapper (wveNEST) + its principal-collateral market.
        //    addRewardToken is guardian-only -> done POST-DEPLOY by the guardian multisig.
        ReceiptWrapper wrapper = new ReceiptWrapper(VE_NEST, NEST_VOTER, NEST, guardian, keeper, yieldReceiver);

        VeTwapOracle nestTwap = new VeTwapOracle(
            NEST_WHYPE_POOL, NEST, WHYPE, 18, 18, PYTH, HYPE_FEED, TWAP_WINDOW, MAX_TICK_DEVIATION, MAX_AGE, MAX_CONF_BPS
        );
        HaircutOracle haircut = new HaircutOracle(
            address(nestTwap), PYTH, USDC_FEED, DLOM_BPS, 18, 6, MAX_AGE, MAX_CONF_BPS
        );
        // market owner = multisig (fast) so pause / emergencyPrice / supplyCap aren't timelock-delayed.
        // setSupplyCap is owner-only -> done POST-DEPLOY by the multisig (guarded rollout).
        WrappedCollateralMarket wveNestMarket = new WrappedCollateralMarket(
            USDC, address(wrapper), address(haircut), address(0), LLTV, LIQUIDATION_BONUS, multisig, treasury
        );

        // 7) hand core governance to the Timelock now that the guarded caps are set. 2-step: the
        //    Timelock must {acceptOwnership} post-deploy (multisig proposal). Until it does, the
        //    deployer remains owner — caps are already in place, so the markets stay capped throughout.
        core.transferOwnership(address(timelock));

        vm.stopBroadcast();

        console2.log("Timelock           ", address(timelock));
        console2.log("AlgebraRouterAdapter", address(routerAdapter));
        console2.log("LendingCore        ", address(core));
        console2.log("KittenAdapter      ", address(kittenAdapter));
        console2.log("NestAdapter        ", address(nestAdapter));
        console2.log("KittenCreditManager", address(kittenCM));
        console2.log("NestCreditManager  ", address(nestCM));
        console2.log("SelfRepayEngine    ", address(engine));
        console2.log("ReceiptWrapper     ", address(wrapper));
        console2.log("VeTwapOracle(NEST) ", address(nestTwap));
        console2.log("HaircutOracle      ", address(haircut));
        console2.log("wveNEST Market     ", address(wveNestMarket));
        console2.log("=== veNFT markets launched CAPPED at $15k each (KITTEN + NEST) ===");
        console2.log("=== POST-DEPLOY ACTIONS (multisig/guardian) ===");
        console2.log("1. Timelock: acceptOwnership() on LendingCore (multisig proposal) to finish governance handoff");
        console2.log("2. guardian: wrapper.addRewardToken(WHYPE/USDC/USDT0/UETH) for pro-rata distribution");
        console2.log("3. multisig(owner): wveNestMarket.setSupplyCap(15000e6) when the principal market goes live");
        console2.log("4. multisig: document/rehearse setEmergencyPrice procedure for oracle outage");
        console2.log("5. raise veNFT-market caps gradually via Timelock as confidence grows (<=2x/day, on-chain)");
        console2.log("6. LendingCore fee + cap changes flow through the Timelock (proposer=multisig, delay set)");
    }

    function _priced() internal pure returns (address[] memory tokens, bytes32[] memory feeds) {
        tokens = new address[](4);
        feeds = new bytes32[](4);
        tokens[0] = WHYPE;
        feeds[0] = HYPE_FEED;
        tokens[1] = USDC;
        feeds[1] = USDC_FEED;
        tokens[2] = USDT0;
        feeds[2] = USDT_FEED;
        tokens[3] = UETH;
        feeds[3] = ETH_FEED;
    }
}
