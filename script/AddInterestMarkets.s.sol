// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LendingCore} from "../src/LendingCore.sol";
import {KinkIRM} from "../src/irm/KinkIRM.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/libraries/Types.sol";

/// @notice Deploys the KinkIRM and creates interest-bearing NEST + KITTEN credit-line markets so USDC
///         lenders earn yield (paid by borrowers). createMarket is permissionless; the broadcaster only
///         pays gas. The pre-existing 0%-interest markets are left untouched (deprecated, unused).
///         Curve: 2% base, 14% at 90% utilization, 100% at 100% utilization. At launch the market fee is
///         0 (lenders keep 100% of interest ~12% in the healthy band); a protocol cut can be added later
///         via the Timelock.
contract AddInterestMarkets is Script {
    using MarketParamsLib for MarketParams;

    // HyperEVM mainnet (chainId 999) — verified deployment
    address constant CORE = 0x545C9C426d968329f95F21146291E0C727015852;
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant NEST_ADAPTER = 0x63BA0cf6b4bf32A1c4E3C1C9076a5dadB7F216c1;
    address constant KITTEN_ADAPTER = 0x295D025258E72dA9203F3aAA777Fe61B297af415;
    address constant NEST_CM = 0x0288cD9f29279d9CF0DcF36cC89bD0A67b4eaC6A;
    address constant KITTEN_CM = 0x7eA45Ba437E1DC52485DD65820907953ba9ed261;
    address constant ENGINE = 0x63317AFEa8ea5C59E01dC492546aC89d0d4F8b23;
    address constant KEEPER = 0x7a54D78b15F7124E95909c445627B4ce49DCDCc0;

    function run() external {
        vm.startBroadcast();
        KinkIRM irm = new KinkIRM(0.02e18, 0.14e18, 1.0e18, 0.90e18);

        MarketParams memory nest =
            MarketParams({loanToken: USDC, veAdapter: NEST_ADAPTER, oracle: address(0), irm: address(irm), lltv: 0});
        MarketParams memory kit =
            MarketParams({loanToken: USDC, veAdapter: KITTEN_ADAPTER, oracle: address(0), irm: address(irm), lltv: 0});

        LendingCore(CORE).createMarket(nest, NEST_CM, ENGINE, KEEPER);
        LendingCore(CORE).createMarket(kit, KITTEN_CM, ENGINE, KEEPER);
        vm.stopBroadcast();

        console2.log("KinkIRM            ", address(irm));
        console2.log("NEST interest mktId");
        console2.logBytes32(Id.unwrap(nest.id()));
        console2.log("KITTEN interest mktId");
        console2.logBytes32(Id.unwrap(kit.id()));
        console2.log("== POST: keeper must use these params (irm = KinkIRM); set supplyCap to open ==");
    }
}
