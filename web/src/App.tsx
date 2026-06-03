import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  useAccount, useConnect, useDisconnect, usePublicClient, useReadContracts, useSwitchChain,
  useWaitForTransactionReceipt, useWriteContract,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { formatUnits, parseAbiItem, parseUnits } from "viem";
import { LogoLockup, Mark } from "./components/Logo";
import { hyperEVM } from "./wagmi";
import { ADDR, CAP_RAISE_INTERVAL_SECONDS, MARKETS, NEST_VOTER, USDC_DECIMALS, adapterAbi, coreAbi, creditManagerAbi, erc20Abi, erc721Abi, irmAbi, marketId, nestVoterAbi } from "./contracts";

const WAD = 10n ** 18n;
const REPO = "https://github.com/twentyeightlend/twentyeight-lend-hub";
const EXPLORER = "https://www.hyperscan.com";
const TWITTER = "https://x.com/twentyeightlend";
const HYPERWARP = "https://www.hyperwarp.fi";
const TELEGRAM = "https://t.me/+nbDC-eK0SXNiZWIy";
const fmt = (v: number, d = 2) => v.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as const;

function useTheme() {
  const [theme, setTheme] = useState(() => localStorage.getItem("theme") || "light");
  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("theme", theme);
  }, [theme]);
  return { theme, toggle: () => setTheme((t) => (t === "light" ? "dark" : "light")) };
}

function Header({ tab, setTab, theme, toggle, onHome }: { tab: string; setTab: (t: string) => void; theme: string; toggle: () => void; onHome: () => void }) {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const [pickerOpen, setPickerOpen] = useState(false);
  // EIP-6963 discovery surfaces each installed wallet (Rabby, MetaMask, …) as its own connector.
  // Dedupe by name and drop the generic "Injected" fallback when named wallets are present, so the
  // user picks the exact wallet instead of connecting to whoever owns window.ethereum.
  const wallets = useMemo(() => {
    const seen = new Set<string>();
    const named = connectors.filter((c) => {
      const k = (c.name || c.id).toLowerCase();
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
    const realWallets = named.filter((c) => c.name && c.name.toLowerCase() !== "injected");
    return realWallets.length ? realWallets : named;
  }, [connectors]);
  const onConnect = () => {
    if (wallets.length === 0) return;
    if (wallets.length === 1) connect({ connector: wallets[0] });
    else setPickerOpen((o) => !o);
  };
  return (
    <header className="header">
      <div className="container header-inner">
        <span role="button" tabIndex={0} onClick={onHome} onKeyDown={(e) => e.key === "Enter" && onHome()} style={{ cursor: "pointer" }}><LogoLockup /></span>
        <nav className="nav" role="tablist">
          {["Lend", "Borrow", "Dashboard", "Protocol"].map((t) => (
            <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>{t}</button>
          ))}
        </nav>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <button className="icon-btn" onClick={toggle} aria-label="Toggle theme">
            {theme === "light" ? (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" /></svg>
            ) : (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" /></svg>
            )}
          </button>
          {!isConnected ? (
            <div style={{ position: "relative" }}>
              <button className="btn btn-primary" disabled={wallets.length === 0} onClick={onConnect}>
                {wallets.length === 0 ? "No wallet found" : "Connect"}
              </button>
              {pickerOpen && wallets.length > 1 && (
                <>
                  <div onClick={() => setPickerOpen(false)} style={{ position: "fixed", inset: 0, zIndex: 40 }} />
                  <div className="card" style={{ position: "absolute", right: 0, top: "calc(100% + 6px)", padding: 6, minWidth: 190, zIndex: 50 }}>
                    {wallets.map((c) => (
                      <button key={c.uid} className="btn btn-ghost" style={{ display: "flex", alignItems: "center", gap: 8, width: "100%", textAlign: "left", padding: "8px 10px" }}
                        onClick={() => { connect({ connector: c }); setPickerOpen(false); }}>
                        {c.icon && <img src={c.icon} alt="" width={18} height={18} style={{ borderRadius: 4 }} />}
                        {c.name}
                      </button>
                    ))}
                  </div>
                </>
              )}
            </div>
          ) : chainId !== hyperEVM.id ? (
            <button className="btn btn-accent" onClick={() => switchChain({ chainId: hyperEVM.id })}>Switch to HyperEVM</button>
          ) : (
            <button className="btn btn-ghost" onClick={() => disconnect()}>{short(address)}</button>
          )}
        </div>
      </div>
    </header>
  );
}

type MarketStats = {
  supplyAprPct: number; util: number; tvl: number;
  positionAssets: bigint; idleLiquidity: bigint; hasBorrowers: boolean;
  capped: boolean; cap: number; capRemaining: number; capRemainingRaw: bigint; capPct: number; nextRaiseTs: number;
};

function useMarket(id: `0x${string}`): MarketStats {
  const { address } = useAccount();
  const { data } = useReadContracts({
    contracts: [
      { address: ADDR.core, abi: coreAbi, functionName: "market", args: [id] },
      { address: ADDR.core, abi: coreAbi, functionName: "supplyShares", args: [id, address ?? ZERO_ADDR] },
      { address: ADDR.core, abi: coreAbi, functionName: "supplyCap", args: [id] },
      { address: ADDR.core, abi: coreAbi, functionName: "lastCapRaise", args: [id] },
    ],
    query: { refetchInterval: 12_000 },
  });
  const market = data?.[0]?.result as readonly bigint[] | undefined;
  const shares = (data?.[1]?.result as bigint | undefined) ?? 0n;
  const capRaw = (data?.[2]?.result as bigint | undefined) ?? 0n;
  const lastRaise = (data?.[3]?.result as bigint | undefined) ?? 0n;

  const base = useMemo(() => {
    if (!market) return { util: 0, tvl: 0, positionAssets: 0n, idleLiquidity: 0n, hasBorrowers: false, fee: 0n, utilWad: 0n,
      capped: false, cap: 0, capRemaining: 0, capRemainingRaw: 0n, capPct: 0, nextRaiseTs: 0 };
    const [supplyA, supplyS, borrowA, , , fee] = market;
    const utilWad = supplyA > 0n ? (borrowA * WAD) / supplyA : 0n;
    const capped = capRaw > 0n;
    const capRemainingRaw = capped ? (capRaw > supplyA ? capRaw - supplyA : 0n) : 0n;
    return {
      util: Number(utilWad) / 1e18,
      tvl: Number(formatUnits(supplyA, USDC_DECIMALS)),
      positionAssets: supplyS > 0n ? (shares * supplyA) / supplyS : 0n,
      idleLiquidity: supplyA > borrowA ? supplyA - borrowA : 0n,
      hasBorrowers: borrowA > 0n,
      fee, utilWad,
      capped,
      cap: capped ? Number(formatUnits(capRaw, USDC_DECIMALS)) : 0,
      capRemaining: capped ? Number(formatUnits(capRemainingRaw, USDC_DECIMALS)) : 0,
      capRemainingRaw,
      capPct: capped ? Math.min(1, Number(supplyA) / Number(capRaw)) : 0,
      nextRaiseTs: capped ? Number(lastRaise) + CAP_RAISE_INTERVAL_SECONDS : 0,
    };
  }, [market, shares, capRaw, lastRaise]);

  const { data: aprData } = useReadContracts({
    contracts: [{ address: ADDR.irm, abi: irmAbi, functionName: "aprAtUtilization", args: [base.utilWad] }],
    query: { enabled: !!market, refetchInterval: 12_000 },
  });
  const borrowApr = Number(formatUnits((aprData?.[0]?.result as bigint | undefined) ?? 0n, 18));
  const fee = Number(base.fee) / 1e18;
  const supplyAprPct = borrowApr * base.util * (1 - fee) * 100;

  return {
    supplyAprPct, util: base.util, tvl: base.tvl,
    positionAssets: base.positionAssets, idleLiquidity: base.idleLiquidity, hasBorrowers: base.hasBorrowers,
    capped: base.capped, cap: base.cap, capRemaining: base.capRemaining, capRemainingRaw: base.capRemainingRaw,
    capPct: base.capPct, nextRaiseTs: base.nextRaiseTs,
  };
}

function AprValue({ s }: { s: MarketStats }) {
  if (!s.hasBorrowers) return <span title="Yield begins once borrowers draw against the market">—</span>;
  return <>{fmt(s.supplyAprPct)}<span className="unit">%</span></>;
}

function Stats({ s }: { s: MarketStats }) {
  return (
    <div className="stats">
      <div className="stat"><div className="label">Supply APR</div><div className="value" style={{ color: "var(--accent)" }}><AprValue s={s} /></div></div>
      <div className="stat"><div className="label">Total supplied</div><div className="value">{fmt(s.tvl, 0)}<span className="unit">USDC</span></div></div>
      <div className="stat"><div className="label">Utilization</div><div className="value">{fmt(s.util * 100, 1)}<span className="unit">%</span></div></div>
    </div>
  );
}

function capRaiseEta(ts: number): string {
  const now = Math.floor(Date.now() / 1000);
  if (ts <= now) return "now";
  const h = Math.ceil((ts - now) / 3600);
  if (h < 24) return `in ~${h}h`;
  return `in ~${Math.ceil(h / 24)}d`;
}

function Logo({ src, size = 18 }: { src: string; size?: number }) {
  return <img src={src} alt="" width={size} height={size} style={{ borderRadius: "50%", verticalAlign: "middle", flexShrink: 0 }} />;
}

function AllMarketsTotal() {
  const { data } = useReadContracts({
    contracts: MARKETS.map((mk) => ({ address: ADDR.core, abi: coreAbi, functionName: "market" as const, args: [marketId(mk.params) as `0x${string}`] })),
    query: { refetchInterval: 15_000 },
  });
  const per = MARKETS.map((mk, i) => {
    const m = data?.[i]?.result as readonly bigint[] | undefined;
    return { key: mk.key, label: mk.label, logo: mk.logo, supplied: m ? Number(formatUnits(m[0], USDC_DECIMALS)) : 0 };
  });
  const total = per.reduce((a, b) => a + b.supplied, 0);
  return (
    <div className="card card-pad" style={{ marginBottom: 14 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <span className="muted" style={{ fontSize: 13 }}>Total USDC supplied · all markets</span>
        <span style={{ fontSize: 18, fontWeight: 600 }}>{fmt(total, 0)} <span className="unit">USDC</span></span>
      </div>
      <div style={{ display: "flex", gap: 18, marginTop: 10, flexWrap: "wrap" }}>
        {per.map((p) => (
          <span key={p.key} style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13 }}>
            <Logo src={p.logo} size={16} /> {p.label} <b>{fmt(p.supplied, 0)}</b> USDC
          </span>
        ))}
      </div>
    </div>
  );
}

function CapacityCard({ s }: { s: MarketStats }) {
  if (!s.capped) return null; // launching uncapped — no cap card to show
  const pct = Math.round(s.capPct * 100);
  const full = s.capRemaining <= 0;
  const barColor = pct >= 90 ? "var(--danger)" : "var(--accent)";
  return (
    <div className="card card-pad" style={{ marginTop: 14 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 8 }}>
        <span className="muted" style={{ fontSize: 13 }}>Guarded rollout · supply cap</span>
        <span style={{ fontSize: 13, color: barColor }}>{pct}% full</span>
      </div>
      <div style={{ height: 8, borderRadius: 6, background: "var(--line, #2a2a2a)", overflow: "hidden" }}>
        <div style={{ width: `${pct}%`, height: "100%", background: barColor, transition: "width .3s" }} />
      </div>
      <div style={{ marginTop: 12 }}>
        <div className="kv"><span className="k">Cap</span><span className="v">{fmt(s.cap, 0)} USDC</span></div>
        <div className="kv"><span className="k">Supplied</span><span className="v">{fmt(s.tvl, 0)} USDC</span></div>
        <div className="kv"><span className="k">Remaining capacity</span><span className="v" style={{ color: full ? "var(--danger)" : undefined }}>{fmt(s.capRemaining, 0)} USDC</span></div>
        <div className="kv"><span className="k">Next increase possible</span><span className="v">{capRaiseEta(s.nextRaiseTs)}</span></div>
      </div>
      <p className="muted" style={{ fontSize: 12, marginTop: 10, lineHeight: 1.5 }}>
        This market is in a guarded rollout. The cap bounds total deposits while the protocol proves itself in
        production. It can be raised by at most 2× per day (and never removed in a single transaction); every change
        is recorded on-chain.
      </p>
    </div>
  );
}

// Auto-discovers deposited positions via SupplyCollateral logs (works with the dedicated RPC, which
// supports getLogs). Results cached in localStorage (incremental + a recent-overlap re-scan so a stale
// cache can't hide a deposit). add() records a deposit/position instantly. Manual token-ID entry +
// in-wallet enumeration remain as RPC-independent fallbacks.
const DEPLOY_BLOCK = 36749121n;
const DEP_CHUNK = 4500n;          // dedicated RPC handles ~5000-block getLogs; 4500 = safe margin
const INITIAL_LOOKBACK = 50000n;  // first-scan window when no cache
const OVERLAP = 6000n;            // always re-scan the most recent blocks (robust to stale cache)
const SUPPLY_COLLATERAL_EVENT = parseAbiItem("event SupplyCollateral(bytes32 indexed id, uint256 indexed tokenId, address indexed onBehalf)");
const BORROW_EVENT = parseAbiItem("event Borrow(bytes32 indexed id, uint256 indexed tokenId, address receiver, uint256 assets, uint256 shares)");
const REPAY_EVENT = parseAbiItem("event Repay(bytes32 indexed id, uint256 indexed tokenId, address indexed onBehalf, uint256 assets, uint256 shares)");
const depKey = (chainId: number, a: string) => `tw28:deps:v3:${chainId}:${a.toLowerCase()}`;
type DepStore = { byKey: Record<string, string[]>; lastScanned: number };
function loadDepStore(chainId: number, a: string): DepStore {
  try { const v = JSON.parse(localStorage.getItem(depKey(chainId, a)) || "{}"); return { byKey: v.byKey || {}, lastScanned: v.lastScanned || 0 }; } catch { return { byKey: {}, lastScanned: 0 }; }
}
function saveDepStore(chainId: number, a: string, s: DepStore) { try { localStorage.setItem(depKey(chainId, a), JSON.stringify(s)); } catch { /* ignore quota */ } }
const bmax = (a: bigint, b: bigint) => (a > b ? a : b);
const bmin = (a: bigint, b: bigint) => (a < b ? a : b);
async function runCapped(tasks: (() => Promise<void>)[], cap: number) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(cap, tasks.length) }, async () => { while (i < tasks.length) { await tasks[i++](); } }));
}
// chunked getLogs over a block range (works on the dedicated /rpc which supports getLogs)
async function scanLogs(client: any, event: any, args: any, fromBlock: bigint, tip: bigint, chunk = DEP_CHUNK): Promise<any[]> {
  const out: any[] = [];
  const tasks: (() => Promise<void>)[] = [];
  for (let from = fromBlock; from <= tip; from += chunk + 1n) {
    const to = from + chunk > tip ? tip : from + chunk;
    const f = from;
    tasks.push(async () => {
      for (let a = 0; a < 2; a++) {
        try { const logs = await client.getLogs({ address: ADDR.core, event, args, fromBlock: f, toBlock: to }); out.push(...logs); return; } catch { /* retry once */ }
      }
    });
  }
  await runCapped(tasks, 3);
  return out;
}

function useDeposits() {
  const { address, chainId } = useAccount();
  const client = usePublicClient();
  const [byMarket, setByMarket] = useState<bigint[][]>(MARKETS.map(() => []));
  const [scanning, setScanning] = useState(false);
  const [scanFailed, setScanFailed] = useState(false);
  const fromStore = useCallback((store: DepStore) => {
    setByMarket(MARKETS.map((mk) => [...new Set(store.byKey[mk.key] || [])].map(BigInt)));
  }, []);

  useEffect(() => {
    if (!address || !client || !chainId) { setByMarket(MARKETS.map(() => [])); return; }
    const store = loadDepStore(chainId, address);
    fromStore(store);
    let cancelled = false;
    (async () => {
      setScanning(true);
      setScanFailed(false);
      let anyFail = false;
      const tip = await client.getBlockNumber().catch(() => null);
      if (tip) {
        const last = BigInt(store.lastScanned || 0);
        let start = last > 0n ? last + 1n : bmax(tip - INITIAL_LOOKBACK, DEPLOY_BLOCK);
        start = bmin(start, bmax(tip - OVERLAP, DEPLOY_BLOCK)); // always re-cover the recent window
        if (start < DEPLOY_BLOCK) start = DEPLOY_BLOCK;
        const acc: Record<string, Set<string>> = {};
        for (const mk of MARKETS) acc[mk.key] = new Set(store.byKey[mk.key] || []);
        const tasks: (() => Promise<void>)[] = [];
        for (let from = start; from <= tip; from += DEP_CHUNK + 1n) {
          const to = from + DEP_CHUNK > tip ? tip : from + DEP_CHUNK;
          const f = from;
          tasks.push(async () => {
            let logs: { args: { id?: string; tokenId?: bigint } }[] = [];
            let ok = false;
            for (let a = 0; a < 2; a++) { try { logs = await client.getLogs({ address: ADDR.core, event: SUPPLY_COLLATERAL_EVENT, args: { onBehalf: address }, fromBlock: f, toBlock: to }) as typeof logs; ok = true; break; } catch { logs = []; } }
            if (!ok) { anyFail = true; return; }
            for (const l of logs) { const ar = l.args; if (!ar.id || ar.tokenId === undefined) continue; const mk = MARKETS.find((m) => (marketId(m.params) as string).toLowerCase() === ar.id!.toLowerCase()); if (mk) acc[mk.key].add(ar.tokenId.toString()); }
          });
        }
        await runCapped(tasks, 3);
        if (!cancelled) {
          const byKey: Record<string, string[]> = {};
          for (const mk of MARKETS) byKey[mk.key] = [...acc[mk.key]];
          const next = { byKey, lastScanned: Number(tip) };
          saveDepStore(chainId, address, next);
          fromStore(next);
        }
      } else {
        anyFail = true;
      }
      if (!cancelled) { setScanFailed(anyFail); setScanning(false); }
    })();
    return () => { cancelled = true; };
  }, [address, client, chainId, fromStore]);

  const add = useCallback((mIdx: number, tokenId: bigint) => {
    if (!address || !chainId) return;
    const store = loadDepStore(chainId, address);
    const key = MARKETS[mIdx].key;
    const set = new Set(store.byKey[key] || []); set.add(tokenId.toString());
    store.byKey[key] = [...set];
    saveDepStore(chainId, address, store);
    fromStore(store);
  }, [address, chainId, fromStore]);

  return { byMarket, scanning, scanFailed, add };
}

type PosAct = { borrowed: bigint; repaid: bigint; repaid7d: bigint; events: { type: "Borrow" | "Repay"; assets: bigint; ts: number }[] };
const WEEK_BLOCKS = 570000n; // ~7 days at ~1s/block on HyperEVM
// Per-position loan history: scans Borrow/Repay logs (filtered by id+tokenId) so the Dashboard can show
// "repaid this week", total repaid, and a recent-activity list. Powers the self-repay storytelling.
function usePositionActivity(positions: { mIdx: number; tokenId: bigint }[]) {
  const client = usePublicClient();
  const [data, setData] = useState<Record<string, PosAct>>({});
  const sig = positions.map((p) => `${p.mIdx}:${p.tokenId}`).join(",");
  useEffect(() => {
    if (!client || positions.length === 0) { setData({}); return; }
    let cancelled = false;
    (async () => {
      const tip = await client.getBlockNumber().catch(() => null);
      if (!tip) return;
      const from = bmax(tip - 600000n, DEPLOY_BLOCK);
      const res: Record<string, PosAct> = {};
      for (const p of positions) {
        const id = marketId(MARKETS[p.mIdx].params) as `0x${string}`;
        const [bLogs, rLogs] = await Promise.all([
          scanLogs(client, BORROW_EVENT, { id, tokenId: p.tokenId }, from, tip),
          scanLogs(client, REPAY_EVENT, { id, tokenId: p.tokenId }, from, tip),
        ]);
        const raw = [
          ...bLogs.map((l: any) => ({ type: "Borrow" as const, assets: l.args.assets as bigint, block: l.blockNumber as bigint })),
          ...rLogs.map((l: any) => ({ type: "Repay" as const, assets: l.args.assets as bigint, block: l.blockNumber as bigint })),
        ].sort((a, b) => Number(b.block - a.block)).slice(0, 8);
        await Promise.all(raw.map(async (e: any) => { try { const blk = await client.getBlock({ blockNumber: e.block }); e.ts = Number(blk.timestamp); } catch { e.ts = 0; } }));
        const borrowed = bLogs.reduce((s: bigint, l: any) => s + (l.args.assets as bigint), 0n);
        const repaid = rLogs.reduce((s: bigint, l: any) => s + (l.args.assets as bigint), 0n);
        const repaid7d = rLogs.filter((l: any) => (l.blockNumber as bigint) >= tip - WEEK_BLOCKS).reduce((s: bigint, l: any) => s + (l.args.assets as bigint), 0n);
        res[`${p.mIdx}:${p.tokenId}`] = { borrowed, repaid, repaid7d, events: raw.map((e: any) => ({ type: e.type, assets: e.assets, ts: e.ts })) };
      }
      if (!cancelled) setData(res);
    })();
    return () => { cancelled = true; };
  }, [client, sig]);
  return data;
}

function relTime(ts: number): string {
  if (!ts) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

// veNEST detach/vote is blocked in the first & last hour of each weekly epoch (Thu 00:00 UTC).
function inDistributionWindow(windowSec = 3600): boolean {
  const now = Math.floor(Date.now() / 1000);
  const intoEpoch = now % 604800;
  return intoEpoch < windowSec || intoEpoch >= 604800 - windowSec;
}

function LendPanel() {
  const { address, isConnected, chainId } = useAccount();
  const qc = useQueryClient();
  const [idx, setIdx] = useState(0);
  const [mode, setMode] = useState<"supply" | "withdraw">("supply");
  const [amount, setAmount] = useState("");
  const [isMax, setIsMax] = useState(false);
  const m = MARKETS[idx];
  const id = marketId(m.params) as `0x${string}`;
  const market = useMarket(id);

  const { writeContract, data: hash, error: writeError, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess } = useWaitForTransactionReceipt({ hash });

  const { data: walletData } = useReadContracts({
    contracts: [
      { address: ADDR.usdc, abi: erc20Abi, functionName: "balanceOf", args: [address ?? ZERO_ADDR] },
      { address: ADDR.usdc, abi: erc20Abi, functionName: "allowance", args: [address ?? ZERO_ADDR, ADDR.core] },
    ],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });
  const balance = (walletData?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (walletData?.[1]?.result as bigint | undefined) ?? 0n;
  // amount to auto-supply once a preceding USDC approval confirms (so the supply tx pops on its own)
  const pendingSupply = useRef<bigint | null>(null);

  // After a confirmed tx: if it was the approval, auto-fire the supply; otherwise refetch + clear.
  useEffect(() => {
    if (!isSuccess) return;
    qc.invalidateQueries();
    const pending = pendingSupply.current;
    if (pending && pending > 0n && address) {
      pendingSupply.current = null;
      writeContract({ address: ADDR.core, abi: coreAbi, functionName: "supply", args: [m.params, pending, address] });
      return;
    }
    setAmount(""); setIsMax(false); reset();
  }, [isSuccess, qc, reset]);
  // reset input when switching mode/market
  useEffect(() => { setAmount(""); setIsMax(false); }, [mode, idx]);

  // In supply mode, the cap (if any) limits how much can still be deposited.
  const maxRaw = mode === "supply"
    ? (market.capped ? bmin(balance, market.capRemainingRaw) : balance)
    : market.positionAssets;
  const maxDisplay = Number(formatUnits(maxRaw, USDC_DECIMALS));
  const typed = useMemo(() => { try { return amount ? parseUnits(amount, USDC_DECIMALS) : 0n; } catch { return 0n; } }, [amount]);
  // when "MAX" is active, use the exact on-chain bigint (no float round-trip)
  const amt = isMax ? maxRaw : typed;
  const needsApprove = mode === "supply" && amt > allowance;
  const overWithdrawLiquidity = mode === "withdraw" && amt > market.idleLiquidity;
  const overCap = mode === "supply" && market.capped && amt > market.capRemainingRaw;

  const setMax = () => { setAmount(maxDisplay ? String(maxDisplay) : ""); setIsMax(maxRaw > 0n); };

  const onAction = () => {
    if (!isConnected || chainId !== hyperEVM.id || amt === 0n) return;
    if (mode === "supply" && needsApprove) {
      pendingSupply.current = amt; // auto-fire supply once this approval confirms
      return writeContract({ address: ADDR.usdc, abi: erc20Abi, functionName: "approve", args: [ADDR.core, amt] });
    }
    if (mode === "supply")
      return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "supply", args: [m.params, amt, address!] });
    return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "withdraw", args: [m.params, amt, address!, address!] });
  };

  const busy = isPending || isMining;
  const cta = !isConnected ? "Connect wallet"
    : chainId !== hyperEVM.id ? "Switch to HyperEVM"
    : amt === 0n ? "Enter an amount"
    : overWithdrawLiquidity ? "Not enough liquidity"
    : overCap ? "Exceeds supply cap"
    : mode === "supply" ? (needsApprove ? "Approve USDC" : "Supply USDC")
    : "Withdraw USDC";
  const disabled = busy || !isConnected || chainId !== hyperEVM.id || amt === 0n || overWithdrawLiquidity || overCap;

  return (
    <div className="panel">
      <AllMarketsTotal />
      <Stats s={market} />
      <CapacityCard s={market} />
      <div className="card card-pad" style={{ marginTop: 20 }}>
        <div className="seg">
          <button className={mode === "supply" ? "active" : ""} onClick={() => setMode("supply")}>Supply</button>
          <button className={mode === "withdraw" ? "active" : ""} onClick={() => setMode("withdraw")}>Withdraw</button>
        </div>
        <p className="muted" style={{ fontSize: 12, margin: "0 0 8px" }}>Pick a market to supply into — each veNFT market is isolated:</p>
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {MARKETS.map((mk, i) => (
            <button key={mk.key} className="btn" style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 7, flex: 1, padding: "8px", fontSize: 13, color: i === idx ? "var(--ink)" : "var(--muted)", border: `1px solid ${i === idx ? "var(--accent)" : "transparent"}`, background: "transparent" }} onClick={() => setIdx(i)}><Logo src={mk.logo} size={18} />{mk.label} market</button>
          ))}
        </div>
        <div className="field">
          <div className="sub"><span>{mode === "supply" ? "You supply" : "You withdraw"}</span><span>Max {fmt(maxDisplay)} <span className="max" role="button" tabIndex={0} onClick={setMax} onKeyDown={(e) => e.key === "Enter" && setMax()}>USE MAX</span></span></div>
          <div className="row"><input inputMode="decimal" aria-label="amount" placeholder="0.00" value={amount} onChange={(e) => { setIsMax(false); setAmount(e.target.value.replace(/[^0-9.]/g, "").replace(/(\..*)\./g, "$1")); }} /><span className="token">USDC</span></div>
        </div>
        <div style={{ marginTop: 18 }}>
          <div className="kv"><span className="k">Supply APR</span><span className="v" style={{ color: "var(--accent)" }}>{market.hasBorrowers ? `${fmt(market.supplyAprPct)}%` : "— (no borrowers yet)"}</span></div>
          <div className="kv"><span className="k">Your position</span><span className="v">{fmt(maxDisplay && mode === "withdraw" ? maxDisplay : Number(formatUnits(market.positionAssets, USDC_DECIMALS)))} USDC</span></div>
          {mode === "withdraw" && <div className="kv"><span className="k">Available now</span><span className="v">{fmt(Number(formatUnits(market.idleLiquidity, USDC_DECIMALS)))} USDC</span></div>}
          {mode === "supply" && market.capped && <div className="kv"><span className="k">Remaining capacity</span><span className="v" style={{ color: overCap ? "var(--danger)" : undefined }}>{fmt(market.capRemaining, 0)} USDC</span></div>}
          <hr className="divider" />
          <button className="btn btn-accent btn-block" disabled={disabled} onClick={onAction}>{busy ? (isMining ? "Transaction pending…" : "Confirm in wallet…") : cta}</button>
          {writeError && <p className="center" style={{ color: "var(--danger)", fontSize: 13, marginTop: 12 }}>{(writeError as { shortMessage?: string }).shortMessage || "Transaction failed"}</p>}
          {isSuccess && hash && <p className="center" style={{ color: "var(--accent)", fontSize: 13, marginTop: 12 }}>Confirmed · <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" style={{ color: "var(--accent)" }}>view</a></p>}
        </div>
      </div>
      <details className="card" open style={{ marginTop: 14, padding: "14px 18px", fontSize: 13 }}>
        <summary className="muted" style={{ cursor: "pointer" }}>Risks before you supply</summary>
        <p className="muted" style={{ marginTop: 10, lineHeight: 1.6 }}>
          This is a <b>non-liquidating</b> market. Yield is paid by borrowers from their veNFT voting revenue —
          there is no yield until borrowers draw against the market. Because there are <b>no liquidations</b>, if a
          borrower stops earning/voting their loan may not fully repay; in the worst case lender principal can be
          impaired and the loss socialized across suppliers. Credit lines are sized conservatively to mitigate this,
          but it is not eliminated. Supply only what you can afford to lose.
        </p>
      </details>
    </div>
  );
}

function BorrowPanel() {
  const { address, isConnected, chainId } = useAccount();
  const qc = useQueryClient();
  const [idx, setIdx] = useState(0);
  const [tokenId, setTokenId] = useState("");
  const [action, setAction] = useState<"borrow" | "repay">("borrow");
  const [amount, setAmount] = useState("");
  const [isMax, setIsMax] = useState(false);
  const m = MARKETS[idx];
  const id = marketId(m.params) as `0x${string}`;
  const tid = useMemo(() => { try { return tokenId.trim() ? BigInt(tokenId.trim()) : null; } catch { return null; } }, [tokenId]);

  const { writeContract, data: hash, error: writeError, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess } = useWaitForTransactionReceipt({ hash });
  useEffect(() => { if (isSuccess) { qc.invalidateQueries(); setAmount(""); setIsMax(false); reset(); } }, [isSuccess, qc, reset]);
  useEffect(() => { setAmount(""); setIsMax(false); }, [action, idx, tokenId]);

  const { data, isLoading: posLoading } = useReadContracts({
    contracts: tid !== null ? [
      { address: m.creditManager, abi: creditManagerAbi, functionName: "creditLine", args: [m.params, tid] },
      { address: ADDR.core, abi: coreAbi, functionName: "position", args: [id, tid] },
      { address: m.veToken, abi: erc721Abi, functionName: "ownerOf", args: [tid] },
      { address: m.veToken, abi: erc721Abi, functionName: "isApprovedForAll", args: [address ?? ZERO_ADDR, m.params.veAdapter] },
      { address: ADDR.core, abi: coreAbi, functionName: "market", args: [id] },
      { address: ADDR.usdc, abi: erc20Abi, functionName: "allowance", args: [address ?? ZERO_ADDR, ADDR.core] },
      { address: m.params.veAdapter, abi: adapterAbi, functionName: "isAcceptableCollateral", args: [tid] },
    ] : [],
    query: { enabled: tid !== null && !!address, refetchInterval: 12_000 },
  });
  const creditPreview = (data?.[0]?.result as bigint | undefined) ?? 0n;
  const pos = data?.[1]?.result as readonly [string, bigint, bigint, number] | undefined;
  const owner = data?.[2]?.result as string | undefined;
  const approved = (data?.[3]?.result as boolean | undefined) ?? false;
  const market = data?.[4]?.result as readonly bigint[] | undefined;
  const usdcAllowance = (data?.[5]?.result as bigint | undefined) ?? 0n;
  const accept = data?.[6]?.result as readonly [boolean, string] | undefined;
  const acceptResolved = accept !== undefined; // false while the eligibility read is loading/failed
  const acceptable = accept ? accept[0] : true;
  const acceptReason = accept?.[1] ?? "";

  // candidates = wallet-held veNFTs (ERC721Enumerable) + already-deposited positions (event scan)
  const { data: nftBal, isLoading: nftLoading } = useReadContracts({
    contracts: address ? [{ address: m.veToken, abi: erc721Abi, functionName: "balanceOf", args: [address] }] : [],
    query: { enabled: !!address, refetchInterval: 30_000 },
  });
  const nftCount = Number((nftBal?.[0]?.result as bigint | undefined) ?? 0n);
  const { data: ownedData } = useReadContracts({
    contracts: address && nftCount > 0
      ? Array.from({ length: Math.min(nftCount, 8) }, (_, i) => ({ address: m.veToken, abi: erc721Abi, functionName: "tokenOfOwnerByIndex" as const, args: [address, BigInt(i)] }))
      : [],
    query: { enabled: !!address && nftCount > 0 },
  });
  const owned = (ownedData ?? []).map((d) => d.result as bigint | undefined).filter((x): x is bigint => x !== undefined).map(String);
  const deposits = useDeposits();
  const depositedHere = deposits.byMarket[idx].map(String);
  const candidates = [...new Set([...depositedHere, ...owned])];
  const detecting = (!!address && nftLoading) || deposits.scanning;
  const autofilled = useRef(false);
  useEffect(() => { autofilled.current = false; }, [idx, address]);
  useEffect(() => { if (!autofilled.current && !tokenId && candidates.length > 0) { setTokenId(candidates[0]); autofilled.current = true; } }, [candidates.join(","), tokenId]);

  const me = (address ?? "").toLowerCase();
  const collateralized = !!pos && pos[0] !== ZERO_ADDR && pos[0].toLowerCase() === me;
  const borrowShares = pos?.[1] ?? 0n;
  // pos[2] is the cached line — it stays 0 until the first borrow caches it, so fall back to the
  // live preview from the credit manager. borrow() computes the line inline anyway, so the live
  // figure is the real capacity. Use the larger so a fresh deposit isn't shown as "0 available".
  const creditLine = collateralized ? bmax(pos?.[2] ?? 0n, creditPreview) : creditPreview;
  const debt = market && borrowShares > 0n && market[3] > 0n ? (borrowShares * market[2]) / market[3] : 0n;
  const available = creditLine > debt ? creditLine - debt : 0n;
  const ownsNft = !!owner && owner.toLowerCase() === me;
  // persist any position we confirm is collateralized to this wallet (survives the RPC's log limits)
  useEffect(() => { if (collateralized && tid !== null) deposits.add(idx, tid); }, [collateralized, tid, idx]);

  const typed = useMemo(() => { try { return amount ? parseUnits(amount, USDC_DECIMALS) : 0n; } catch { return 0n; } }, [amount]);
  const maxRaw = action === "borrow" ? available : debt;
  const amt = isMax ? maxRaw : typed;
  const needsUsdcApprove = action === "repay" && amt > usdcAllowance;
  const setMax = () => { setAmount(maxRaw > 0n ? String(Number(formatUnits(maxRaw, USDC_DECIMALS))) : ""); setIsMax(maxRaw > 0n); };

  const busy = isPending || isMining;
  const wrongChain = chainId !== hyperEVM.id;

  const isManaged = !collateralized && ownsNft && !acceptable && /attached|managed/i.test(acceptReason) && m.key === "NEST";
  const detachBlocked = inDistributionWindow();

  const onAction = () => {
    if (!isConnected || wrongChain || tid === null) return;
    if (!collateralized) {
      if (isManaged) { if (detachBlocked) return; return writeContract({ address: NEST_VOTER, abi: nestVoterAbi, functionName: "dettachFromManagedNFT", args: [tid] }); }
      if (!ownsNft || !acceptable || !acceptResolved) return;
      if (!approved) return writeContract({ address: m.veToken, abi: erc721Abi, functionName: "setApprovalForAll", args: [m.params.veAdapter, true] });
      return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "supplyCollateral", args: [m.params, tid, address!] });
    }
    if (action === "borrow") {
      if (amt === 0n) return;
      return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "borrow", args: [m.params, tid, amt, address!] });
    }
    // repay
    if (amt === 0n) return;
    if (needsUsdcApprove) return writeContract({ address: ADDR.usdc, abi: erc20Abi, functionName: "approve", args: [ADDR.core, amt] });
    return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "repay", args: [m.params, tid, amt] });
  };

  const onWithdraw = () => {
    if (!isConnected || wrongChain || tid === null || debt > 0n) return;
    writeContract({ address: ADDR.core, abi: coreAbi, functionName: "withdrawCollateral", args: [m.params, tid, address!] });
  };

  const cta = !isConnected ? "Connect wallet"
    : wrongChain ? "Switch to HyperEVM"
    : tid === null ? "Enter your veNFT ID"
    : !collateralized ? (!ownsNft ? "You don't own this veNFT" : isManaged ? (detachBlocked ? "Detach blocked — try in ~1h" : "Detach auto-vote to continue") : !acceptResolved ? "Checking eligibility…" : !acceptable ? "Not eligible as collateral" : !approved ? `Approve ${m.label}` : `Deposit ${m.label} as collateral`)
    : amt === 0n ? "Enter an amount"
    : action === "borrow" ? "Borrow USDC"
    : needsUsdcApprove ? "Approve USDC" : "Repay USDC";

  const disabled = busy || !isConnected || wrongChain || tid === null
    || (!collateralized && !isManaged && (!ownsNft || !acceptResolved || !acceptable))
    || (!collateralized && isManaged && detachBlocked)
    || (collateralized && amt === 0n);

  const fmtU = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)));

  return (
    <div className="panel">
      <div className="card card-pad">
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {MARKETS.map((mk, i) => (
            <button key={mk.key} className="btn" style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 7, flex: 1, padding: "8px", fontSize: 13, color: i === idx ? "var(--ink)" : "var(--muted)", border: `1px solid ${i === idx ? "var(--accent)" : "transparent"}`, background: "transparent" }} onClick={() => setIdx(i)}><Logo src={mk.logo} size={18} />{mk.label}</button>
          ))}
        </div>
        <div className="field" style={{ marginBottom: candidates.length ? 10 : 14 }}>
          <div className="sub"><span>{collateralized ? "Your deposited" : "Your"} {m.label} · token ID</span></div>
          <div className="row"><input inputMode="numeric" aria-label="veNFT token id" placeholder="e.g. 1234" value={tokenId} onChange={(e) => setTokenId(e.target.value.replace(/[^0-9]/g, ""))} /></div>
        </div>
        {detecting && candidates.length === 0 && (
          <p className="muted" style={{ fontSize: 12, marginBottom: 14 }}>Checking your wallet &amp; positions…</p>
        )}
        {candidates.length > 0 && (
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14, alignItems: "center" }}>
            <span className="muted" style={{ fontSize: 12 }}>Your veNFTs:</span>
            {candidates.map((t) => (
              <button key={t} onClick={() => setTokenId(t)} className="pill" style={{ cursor: "pointer", border: "none", background: t === tokenId ? "var(--accent-soft)" : "var(--surface-2)", color: t === tokenId ? "var(--accent-ink)" : "var(--ink-soft)" }}>#{t}{depositedHere.includes(t) ? " · deposited" : ""}</button>
            ))}
          </div>
        )}
        {isConnected && !detecting && deposits.scanFailed && candidates.length === 0 && (
          <p style={{ fontSize: 12, marginBottom: 14, color: "var(--danger)", background: "rgba(210,73,63,0.08)", padding: "9px 12px", borderRadius: 8, lineHeight: 1.5 }}>Couldn't scan your deposits right now (RPC issue) — your funds are safe. Enter your veNFT token ID above to load it manually.</p>
        )}
        {isConnected && !detecting && !deposits.scanFailed && candidates.length === 0 && !collateralized && (
          <p className="muted" style={{ fontSize: 12, marginBottom: 14 }}>No {m.label} in your wallet. Already deposited one? Enter its token ID above to load it.</p>
        )}
        {collateralized && (
          <div className="pill" style={{ marginBottom: 14 }}><span className="dot" /> #{tokenId} deposited as collateral · voting</div>
        )}
        {isManaged && (
          <p style={{ color: "var(--ink-soft)", fontSize: 12.5, marginBottom: 14, lineHeight: 1.55, background: "var(--accent-soft)", padding: "10px 12px", borderRadius: 10 }}>
            #{tokenId} is <b>auto-voting (managed)</b>. Tap <b>Detach auto-vote</b> below to free it — one signature from your wallet, you keep the NFT, and our keeper takes over voting once you deposit. No need to leave for the NEST app.
            {detachBlocked ? " ⚠️ Detach is paused in the first/last hour of the weekly epoch — try again shortly." : ""}
          </p>
        )}
        {tid !== null && ownsNft && !collateralized && !acceptable && !isManaged && (
          <p style={{ color: "var(--danger)", fontSize: 12.5, marginBottom: 14, lineHeight: 1.5, background: "rgba(210,73,63,0.09)", padding: "10px 12px", borderRadius: 10 }}>
            #{tokenId} can't be used as collateral: <b>{acceptReason || "not eligible"}</b>. Resolve this on the NEST app, then retry.
          </p>
        )}

        {tid !== null && posLoading && (
          <p className="muted" style={{ fontSize: 13, marginBottom: 16 }}>Loading position…</p>
        )}
        {tid !== null && !posLoading && (
          <div style={{ marginBottom: 16 }}>
            <div className="kv"><span className="k">{collateralized ? "Credit line" : "Estimated credit line"}</span><span className="v">{fmtU(creditLine)} USDC</span></div>
            <div className="kv"><span className="k">Borrowed</span><span className="v">{fmtU(debt)} USDC</span></div>
            <div className="kv"><span className="k">Available to borrow</span><span className="v" style={{ color: "var(--accent)" }}>{fmtU(available)} USDC</span></div>
            {creditLine === 0n && (
              <p className="muted" style={{ fontSize: 12, marginTop: 10, lineHeight: 1.55 }}>
                No credit yet. Credit is sized from this veNFT's <b>realized voting-fee history</b> — make sure the
                position is actively voting (depositing lets the keeper vote it for you), and credit builds over the
                next few closed epochs.
              </p>
            )}
          </div>
        )}

        {collateralized && (
          <>
            <div className="seg">
              <button className={action === "borrow" ? "active" : ""} onClick={() => setAction("borrow")}>Borrow</button>
              <button className={action === "repay" ? "active" : ""} onClick={() => setAction("repay")}>Repay</button>
            </div>
            <div className="field">
              <div className="sub"><span>{action === "borrow" ? "Borrow" : "Repay"}</span><span>Max {fmtU(maxRaw)} <span className="max" role="button" tabIndex={0} onClick={setMax} onKeyDown={(e) => e.key === "Enter" && setMax()}>USE MAX</span></span></div>
              <div className="row"><input inputMode="decimal" aria-label="amount" placeholder="0.00" value={amount} onChange={(e) => { setIsMax(false); setAmount(e.target.value.replace(/[^0-9.]/g, "").replace(/(\..*)\./g, "$1")); }} /><span className="token">USDC</span></div>
            </div>
          </>
        )}

        <div style={{ marginTop: 18 }}>
          <button className="btn btn-accent btn-block" disabled={disabled} onClick={onAction}>{busy ? (isMining ? "Transaction pending…" : "Confirm in wallet…") : cta}</button>
          {collateralized && (
            <button className="btn btn-ghost btn-block" style={{ marginTop: 10 }} disabled={busy || debt > 0n} onClick={onWithdraw}>{debt > 0n ? "Repay loan to withdraw" : "Withdraw veNFT"}</button>
          )}
          {writeError && <p className="center" style={{ color: "var(--danger)", fontSize: 13, marginTop: 12 }}>{(writeError as { shortMessage?: string }).shortMessage || "Transaction failed"}</p>}
          {isSuccess && hash && <p className="center" style={{ color: "var(--accent)", fontSize: 13, marginTop: 12 }}>Confirmed · <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" style={{ color: "var(--accent)" }}>view</a></p>}
        </div>
      </div>
      <p className="center muted" style={{ fontSize: 12, marginTop: 14 }}>
        Your veNFT is custodied while borrowed; voting yield self-repays the loan. Credit is sized from your realized voting history. Non-liquidating — but interest accrues, so keep the loan covered by yield.
      </p>
    </div>
  );
}

function DashboardPanel({ onManage }: { onManage: () => void }) {
  const { address, isConnected } = useAccount();
  const fmtU = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)));
  const { byMarket, scanning } = useDeposits();
  const deposits = byMarket.flatMap((arr, mi) => arr.map((tokenId) => ({ mIdx: mi, tokenId })));
  const activity = usePositionActivity(deposits.map((d) => ({ mIdx: d.mIdx, tokenId: d.tokenId })));

  const { data: lendData } = useReadContracts({
    contracts: MARKETS.flatMap((mk) => {
      const lid = marketId(mk.params) as `0x${string}`;
      return [
        { address: ADDR.core, abi: coreAbi, functionName: "market", args: [lid] },
        { address: ADDR.core, abi: coreAbi, functionName: "supplyShares", args: [lid, address ?? ZERO_ADDR] },
      ];
    }),
    query: { enabled: !!address, refetchInterval: 15_000 },
  });

  const { data: posData } = useReadContracts({
    contracts: deposits.flatMap((d) => {
      const mk = MARKETS[d.mIdx]; const pid = marketId(mk.params) as `0x${string}`;
      return [
        { address: ADDR.core, abi: coreAbi, functionName: "position", args: [pid, d.tokenId] },
        { address: mk.creditManager, abi: creditManagerAbi, functionName: "creditLine", args: [mk.params, d.tokenId] },
        { address: ADDR.core, abi: coreAbi, functionName: "market", args: [pid] },
      ];
    }),
    query: { enabled: deposits.length > 0, refetchInterval: 15_000 },
  });

  if (!isConnected) return <div className="panel"><div className="card card-pad coming"><p className="muted">Connect your wallet to see your positions.</p></div></div>;

  const lendRows = MARKETS.map((mk, i) => {
    const market = lendData?.[i * 2]?.result as readonly bigint[] | undefined;
    const shares = (lendData?.[i * 2 + 1]?.result as bigint | undefined) ?? 0n;
    const supplied = market && market[1] > 0n ? (shares * market[0]) / market[1] : 0n;
    return { label: mk.label, logo: mk.logo, supplied };
  }).filter((r) => r.supplied > 0n);

  const borrowRows = deposits.map((d, i) => {
    const pos = posData?.[i * 3]?.result as readonly [string, bigint, bigint, number] | undefined;
    const creditPrev = (posData?.[i * 3 + 1]?.result as bigint | undefined) ?? 0n;
    const market = posData?.[i * 3 + 2]?.result as readonly bigint[] | undefined;
    if (!pos || pos[0].toLowerCase() !== (address ?? "").toLowerCase()) return null;
    const debt = market && pos[1] > 0n && market[3] > 0n ? (pos[1] * market[2]) / market[3] : 0n;
    const credit = pos[2] > 0n ? pos[2] : creditPrev;
    return { mIdx: d.mIdx, label: MARKETS[d.mIdx].label, tokenId: d.tokenId.toString(), credit, debt, avail: credit > debt ? credit - debt : 0n };
  }).filter(Boolean) as { mIdx: number; label: string; tokenId: string; credit: bigint; debt: bigint; avail: bigint }[];

  return (
    <div className="panel" style={{ maxWidth: 640 }}>
      <div className="card card-pad" style={{ marginBottom: 16 }}>
        <div className="eyebrow" style={{ marginBottom: 14 }}>Your supplied USDC</div>
        {lendRows.length ? lendRows.map((r) => (
          <div className="kv" key={r.label}><span className="k" style={{ display: "inline-flex", alignItems: "center", gap: 6 }}><Logo src={r.logo} size={15} />{r.label} market</span><span className="v">{fmtU(r.supplied)} USDC</span></div>
        )) : <p className="muted" style={{ fontSize: 14 }}>You haven't supplied USDC yet.</p>}
      </div>
      <div className="card card-pad">
        <div className="eyebrow" style={{ marginBottom: 14 }}>Your borrow positions</div>
        {scanning && !borrowRows.length ? <p className="muted" style={{ fontSize: 14 }}>Loading your positions…</p> : borrowRows.length ? borrowRows.map((r) => {
          const a = activity[`${r.mIdx}:${r.tokenId}`];
          const util = r.credit > 0n ? Math.min(100, Number((r.debt * 10000n) / r.credit) / 100) : 0;
          const weeks = r.debt > 0n && a && a.repaid7d > 0n ? Number(r.debt) / Number(a.repaid7d) : 0;
          return (
          <div key={r.tokenId} style={{ padding: "14px 0", borderTop: "1px solid var(--hairline)" }}>
            <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 10, alignItems: "center" }}>
              <span style={{ display: "inline-flex", alignItems: "center", gap: 7, fontWeight: 600 }}><Logo src={MARKETS[r.mIdx].logo} size={18} />{r.label} #{r.tokenId}</span>
              <button className="btn btn-ghost" style={{ padding: "5px 16px", fontSize: 13 }} onClick={onManage}>Manage</button>
            </div>
            {r.debt > 0n && (
              <div style={{ marginBottom: 12 }}>
                <div className="sub" style={{ marginBottom: 6, alignItems: "center" }}>
                  <span>Credit used</span>
                  <span style={{ fontSize: 12, fontWeight: 600, padding: "2px 9px", borderRadius: 999, background: "rgba(127,127,127,0.12)", color: "var(--accent)" }}>{fmt(util, 0)}%</span>
                </div>
                <div className="healthbar"><span style={{ width: `${util}%`, background: "var(--accent)" }} /></div>
              </div>
            )}
            <div className="kv"><span className="k">Credit line</span><span className="v">{r.credit > 0n ? `${fmtU(r.credit)} USDC` : "building…"}</span></div>
            <div className="kv"><span className="k">Borrowed</span><span className="v">{fmtU(r.debt)} USDC</span></div>
            <div className="kv"><span className="k">Available</span><span className="v" style={{ color: "var(--accent)" }}>{fmtU(r.avail)} USDC</span></div>
            {a && a.repaid > 0n && <div className="kv"><span className="k">Self-repaid (total)</span><span className="v" style={{ color: "var(--accent)" }}>{fmtU(a.repaid)} USDC</span></div>}
            {a && a.repaid7d > 0n && <div className="kv"><span className="k">Self-repaid this week</span><span className="v">{fmtU(a.repaid7d)} USDC</span></div>}
            {weeks > 0 && <div className="kv"><span className="k">Est. payoff at this pace</span><span className="v">~{weeks < 1 ? "<1" : Math.round(weeks)} week{!(weeks < 1) && Math.round(weeks) === 1 ? "" : "s"}</span></div>}
            {a && a.events.length > 0 && (
              <details style={{ marginTop: 8 }}>
                <summary className="muted" style={{ cursor: "pointer", fontSize: 13 }}>Activity ({a.events.length})</summary>
                <div style={{ marginTop: 8 }}>
                  {a.events.map((e, j) => (
                    <div className="kv" key={j} style={{ fontSize: 13 }}>
                      <span className="k">{e.type === "Repay" ? "Self-repay" : "Borrow"} · {relTime(e.ts)}</span>
                      <span className="v" style={{ color: e.type === "Repay" ? "var(--accent)" : "var(--ink)" }}>{e.type === "Repay" ? "−" : "+"}{fmtU(e.assets)} USDC</span>
                    </div>
                  ))}
                </div>
              </details>
            )}
            {r.debt === 0n && r.credit === 0n && <p className="muted" style={{ fontSize: 12, marginTop: 8, lineHeight: 1.55 }}>Credit builds from this veNFT's voting-fee history after the next epoch close — then you can borrow.</p>}
          </div>
          );
        }) : <p className="muted" style={{ fontSize: 14 }}>No collateral deposited yet.</p>}
      </div>
    </div>
  );
}

function ActivityFeed() {
  const client = usePublicClient();
  const [items, setItems] = useState<{ kind: string; label: string; assets?: bigint; tokenId: string; ts: number }[] | null>(null);
  useEffect(() => {
    if (!client) return;
    let cancelled = false;
    (async () => {
      const tip = await client.getBlockNumber().catch(() => null);
      if (!tip) { if (!cancelled) setItems([]); return; }
      const from = bmax(tip - 300000n, DEPLOY_BLOCK);
      const [borrows, repays, deps] = await Promise.all([
        scanLogs(client, BORROW_EVENT, undefined, from, tip),
        scanLogs(client, REPAY_EVENT, undefined, from, tip),
        scanLogs(client, SUPPLY_COLLATERAL_EVENT, undefined, from, tip),
      ]);
      const lbl = (id: string) => MARKETS.find((m) => (marketId(m.params) as string).toLowerCase() === id.toLowerCase())?.label ?? "veNFT";
      const all = [
        ...borrows.map((l: any) => ({ kind: "Borrow", label: lbl(l.args.id), assets: l.args.assets as bigint, tokenId: (l.args.tokenId as bigint).toString(), block: l.blockNumber as bigint })),
        ...repays.map((l: any) => ({ kind: "Repay", label: lbl(l.args.id), assets: l.args.assets as bigint, tokenId: (l.args.tokenId as bigint).toString(), block: l.blockNumber as bigint })),
        ...deps.map((l: any) => ({ kind: "Deposit", label: lbl(l.args.id), tokenId: (l.args.tokenId as bigint).toString(), block: l.blockNumber as bigint })),
      ].sort((a, b) => Number(b.block - a.block)).slice(0, 10);
      await Promise.all(all.map(async (e: any) => { try { const blk = await client.getBlock({ blockNumber: e.block }); e.ts = Number(blk.timestamp); } catch { e.ts = 0; } }));
      if (!cancelled) setItems(all.map((e: any) => ({ kind: e.kind, label: e.label, assets: e.assets, tokenId: e.tokenId, ts: e.ts })));
    })();
    return () => { cancelled = true; };
  }, [client]);
  const fmtU = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)));
  return (
    <div className="card card-pad mtable" style={{ marginTop: 16 }}>
      <div className="eyebrow" style={{ marginBottom: 14 }}>Recent activity</div>
      {items === null ? <p className="muted" style={{ fontSize: 14 }}>Loading…</p>
        : items.length === 0 ? <p className="muted" style={{ fontSize: 14 }}>No activity yet — be the first to deposit or borrow.</p>
        : items.map((e, j) => (
          <div className="kv" key={j} style={{ padding: "9px 0", borderTop: j ? "1px solid var(--hairline)" : "none" }}>
            <span className="k">{e.kind === "Deposit" ? "Deposited" : e.kind === "Borrow" ? "Borrowed against" : "Self-repaid"} {e.label} #{e.tokenId}</span>
            <span className="v">{e.assets !== undefined ? `${fmtU(e.assets)} USDC · ` : ""}{relTime(e.ts)}</span>
          </div>
        ))}
    </div>
  );
}

function ProtocolPanel() {
  const { data } = useReadContracts({
    contracts: MARKETS.map((mk) => ({ address: ADDR.core, abi: coreAbi, functionName: "market", args: [marketId(mk.params) as `0x${string}`] })),
    query: { refetchInterval: 15_000 },
  });
  const markets = MARKETS.map((mk, i) => {
    const m = data?.[i]?.result as readonly bigint[] | undefined;
    const supplyA = m?.[0] ?? 0n;
    const borrowA = m?.[2] ?? 0n;
    const fee = m?.[5] ?? 0n;
    const utilWad = supplyA > 0n ? (borrowA * WAD) / supplyA : 0n;
    return { ...mk, supplyA, borrowA, fee, utilWad, hasBorrowers: borrowA > 0n };
  });
  const { data: aprData } = useReadContracts({
    contracts: markets.map((m) => ({ address: ADDR.irm, abi: irmAbi, functionName: "aprAtUtilization", args: [m.utilWad] })),
    query: { refetchInterval: 15_000 },
  });
  // active collateral positions = veNFTs custodied by each market's adapter
  const { data: posData } = useReadContracts({
    contracts: MARKETS.map((mk) => ({ address: mk.veToken, abi: erc721Abi, functionName: "balanceOf", args: [mk.params.veAdapter] })),
    query: { refetchInterval: 30_000 },
  });
  const positionsOf = (i: number) => Number((posData?.[i]?.result as bigint | undefined) ?? 0n);
  const totalPositions = MARKETS.reduce((a, _, i) => a + positionsOf(i), 0);

  const totalSupplied = markets.reduce((a, m) => a + m.supplyA, 0n);
  const totalBorrowed = markets.reduce((a, m) => a + m.borrowA, 0n);
  const util = totalSupplied > 0n ? Number((totalBorrowed * WAD) / totalSupplied) / 1e18 : 0;
  const usd = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)), 0);
  const empty = totalSupplied === 0n && totalBorrowed === 0n;

  return (
    <div className="panel" style={{ maxWidth: 640 }}>
      <div className="stats" style={{ marginBottom: 16 }}>
        <div className="stat"><div className="label">Total supplied</div><div className="value">{usd(totalSupplied)}<span className="unit">USDC</span></div></div>
        <div className="stat"><div className="label">Total borrowed</div><div className="value">{usd(totalBorrowed)}<span className="unit">USDC</span></div></div>
        <div className="stat"><div className="label">Utilization</div><div className="value">{fmt(util * 100, 1)}<span className="unit">%</span></div></div>
      </div>
      <p className="center muted" style={{ fontSize: 12, marginTop: -4, marginBottom: 16 }}>{totalPositions} veNFT{totalPositions === 1 ? "" : "s"} deposited as collateral across all markets</p>
      <div className="card card-pad">
        <div className="eyebrow" style={{ marginBottom: 14 }}>Live markets · {MARKETS.length}</div>
        {markets.map((m, i) => {
          const borrowApr = Number(formatUnits((aprData?.[i]?.result as bigint | undefined) ?? 0n, 18));
          const supplyApr = borrowApr * (Number(m.utilWad) / 1e18) * (1 - Number(m.fee) / 1e18) * 100;
          const logo = MARKETS.find((x) => x.key === m.key)?.logo;
          return (
            <div key={m.key} style={{ padding: "12px 0", borderTop: i ? "1px solid var(--hairline)" : "none" }}>
              <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 8, alignItems: "center" }}>
                <span style={{ display: "inline-flex", alignItems: "center", gap: 7, fontWeight: 600 }}>{logo && <Logo src={logo} size={18} />}{m.label} market</span>
                <span className="pill">{m.hasBorrowers ? `${fmt(supplyApr)}% supply APR` : "no borrowers yet"}</span>
              </div>
              <div className="kv"><span className="k">Supplied</span><span className="v">{usd(m.supplyA)} USDC</span></div>
              <div className="kv"><span className="k">Borrowed</span><span className="v">{usd(m.borrowA)} USDC</span></div>
              <div className="kv"><span className="k">Utilization</span><span className="v">{fmt(Number(m.utilWad) / 1e18 * 100, 1)}%</span></div>
              <div className="kv"><span className="k">Collateral deposited</span><span className="v">{positionsOf(i)} veNFT{positionsOf(i) === 1 ? "" : "s"}</span></div>
            </div>
          );
        })}
      </div>
      {empty && <p className="center muted" style={{ fontSize: 13, marginTop: 16, lineHeight: 1.6 }}>Freshly launched — no deposits or borrows yet. Credit lines build from realized voting fees over the coming epochs; these figures update live from chain as activity begins.</p>}
      <ActivityFeed />
      <p className="center muted" style={{ fontSize: 12, marginTop: 14 }}>Live on-chain figures · refreshed every 15s · <a href={`${EXPLORER}/address/${ADDR.core}`} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>verify on explorer</a></p>
    </div>
  );
}

function EpochBar() {
  const WEEK = 604800;
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
  const start = Math.floor(now / WEEK) * WEEK; // ve(3,3) epochs align to Thu 00:00 UTC
  const rem = Math.max(0, start + WEEK - now);
  const pct = Math.min(100, ((now - start) / WEEK) * 100);
  const d = Math.floor(rem / 86400), h = Math.floor((rem % 86400) / 3600), mn = Math.floor((rem % 3600) / 60), s = rem % 60;
  const t = d > 0 ? `${d}d ${h}h ${mn}m` : `${h}h ${mn}m ${s}s`;
  return (
    <div className="epochbar">
      <div className="container epochbar-inner">
        <span className="lbl">Epoch ends in</span>
        <span className="time">{t}</span>
        <div className="bar" role="progressbar" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}><span style={{ width: `${pct}%` }} /></div>
        <span className="note">Credit lines refresh at epoch close · Thu 00:00 UTC</span>
      </div>
    </div>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="container" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 12 }}>
        <span>28 LEND · HyperEVM · non-custodial</span>
        <span style={{ display: "flex", gap: 18, alignItems: "center" }}>
          <a href={TELEGRAM} target="_blank" rel="noreferrer" aria-label="Telegram" style={{ color: "var(--muted)", display: "inline-flex" }}>
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden>
              <path d="M9.78 18.65l.28-4.23 7.68-6.92c.34-.31-.07-.46-.52-.19L7.74 13.3 3.64 12c-.88-.25-.89-.86.2-1.3l15.97-6.16c.73-.33 1.43.18 1.15 1.3l-2.72 12.81c-.19.91-.74 1.13-1.5.71L12.6 16.3l-1.99 1.93c-.23.23-.42.42-.83.42z" />
            </svg>
          </a>
          <a href={TWITTER} target="_blank" rel="noreferrer" aria-label="X (Twitter)" style={{ color: "var(--muted)", display: "inline-flex" }}>
            <svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" aria-hidden>
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
            </svg>
          </a>
          <a href={REPO} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Code</a>
          <a href={`${EXPLORER}/address/${ADDR.core}`} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Verified contracts</a>
        </span>
      </div>
      <div className="container" style={{ marginTop: 16, fontSize: 11, lineHeight: 1.6, color: "var(--muted)", opacity: 0.85, maxWidth: 860 }}>
        28 LEND is a new, non-custodial protocol, provided “as is” without warranty of any kind, and has not yet completed a formal third-party security audit. Nothing here is financial, investment, or legal advice. These are non-liquidating markets: a borrower who stops earning can leave debt unpaid, and lender principal may be impaired and socialized — only supply what you can afford to lose. Not available where prohibited by law. By using this app you accept these risks.
      </div>
    </footer>
  );
}

function ThemeToggle({ theme, toggle }: { theme: string; toggle: () => void }) {
  return (
    <button className="icon-btn" onClick={toggle} aria-label="Toggle theme">
      {theme === "light" ? (
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" /></svg>
      ) : (
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" /></svg>
      )}
    </button>
  );
}

function useInView<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [inView, setInView] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ob = new IntersectionObserver(
      (entries) => entries.forEach((e) => { if (e.isIntersecting) { setInView(true); ob.disconnect(); } }),
      { threshold: 0.15 }
    );
    ob.observe(el);
    return () => ob.disconnect();
  }, []);
  return { ref, inView };
}

function Reveal({ children, delay = 0, style }: { children: ReactNode; delay?: number; style?: CSSProperties }) {
  const { ref, inView } = useInView<HTMLDivElement>();
  return (
    <div ref={ref} className={`reveal${inView ? " in" : ""}`} style={{ transitionDelay: `${delay}ms`, ...style }}>
      {children}
    </div>
  );
}

function HowItWorks() {
  const steps = [
    { n: "01", t: "Deposit", d: "Lock your veNEST or veKITTEN as collateral. The keeper keeps it voting, so it keeps earning fees while it backs your loan." },
    { n: "02", t: "Borrow", d: "Draw USDC against a credit line sized from your veNFT's realized voting-fee history — read from the chain. No price oracle, no manual approval." },
    { n: "03", t: "It self-repays", d: "Your voting fees are harvested and pay the loan down automatically. No fixed schedule, no liquidations — the debt only shrinks." },
  ];
  return (
    <div className="steps">
      {steps.map((s, i) => (
        <Reveal key={s.n} delay={i * 120}>
          <div className="step">
            <div className="num">STEP {s.n}</div>
            <h3>{s.t}</h3>
            <p>{s.d}</p>
          </div>
        </Reveal>
      ))}
    </div>
  );
}

function Simulator() {
  const [weekly, setWeekly] = useState(50);
  const [epochs, setEpochs] = useState(8);
  const credit = weekly * 0.8 * epochs; // weekly × 8 (multiplier) × 0.8 (safety) × epochs/8 (participation)
  const m = (v: number) => `$${v.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
  return (
    <div className="sim">
      <div className="card card-pad">
        <div className="field">
          <div className="sub"><span>Weekly voting fees</span><span className="mono" style={{ color: "var(--ink)" }}>{m(weekly)}</span></div>
          <input type="range" min={1} max={2000} step={1} value={weekly} onChange={(e) => setWeekly(Number(e.target.value))} aria-label="weekly voting fees" />
        </div>
        <div style={{ marginTop: 16 }}>
          <div className="sub" style={{ marginBottom: 8 }}><span>Epochs voted (history)</span><span className="mono" style={{ color: "var(--ink)" }}>{epochs} / 8</span></div>
          <div style={{ display: "flex", gap: 6 }}>
            {[1, 2, 3, 4, 5, 6, 7, 8].map((n) => (
              <button key={n} type="button" onClick={() => setEpochs(n)} className="btn" aria-pressed={n === epochs}
                style={{ flex: 1, padding: "7px 0", fontSize: 12, background: n === epochs ? "var(--accent)" : "transparent", color: n === epochs ? "var(--on-accent)" : "var(--muted)" }}>{n}</button>
            ))}
          </div>
        </div>
        <div className="out">
          <div><div className="label">Est. credit line</div><div className="v" style={{ color: "var(--accent)" }}>{m(credit)}</div></div>
          <div><div className="label">Available to borrow</div><div className="v">{m(credit)} <span style={{ fontSize: 13, color: "var(--muted)" }}>USDC</span></div></div>
        </div>
        <p className="muted" style={{ fontSize: 12, marginTop: 14, lineHeight: 1.65 }}>
          Illustrative. Real credit = the <b>trailing minimum</b> of your realized weekly voting fees × an 8× multiplier × an 80% safety buffer, scaled by how many of the last 8 epochs you actually voted ({epochs}/8 here) — computed on-chain from your history, not a token price.
        </p>
      </div>
    </div>
  );
}

function LandingMarkets() {
  const { data } = useReadContracts({
    contracts: MARKETS.map((mk) => ({ address: ADDR.core, abi: coreAbi, functionName: "market", args: [marketId(mk.params) as `0x${string}`] })),
    query: { refetchInterval: 20_000 },
  });
  const { data: posData } = useReadContracts({
    contracts: MARKETS.map((mk) => ({ address: mk.veToken, abi: erc721Abi, functionName: "balanceOf", args: [mk.params.veAdapter] })),
    query: { refetchInterval: 30_000 },
  });
  const usd = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)), 0);
  return (
    <div className="card card-pad mtable">
      <div className="mrow head">
        <div>Market</div><div className="mv">Supplied</div><div className="mv">Borrowed</div><div className="mv mcol-collat">Collateral</div>
      </div>
      {MARKETS.map((mk, i) => {
        const mk2 = data?.[i]?.result as readonly bigint[] | undefined;
        const pos = Number((posData?.[i]?.result as bigint | undefined) ?? 0n);
        return (
          <div className="mrow" key={mk.key}>
            <div className="mname" style={{ display: "inline-flex", alignItems: "center", gap: 7 }}><Logo src={mk.logo} size={18} />{mk.label}</div>
            <div className="mv">{usd(mk2?.[0] ?? 0n)} USDC</div>
            <div className="mv">{usd(mk2?.[2] ?? 0n)} USDC</div>
            <div className="mv mcol-collat">{pos} veNFT{pos === 1 ? "" : "s"}</div>
          </div>
        );
      })}
    </div>
  );
}

function Faq() {
  const qs = [
    { q: "What's a veNFT?", a: "A vote-escrowed NFT — your locked governance position in a ve(3,3) DEX (veNEST on NEST, veKITTEN on KittenSwap). It earns voting fees, but your principal is locked, often permanently." },
    { q: "How is my credit line calculated?", a: "From your veNFT's realized voting-fee history, read directly from the chain: the trailing minimum of your weekly fees over the last 8 closed epochs, times a multiplier, with a safety buffer. There's no token-price oracle to manipulate and no off-chain operator deciding your limit." },
    { q: "What does “self-repaying” mean?", a: "A keeper harvests the voting fees your custodied veNFT earns and uses them to repay your loan automatically. You can also repay manually anytime — the debt only shrinks." },
    { q: "Are there liquidations?", a: "No. The live markets are non-liquidating. The tradeoff: if a borrower stops earning/voting, their loan may not fully repay, and in the worst case lender principal can be impaired and socialized across suppliers. Credit is sized conservatively to mitigate this." },
    { q: "When can I borrow?", a: "Once your veNFT has built fee history across closed epochs. A freshly deposited position starts at a 0 credit line until the next epoch closes, then it grows each week from there." },
    { q: "I use auto-vote (a managed veNEST) — can I still borrow?", a: "Yes. If your veNEST is in NEST's auto-vote (managed) position, the app detects it and lets you detach it in one click — right here, no trip to the NEST app. You keep the NFT, and our keeper takes over voting (into top fee pools) once you deposit, so you stay hands-off and still borrow. Note: detaching restores your lock as a fresh long-term lock, and detach is briefly paused in the first and last hour of each weekly epoch." },
    { q: "Who controls it? Is it safe?", a: "The core is immutable (no upgrade path) and fully non-custodial — no one can move your funds. Parameter changes flow through a 2-day timelock. A formal third-party audit is on the way; until then, treat it as new software and only supply what you can afford to lose." },
    { q: "What does it cost?", a: "No origination fee. The protocol takes a small cut of harvested voting fees; lenders earn the interest. For borrowers, it's cheaper than comparable veNFT lenders." },
  ];
  return (
    <div className="faq">
      {qs.map((x) => (
        <details key={x.q}>
          <summary>{x.q}</summary>
          <p>{x.a}</p>
        </details>
      ))}
    </div>
  );
}

function Landing({ theme, toggle, onLaunch }: { theme: string; toggle: () => void; onLaunch: () => void }) {
  const props = [
    { t: "Self-repaying", d: "Borrow USDC against your veNFT. Voting bribes pay the loan down automatically — no fixed schedule, no liquidations." },
    { t: "Real yield", d: "Lenders earn USDC interest from real on-chain voting revenue — not token emissions. No borrowers yet, so supply APR is currently 0%; it rises with utilization." },
    { t: "Verifiable", d: "Immutable core, 2-day timelock, no deployer backdoor. Every contract verified on-chain." },
  ];
  return (
    <div className="app">
      <header className="header">
        <div className="container header-inner">
          <LogoLockup />
          <nav className="lnav">
            <a href="#how">How it works</a>
            <a href="#simulator">Simulator</a>
            <a href="#markets">Markets</a>
            <a href="#getvenest">Get veNFT</a>
            <a href="#faq">FAQ</a>
          </nav>
          <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <ThemeToggle theme={theme} toggle={toggle} />
            <button className="btn btn-primary" onClick={onLaunch}>Launch App</button>
          </div>
        </div>
      </header>
      <main className="container" style={{ flex: 1 }}>
        <section style={{ textAlign: "center", padding: "96px 0 36px" }}>
          <div style={{ display: "flex", justifyContent: "center", marginBottom: 18 }}><Mark size={78} /></div>
          <div style={{ fontSize: "clamp(24px, 4vw, 34px)", fontWeight: 200, letterSpacing: "0.01em", marginBottom: 22 }}>
            twentyeight <span style={{ color: "var(--accent)" }}>lend</span>
          </div>
          <div className="pill" style={{ marginBottom: 22 }}><span className="dot" /> Live on HyperEVM</div>
          <h1 style={{ fontSize: "clamp(44px, 8vw, 84px)", fontWeight: 200, letterSpacing: "-0.045em", lineHeight: 1.0 }}>
            Liquidity for<br />locked <span style={{ color: "var(--accent)" }}>governance</span>.
          </h1>
          <p style={{ maxWidth: 580, margin: "26px auto 0", fontSize: 19, color: "var(--ink-soft)", lineHeight: 1.5 }}>
            28 LEND turns vote-escrowed NFTs into self-repaying USDC loans on HyperEVM — and lets USDC lenders earn real yield from voting revenue. Non-custodial. Non-liquidating.
          </p>
          <div style={{ marginTop: 34, display: "flex", gap: 12, justifyContent: "center", flexWrap: "wrap" }}>
            <button className="btn btn-accent" style={{ padding: "14px 30px", fontSize: 16 }} onClick={onLaunch}>Launch App</button>
            <a className="btn btn-ghost" style={{ padding: "14px 30px", fontSize: 16 }} href={REPO} target="_blank" rel="noreferrer">View code</a>
          </div>
        </section>
        <section className="stats" style={{ margin: "20px 0 40px" }}>
          {props.map((p) => (
            <div className="stat" key={p.t}>
              <div className="eyebrow">{p.t}</div>
              <p className="muted" style={{ marginTop: 12, fontSize: 14, lineHeight: 1.55 }}>{p.d}</p>
            </div>
          ))}
        </section>

        <section id="how" className="section">
          <Reveal><div className="section-head"><div className="eyebrow">How it works</div><h2>Liquidity that <span className="accent">repays itself</span></h2><p>Three steps. No fixed schedule, no liquidations.</p></div></Reveal>
          <HowItWorks />
        </section>

        <section id="simulator" className="section">
          <Reveal><div className="section-head"><div className="eyebrow">Simulator</div><h2>Estimate your credit line</h2><p>See what your veNFT's voting fees could unlock — drag to explore.</p></div></Reveal>
          <Reveal delay={80}><Simulator /></Reveal>
        </section>

        <section id="markets" className="section">
          <Reveal><div className="section-head"><div className="eyebrow">Markets</div><h2>Live markets</h2><p>Real on-chain figures, refreshed continuously.</p></div></Reveal>
          <Reveal delay={80}><LandingMarkets /></Reveal>
        </section>

        <section id="getvenest" className="section">
          <Reveal><div className="section-head"><div className="eyebrow">Get a veNFT</div><h2>Don't have a veNEST or veKITTEN yet?</h2><p>veNEST and veKITTEN positions trade on HyperWarp. Grab one, bring it here, and borrow against it.</p></div></Reveal>
          <Reveal delay={80}>
            <div className="card card-pad" style={{ maxWidth: 520, margin: "0 auto", textAlign: "center" }}>
              <p className="muted" style={{ fontSize: 14, lineHeight: 1.65, marginBottom: 18 }}>HyperWarp is the veNFT marketplace on HyperEVM. Browse live veNEST &amp; veKITTEN listings, then deposit your position on 28 LEND to unlock self-repaying USDC — without selling it.</p>
              <a className="btn btn-accent" style={{ padding: "13px 26px", fontSize: 15 }} href={HYPERWARP} target="_blank" rel="noreferrer">Browse veNFTs on HyperWarp ↗</a>
            </div>
          </Reveal>
        </section>

        <section id="faq" className="section">
          <Reveal><div className="section-head"><div className="eyebrow">FAQ</div><h2>Questions</h2></div></Reveal>
          <Reveal delay={80}><Faq /></Reveal>
        </section>
      </main>
      <Footer />
    </div>
  );
}

export function App() {
  const { theme, toggle } = useTheme();
  const [view, setView] = useState<"landing" | "app">(() => (localStorage.getItem("tw28:view") === "app" ? "app" : "landing"));
  const [tab, setTab] = useState(() => {
    const t = localStorage.getItem("tw28:tab");
    return t && ["Lend", "Borrow", "Dashboard", "Protocol"].includes(t) ? t : "Lend";
  });
  useEffect(() => { localStorage.setItem("tw28:view", view); }, [view]);
  useEffect(() => { localStorage.setItem("tw28:tab", tab); }, [tab]);
  if (view === "landing") return <Landing theme={theme} toggle={toggle} onLaunch={() => setView("app")} />;
  return (
    <div className="app">
      <Header tab={tab} setTab={setTab} theme={theme} toggle={toggle} onHome={() => setView("landing")} />
      <EpochBar />
      <main className="container" style={{ flex: 1 }}>
        {tab === "Lend" ? (
          <section className="hero">
            <div className="pill" style={{ marginBottom: 20 }}><span className="dot" /> Live on HyperEVM</div>
            <h1>Earn on USDC,<br />backed by <span className="accent">voting revenue</span>.</h1>
            <p>Supply USDC to earn yield paid by veNFT borrowers from real on-chain voting revenue — not emissions or protocol capital. No borrowers yet, so supply APR is currently 0%; it rises with utilization, targeting ~11–13% at healthy usage.</p>
          </section>
        ) : (
          <div style={{ textAlign: "center", padding: "56px 0 28px" }}>
            <h2 style={{ fontWeight: 300, fontSize: 30, letterSpacing: "-0.03em" }}>{tab === "Borrow" ? "Borrow against your veNFT" : tab === "Protocol" ? "Protocol stats" : "Your dashboard"}</h2>
          </div>
        )}
        {tab === "Lend" ? <LendPanel /> : tab === "Borrow" ? <BorrowPanel /> : tab === "Protocol" ? <ProtocolPanel /> : <DashboardPanel onManage={() => setTab("Borrow")} />}
      </main>
      <Footer />
    </div>
  );
}
