// 28 LEND brand marks. Minimal line-art interpretation of the X/28 monogram:
// a crossing X (one ink stroke, one teal) with the K stem and teal serifs.
const teal = { stroke: "var(--accent)" } as const;

export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 120 120" fill="none" aria-hidden>
      <g strokeWidth={3.4} strokeLinecap="round">
        <line x1="22" y1="22" x2="98" y2="98" stroke="currentColor" />
        <line x1="22" y1="98" x2="98" y2="22" style={teal} />
        <line x1="64" y1="25" x2="64" y2="95" stroke="currentColor" strokeWidth={4.2} />
        <line x1="41" y1="25" x2="64" y2="25" style={teal} strokeWidth={2.6} />
        <line x1="41" y1="95" x2="64" y2="95" style={teal} strokeWidth={2.6} />
      </g>
    </svg>
  );
}

export function Wordmark({ size = 20 }: { size?: number }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "baseline", gap: 8, lineHeight: 1 }}>
      <span style={{ fontWeight: 200, fontSize: size * 1.4, letterSpacing: "-0.04em" }}>28</span>
      <span style={{ fontWeight: 500, fontSize: size * 0.78, letterSpacing: "0.18em" }}>
        <span style={{ color: "var(--accent)" }}>L</span>END
      </span>
    </span>
  );
}

export function LogoLockup() {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 12, color: "var(--ink)" }}>
      <Mark size={30} />
      <Wordmark size={18} />
    </span>
  );
}
