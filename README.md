# twentyeight-lend

Non-custodial lending against vote-escrow (ve) NFTs on **HyperEVM (chainId 999)**. veNFT holders
(veNEST priority, veKITTEN) borrow USDC against their locked position, self-repaid from voting yield.
Morpho-Blue-style architecture: an immutable singleton core plus isolated, permissionless markets.

> Status: **deployed to HyperEVM mainnet**. The market is launched with a guarded supply cap.

## Architecture
- **LendingCore** — immutable singleton. Yield-tier markets keyed by `MarketParams`. On-chain credit
  lines sized from trailing-minimum voting fees (manipulation-proof historical share for NEST).
- **ve adapters** (Nest/Kitten) — custody veNFTs, strip approvals, pass through votes, harvest fees.
- **Credit-line managers** — compute borrowable credit from realized, historical per-gauge fee revenue.
- **ReceiptWrapper (wveNEST)** — liquid ERC20 wrapper over permanently-locked veNEST; Synthetix-style
  reward distribution to holders.
- **WrappedCollateralMarket** — USDC market with wveNEST as ERC20 collateral; liquidation + collateral
  voting-yield forwarded to borrowers.
- **Oracles** — Algebra TWAP (NEST/WHYPE × Pyth WHYPE/USD) with a short-vs-long deviation guard, wrapped
  by a haircut (DLOM) oracle in Morpho 1e36 convention.
- **Keeper + monitor** (`keeper/`) — off-chain, non-custodial ops: re-vote, self-repay, liquidation
  watch, and a read-only watchdog (proxy-upgrade, bad-debt, oracle-health, gas, keeper-liveness alerts).

## Deployed addresses (HyperEVM, chainId 999)
| Contract | Address |
|---|---|
| Timelock (2-day) | `0x4B5bb0C23bA48449F4cF23cAdEa5Ac2169cAb912` |
| LendingCore | `0x545C9C426d968329f95F21146291E0C727015852` |
| wveNEST Market | `0x84950aF78cD77e124992a642087e26279b6Abe7e` |
| ReceiptWrapper (wveNEST) | `0xC0f9B28D02ecb2633262D1AA58C41d68aB9BcAbE` |
| HaircutOracle | `0x2cFAcd7969aB19DF9CFbdD89F5c5440Db11da658` |
| VeTwapOracle (NEST) | `0xA2988e27374f6A61665Fa66Eb1251E92E26aAffA` |
| SelfRepayEngine | `0x63317AFEa8ea5C59E01dC492546aC89d0d4F8b23` |
| NestAdapter | `0x63BA0cf6b4bf32A1c4E3C1C9076a5dadB7F216c1` |
| KittenAdapter | `0x295D025258E72dA9203F3aAA777Fe61B297af415` |
| NestCreditLineManager | `0x0288cD9f29279d9CF0DcF36cC89bD0A67b4eaC6A` |
| KittenCreditLineManager | `0x7eA45Ba437E1DC52485DD65820907953ba9ed261` |
| AlgebraRouterAdapter | `0x8A7DAF63FA7C8d605a81d1D254De383c6a0b929e` |

## Verify it yourself
**Build & test:**
```bash
forge install            # or: git submodule update --init --recursive
forge test               # unit + invariant/fuzz + fork-pinned tests
```
**Bytecode matches source** — compare any deployed contract to the local artifact:
```bash
diff <(cast code <address> --rpc-url https://rpc.hyperliquid.xyz/evm) \
     <(forge inspect <ContractName> deployedBytecode)
```
**Governance is locked, no deployer backdoor:**
```bash
RPC=https://rpc.hyperliquid.xyz/evm
cast call 0x545C9C426d968329f95F21146291E0C727015852 "owner()(address)" --rpc-url $RPC   # == Timelock
cast call 0x4B5bb0C23bA48449F4cF23cAdEa5Ac2169cAb912 "getMinDelay()(uint256)" --rpc-url $RPC  # 172800 (2d)
# deployer holds NO timelock roles (proposer/executor/admin all false)
```

## Security model
- **Core is immutable** — no proxy, no upgrade path on the lending logic.
- **2-day Timelock** owns the core; a multisig holds proposer/executor; **the deployer has zero roles**.
- **Guardian** can pause adapters/wrapper into exit-only mode (repay/withdraw always open).
- **Guarded rollout** via supply cap; oracle deviation guards; on-chain liquidation with bad-debt
  socialization; emergency-price fallback for oracle outages.
- Off-chain keeper key is low-privilege (gas-only vote/self-repay caller; cannot move user funds).

## Repository layout
- `src/` — contracts. `test/` — Foundry tests. `script/Deploy.s.sol` — deployment.
- `keeper/` — off-chain keeper + monitor (Node/viem). `ROLLOUT.md` — operational runbook.

## Disclaimer
Experimental DeFi software. Interacting with these contracts carries risk of loss. Not audited advice;
do your own review using the steps above.
