import { useEffect, useMemo, useState } from "react";
import { useAccount, useConnect, useDisconnect, useReadContracts, useSwitchChain, useWriteContract } from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { LogoLockup } from "./components/Logo";
import { hyperEVM } from "./wagmi";
import { ADDR, MARKETS, USDC_DECIMALS, coreAbi, erc20Abi, irmAbi, marketId } from "./contracts";

const WAD = 10n ** 18n;
const fmt = (v: number, d = 2) => v.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

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
        <nav className="nav">
          {["Lend", "Borrow"].map((t) => (
            <button key={t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>{t}</button>
          ))}
        </nav>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <button className="icon-btn" onClick={toggle} title="Theme">{theme === "light" ? "☾" : "☀"}</button>
          {!isConnected ? (
            <button className="btn btn-primary" onClick={() => connect({ connector: injected })}>Connect</button>
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

type MarketStats = { supplyApr: number; util: number; tvl: number; position: number };

function useMarket(idx: number): MarketStats & { id: `0x${string}`; refetchKey: number } {
  const { address } = useAccount();
  const m = MARKETS[idx];
  const id = marketId(m.params) as `0x${string}`;
  const { data, dataUpdatedAt } = useReadContracts({
    contracts: [
      { address: ADDR.core, abi: coreAbi, functionName: "market", args: [id] },
      { address: ADDR.core, abi: coreAbi, functionName: "supplyShares", args: [id, address ?? "0x0000000000000000000000000000000000000000"] },
    ],
    query: { refetchInterval: 12_000 },
  });
  const stats = useMemo<MarketStats>(() => {
    const market = data?.[0]?.result as readonly bigint[] | undefined;
    const shares = (data?.[1]?.result as bigint | undefined) ?? 0n;
    if (!market) return { supplyApr: 0, util: 0, tvl: 0, position: 0 };
    const [supplyA, supplyS, borrowA, , , fee] = market;
    const util = supplyA > 0n ? Number((borrowA * WAD) / supplyA) / 1e18 : 0;
    const tvl = Number(formatUnits(supplyA, USDC_DECIMALS));
    const position = supplyS > 0n ? Number(formatUnits((shares * supplyA) / supplyS, USDC_DECIMALS)) : 0;
    return { supplyApr: 0, util, tvl, position, _fee: fee } as MarketStats & { _fee: bigint };
  }, [data]);
  // borrow APR from the IRM, then lender APR = borrowApr * util * (1 - fee)
  const { data: aprData } = useReadContracts({
    contracts: [{ address: ADDR.irm, abi: irmAbi, functionName: "aprAtUtilization", args: [BigInt(Math.round(stats.util * 1e18))] }],
    query: { refetchInterval: 12_000 },
  });
  const borrowApr = Number(formatUnits((aprData?.[0]?.result as bigint | undefined) ?? 0n, 18));
  const fee = Number(((stats as unknown as { _fee?: bigint })._fee ?? 0n)) / 1e18;
  const supplyApr = borrowApr * stats.util * (1 - fee) * 100;
  return { ...stats, supplyApr, id, refetchKey: dataUpdatedAt };
}

function Stats({ s }: { s: MarketStats }) {
  return (
    <div className="stats">
      <div className="stat"><div className="label">Supply APR</div><div className="value" style={{ color: "var(--accent)" }}>{fmt(s.supplyApr)}<span className="unit">%</span></div></div>
      <div className="stat"><div className="label">Total supplied</div><div className="value">{fmt(s.tvl, 0)}<span className="unit">USDC</span></div></div>
      <div className="stat"><div className="label">Utilization</div><div className="value">{fmt(s.util * 100, 1)}<span className="unit">%</span></div></div>
    </div>
  );
}

function LendPanel() {
  const { address, isConnected, chainId } = useAccount();
  const [idx, setIdx] = useState(0);
  const [mode, setMode] = useState<"supply" | "withdraw">("supply");
  const [amount, setAmount] = useState("");
  const m = MARKETS[idx];
  const market = useMarket(idx);
  const { writeContract, isPending } = useWriteContract();

  const { data: walletData } = useReadContracts({
    contracts: [
      { address: ADDR.usdc, abi: erc20Abi, functionName: "balanceOf", args: [address ?? "0x0000000000000000000000000000000000000000"] },
      { address: ADDR.usdc, abi: erc20Abi, functionName: "allowance", args: [address ?? "0x0000000000000000000000000000000000000000", ADDR.core] },
    ],
    query: { enabled: !!address, refetchInterval: 12_000 },
  });
  const balance = (walletData?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (walletData?.[1]?.result as bigint | undefined) ?? 0n;

  const amt = useMemo(() => { try { return amount ? parseUnits(amount, USDC_DECIMALS) : 0n; } catch { return 0n; } }, [amount]);
  const needsApprove = mode === "supply" && amt > allowance;
  const max = mode === "supply" ? Number(formatUnits(balance, USDC_DECIMALS)) : market.position;

  const onAction = () => {
    if (!isConnected || chainId !== hyperEVM.id || amt === 0n) return;
    if (mode === "supply" && needsApprove)
      return writeContract({ address: ADDR.usdc, abi: erc20Abi, functionName: "approve", args: [ADDR.core, amt] });
    if (mode === "supply")
      return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "supply", args: [m.params, amt, address!] });
    return writeContract({ address: ADDR.core, abi: coreAbi, functionName: "withdraw", args: [m.params, amt, address!, address!] });
  };

  const cta = !isConnected ? "Connect wallet"
    : chainId !== hyperEVM.id ? "Switch to HyperEVM"
    : amt === 0n ? "Enter an amount"
    : mode === "supply" ? (needsApprove ? "Approve USDC" : "Supply USDC")
    : "Withdraw USDC";

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
            <button key={mk.key} className={`btn ${i === idx ? "btn-ghost" : ""}`} style={{ flex: 1, padding: "8px", fontSize: 13, color: i === idx ? "var(--ink)" : "var(--muted)", borderColor: i === idx ? "var(--accent)" : "transparent" }} onClick={() => setIdx(i)}>{mk.label} market</button>
          ))}
        </div>
        <div className="field">
          <div className="sub"><span>{mode === "supply" ? "You supply" : "You withdraw"}</span><span>Max {fmt(max)} <span className="max" onClick={() => setAmount(String(max))}>USE MAX</span></span></div>
          <div className="row"><input inputMode="decimal" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} /><span className="token">USDC</span></div>
        </div>
        <div style={{ marginTop: 18 }}>
          <div className="kv"><span className="k">Supply APR</span><span className="v" style={{ color: "var(--accent)" }}>{fmt(market.supplyApr)}%</span></div>
          <div className="kv"><span className="k">Your position</span><span className="v">{fmt(market.position)} USDC</span></div>
          <hr className="divider" />
          <button className="btn btn-accent btn-block" disabled={isPending || (isConnected && chainId === hyperEVM.id && amt === 0n)} onClick={onAction}>{isPending ? "Confirm in wallet…" : cta}</button>
        </div>
      </div>
      <p className="center muted" style={{ fontSize: 12, marginTop: 14 }}>
        Yield is paid by borrowers from veNFT voting revenue. Non-liquidating tier — supplying carries borrower-default risk.
      </p>
    </div>
  );
}

function BorrowPanel() {
  return (
    <div className="panel">
      <div className="card card-pad coming">
        <div className="pill" style={{ marginBottom: 16 }}><span className="dot" /> Coming next</div>
        <h3 style={{ fontWeight: 300, fontSize: 22 }}>Borrow against your veNFT</h3>
        <p className="muted" style={{ marginTop: 10, fontSize: 14, maxWidth: 360, marginInline: "auto" }}>
          Deposit a veNEST or veKITTEN position, draw USDC against your credit line, and let voting yield self-repay it. Borrower flow ships in the next release.
        </p>
      </div>
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
          <p>Supply USDC and earn yield paid by veNFT borrowers — funded by real on-chain voting bribes, not emissions or protocol capital.</p>
        </section>
        {tab === "Lend" ? <LendPanel /> : <BorrowPanel />}
      </main>
      <footer className="footer">
        <div className="container" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 12 }}>
          <span>28 LEND · HyperEVM</span>
          <span>Self-repaying veNFT credit · non-custodial</span>
        </div>
      </footer>
    </div>
  );
}
