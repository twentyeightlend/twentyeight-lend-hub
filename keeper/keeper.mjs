// twentyeight-lend keeper. Jobs each loop:
//   1) pushPyth        — refresh Pyth feeds (pull-based) so oracle-dependent txs don't revert
//   2) scanEvents      — discover positions from on-chain events, persist to STATE_FILE
//   3) revoteDeposits  — re-vote newly custodied veNFTs (custody RESETS votes) so they keep earning
//   4) runSelfRepay    — harvest+swap+repay positions carrying debt
//   5) watchLiquidations — liquidate unhealthy wveNEST-market positions
// Safety: DRY_RUN=1 by default (logs, never sends). Every job is isolated in try/catch so one
// failure never stops the others. The keeper key is a low-privilege hot key (gas only) and is
// never logged. All sends go through one wallet client (sequential nonces).
import { readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import {
    createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
    encodePacked, parseAbiParameters
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { lendingCoreAbi, selfRepayEngineAbi, marketAbi, pythAbi, voterReadAbi, MARKET_PARAMS } from "./abis.mjs";
import { computeTopPools } from "./optimalVote.mjs";

// ---------------------------------------------------------------- config
const env = process.env;
const need = (k) => { const v = env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const RPC = env.RPC_URL || "https://rpc.hyperliquid.xyz/evm";
const DRY = env.DRY_RUN !== "0"; // default DRY (safe)
const POLL = Number(env.POLL_SECONDS || 60) * 1000;
const RUN_ONCE = env.RUN_ONCE === "1" || process.argv.includes("--once");
const STATE_FILE = env.STATE_FILE || "./keeper-state.json";
const USDC = need("USDC");
const PYTH = need("PYTH");
const HERMES = env.HERMES_URL || "https://hermes.pyth.network";
const FEED_IDS = (env.PYTH_FEED_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);

const CORE = need("LENDING_CORE");
const ENGINE = need("SELF_REPAY_ENGINE");
const MARKET = need("WVENEST_MARKET");

// market params (must match on-chain exactly)
const IRM = env.IRM || ZERO(); // KinkIRM => interest-bearing markets; ZERO => legacy 0% markets
const NEST = { loanToken: USDC, veAdapter: need("NEST_ADAPTER"), oracle: ZERO(), irm: IRM, lltv: 0n };
const KIT = { loanToken: USDC, veAdapter: need("KITTEN_ADAPTER"), oracle: ZERO(), irm: IRM, lltv: 0n };
const NEST_VOTER = need("NEST_VOTER");
const KIT_VOTER = need("KITTEN_VOTER");
function ZERO() { return "0x0000000000000000000000000000000000000000"; }

// re-vote targets (operator-configured pools the keeper votes new deposits to). Empty => skip
// re-vote for that protocol (with a warning) — never guess.
const VOTE_NEST = (env.VOTE_POOLS_NEST || "").split(",").map((s) => s.trim()).filter(Boolean);
const VOTE_KIT = (env.VOTE_POOLS_KITTEN || "").split(",").map((s) => s.trim()).filter(Boolean);
// USE_OPTIMAL_VOTE=1: compute the top-fee pools live each tick instead of the static lists above.
const USE_OPTIMAL = env.USE_OPTIMAL_VOTE === "1";
const OPTIMAL_TOP_N = Number(env.OPTIMAL_TOP_N || 5);
// self-repay swap routes: tokenIn -> Algebra path (packed addrs). Empty data => direct hop.
const SWAP_TOKENS = (env.SELF_REPAY_TOKENS || "0x5555555555555555555555555555555555555555")
    .split(",").map((s) => s.trim()).filter(Boolean); // default: WHYPE

// ---------------------------------------------------------------- clients
const pub = createPublicClient({ transport: http(RPC) });
const account = env.KEEPER_PK ? privateKeyToAccount(env.KEEPER_PK) : null;
const wallet = account ? createWalletClient({ account, transport: http(RPC) }) : null;
if (!DRY && !wallet) throw new Error("DRY_RUN=0 requires KEEPER_PK");
const KEEPER = account ? account.address : "(dry-run, no key)";

function marketId(p) {
    return keccak256(encodeAbiParameters([MARKET_PARAMS], [p]));
}
const NEST_ID = marketId(NEST);
const KIT_ID = marketId(KIT);

// ---------------------------------------------------------------- state
function freshState() {
    return { lastBlock: Number(env.START_BLOCK || 0), nestTokens: [], kitTokens: [], marketBorrowers: [] };
}
function loadState() {
    if (existsSync(STATE_FILE)) {
        try {
            const s = JSON.parse(readFileSync(STATE_FILE, "utf8"));
            // tolerate older/partial files: backfill any missing arrays
            return { ...freshState(), ...s };
        } catch {
            // corrupt (e.g. truncated by a mid-write kill / full disk) — reinitialise rather than
            // crash-loop under pm2. Re-scanning from START_BLOCK recovers positions idempotently.
            console.warn("  state file unreadable, reinitialising from START_BLOCK");
        }
    }
    return freshState();
}
// Atomic write: write a temp file then rename, so a kill mid-write can never leave a corrupt STATE_FILE.
function saveState(s) {
    const tmp = STATE_FILE + ".tmp";
    writeFileSync(tmp, JSON.stringify(s, null, 2));
    renameSync(tmp, STATE_FILE);
}
const uniqPush = (arr, v) => { if (!arr.includes(v)) arr.push(v); };

// ---------------------------------------------------------------- tx helper
async function send(label, address, abi, functionName, args, value = 0n) {
    if (DRY) { console.log(`  [DRY] ${label} ${functionName}(${args.map(String).join(",")})${value ? ` value=${value}` : ""}`); return; }
    try {
        const { request } = await pub.simulateContract({ account, address, abi, functionName, args, value });
        const hash = await wallet.writeContract(request);
        console.log(`  [tx] ${label} ${functionName} -> ${hash}`);
        await pub.waitForTransactionReceipt({ hash });
    } catch (e) {
        console.warn(`  [skip] ${label} ${functionName}: ${(e.shortMessage || e.message || "").split("\n")[0].slice(0, 90)}`);
    }
}

// ---------------------------------------------------------------- jobs
async function pushPyth(state) {
    if (FEED_IDS.length === 0) return;
    // Only push when there's something oracle-dependent to protect. An empty market needs no
    // fresh feed; pushing every tick would needlessly drain the keeper's gas. scanEvents runs
    // first so this sees up-to-date position counts.
    if (!state.marketBorrowers.length && !state.nestTokens.length && !state.kitTokens.length) {
        console.log("  pyth: no positions yet, skip push");
        return;
    }
    const ids = FEED_IDS.map((id) => `ids[]=${id}`).join("&");
    const r = await fetch(`${HERMES}/v2/updates/price/latest?${ids}&encoding=hex`, { signal: AbortSignal.timeout(12000) });
    if (!r.ok) { console.warn("  pyth: hermes fetch failed", r.status); return; }
    const j = await r.json();
    const updateData = (j.binary?.data || []).map((h) => (h.startsWith("0x") ? h : `0x${h}`));
    if (updateData.length === 0) { console.warn("  pyth: no update data"); return; }
    const fee = await pub.readContract({ address: PYTH, abi: pythAbi, functionName: "getUpdateFee", args: [updateData] });
    await send("pyth", PYTH, pythAbi, "updatePriceFeeds", [updateData], fee);
}

async function scanEvents(state) {
    const tip = Number(await pub.getBlockNumber());
    let from = state.lastBlock + 1;
    if (from > tip) return;
    const STEP = 9000; // RPC log range cap
    for (let start = from; start <= tip; start += STEP) {
        const end = Math.min(start + STEP - 1, tip);
        const core = await pub.getContractEvents({ address: CORE, abi: lendingCoreAbi, fromBlock: BigInt(start), toBlock: BigInt(end) }).catch(() => []);
        for (const ev of core) {
            if (ev.eventName === "SupplyCollateral") {
                const id = ev.args.id, tid = ev.args.tokenId.toString();
                if (id === NEST_ID) uniqPush(state.nestTokens, tid);
                else if (id === KIT_ID) uniqPush(state.kitTokens, tid);
            }
        }
        const mkt = await pub.getContractEvents({ address: MARKET, abi: marketAbi, fromBlock: BigInt(start), toBlock: BigInt(end) }).catch(() => []);
        for (const ev of mkt) {
            if (ev.eventName === "Borrow" || ev.eventName === "SupplyCollateral") {
                uniqPush(state.marketBorrowers, (ev.args.borrower || ev.args.onBehalf).toLowerCase());
            }
        }
        state.lastBlock = end;
    }
}

function voteData(pools) {
    const weights = pools.map(() => 1n); // equal; credit uses HISTORICAL share, fees use these
    return encodeAbiParameters(parseAbiParameters("address[], uint256[]"), [pools, weights]);
}

// Self-healing: re-vote any custodied position that currently has NO votes (custody resets votes,
// and epoch resets can clear them too). Idempotent — only votes when poolVoteLength==0, so no gas
// is wasted when a position is already voting.
async function revoteDeposits(state) {
    const todo = [
        { proto: "nest", params: NEST, id: NEST_ID, tokens: state.nestTokens, pools: VOTE_NEST, voter: NEST_VOTER },
        { proto: "kit", params: KIT, id: KIT_ID, tokens: state.kitTokens, pools: VOTE_KIT, voter: KIT_VOTER }
    ];
    for (let { proto, params, id, tokens, pools, voter } of todo) {
        // optionally replace the static target with the live top-fee pools (computed once per proto)
        if (USE_OPTIMAL) {
            const top = await computeTopPools({ rpc: RPC, hermes: HERMES, proto, voter, topN: OPTIMAL_TOP_N }).catch(() => []);
            if (top.length > 0) pools = top;
            console.log(`  optimal ${proto} pools: ${pools.length}`);
        }
        for (const tid of tokens) {
            const key = `${proto}:${tid}`;
            const pos = await pub.readContract({ address: CORE, abi: lendingCoreAbi, functionName: "position", args: [id, BigInt(tid)] }).catch(() => null);
            if (!pos || pos[0] === ZERO()) continue; // not custodied (e.g. withdrawn) -> skip
            const nVotes = await pub.readContract({ address: voter, abi: voterReadAbi, functionName: "poolVoteLength", args: [BigInt(tid)] })
                .catch(() => { console.warn(`  poolVoteLength read failed for ${key}; assuming voting (skip re-vote this tick)`); return 1n; });
            if (nVotes > 0n) continue; // already voting -> nothing to do
            if (pools.length === 0) { console.warn(`  revote ${key}: no VOTE_POOLS configured, skipping`); continue; }
            await send(`revote ${key}`, CORE, lendingCoreAbi, "vote", [params, BigInt(tid), voteData(pools)]);
        }
    }
}

async function runSelfRepay(state) {
    const swaps = SWAP_TOKENS.map((t) => ({ tokenIn: t, minOut: 0n, data: encodePacked(["address", "address"], [t, USDC]) }));
    const todo = [
        { proto: "nest", params: NEST, id: NEST_ID, tokens: state.nestTokens },
        { proto: "kit", params: KIT, id: KIT_ID, tokens: state.kitTokens }
    ];
    for (const { proto, params, id, tokens } of todo) {
        for (const tid of tokens) {
            const pos = await pub.readContract({ address: CORE, abi: lendingCoreAbi, functionName: "position", args: [id, BigInt(tid)] }).catch(() => null);
            if (!pos || pos[1] === 0n) continue; // no debt -> skip (engine would revert NoDebt)
            await send(`selfRepay ${proto}:${tid}`, ENGINE, selfRepayEngineAbi, "selfRepay", [params, BigInt(tid), swaps]);
        }
    }
}

// Poke the market to claim its accrued wveNEST voting rewards and distribute to collateral
// borrowers. No-op on-chain if totalCollateral==0 or no reward tokens allowlisted.
async function harvestCollatRewards() {
    const total = await pub.readContract({ address: MARKET, abi: marketAbi, functionName: "totalCollateral" }).catch(() => 0n);
    if (total === 0n) return;
    await send("collateral-yield", MARKET, marketAbi, "harvestCollateralRewards", []);
}

async function watchLiquidations(state) {
    const alive = [];
    for (const borrower of state.marketBorrowers) {
        const pos = await pub.readContract({ address: MARKET, abi: marketAbi, functionName: "position", args: [borrower] }).catch(() => null);
        if (pos === null) { alive.push(borrower); continue; } // read failed -> keep, retry next tick
        if (pos[0] === 0n && pos[1] === 0n) continue; // position fully closed -> prune from the watch list
        alive.push(borrower);
        const healthy = await pub.readContract({ address: MARKET, abi: marketAbi, functionName: "isHealthy", args: [borrower] }).catch(() => true);
        if (healthy || pos[0] === 0n) continue;
        console.log(`  UNHEALTHY ${borrower} collateral=${pos[0]} — liquidating`);
        await send(`liquidate ${borrower}`, MARKET, marketAbi, "liquidate", [borrower, pos[0]]); // seize up to all collateral
    }
    state.marketBorrowers = alive;
}

async function tick() {
    const state = loadState();
    console.log(`[${new Date().toISOString()}] keeper=${KEEPER} dry=${DRY} block-from=${state.lastBlock}`);
    for (const [name, fn] of [
        ["scanEvents", () => scanEvents(state)],
        ["pushPyth", () => pushPyth(state)],
        ["revoteDeposits", () => revoteDeposits(state)],
        ["runSelfRepay", () => runSelfRepay(state)],
        ["harvestCollatRewards", () => harvestCollatRewards()],
        ["watchLiquidations", () => watchLiquidations(state)]
    ]) {
        try { await fn(); } catch (e) { console.warn(`  [job ${name} failed] ${(e.message || "").slice(0, 120)}`); }
    }
    saveState(state);
}

async function main() {
    if (RUN_ONCE) { await tick(); return; }
    for (;;) { await tick(); await new Promise((r) => setTimeout(r, POLL)); }
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
