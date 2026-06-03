# twentyeight-lend — Launch Deploy Runbook

Deploys the full stack on HyperEVM (chainId 999) with both veNFT markets **capped at $15k**
atomically (never live uncapped). The currently-deployed core (`0x545C…`) is immutable + uncapped
and is being replaced — it only holds ~$9 of test funds.

---

## 0. Prerequisites
- **Foundry** installed (`forge --version`).
- **Deployer EOA** funded with **HYPE** for gas. This key briefly owns the core during the script
  (to set caps), then hands ownership to the Timelock. Use a hardware wallet or keystore — not a
  raw hot key if you can avoid it.
- **Safe multisig addresses** ready for the 5 governance roles (can be the same Safe for several):
  `MULTISIG`, `GUARDIAN`, `KEEPER`, `TREASURY`, `YIELD_RECEIVER`.
- (Optional) `HYPERSCAN_KEY` if you want `--verify`.

## 1. Withdraw the old $9 FIRST
While the UI still points at the old core, open the app → **Withdraw** tab → withdraw your USDC.
(Or `cast send 0x545C9C426d968329f95F21146291E0C727015852 "withdraw((address,address,address,address,uint256),uint256,address,address)" ... --private-key $PK --rpc-url hyperevm`.)
Do this before switching `ADDR.core`, or the old position drops out of the UI.

## 2. Enable big blocks on the deployer EOA
HyperEVM needs **big blocks** for large deploys. This is an L1 action (`evmUserModify`,
`usingBigBlocks = true`) — NOT a forge command. Easiest path: Hyperliquid Python SDK
`exchange.use_big_blocks(True)`, or any HyperEVM "big blocks toggle" tool, signed by the deployer EOA.
Confirm it's on before broadcasting, or the deploy tx may not land.

## 3. Set environment variables
```bash
export MULTISIG=0xYourSafe          # owner of fast roles (becomes Timelock proposer/executor)
export GUARDIAN=0xYourGuardianSafe  # instant emergency pause
export KEEPER=0xYourKeeper          # vote keeper / harvest
export TREASURY=0xYourTreasury
export YIELD_RECEIVER=0xYourYieldReceiver
export TIMELOCK_MIN_DELAY=172800    # optional, default 2 days
export PK=0xYourDeployerPrivateKey  # or use --account / --ledger instead
```

## 4. Dry run (simulate, NO broadcast)
```bash
forge script script/Deploy.s.sol --rpc-url hyperevm --private-key $PK
```
Check it simulates cleanly and the console prints all addresses + the
"veNFT markets launched CAPPED at $15k each" line.

## 5. Broadcast for real
```bash
forge script script/Deploy.s.sol --rpc-url hyperevm --private-key $PK --broadcast --slow
```
`--slow` sends txs one at a time (safer with big blocks). **Copy every printed address.**
(Prefer `--ledger` or `--account <keystore>` over `--private-key` for a real launch.)

## 6. Post-deploy governance actions (multisig)
1. **Timelock `acceptOwnership()` on LendingCore** — finishes the governance handoff (multisig proposal).
   Until this runs, the deployer EOA is still owner; caps are already set, so markets stay capped.
2. **Guardian: `wrapper.addRewardToken(WHYPE / USDC / USDT0 / UETH)`** for wveNEST yield distribution.
3. **Multisig: `wveNestMarket.setSupplyCap(15000e6)`** — only when the principal market goes live.
4. Document/rehearse the `setEmergencyPrice` procedure for an oracle outage.

## 7. Verify the caps are live
```bash
# market id = keccak(abi.encode(MarketParams)); the UI's marketId() computes it, or read the event.
cast call <NEW_CORE> "supplyCap(bytes32)(uint256)" <MARKET_ID> --rpc-url hyperevm
# expect 15000000000  (15_000e6)
```

## 8. Point the frontend at the new stack
In `web/src/contracts.ts`, update from the script output:
- `ADDR.core`            → new LendingCore
- `ADDR.nestAdapter`     → new NestAdapter
- `ADDR.kittenAdapter`   → new KittenAdapter
- `MARKETS` NEST `creditManager`   → new NestCreditLineManager
- `MARKETS` KITTEN `creditManager` → new KittenCreditLineManager
- `DEPLOY_BLOCK` (in `App.tsx`) → the block the new core was deployed at (for the position log scan)

`ADDR.irm`, `ADDR.usdc`, and the `veToken` addresses are unchanged (not redeployed).

## 9. Ship the frontend
```bash
cd web && npm run build      # then deploy dist/ to your host (Caddy/Cloudflare)
```
Reload the site → Supply tab now shows the **Guarded rollout · $15k** card.

## 10. Raising the cap later (gradual, Morpho-style)
Cap raises go through the **Timelock** (`setSupplyCap`), rate-limited in the core to **≤2× per day**
and **never removable in one tx**. Lowering is instant. Ramp: $15k → $30k → … as production stays
clean. Emergency inflow-stop is the **guardian adapter-pause** (instant), so you never need a fast
cap-drop.
