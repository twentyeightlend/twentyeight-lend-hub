# twentyeight-lend — Audit Scope

**Audit contact:** scoping@pashov.com (Pashov Audit Group)
**Chain:** HyperEVM (chainId 999) · **Solidity:** 0.8.26 (Cancun, `via_ir`) · **Framework:** Foundry
**Repo state:** `main` — tag a frozen commit before engagement (current HEAD `d85b2b3` has pending working-tree changes).
**Build/test:** `forge test --no-match-path "test/Fork*.t.sol"` — 113 tests (unit + 12.8k-call invariant suite) green. Fork tests need a pinned recent block (see test/Fork*).

---

## Protocol summary
Immutable, isolated-market lending against veNFT **voting-fee cashflow** (Morpho-Blue architecture; same category as 40acres, but reward entitlement is computed **on-chain** from votes × pool fees — no off-chain relayer). Borrowers draw USDC against a veNEST/veKITTEN lock; loans **self-repay** from the lock's harvested voting fees. Non-liquidating base tier; a principal-backed tier (wveNEST) is built but **not part of the launch**.

## Codebase size
23 contracts, **~2,200 nSLOC** (excl. interfaces; `TickMath` ~130 nSLOC is standard Uniswap math). See breakdown below.

---

## In scope

### Recommended LAUNCH engagement (~1,400 nSLOC) — audit this first
The live yield-tier markets (veNEST + veKITTEN) only:
- `src/LendingCore.sol` — immutable singleton: supply/withdraw, borrow/repay, interest accrual, per-market supply cap, veNFT custody routing
- `src/adapters/KittenAdapter.sol`, `src/adapters/NestAdapter.sol` — veNFT custody, harvest, vote, guardian pause
- `src/credit/CreditLineManagerBase.sol`, `KittenCreditLineManager.sol`, `NestCreditLineManager.sol` — on-chain reward attestation → credit line
- `src/SelfRepayEngine.sol` — oracle-floored reward→USDC swaps → repay
- `src/LenderVault.sol` — ERC4626 over a single market
- `src/irm/KinkIRM.sol` — kinked interest-rate model
- `src/libraries/SharesMathLib.sol`, `PythPriceLib.sol`, `Types.sol`
- `src/periphery/AlgebraRouterAdapter.sol`
- `src/interfaces/*`

### Phase 3 — principal tier (audit later, separate engagement; ~800 nSLOC)
- `src/ReceiptWrapper.sol` (wveNEST liquid receipt) · `src/WrappedCollateralMarket.sol` (USDC vs wveNEST, LTV + liquidation + bad-debt)
- `src/oracles/VeTwapOracle.sol` (Algebra TWAP), `src/oracles/HaircutOracle.sol` (DLOM)
- `src/libraries/TickMath.sol`

## Out of scope (trust assumptions — review *integration*, not the contracts)
OpenZeppelin / Solady libraries (pre-audited). External protocol contracts: **NEST/KITTEN** votingEscrow / Voter / bribe / votingReward (upgradeable proxies), **Pyth**, **Algebra** pools.

---

## Threat model — priority focus areas
1. **Share inflation / donation** — ERC4626 vault + virtual shares (`SharesMathLib`)
2. **Oracle manipulation** — Pyth staleness/confidence; (Phase 3) Algebra TWAP cost-to-manipulate vs. value-borrowable on thin pools
3. **Self-repay MEV** — swap `minOut` floor adequacy given real Algebra pool depth (KITTEN/WHYPE ~$2k/day vol)
4. **Credit-line attestation correctness** — closed-epoch alignment, vote-share math, gross-of-claim handling, wash-fed-fee inflation across the trailing-MIN window
5. **Liquidation math + bad-debt socialization** (Phase 3 wrapped market)
6. **Reentrancy** across custody/harvest/vote flows
7. **Access control** — guardian/owner/keeper/core-only boundaries; confirm no privileged path can move custodied veNFTs
8. **Upgradeable-proxy dependency** — NEST/KITTEN escrow impl can change under an open loan; guardian-pause is the only mitigation
9. **Interest × non-liquidation** — max-draw-then-stop-voting lender griefing; IRM rate clamp
10. **veNFT custody edge cases** — managed/attached NEST (Debita #535), lock expiry vs loan maturity

### Suspected attack paths (the team's own sharpest worries — please prioritize PoCs here)
- Credit-line inflation by sustaining wash-traded fees on a voted pool across the 8-epoch window, then borrowing and exiting.
- Repeated self-repay sandwich skimming the full slippage tolerance per harvest on thin KITTEN pools.
- External escrow proxy upgrade mid-loan altering `locked()`/custody semantics.

---

## Provided materials
`BUILD_SPEC.md` (full engineering spec) · internal Security Audit Pass 1 & 2 notes + accepted findings · invariant suite (`test/invariant/`) · triaged Slither report (`slither.config.json`; 0 unmitigated high/med) · this scope.

## Known / accepted findings (do not re-report unless materially worse)
- NEST credit-line gas (multi-pool positions) — mitigated by cached, refreshable line
- Base-tier non-liquidating freeze if a borrower stops voting — mitigated by `voteKeeper`
- Permissionless per-market params are trust-critical and immutable (Morpho model) — disclosed to lenders
- Linear interest accrual (under-charges vs compounding — conservative)
- Owner-set emergency price (Phase 3 wrapped market) — centralization, multisig-gated

---

## nSLOC by area
| Area | ~nSLOC |
|---|---|
| core (LendingCore, SelfRepayEngine, LenderVault, ReceiptWrapper, WrappedCollateralMarket) | 1,111 |
| adapters | 434 |
| credit | 260 |
| oracles | 161 |
| libraries (incl. ~130 standard TickMath) | 131 |
| irm | 45 |
| periphery | 39 |
