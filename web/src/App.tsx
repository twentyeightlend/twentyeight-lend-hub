import { useEffect, useMemo, useRef, useState } from "react";
import {
  useAccount, useConnect, useDisconnect, useReadContracts, useSwitchChain,
  useWaitForTransactionReceipt, useWriteContract,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { formatUnits, parseUnits } from "viem";
import { LogoLockup, Mark } from "./components/Logo";
import { hyperEVM } from "./wagmi";
import { ADDR, MARKETS, USDC_DECIMALS, adapterAbi, coreAbi, creditManagerAbi, erc20Abi, erc721Abi, irmAbi, marketId } from "./contracts";

const WAD = 10n ** 18n;
const REPO = "https://github.com/twentyeightlend/twentyeight-lend-hub";
const EXPLORER = "https://www.hyperscan.com";
const TWITTER = "https://x.com/twentyeightlend";
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
  const injected = connectors[0];
  return (
    <header className="header">
      <div className="container header-inner">
        <span role="button" tabIndex={0} onClick={onHome} onKeyDown={(e) => e.key === "Enter" && onHome()} style={{ cursor: "pointer" }}><LogoLockup /></span>
        <nav className="nav" role="tablist">
          {["Lend", "Borrow"].map((t) => (
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
  const acceptable = accept ? accept[0] : true;
  const acceptReason = accept?.[1] ?? "";

  // auto-detect the connected wallet's veNFTs for this market (VE tokens are ERC721Enumerable)
  const { data: nftBal } = useReadContracts({
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
  const autofilled = useRef(false);
  useEffect(() => { autofilled.current = false; }, [idx, address]);
  useEffect(() => { if (!autofilled.current && !tokenId && owned.length > 0) { setTokenId(owned[0]); autofilled.current = true; } }, [owned, tokenId]);

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
      if (!ownsNft || !acceptable) return;
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
    : !collateralized ? (!ownsNft ? "You don't own this veNFT" : !acceptable ? "Not eligible as collateral" : !approved ? `Approve ${m.label}` : `Deposit ${m.label} as collateral`)
    : amt === 0n ? "Enter an amount"
    : action === "borrow" ? "Borrow USDC"
    : needsUsdcApprove ? "Approve USDC" : "Repay USDC";

  const disabled = busy || !isConnected || wrongChain || tid === null
    || (!collateralized && (!ownsNft || !acceptable))
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
        <div className="field" style={{ marginBottom: owned.length ? 10 : 14 }}>
          <div className="sub"><span>Your {m.label} to deposit as collateral · token ID</span></div>
          <div className="row"><input inputMode="numeric" aria-label="veNFT token id" placeholder="e.g. 1234" value={tokenId} onChange={(e) => setTokenId(e.target.value.replace(/[^0-9]/g, ""))} /></div>
        </div>
        {owned.length > 0 && (
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14, alignItems: "center" }}>
            <span className="muted" style={{ fontSize: 12 }}>Detected:</span>
            {owned.map((t) => (
              <button key={t} onClick={() => setTokenId(t)} className="pill" style={{ cursor: "pointer", border: "none", background: t === tokenId ? "var(--accent-soft)" : "var(--surface-2)", color: t === tokenId ? "var(--accent-ink)" : "var(--ink-soft)" }}>#{t}</button>
            ))}
          </div>
        )}
        {isConnected && nftCount === 0 && (
          <p className="muted" style={{ fontSize: 12, marginBottom: 14 }}>No {m.label} found in this wallet on HyperEVM.</p>
        )}
        {tid !== null && ownsNft && !collateralized && !acceptable && (
          <p style={{ color: "var(--danger)", fontSize: 12.5, marginBottom: 14, lineHeight: 1.5, background: "rgba(210,73,63,0.09)", padding: "10px 12px", borderRadius: 10 }}>
            #{tokenId} can't be used as collateral: <b>{acceptReason || "not eligible"}</b>.{" "}
            {/attached|managed/i.test(acceptReason)
              ? "Detach it from the managed / auto-vote position on the NEST app, then it becomes eligible."
              : "Resolve this on the NEST app, then retry."}
          </p>
        )}

        {tid !== null && (
          <div style={{ marginBottom: 16 }}>
            <div className="kv"><span className="k">Credit line</span><span className="v">{fmtU(creditLine)} USDC</span></div>
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

function Footer() {
  return (
    <footer className="footer">
      <div className="container" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 12 }}>
        <span>28 LEND · HyperEVM · non-custodial</span>
        <span style={{ display: "flex", gap: 18, alignItems: "center" }}>
          <a href={TWITTER} target="_blank" rel="noreferrer" aria-label="X (Twitter)" style={{ color: "var(--muted)", display: "inline-flex" }}>
            <svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" aria-hidden>
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
            </svg>
          </a>
          <a href={REPO} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Code</a>
          <a href={`${EXPLORER}/address/${ADDR.core}`} target="_blank" rel="noreferrer" style={{ color: "var(--muted)" }}>Verified contracts</a>
        </span>
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

function Landing({ theme, toggle, onLaunch }: { theme: string; toggle: () => void; onLaunch: () => void }) {
  const props = [
    { t: "Self-repaying", d: "Borrow USDC against your veNFT. Voting bribes pay the loan down automatically — no fixed schedule, no liquidations." },
    { t: "Real yield", d: "Lenders earn USDC interest funded by on-chain voting revenue — not token emissions or subsidies." },
    { t: "Verifiable", d: "Immutable core, 2-day timelock, no deployer backdoor. Every contract verified on-chain." },
  ];
  return (
    <div className="app">
      <header className="header">
        <div className="container header-inner">
          <LogoLockup />
          <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <ThemeToggle theme={theme} toggle={toggle} />
            <button className="btn btn-primary" onClick={onLaunch}>Launch App</button>
          </div>
        </div>
      </header>
      <main className="container" style={{ flex: 1 }}>
        <section style={{ textAlign: "center", padding: "100px 0 36px" }}>
          <div style={{ display: "flex", justifyContent: "center", marginBottom: 30 }}><Mark size={84} /></div>
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
        <section className="stats" style={{ margin: "20px 0 90px" }}>
          {props.map((p) => (
            <div className="stat" key={p.t}>
              <div className="eyebrow">{p.t}</div>
              <p className="muted" style={{ marginTop: 12, fontSize: 14, lineHeight: 1.55 }}>{p.d}</p>
            </div>
          ))}
        </section>
      </main>
      <Footer />
    </div>
  );
}

export function App() {
  const { theme, toggle } = useTheme();
  const [view, setView] = useState<"landing" | "app">("landing");
  const [tab, setTab] = useState("Lend");
  if (view === "landing") return <Landing theme={theme} toggle={toggle} onLaunch={() => setView("app")} />;
  return (
    <div className="app">
      <Header tab={tab} setTab={setTab} theme={theme} toggle={toggle} onHome={() => setView("landing")} />
      <main className="container" style={{ flex: 1 }}>
        <section className="hero">
          <div className="pill" style={{ marginBottom: 20 }}><span className="dot" /> Live on HyperEVM</div>
          <h1>Earn on USDC,<br />backed by <span className="accent">voting revenue</span>.</h1>
          <p>Supply USDC and earn yield paid by veNFT borrowers — funded by real on-chain voting bribes, not emissions or protocol capital. Target 11–13% once borrowers are active.</p>
        </section>
        {tab === "Lend" ? <LendPanel /> : <BorrowPanel />}
      </main>
      <Footer />
    </div>
  );
}
