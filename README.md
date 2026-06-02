# twentyeight-lend

Non-custodial lending against vote-escrow (ve) NFTs on **HyperEVM (chainId 999)**. veNFT holders
(veNEST priority, veKITTEN) borrow USDC against their locked position, and the loan self-repays from the
position's voting yield. Morpho-Blue-style architecture: an immutable singleton core plus isolated markets.

> Status: **deployed to HyperEVM mainnet.**

**Launch scope:** the live product is the **self-repaying credit-line tier** — loans are sized from
*realized* on-chain voting yield, are **non-liquidating**, and repay themselves. A separate liquid-wrapper
collateral module (`wveNEST`) is deployed but **dormant by design** (see *Design choice* below): it is not
enabled at launch, so lenders carry no liquid-locker / depeg exposure. USDC lenders supply to the
credit-line markets and earn interest paid by borrowers out of their voting yield (see *For lenders*).

## Architecture
**Core (live):**
- **LendingCore** — immutable singleton. Yield-tier markets keyed by `MarketParams`. On-chain credit
  lines sized from trailing-minimum voting fees (manipulation-proof historical share for NEST).
- **ve adapters** (Nest/Kitten) — custody veNFTs, strip approvals, pass through votes, harvest fees.
- **Credit-line managers** — compute borrowable credit from realized, historical per-gauge fee revenue.
- **SelfRepayEngine** — harvests voting fees and swaps them (oracle-floored, sandwich-protected) to pay
  down debt automatically; takes the 5% performance fee.
- **Keeper + monitor** (`keeper/`) — off-chain, non-custodial ops: re-vote, self-repay, and a read-only
  watchdog (proxy-upgrade, bad-debt, oracle-health, gas, keeper-liveness alerts).

**Liquid-wrapper module (deployed, dormant — not enabled at launch):**
- **ReceiptWrapper (wveNEST)** — liquid ERC20 wrapper over permanently-locked veNEST; Synthetix-style
  reward distribution to holders.
- **WrappedCollateralMarket** — USDC market with wveNEST as ERC20 collateral and liquidation.
- **Oracles** — Algebra TWAP (NEST/WHYPE × Pyth WHYPE/USD) with a deviation guard, wrapped by a haircut
  (DLOM) oracle. Only used by the wveNEST market.

## Economics (how the protocol earns)
Two revenue streams, both accruing on-chain to the treasury multisig — no custody, no manual market-making.

- **Performance fee on voting yield (live, 5%).** Borrowed positions self-repay from their gauge voting
  fees; the `SelfRepayEngine` routes `treasuryBps = 500` (5%) of each harvest to the treasury before
  repaying the borrower. It scales with locked TVL and voting yield, and is independent of interest rates
  or liquidations — closer to a yield-vault performance fee than a traditional lending spread.
- **Lending spread (dormant module).** If/when the liquid wveNEST collateral market is enabled, it can
  charge borrow interest and keep a protocol reserve cut of up to 25% of that interest (`MAX_FEE`). Not
  active at launch.

The performance fee is the protocol's live revenue. The protocol may also take a cut of borrow interest
(0% at launch, up to 25% via the Timelock). All fee changes flow through the 2-day Timelock (core) or the
market owner — transparent and rate-limited, so users can see any change coming.

## For lenders
Supply USDC to the NEST/KITTEN credit-line markets and earn the interest borrowers pay — funded by the
borrowers' voting bribes, not by token emissions or protocol capital. Rates follow a `KinkIRM` curve
(2% base, 14% at 90% utilization, 100% at 100%), targeting roughly **11–13% APR** for lenders in the
healthy utilization band (NEST voters currently earn ~19%+, so borrowers stay net-positive). The tier is
**non-liquidating**: credit is sized conservatively below realized yield and loans self-repay, but lenders
do bear borrower-default risk (there are no liquidations), which is why credit lines are deliberately
conservative. Interest markets:
- NEST: `0x6a640c12d0d1984e6230fbd7097f9fe3ce1d80520f202b02f92f5e3ce882de2c`
- KITTEN: `0xbed26819cc1aa8bcad2a848dd14cb89e38af209ce816f073df14e3cb620e8ea9`

## Why this design
- **On-chain, manipulation-proof credit.** Credit lines are sized from *realized, historical* per-gauge
  fee revenue (NEST uses `balanceOfAt` at a closed epoch), not an off-chain relayer or a spot snapshot
  that can be gamed.
- **Loans repay themselves.** Voting bribes are harvested and swapped (oracle-floored, sandwich-protected)
  to pay down debt automatically — the borrower doesn't have to manage it.
- **No liquid-locker collateral risk.** The live product lends against *realized voting yield*, not against
  a wrapper's market price. We deliberately do **not** use a liquid wrapper as loan collateral at launch
  (see *Design choice* below), so lenders can't be hit by a wrapper depeg.
- **Non-liquidating.** Credit is sized conservatively below realized yield and the loan self-repays — there
  are no liquidations in the live tier.
- **Immutable core, isolated markets.** No upgrade switch on the lending logic; per-market risk isolation;
  permissionless market creation.
- **Yield is actively maximized.** The keeper re-votes idle positions into the highest-fee gauges each
  epoch, so the cashflow that repays loans (and feeds the performance fee) is as large as possible.

## Design choice: why wveNEST collateral is dormant
A liquid wrapper of a *permanently* locked position has no redemption path, so it can trade below the
underlying's value and become exit liquidity — a well-documented failure mode for liquid lockers. Using
such a token as loan collateral would risk bad debt if it depegs faster than the oracle assumes. The core
protocol needs none of this: self-repay credit lines borrow against realized on-chain yield, never sell a
wrapper, and never depend on a peg. The wveNEST collateral market is **paused** (exit-only — no new supply
or borrow); it would only be enabled later, with a peg-aware oracle (pricing wveNEST at the *minimum* of
NEST-derived value and the wrapper's own market TWAP) and proven secondary liquidity. Until then, lenders
carry zero liquid-locker exposure.

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
| KinkIRM (lender-yield model) | `0xEA58bC25A7F096fcDFbFb3aDbEDabC9edF096C42` |
| AlgebraRouterAdapter | `0x8A7DAF63FA7C8d605a81d1D254De383c6a0b929e` |

The **live** product is LendingCore + ve adapters + credit managers + SelfRepayEngine. The **wveNEST Market,
ReceiptWrapper, HaircutOracle, and VeTwapOracle** belong to the dormant liquid-wrapper module (the market
is **paused**, exit-only) and are not in use at launch.

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
