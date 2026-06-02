import { useEffect, useMemo, useState } from "react";
import {
  useAccount, useConnect, useDisconnect, useReadContracts, useSwitchChain,
  useWaitForTransactionReceipt, useWriteContract,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { formatUnits, parseUnits } from "viem";
import { LogoLockup } from "./components/Logo";
import { hyperEVM } from "./wagmi";
import { ADDR, MARKETS, USDC_DECIMALS, coreAbi, creditManagerAbi, erc20Abi, erc721Abi, irmAbi, marketId } from "./contracts";

const WAD = 10n ** 18n;
const REPO = "https://github.com/twentyeightlend/twentyeight-lend-hub";
const EXPLORER = "https://www.hyperscan.com";
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

function Header({ tab, setTab, theme, toggle }: { tab: string; setTab: (t: string) => void; theme: string; toggle: () => void }) {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const injected = connectors[0];
  return (
    <header className="header">
      <div className="container header-inner">
        <LogoLockup />
        <nav className="nav" role="tablist">
          {["Lend", "Borrow"].map((t) => (
            <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>{t}</button>
          ))}
        </nav>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <button className="icon-btn" onClick={toggle} aria-label="Toggle theme">{theme === "light" ? "☾" : "☀"}</button>
          {!isConnected ? (
            <button className="btn btn-primary" disabled={!injected} onClick={() => injected && connect({ connector: injected })}>Connect</button>
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
};

function useMarket(id: `0x${string}`): MarketStats {
  const { address } = useAccount();
  const { data } = useReadContracts({
    contracts: [
      { address: ADDR.core, abi: coreAbi, functionName: "market", args: [id] },
      { address: ADDR.core, abi: coreAbi, functionName: "supplyShares", args: [id, address ?? ZERO_ADDR] },
    ],
    query: { refetchInterval: 12_000 },
  });
  const market = data?.[0]?.result as readonly bigint[] | undefined;
  const shares = (data?.[1]?.result as bigint | undefined) ?? 0n;

  const base = useMemo(() => {
    if (!market) return { util: 0, tvl: 0, positionAssets: 0n, idleLiquidity: 0n, hasBorrowers: false, fee: 0n, utilWad: 0n };
    const [supplyA, supplyS, borrowA, , , fee] = market;
    const utilWad = supplyA > 0n ? (borrowA * WAD) / supplyA : 0n;
    return {
      util: Number(utilWad) / 1e18,
      tvl: Number(formatUnits(supplyA, USDC_DECIMALS)),
      positionAssets: supplyS > 0n ? (shares * supplyA) / supplyS : 0n,
      idleLiquidity: supplyA > borrowA ? supplyA - borrowA : 0n,
      hasBorrowers: borrowA > 0n,
      fee, utilWad,
    };
  }, [market, shares]);

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

  // refetch balances/market after a confirmed tx, and clear the input
  useEffect(() => {
    if (isSuccess) { qc.invalidateQueries(); setAmount(""); setIsMax(false); reset(); }
  }, [isSuccess, qc, reset]);
  // reset input when switching mode/market
  useEffect(() => { setAmount(""); setIsMax(false); }, [mode, idx]);

  const maxRaw = mode === "supply" ? balance : market.positionAssets;
  const maxDisplay = Number(formatUnits(maxRaw, USDC_DECIMALS));
  const typed = useMemo(() => { try { return amount ? parseUnits(amount, USDC_DECIMALS) : 0n; } catch { return 0n; } }, [amount]);
  // when "MAX" is active, use the exact on-chain bigint (no float round-trip)
  const amt = isMax ? maxRaw : typed;
  const needsApprove = mode === "supply" && amt > allowance;
  const overWithdrawLiquidity = mode === "withdraw" && amt > market.idleLiquidity;

  const setMax = () => { setAmount(maxDisplay ? String(maxDisplay) : ""); setIsMax(maxRaw > 0n); };

  const onAction = () => {
    if (!isConnected || chainId !== hyperEVM.id || amt === 0n) return;
    if (mode === "supply" && needsApprove)
      return writeContract({ address: ADDR.usdc, abi: erc20Abi, functionName: "approve", args: [ADDR.core, amt] });
    if (mode === "supply")
      return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "supply", args: [m.params, amt, address!] });
    return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "withdraw", args: [m.params, amt, address!, address!] });
  };

  const busy = isPending || isMining;
  const cta = !isConnected ? "Connect wallet"
    : chainId !== hyperEVM.id ? "Switch to HyperEVM"
    : amt === 0n ? "Enter an amount"
    : overWithdrawLiquidity ? "Not enough liquidity"
    : mode === "supply" ? (needsApprove ? "Approve USDC" : "Supply USDC")
    : "Withdraw USDC";
  const disabled = busy || !isConnected || chainId !== hyperEVM.id || amt === 0n || overWithdrawLiquidity;

  return (
    <div className="panel">
      <Stats s={market} />
      <div className="card card-pad" style={{ marginTop: 20 }}>
        <div className="seg">
          <button className={mode === "supply" ? "active" : ""} onClick={() => setMode("supply")}>Supply</button>
          <button className={mode === "withdraw" ? "active" : ""} onClick={() => setMode("withdraw")}>Withdraw</button>
        </div>
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {MARKETS.map((mk, i) => (
            <button key={mk.key} className="btn" style={{ flex: 1, padding: "8px", fontSize: 13, color: i === idx ? "var(--ink)" : "var(--muted)", border: `1px solid ${i === idx ? "var(--accent)" : "transparent"}`, background: "transparent" }} onClick={() => setIdx(i)}>{mk.label} market</button>
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
          <hr className="divider" />
          <button className="btn btn-accent btn-block" disabled={disabled} onClick={onAction}>{busy ? (isMining ? "Transaction pending…" : "Confirm in wallet…") : cta}</button>
          {writeError && <p className="center" style={{ color: "var(--danger)", fontSize: 13, marginTop: 12 }}>{(writeError as { shortMessage?: string }).shortMessage || "Transaction failed"}</p>}
          {isSuccess && hash && <p className="center" style={{ color: "var(--accent)", fontSize: 13, marginTop: 12 }}>Confirmed · <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer" style={{ color: "var(--accent)" }}>view</a></p>}
        </div>
      </div>
      <details className="card" style={{ marginTop: 14, padding: "14px 18px", fontSize: 13 }}>
        <summary className="muted" style={{ cursor: "pointer" }}>Risks before you supply</summary>
        <p className="muted" style={{ marginTop: 10, lineHeight: 1.6 }}>
          This is a <b>non-liquidating</b> market. Yield is paid by borrowers from their veNFT voting revenue —
          there is no yield until borrowers draw against the market. Because there are <b>no liquidations</b>, if a
          borrower stops earning/voting their loan may not fully repay; in the worst case lender principal can be
          impaired and the loss socialized across suppliers. Credit lines are sized conservatively to mitigate this,
          but it is not eliminated. Experimental software — supply only what you can afford to lose.
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

  const { data } = useReadContracts({
    contracts: tid !== null ? [
      { address: m.creditManager, abi: creditManagerAbi, functionName: "creditLine", args: [m.params, tid] },
      { address: ADDR.core, abi: coreAbi, functionName: "position", args: [id, tid] },
      { address: m.veToken, abi: erc721Abi, functionName: "ownerOf", args: [tid] },
      { address: m.veToken, abi: erc721Abi, functionName: "isApprovedForAll", args: [address ?? ZERO_ADDR, m.params.veAdapter] },
      { address: ADDR.core, abi: coreAbi, functionName: "market", args: [id] },
      { address: ADDR.usdc, abi: erc20Abi, functionName: "allowance", args: [address ?? ZERO_ADDR, ADDR.core] },
    ] : [],
    query: { enabled: tid !== null && !!address, refetchInterval: 12_000 },
  });
  const creditPreview = (data?.[0]?.result as bigint | undefined) ?? 0n;
  const pos = data?.[1]?.result as readonly [string, bigint, bigint, number] | undefined;
  const owner = data?.[2]?.result as string | undefined;
  const approved = (data?.[3]?.result as boolean | undefined) ?? false;
  const market = data?.[4]?.result as readonly bigint[] | undefined;
  const usdcAllowance = (data?.[5]?.result as bigint | undefined) ?? 0n;

  const me = (address ?? "").toLowerCase();
  const collateralized = !!pos && pos[0] !== ZERO_ADDR && pos[0].toLowerCase() === me;
  const borrowShares = pos?.[1] ?? 0n;
  const creditLine = collateralized ? (pos?.[2] ?? 0n) : creditPreview;
  const debt = market && borrowShares > 0n && market[3] > 0n ? (borrowShares * market[2]) / market[3] : 0n;
  const available = creditLine > debt ? creditLine - debt : 0n;
  const ownsNft = !!owner && owner.toLowerCase() === me;

  const typed = useMemo(() => { try { return amount ? parseUnits(amount, USDC_DECIMALS) : 0n; } catch { return 0n; } }, [amount]);
  const maxRaw = action === "borrow" ? available : debt;
  const amt = isMax ? maxRaw : typed;
  const needsUsdcApprove = action === "repay" && amt > usdcAllowance;
  const setMax = () => { setAmount(maxRaw > 0n ? String(Number(formatUnits(maxRaw, USDC_DECIMALS))) : ""); setIsMax(maxRaw > 0n); };

  const busy = isPending || isMining;
  const wrongChain = chainId !== hyperEVM.id;

  const onAction = () => {
    if (!isConnected || wrongChain || tid === null) return;
    if (!collateralized) {
      if (!ownsNft) return;
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
    : !collateralized ? (!ownsNft ? "You don't own this veNFT" : !approved ? `Approve ${m.label}` : `Deposit ${m.label}`)
    : amt === 0n ? "Enter an amount"
    : action === "borrow" ? "Borrow USDC"
    : needsUsdcApprove ? "Approve USDC" : "Repay USDC";

  const disabled = busy || !isConnected || wrongChain || tid === null
    || (!collateralized && !ownsNft)
    || (collateralized && amt === 0n);

  const fmtU = (v: bigint) => fmt(Number(formatUnits(v, USDC_DECIMALS)));

  return (
    <div className="panel">
      <div className="card card-pad">
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {MARKETS.map((mk, i) => (
            <button key={mk.key} className="btn" style={{ flex: 1, padding: "8px", fontSize: 13, color: i === idx ? "var(--ink)" : "var(--muted)", border: `1px solid ${i === idx ? "var(--accent)" : "transparent"}`, background: "transparent" }} onClick={() => setIdx(i)}>{mk.label}</button>
          ))}
        </div>
        <div className="field" style={{ marginBottom: 14 }}>
          <div className="sub"><span>Your {m.label} token ID</span></div>
          <div className="row"><input inputMode="numeric" aria-label="veNFT token id" placeholder="e.g. 1234" value={tokenId} onChange={(e) => setTokenId(e.target.value.replace(/[^0-9]/g, ""))} /></div>
        </div>

        {tid !== null && (
          <div style={{ marginBottom: 16 }}>
            <div className="kv"><span className="k">Credit line</span><span className="v">{fmtU(creditLine)} USDC</span></div>
            <div className="kv"><span className="k">Borrowed</span><span className="v">{fmtU(debt)} USDC</span></div>
            <div className="kv"><span className="k">Available to borrow</span><span className="v" style={{ color: "var(--accent)" }}>{fmtU(available)} USDC</span></div>
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
          {collateralized && debt === 0n && (
            <button className="btn btn-ghost btn-block" style={{ marginTop: 10 }} disabled={busy} onClick={onWithdraw}>Withdraw veNFT</button>
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

export function App() {
  const { theme, toggle } = useTheme();
  const [tab, setTab] = useState("Lend");
  return (
    <div className="app">
      <Header tab={tab} setTab={setTab} theme={theme} toggle={toggle} />
      <main className="container" style={{ flex: 1 }}>
        <section className="hero">
          <div className="pill" style={{ marginBottom: 20 }}><span className="dot" /> Live on HyperEVM</div>
          <h1>Earn on USDC,<br />backed by <span className="accent">voting revenue</span>.</h1>
          <p>Supply USDC and earn yield paid by veNFT borrowers — funded by real on-chain voting bribes, not emissions or protocol capital. Target 11–13% once borrowers are active.</p>
        </section>
        {tab === "Lend" ? <LendPanel /> : <BorrowPanel />}
      </main>
      <footer className="footer">
        <div className="container" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 12 }}>
          <span>28 LEND · HyperEVM · non-custodial</span>
          <span style={{ display: "flex", gap: 18 }}>
            <a href={REPO} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Code</a>
            <a href={`${EXPLORER}/address/${ADDR.core}`} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Verified contracts</a>
          </span>
        </div>
      </footer>
    </div>
  );
}
