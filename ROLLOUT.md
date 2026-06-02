# twentyeight-lend — Mainnet Rollout Runbook (HyperEVM, chainId 999)

A guarded, reversible rollout. Do the phases in order; do not skip the gates.

## 0. Pre-flight (must all be TRUE)
- [ ] External audit report received and all High/Critical findings fixed & re-reviewed.
- [ ] `forge test` green (unit + invariant + fork): `export PATH="$PATH:/c/Users/cyber/.foundry/bin" && forge test`.
- [ ] Governance addresses ready as **multisigs** (Gnosis Safe, ≥2/3):
  - `MULTISIG` (market owner — fast actions: pause, emergencyPrice, supplyCap), also Timelock proposer/executor.
  - `GUARDIAN` (instant adapter/wrapper pause). `KEEPER`, `TREASURY`, `YIELD_RECEIVER`.
- [ ] Keeper hot-key funded with HYPE for gas only (low-privilege; it is the markets' `voteKeeper`).
- [ ] Confirm tunable params in `script/Deploy.s.sol` (DLOM 40%, LLTV 50%, bonus 8%, TWAP window 1800s,
      maxConfBps, multiplier/window, supply cap) vs current pool depth & risk appetite.

## 1. Deploy
1. Enable big blocks for the deployer EOA: HyperCore `evmUserModify(usingBigBlocks=true)` (off-chain).
2. `export MULTISIG=... GUARDIAN=... KEEPER=... TREASURY=... YIELD_RECEIVER=... TIMELOCK_MIN_DELAY=172800`
3. `forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast --slow`
4. Record every logged address (Timelock, AlgebraRouterAdapter, LendingCore, adapters, credit managers,
   engine, wrapper, oracles, wveNEST market). Verify on the explorer.

## 2. Post-deploy configuration (via multisig/guardian)
- [ ] `GUARDIAN`: `ReceiptWrapper.addRewardToken(WHYPE, USDC, USDT0, UETH)` — enables holder yield distribution.
- [ ] `MULTISIG` (market owner): `WrappedCollateralMarket.setSupplyCap(250_000e6)` — start small.
- [ ] `MULTISIG`: `WrappedCollateralMarket.addCollatRewardToken(WHYPE, USDT0, UETH)` — forward collateral
      voting yield (NOT USDC — comingled with lender liquidity, rejected by the contract).
- [ ] Confirm `voteKeeper` on each LendingCore market == the keeper address (set at createMarket).
- [ ] Sanity-read each oracle `price()` and a known whale `creditLine` on-chain; compare to expectations.
- [ ] Document the `setEmergencyPrice` procedure (only used if the oracle reverts during an outage).

## 3. Keeper bring-up
1. `cd keeper && npm install`, copy `.env.example` -> `.env`, fill addresses + `KEEPER_PK`.
2. Run with `DRY_RUN=1 npm run once` — verify it scans, prices via Pyth, and logs intended txs only.
3. Flip `DRY_RUN=0`, run `npm start` under a process manager (pm2/systemd). Jobs: Pyth push, event scan,
   self-healing re-vote (set `USE_OPTIMAL_VOTE=1` to vote top-fee pools), self-repay, collateral-yield
   harvest, liquidation watch. Alert on repeated `[skip]`/`[job failed]` lines.
4. Start the **monitor** (read-only, no key): set `ALERT_WEBHOOK`, `WATCH_PROXIES` (NEST/KITTEN ve + voters),
   `WVENEST_MARKET`, `HAIRCUT_ORACLE`; verify with `npm run monitor:once`, then `npm run monitor` under pm2.

## 4. Guarded rollout (raise caps only after each phase is clean for ≥1 week)
| Phase | Supply cap | Watch for |
|---|---|---|
| Soft launch | $250k | any bad debt, oracle reverts, keeper errors, liquidation execution |
| Scale 1 | $1M | utilization, self-repay throughput, credit-line sizing vs realized fees |
| Scale 2 | $5M+ | TWAP manipulation cost vs pool depth; widen window if pools thin |

## 5. Monitoring & alerts
Run `keeper/monitor.mjs` (read-only, no key; `npm run monitor`). It checks every poll and pages the
`ALERT_WEBHOOK` (Slack/Discord-compatible), de-duplicated with a cooldown:
- Proxy-upgrade watch (CRITICAL): polls each `WATCH_PROXIES` EIP-1967 impl slot vs a recorded baseline AND
  scans for `Upgraded` events — on any change the GUARDIAN must `pause()` adapters/wrapper immediately
  (exit-only mode; repay/withdraw stay open).
- Bad debt (CRITICAL): `Liquidate` events with non-zero `badDebt` (socialised lender loss).
- Oracle health (CRITICAL): market `oracle.price()` revert (`TickDeviationTooHigh`/`NotInitialized`/
  `OracleUnavailable`/stale Pyth) → liquidations blocked until MULTISIG `setEmergencyPrice`/oracle recovers.
- Utilization (WARN): `totalBorrowAssets/totalSupplyAssets` ≥ `UTIL_ALERT_BPS` (default 95%).
- Keeper liveness (WARN): `keeper-state.json` `lastBlock` not advancing within `KEEPER_STALE_SECONDS`
  → keeper down (votes/self-repay/liquidations halted).

## 6. Emergency procedures
- **NEST/KITTEN proxy upgraded maliciously** → GUARDIAN `pause()` adapters + wrapper. Users repay/withdraw; no new risk.
- **Oracle outage (Pyth stale / TWAP unservable)** → liquidations: MULTISIG `setEmergencyPrice(<sane 1e36>)` so
  unhealthy positions can be cleared; borrower exits already work oracle-free. Clear it once the oracle recovers.
- **Suspected exploit in a market** → market owner `pause()`; investigate; the core is immutable (no upgrade), so
  contain via pause + supplyCap=0 + guardian.
- Never raise caps or unpause during an active incident.

## Known limitations (disclose)
- LendingCore yield tier is NON-liquidating; credit is conservative (trailing-MIN fee × multiplier × safety).
- Custody resets a veNFT's votes; the keeper re-votes it (credit rebuilds over `window` epochs after deposit).
- USDC-denominated collateral voting fees are not forwarded (comingled with lender funds) — only WHYPE/USDT0/UETH.
- A malicious NEST/KITTEN proxy upgrade making a veNFT non-transferable can strand that NFT (inherent ve-issuer trust).
- Per-market modules (creditManager/oracle/irm) are creator-chosen; only supply to markets with vetted modules.
