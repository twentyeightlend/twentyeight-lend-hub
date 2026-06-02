// twentyeight-lend monitor — READ-ONLY watchdog. No private key, never sends a tx. It only reads
// chain state and raises alerts (console + optional webhook) so a human/guardian can act. Checks:
//   1) proxyUpgrades   — NEST/KITTEN (and any WATCH_PROXIES) EIP-1967 impl slot vs baseline + Upgraded
//                        events. CRITICAL: a malicious ve-issuer upgrade must trigger GUARDIAN pause().
//   2) badDebt         — wveNEST market Liquidate events with badDebt>0 (lender loss socialised).
//   3) oracleHealth    — market oracle.price() reverts (TWAP unservable / Pyth stale / OracleUnavailable).
//   4) utilization     — totalBorrowAssets/totalSupplyAssets near 100% (liquidity crunch / supply at risk).
//   5) keeperLiveness  — keeper-state.json lastBlock not advancing => keeper stuck (votes/self-repay stop).
// Safety: read-only by construction; every check isolated in try/catch; alerts are de-duplicated with a
// cooldown so a persistent condition pages once per window, not every tick.
import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { createPublicClient, http, getAddress, parseEther, formatEther } from "viem";
import { marketAbi } from "./abis.mjs";

// ---------------------------------------------------------------- config
const env = process.env;
const RPC = env.RPC_URL || "https://rpc.hyperliquid.xyz/evm";
const POLL = Number(env.POLL_SECONDS || 60) * 1000;
const RUN_ONCE = env.RUN_ONCE === "1" || process.argv.includes("--once");
const STATE_FILE = env.MONITOR_STATE_FILE || "./monitor-state.json";
const KEEPER_STATE_FILE = env.KEEPER_STATE_FILE || "./keeper-state.json";
const WEBHOOK = env.ALERT_WEBHOOK || ""; // Slack/Discord-compatible incoming webhook (optional)
const COOLDOWN = Number(env.ALERT_COOLDOWN_SECONDS || 3600) * 1000; // re-page a stuck condition at most once/window
const UTIL_ALERT_BPS = Number(env.UTIL_ALERT_BPS || 9500); // alert when borrow/supply >= this (default 95%)
const KEEPER_STALE_SECONDS = Number(env.KEEPER_STALE_SECONDS || 900) * 1000; // keeper block must advance within this
const LOG_RANGE = 9000; // RPC getLogs block-range cap

const MARKET = env.WVENEST_MARKET || "";
const ORACLE = env.HAIRCUT_ORACLE || "";
const KEEPER_ADDRESS = (() => { try { return getAddress(env.KEEPER_ADDRESS || ""); } catch { return ""; } })();
const KEEPER_MIN_WEI = parseEther(env.KEEPER_MIN_HYPE || "0.05"); // alert if keeper gas falls below this
// proxies to watch for upgrades. Default to the ve-issuer governance surfaces if set individually.
const WATCH_PROXIES = (env.WATCH_PROXIES ||
    [env.VE_NEST, env.VE_KITTEN, env.NEST_VOTER, env.KITTEN_VOTER].filter(Boolean).join(","))
    .split(",").map((s) => s.trim()).filter(Boolean)
    .map((a) => { try { return getAddress(a); } catch { return null; } }).filter(Boolean);

// EIP-1967 implementation slot and the standard Upgraded(address) event topic.
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const UPGRADED_TOPIC = "0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b";

const oracleAbi = [{ name: "price", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }];

const pub = createPublicClient({ transport: http(RPC) });

// ---------------------------------------------------------------- state (alert dedupe + baselines)
function loadState() {
    if (existsSync(STATE_FILE)) { try { return JSON.parse(readFileSync(STATE_FILE, "utf8")); } catch { /* corrupt -> reinit */ } }
    return { lastBlock: Number(env.START_BLOCK || 0), implBaseline: {}, lastAlerts: {}, keeperBlock: 0, keeperBlockSeenAt: 0 };
}
function saveState(s) { writeFileSync(STATE_FILE, JSON.stringify(s, null, 2)); }

// ---------------------------------------------------------------- alerting
async function alert(state, key, severity, msg) {
    const now = Date.now();
    const last = state.lastAlerts[key] || 0;
    const line = `[${severity}] ${msg}`;
    if (now - last < COOLDOWN) { console.log(`  (suppressed, cooldown) ${line}`); return; }
    state.lastAlerts[key] = now;
    console.log(`  *** ALERT ${line}`);
    if (!WEBHOOK) return;
    const text = `🚨 twentyeight-lend ${line}`;
    try {
        const r = await fetch(WEBHOOK, {
            method: "POST", headers: { "content-type": "application/json" },
            body: JSON.stringify({ text, content: text }), // text=Slack, content=Discord
            signal: AbortSignal.timeout(10000)
        });
        if (!r.ok) console.warn(`  webhook ${r.status}`);
    } catch (e) { console.warn(`  webhook failed: ${(e.message || "").slice(0, 80)}`); }
}

// ---------------------------------------------------------------- checks
// CRITICAL. Poll the EIP-1967 impl slot of each watched proxy; alert on any change vs the recorded
// baseline. First sight just records the baseline (no alert). Slot read is upgrade-pattern agnostic
// (catches an upgrade even if no Upgraded event was emitted).
async function checkProxyUpgrades(state) {
    for (const proxy of WATCH_PROXIES) {
        const slot = await pub.getStorageAt({ address: proxy, slot: IMPL_SLOT }).catch(() => null);
        if (slot == null || slot.length < 66) continue; // unreadable / short -> skip
        let raw; try { raw = BigInt(slot); } catch { continue; }
        if (raw === 0n) continue; // empty slot => not an EIP-1967 proxy -> skip
        const impl = getAddress("0x" + slot.slice(26)); // low 20 bytes, checksummed
        const prev = state.implBaseline[proxy];
        if (!prev) { state.implBaseline[proxy] = impl; console.log(`  proxy ${proxy} impl baseline ${impl}`); continue; }
        if (prev.toLowerCase() !== impl.toLowerCase()) {
            await alert(state, `upgrade:${proxy}`, "CRITICAL",
                `PROXY UPGRADED ${proxy}: ${prev} -> ${impl}. GUARDIAN must pause() adapters+wrapper NOW (exit-only).`);
            state.implBaseline[proxy] = impl; // re-baseline so we don't page forever on the same impl
        }
    }
}

// Scan recent blocks for market Liquidate events carrying badDebt>0 (socialised lender loss) and any
// Upgraded events on the watched proxies (belt-and-suspenders alongside the slot poll).
async function scanLogs(state, fromBlock, toBlock) {
    if (MARKET) {
        for (let s = fromBlock; s <= toBlock; s += LOG_RANGE) {
            const e = Math.min(s + LOG_RANGE - 1, toBlock);
            const evs = await pub.getContractEvents({ address: MARKET, abi: marketAbi, eventName: "Liquidate", fromBlock: BigInt(s), toBlock: BigInt(e) }).catch(() => []);
            for (const ev of evs) {
                const bd = ev.args.badDebt || 0n;
                if (bd > 0n) await alert(state, `baddebt:${ev.transactionHash}`, "CRITICAL",
                    `BAD DEBT ${bd} (USDC base units) on liquidation of ${ev.args.borrower} tx ${ev.transactionHash}.`);
            }
        }
    }
    if (WATCH_PROXIES.length) {
        for (let s = fromBlock; s <= toBlock; s += LOG_RANGE) {
            const e = Math.min(s + LOG_RANGE - 1, toBlock);
            const logs = await pub.getLogs({ address: WATCH_PROXIES, topics: [UPGRADED_TOPIC], fromBlock: BigInt(s), toBlock: BigInt(e) }).catch(() => []);
            for (const lg of logs) {
                // The HyperEVM RPC ignores the topics filter when an address ARRAY is passed (it returns
                // all logs from those addresses). Verify topic0 client-side so we never mislabel a normal
                // Transfer/Vote/Deposit as an Upgraded event. The impl-slot poll is the authoritative check.
                if (lg.topics?.[0]?.toLowerCase() !== UPGRADED_TOPIC) continue;
                await alert(state, `upgradeevt:${lg.transactionHash}:${lg.logIndex}`, "CRITICAL",
                    `Upgraded event on ${lg.address} tx ${lg.transactionHash}. Verify + GUARDIAN pause if unexpected.`);
            }
        }
    }
}

// Read the market oracle's price(); a revert means liquidations can't price collateral (TWAP unservable,
// Pyth stale, deviation guard, or OracleUnavailable). Borrower exits still work oracle-free.
async function checkOracle(state) {
    if (!ORACLE) return;
    try {
        const p = await pub.readContract({ address: ORACLE, abi: oracleAbi, functionName: "price" });
        if (p === 0n) await alert(state, "oracle:zero", "WARN", "oracle.price() returned 0 — collateral would value to nothing.");
    } catch (e) {
        await alert(state, "oracle:revert", "CRITICAL",
            `oracle.price() REVERTED (${(e.shortMessage || e.message || "").split("\n")[0].slice(0, 80)}). Liquidations blocked until MULTISIG setEmergencyPrice / oracle recovers.`);
    }
}

// Utilization = borrow/supply. Near 100% means lenders can't withdraw and a small loss eats principal.
async function checkUtilization(state) {
    if (!MARKET) return;
    const sup = await pub.readContract({ address: MARKET, abi: marketAbi, functionName: "totalSupplyAssets" }).catch(() => null);
    const bor = await pub.readContract({ address: MARKET, abi: marketAbi, functionName: "totalBorrowAssets" }).catch(() => null);
    if (sup == null || bor == null || sup === 0n) return;
    const bps = Number((bor * 10000n) / sup);
    if (bps >= UTIL_ALERT_BPS) await alert(state, "util:high", "WARN",
        `utilization ${(bps / 100).toFixed(1)}% (borrow ${bor} / supply ${sup}). Liquidity tight.`);
}

// The keeper persists an advancing lastBlock. If it stops advancing, votes/self-repay/liquidations
// stall. Track the value + when we first saw it; page if it hasn't moved within KEEPER_STALE_SECONDS.
async function checkKeeperLiveness(state) {
    if (!existsSync(KEEPER_STATE_FILE)) return; // keeper not colocated -> skip (no false alarm)
    let ks; try { ks = JSON.parse(readFileSync(KEEPER_STATE_FILE, "utf8")); } catch { return; }
    const now = Date.now();
    const blk = Number(ks.lastBlock || 0);
    const mtime = statSync(KEEPER_STATE_FILE).mtimeMs;
    if (blk !== state.keeperBlock) { state.keeperBlock = blk; state.keeperBlockSeenAt = now; return; }
    // block unchanged: stale only if the file itself also hasn't been rewritten within the window
    const idle = now - Math.max(state.keeperBlockSeenAt || mtime, mtime);
    if (idle > KEEPER_STALE_SECONDS) await alert(state, "keeper:stale", "WARN",
        `keeper lastBlock stuck at ${blk} for ${Math.round(idle / 1000)}s — keeper may be down (votes/self-repay/liquidations halted).`);
}

// Silent gas exhaustion: a broke keeper still scans events (lastBlock advances), so the staleness
// check above won't catch it — but its sends fail, so liquidations/self-repay/re-votes stop. Watch
// the keeper EOA balance directly.
async function checkKeeperGas(state) {
    if (!KEEPER_ADDRESS) return; // not configured -> skip
    const bal = await pub.getBalance({ address: KEEPER_ADDRESS }).catch(() => null);
    if (bal == null) return;
    if (bal < KEEPER_MIN_WEI) await alert(state, "keeper:gas", "WARN",
        `keeper gas low: ${formatEther(bal)} HYPE < ${formatEther(KEEPER_MIN_WEI)} — top up ${KEEPER_ADDRESS} or sends (incl. liquidations) will fail.`);
}

// ---------------------------------------------------------------- loop
async function tick() {
    const state = loadState();
    const tip = Number(await pub.getBlockNumber());
    // first run with no START_BLOCK => watch forward only (don't scan all chain history)
    const from = (state.lastBlock > 0 ? state.lastBlock : tip) + 1;
    console.log(`[${new Date().toISOString()}] monitor tip=${tip} scan-from=${from} proxies=${WATCH_PROXIES.length} webhook=${WEBHOOK ? "on" : "off"}`);
    const checks = [
        ["proxyUpgrades", () => checkProxyUpgrades(state)],
        ["scanLogs", () => (from <= tip ? scanLogs(state, from, tip) : null)],
        ["oracleHealth", () => checkOracle(state)],
        ["utilization", () => checkUtilization(state)],
        ["keeperLiveness", () => checkKeeperLiveness(state)],
        ["keeperGas", () => checkKeeperGas(state)]
    ];
    for (const [name, fn] of checks) {
        try { await fn(); } catch (e) { console.warn(`  [check ${name} failed] ${(e.message || "").slice(0, 120)}`); }
    }
    if (from <= tip) state.lastBlock = tip; // only advance the log cursor after a successful tip read
    saveState(state);
}

async function main() {
    if (WATCH_PROXIES.length === 0 && !MARKET && !ORACLE) throw new Error("nothing to monitor: set WVENEST_MARKET / HAIRCUT_ORACLE / WATCH_PROXIES");
    if (RUN_ONCE) { await tick(); return; }
    for (;;) { await tick(); await new Promise((r) => setTimeout(r, POLL)); }
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
