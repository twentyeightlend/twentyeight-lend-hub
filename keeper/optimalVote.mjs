// Optimal-vote allocation: rank a DEX's pools by recent per-pool fee revenue (priced via Hermes)
// and return the top-N pool addresses to vote. Used by the keeper to (re)vote custodied positions
// into the highest-fee gauges so self-repay cashflow is maximised.
import { createPublicClient, http } from "viem";

// token -> { feedId, decimals } for pricing pool fees. Extend as needed.
const TOKENS = {
    "0x5555555555555555555555555555555555555555": { feed: "0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b", dec: 18 }, // WHYPE
    "0xb88339cb7199b77e23db6e890353e22632ba630f": { feed: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a", dec: 6 },  // USDC
    "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb": { feed: "0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b", dec: 6 },  // USDT0
    "0xbe6727b535545c67d5caa73dea54865b92cf7907": { feed: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace", dec: 18 }  // UETH
};
const WEEK = 604800;

const nestVoterAbi = [
    { name: "poolsCounts", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }] },
    { name: "pools", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
    { name: "poolToGauge", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "address" }] },
    { name: "gaugesState", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "bool" }, { type: "bool" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] },
    { name: "epochTimestamp", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }
];
const nestBribeAbi = [
    { name: "rewardsList", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
    { name: "rewardData", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }] }
];
const kitVoterAbi = [
    { name: "getPoolList", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
    { name: "getGauge", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "address" }, { type: "bool" }, { type: "address" }, { type: "bool" }, { type: "address" }] },
    { name: "getCurrentPeriod", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }
];
const kitRewardAbi = [
    { name: "getRewardList", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
    { name: "rewardForPeriod", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "uint256" }] }
];

async function fetchPrices(hermes) {
    const ids = Object.values(TOKENS).map((t) => `ids[]=${t.feed}`).join("&");
    const r = await fetch(`${hermes}/v2/updates/price/latest?${ids}`, { signal: AbortSignal.timeout(12000) });
    if (!r.ok) throw new Error(`hermes ${r.status}`);
    const j = await r.json();
    const byFeed = {};
    for (const p of j.parsed || []) {
        const id = p.id.startsWith("0x") ? p.id : `0x${p.id}`;
        byFeed[id.toLowerCase()] = Number(p.price.price) * 10 ** Number(p.price.expo);
    }
    return byFeed;
}
function tokenUsdPerWei(token, prices) {
    const t = TOKENS[token.toLowerCase()];
    if (!t) return 0; // unpriced -> excluded
    const px = prices[t.feed.toLowerCase()] || 0;
    return px / 10 ** t.dec;
}
const safe = async (fn) => { try { return await fn(); } catch { return null; } };

/// Rank NEST (Dromos) pools by last-closed-epoch internalBribe fee $; return top-N pool addresses.
async function topNest(client, voter, topN, prices) {
    const rc = (a, abi, fn, args = []) => client.readContract({ address: a, abi, functionName: fn, args });
    const counts = await safe(() => rc(voter, nestVoterAbi, "poolsCounts"));
    const et = await safe(() => rc(voter, nestVoterAbi, "epochTimestamp"));
    if (!counts || !et) return [];
    const epoch = Number(et) - WEEK; // last closed epoch
    const n = Math.min(Number(counts[0]), 60);
    const scored = [];
    for (let i = 0; i < n; i++) {
        const pool = await safe(() => rc(voter, nestVoterAbi, "pools", [BigInt(i)]));
        if (!pool) continue;
        const g = await safe(() => rc(voter, nestVoterAbi, "poolToGauge", [pool]));
        if (!g) continue;
        const gs = await safe(() => rc(voter, nestVoterAbi, "gaugesState", [g]));
        if (!gs || !gs[1]) continue; // not alive
        const intB = gs[2];
        const rl = await safe(() => rc(intB, nestBribeAbi, "rewardsList"));
        if (!rl) continue;
        let usd = 0;
        for (const t of rl) {
            const px = tokenUsdPerWei(t, prices);
            if (px === 0) continue;
            const rd = await safe(() => rc(intB, nestBribeAbi, "rewardData", [t, BigInt(epoch)]));
            if (rd) usd += Number(rd[1]) * px;
        }
        if (usd > 0) scored.push({ pool, usd });
    }
    scored.sort((a, b) => b.usd - a.usd);
    return scored.slice(0, topN).map((s) => s.pool);
}

/// Rank KITTEN pools by last-closed-period votingReward fee $; return top-N pool addresses.
async function topKitten(client, voter, topN, prices) {
    const rc = (a, abi, fn, args = []) => client.readContract({ address: a, abi, functionName: fn, args });
    const poolList = await safe(() => rc(voter, kitVoterAbi, "getPoolList"));
    const cur = await safe(() => rc(voter, kitVoterAbi, "getCurrentPeriod"));
    if (!poolList || cur === null) return [];
    const period = Number(cur) - 1;
    const scored = [];
    for (const pool of poolList.slice(0, 60)) {
        const g = await safe(() => rc(voter, kitVoterAbi, "getGauge", [pool]));
        if (!g || g[2] === "0x0000000000000000000000000000000000000000") continue;
        const vr = g[2];
        const rl = await safe(() => rc(vr, kitRewardAbi, "getRewardList"));
        if (!rl) continue;
        let usd = 0;
        for (const t of rl) {
            const px = tokenUsdPerWei(t, prices);
            if (px === 0) continue;
            const r = await safe(() => rc(vr, kitRewardAbi, "rewardForPeriod", [BigInt(period), t]));
            if (r) usd += Number(r) * px;
        }
        if (usd > 0) scored.push({ pool, usd });
    }
    scored.sort((a, b) => b.usd - a.usd);
    return scored.slice(0, topN).map((s) => s.pool);
}

/// @param proto "nest" | "kit"
export async function computeTopPools({ rpc, hermes, proto, voter, topN = 5 }) {
    const client = createPublicClient({ transport: http(rpc) });
    const prices = await fetchPrices(hermes);
    return proto === "nest" ? topNest(client, voter, topN, prices) : topKitten(client, voter, topN, prices);
}
