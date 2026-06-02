# veNFT Lending on HyperEVM — Build Spec (NEST + KITTEN)

Goal: a self-repaying lending protocol where holders of vote-escrow NFTs (veNEST, veKITTEN)
draw USDC against their locked position, repaid from the position's own voting yield —
**materially better than 40acres.finance**, native to HyperEVM, targeting NEST (priority) + KITTEN.

Status: research + on-chain verification COMPLETE (2026-06-02). This is the engineering spec.
Verified addresses live in `../memory/project_ve_lending_hyperevm.md`. RPC chainId 999.

---

## PART 1 — How 40acres is actually built (reverse-engineered)

Source is public: **github.com/40-Acres/loan-contracts** (more useful than BaseScan).

- **Architecture:** evolved from a monolithic `Loan.sol`+`Vault.sol` (the Sherlock-audited, still-live design)
  to a **diamond-proxy per-user "Portfolio Account"** (facets: Voting, Claiming, RewardsProcessing,
  Collateral, ERC721Receiver, AccessControl).
- **Credit-line formula** (`CollateralManager.getMaxLoanByRewardsRate`):
  `maxLoan = ((veBalance * rewardsRate / 1e6) * multiplier) / 1e12`
  - `multiplier` = 8–10 epochs (config, raised over time). You borrow ~10 weeks of **rewards only**,
    never principal. A 33-AERO position borrows ~3 USDC. This is a yield-advance, not a loan.
  - **`rewardsRate` is PUSHED ON-CHAIN BY AN OFF-CHAIN RELAYER** (`RateStorage.setRewardsRate`).
    The averaging is NOT computed on-chain. **This is their core trust weakness** → a compromised/buggy
    relayer can over-state rewards and let users over-borrow. We remove this.
- **Reward split** (config, set at deploy `LoanConfig.initialize(_,20_00,5_00,1_00)`):
  ~75% → debt repayment, **20% → lenders**, **5% → treasury**, +1% zero-balance fee. Origination **0.8%**
  (cap 10%). **Interest 0%.** Reinvestment cap 25%.
- **Lender side:** ERC-4626 USDC vault; yield via share-price appreciation; **80% utilization cap**;
  flash-deposit guard (`lastDepositBlock < block.number`).
- **Custody/voting:** per-user diamond holds veAERO; votes via Aerodrome `IVoter.vote(tokenId,pools,weights)`;
  claims fees/bribes/rebases; swaps via `IAerodromeRouter`.
- **"Immutable" claim is only PARTLY true:** the original supply `Vault` (0xb99b…7cf5) is immutable, but the
  **new PortfolioManager is a proxy, LendingVault is UUPS, and the diamond facets are upgradeable.**
- **Audits:** 3 private Sherlock collaborative audits + $50k bug bounty. Findings NOT public.

---

## PART 2 — Where 40acres is weak → how we beat it (ranked by impact)

1. **CAPITAL EFFICIENCY (their #1 weakness).** They lend ~10 epochs of *rewards only*.
   → We add a **principal-backed term tier** with real LTV alongside the yield-only tier. 10–50× more borrow/position.
2. **PERMANENT-LOCK BLINDSPOT — our structural moat.** ON-CHAIN VERIFIED: **~97% of locked NEST is PERMANENT**
   (permanentTotalSupply 1.318B of 1.357B). A permanent locker has ZERO exit — can never sell or unlock.
   40acres ignores this. → We **wrap the permanent lock → mint a liquid veNEST receipt → lend against the
   receipt's value** (iAERO-proven shape). We give permanent lockers the one thing they lack: exit + borrow power.
3. **PRODUCT GAPS.** No leverage, no tradable position, secondary market still "coming soon."
   → Ship at launch: **one-click leverage loop** (lock→borrow→buy→relock), **ERC-721 tradable loan positions**,
   **live secondary market**.
4. **TRUST/ORACLE FLAW.** Off-chain relayer pushes `rewardsRate`. → We compute reward entitlement from
   **on-chain readable reward data** (KITTEN exposes `earnedForPeriod`/`rewardForPeriod`/`tokenIdVotesInPeriod`;
   NEST via Voter weights) — oracle-attested, not trusted-pushed.
5. **OPAQUE RELAYER (1% fee, unknown operator).** → **Permissionless keeper auction**: anyone cranks the
   epoch harvest for a small on-chain tip. Trustless + cheaper.
6. **ECONOMICS.** 0% interest + thin 20% lender share. → **Utilization-based dynamic rate**, small interest
   spread on the principal tier, **senior/junior tranches** to isolate bad debt and pay junior more.
7. **UPGRADEABILITY.** Their custody/accounting is upgradeable. → **Truly immutable core + immutable adapters**
   (Morpho ethos). Flexibility via new markets/adapters behind a timelocked allowlist, not proxy upgrades.

---

## PART 3 — Our architecture (Morpho-Blue-style: immutable singleton + isolated markets)

`LendingCore` never touches a ve-protocol directly — only through `IVeAdapter`. That seam lets NEST,
KITTEN (and later HYBR) plug in despite different ABIs. **Isolated markets** so a NEST rug can't sink
KITTEN lenders.

| Contract | Responsibility | Mutability |
|---|---|---|
| `LendingCore` (singleton) | All accounting: supply/withdraw/borrow/repay, shares, debt index, per-market state keyed by `id=keccak(MarketParams)` | **Immutable** |
| `MarketRegistry` | `createMarket(MarketParams)`; timelocked allowlist of adapters/oracles/IRMs | Immutable + governed allowlist |
| `NestAdapter`, `KittenAdapter` (`IVeAdapter`) | veNFT custody, vote, harvest, ABI normalization | Immutable per deploy |
| `SelfRepayEngine` | Per-epoch harvest→swap→amortize keeper entry (permissionless, tipped) | Immutable; router via allowlist |
| `IOracle` impls | `price()` in loan-asset terms = `min(marketPrice, redemptionFloor)` | Per-market immutable |
| `IIRM` | Utilization-kink variable rate (yield tier ~0%); fixed for term tier | Per-market immutable |
| `LenderVault` (ERC-4626) | Tokenized lender shares over a market's supply side | Immutable |
| `PositionNFT` (ERC-721) | Tokenizes borrower position (custodied veNFT + debt) → tradable | Immutable |
| `ReceiptWrapper` (NEST permanent) | Wrap permanent veNEST → liquid receipt token (the moat feature) | Immutable |

### IVeAdapter (the abstraction seam)
```solidity
interface IVeAdapter {
    // custody
    function custody(uint256 tokenId, address from) external returns (bytes32 posKey);
    function recoverUnderlying(uint256 tokenId, address to) external; // permanent: unlockPermanent→decay→withdraw
    function isPermanentLock(uint256 tokenId) external view returns (bool);
    function lockEnd(uint256 tokenId) external view returns (uint256); // 0 if permanent
    // valuation (adapter hides NEST's missing locked() getter)
    function currentVotingPower(uint256 tokenId) external view returns (uint256);
    function underlyingToken() external view returns (address);
    // yield
    function harvestableYield(uint256 tokenId) external view returns (uint256 amount, address token);
    function harvest(uint256 tokenId) external returns (uint256 amount, address token);
    function vote(uint256 tokenId, bytes calldata voteData) external;
}
```
- **NestAdapter:** no `locked()` → derive power from `balanceOfNFT`/point-slope; rebase is push-based →
  `harvest` reads the adapter's own balance delta (rebase accrues to holder); permanent → `recoverUnderlying`
  uses `unlockPermanent`→decay→`withdraw`; `vote` via `Voter.vote`, claim via `Voter.claimBribes/claimRewards`.
- **KittenAdapter:** standard `locked()`, `voted()`, readable `earnedForPeriod` → clean path.

### MarketParams
```solidity
struct MarketParams { address loanToken; address veAdapter; address oracle; address irm; uint256 lltv; }
```

### Self-repaying engine (simpler than Alchemix — real USDC, no synthetic/transmuter)
Per epoch, anyone calls `amortize(id, tokenId)`:
1. `adapter.harvest()` → yield token
2. swap yield→loanToken, **minOut derived from oracle (NOT pool spot)**, slippage+deadline guarded
3. `core.repayOnBehalf(...)` — credits debt; **cash never sent to borrower**
Debt is monotonically non-increasing while `epochYield ≥ epochInterest`; enforce
`borrowAPR ≤ expectedYieldAPR × safetyFactor` at open. Healthy positions de-lever over time.

---

## PART 4 — Security checklist (must-implement, from real audit findings)

1. **Debita #535 (CRITICAL — managed-NFT escape):** reject deposit unless `escrowType==NORMAL`; while
   collateralized, vault must self-restrict from `depositManaged/lockPermanent/increaseAmount/merge/split`.
2. **Velodrome C4 #185:** implement `onERC721Received`; ensure vault can `vote/claim/withdraw` (never freeze the lock).
3. **Approval-stripping on intake:** `approve(0,id)`, clear delegates, assert `getApproved(id)==0`.
4. **Same-block flash guard:** don't value/vote a veNFT in the block it arrived (`ownershipChange==block`).
5. **Gauge allowlist:** `vote()` reverts on non-allowlisted pools; changes timelocked.
6. **ERC-4626 inflation:** OZ v5 virtual-shares offset ≥6 + seed dead shares.
7. **Harvest→swap sandwich (Alchemix #30682):** oracle-derived `minOut`, deadline, size cap, consider private submit.
8. **Amortization rounding:** round debt-reduction down / remaining-debt up; clamp `debt = debt>repay? debt-repay : 0`.
9. **Pyth staleness+confidence (Debita #548/#825):** `getPriceNoOlderThan(60–120s)`; use `price−conf` for collateral.
10. **Thin-token TWAP:** ≥30min TWAP; cross-check Pyth vs DEX; freeze-and-use-lowest on divergence; circuit breaker.
11. **Underlying ve is an upgradeable proxy (NEST & KITTEN both):** pin impl, monitor `Upgraded`, auto-pause on change, try/catch all ve calls.
12. **Permanent-lock default recovery:** unit-test `unlockPermanent`→decay→`withdraw`→swap→repay end-to-end.
13. **Admin:** 2-step ownership, guardian can pause borrows+liquidations but NOT move funds, ≥24–48h timelock on params.
14. **HyperEVM:** big-block deploy (30M gas); HyperCore precompile = one oracle among several, never sole; confirm tx before dependent actions.

---

## PART 5 — Concrete parameters (starting points, tune with real data)

| Param | KITTEN (real expiry) | NEST (permanent) |
|---|---|---|
| Yield-only credit horizon H | 12 epochs | 12 epochs |
| Principal LTV_p | 0.60 of redeemable | 0.45 of DLOM-haircut value |
| DLOM haircut | — | 35–45% |
| Loop L_max / Λ_cap | 0.75 / 4× | 0.50 / 2× |
| Liquidation LTV | 0.85 | 0.60 |
| IRM kink U* | 0.85 | 0.85 |
| Fee split | 70% lender / 20% junior / 10% treasury | same |

**No-spiral invariant:** enforce `Λ·Y ≥ (Λ−1)·r_b` at open; throttle new loops if 7-epoch trailing
reward APR < `r_b·(Λ−1)/Λ`. Steady-state leverage `Λ = 1/(1−L)`; looped APR `≈ Λ·Y − (Λ−1)·r_b`.

---

## PART 6 — Build sequence (phased; prove-first)

- **Phase 0 (prove-first, BEFORE contracts):** aggregate real $ avg-weekly-reward per veNFT (rebase+fees+bribes)
  via event logs for NEST + KITTEN → confirm credit lines are safe and the model is profitable. (Task #3)
- **Phase 1 (core MVP):** `LendingCore` + `MarketRegistry` + `KittenAdapter` (cleanest) + `SelfRepayEngine`
  + ERC-4626 `LenderVault`, yield-only non-liquidating tier, oracle-agnostic. Full Foundry invariant tests.
- **Phase 2:** `NestAdapter` (absorb 3 Dromos quirks) + `ReceiptWrapper` for permanent veNEST (the moat).
- **Phase 3:** principal-backed term tier + `PositionNFT` tradable positions + secondary market.
- **Phase 4:** leverage loop + senior/junior tranches.
- Throughout: timelock + guardian + 2 audits + public contest before mainnet. Big-block deploy.

Decisions still open: loan denomination (USDC native vs USDT0 deeper liquidity), unified-senior vs
fully-isolated pools (recommended hybrid: shared senior USDC for yield-only tier, isolated junior per collateral).
