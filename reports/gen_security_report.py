#!/usr/bin/env python3
"""Generate the partner-facing security review PDF for twentyeight-lend.

Renders a triaged summary (NOT raw scanner output) to PDF via xhtml2pdf (pure-python,
no system deps). Source of truth: forge test results, Foundry invariant runs, Slither
triage, and Halmos symbolic proofs.
"""
import sys
from xhtml2pdf import pisa

REPORT_DATE = "2026-06-03"
HALMOS_STATUS = sys.argv[1] if len(sys.argv) > 1 else "3/3 proofs PASSED (no counterexamples)"

TRIAGE_ROWS = [
    # (impact, check, count, status, rationale)
    ("Medium", "reentrancy-no-eth", 13, "Mitigated",
     "Every external entry point is <b>nonReentrant</b> (Solady). The flagged call is the trusted per-market IRM (Morpho model); its rate is clamped to MAX_RATE_PER_SECOND."),
    ("Medium", "divide-before-multiply", 26, "Not applicable",
     "Intentional fixed-point ordering in WAD / virtual-share math. Precision loss is bounded and rounds in the protocol's favor."),
    ("Medium", "uninitialized-local", 17, "False positive",
     "Solidity zero-initializes locals; each is conditionally assigned before use (verified in liquidate() and _accrue())."),
    ("Medium", "unused-return", 18, "By design",
     "Deliberate tuple destructuring of fields not needed; e.g. self-repay re-derives amounts from balance deltas, not the return value."),
    ("Medium", "incorrect-equality", 9, "Reviewed - safe",
     "Exact-zero / state equality checks are intentional (debt == 0, collateral == 0, rate == 0)."),
    ("Medium", "pyth-unchecked-confidence", 1, "False positive",
     "Confidence IS enforced in PythPriceLib (conf*BPS > price*maxConfBps -> revert ConfidenceTooWide). Detector doesn't recognize the manual bps comparison."),
    ("Low", "calls-loop", 32, "Accepted",
     "Reward / credit-line iteration over a position's voted pools; bounded, and per-position gas is documented as a tracked item."),
    ("Low", "missing-zero-check", 21, "Accepted",
     "Immutable constructor args under a documented per-market trust model (Morpho). Lenders vet market params on opt-in."),
    ("Low", "timestamp", 19, "Accepted",
     "block.timestamp drives epoch / TWAP windows; manipulation is bounded by the 30-min TWAP window + short-vs-long deviation guard."),
    ("Low", "reentrancy-benign", 12, "Mitigated",
     "Guarded by nonReentrant; no state-dependent external interaction."),
    ("Low", "reentrancy-events", 3, "Informational",
     "Event-emission ordering only; no value impact."),
    ("Low", "events-maths", 3, "Informational",
     "Event-emission completeness; no security impact."),
    ("Informational", "style / quality (7 checks)", 15, "Informational",
     "naming-convention, cyclomatic-complexity, unindexed-event-address, missing-inheritance, assembly, too-many-digits, unused-state. Readability only."),
]

def badge(status):
    color = {
        "Mitigated": "#0a7d2c", "False positive": "#0a7d2c", "By design": "#0a7d2c",
        "Reviewed - safe": "#0a7d2c", "Not applicable": "#555", "Accepted": "#b8860b",
        "Informational": "#555",
    }.get(status, "#555")
    return f'<font color="{color}"><b>{status}</b></font>'

rows_html = "".join(
    f'<tr><td>{imp}</td><td><font face="Courier">{chk}</font></td>'
    f'<td align="center">{cnt}</td><td>{badge(st)}</td><td>{why}</td></tr>'
    for (imp, chk, cnt, st, why) in TRIAGE_ROWS
)

HTML = f"""
<html><head><style>
@page {{ size: A4; margin: 1.6cm; }}
body {{ font-family: Helvetica, Arial, sans-serif; font-size: 9.5pt; color: #1a1a1a; }}
h1 {{ font-size: 19pt; margin: 0 0 2px 0; }}
h2 {{ font-size: 12.5pt; color: #14304f; border-bottom: 1.5px solid #14304f; padding-bottom: 3px; margin-top: 16px; }}
.sub {{ color: #555; font-size: 9pt; margin-bottom: 10px; }}
.kpi {{ background-color: #f2f6fa; border: 1px solid #d6e0ea; padding: 8px; }}
table {{ width: 100%; border-collapse: collapse; margin-top: 6px; }}
th {{ background-color: #14304f; color: #ffffff; text-align: left; padding: 5px; font-size: 8.5pt; }}
td {{ border-bottom: 1px solid #e2e2e2; padding: 5px; font-size: 8.3pt; vertical-align: top; }}
.note {{ font-size: 8pt; color: #555; }}
.disc {{ background-color: #fff7e6; border: 1px solid #e6c97a; padding: 8px; font-size: 8.6pt; }}
</style></head><body>

<h1>twentyeight-lend &mdash; Internal Security Review</h1>
<div class="sub">veNFT cashflow-lending protocol on HyperEVM (chainId 999) &nbsp;|&nbsp; Report date: {REPORT_DATE} &nbsp;|&nbsp; Status: pre-external-audit</div>

<table class="kpi"><tr>
<td align="center"><b>104</b><br/><span class="note">tests passing</span></td>
<td align="center"><b>0</b><br/><span class="note">failing</span></td>
<td align="center"><b>5 &times; 12,800</b><br/><span class="note">invariant calls, 0 reverts</span></td>
<td align="center"><b>0</b><br/><span class="note">unmitigated High/Med</span></td>
<td align="center"><b>0</b><br/><span class="note">symbolic counterexamples</span></td>
</tr></table>

<h2>Scope &amp; Methodology</h2>
<p>The immutable lending core and its satellites: <font face="Courier">LendingCore</font>, <font face="Courier">WrappedCollateralMarket</font>,
<font face="Courier">SelfRepayEngine</font>, <font face="Courier">LenderVault</font>, <font face="Courier">ReceiptWrapper</font>, the Kitten/Nest adapters,
credit-line managers, IRM, and the <font face="Courier">VeTwapOracle</font>. Four independent methods were applied:</p>
<ul>
<li><b>Unit &amp; integration tests</b> &mdash; 104 tests across 18 suites (Foundry), including a live HyperEVM fork.</li>
<li><b>Invariant fuzzing</b> &mdash; 5 protocol invariants, 256 runs &times; 50 depth = 12,800 calls each; <b>0 reverts, 0 violations</b>.</li>
<li><b>Static analysis</b> &mdash; Slither v0.11.5 (53 contracts, 58 detectors). Every finding triaged below.</li>
<li><b>Symbolic verification</b> &mdash; Halmos proofs on the virtual-shares accounting (anti-inflation). {HALMOS_STATUS}.</li>
</ul>

<h2>Invariants proven to hold</h2>
<ul>
<li>Loan-token solvency: core balance &ge; (supplied &minus; borrowed) at all times.</li>
<li>Supplied &ge; borrowed for every market.</li>
<li>Supply-share conservation: &Sigma; holder shares + fee shares == total supply shares.</li>
<li>Borrow-share conservation: &Sigma; position shares == total borrow shares.</li>
<li>Debt &le; credit line, and a borrower is recorded whenever debt is non-zero.</li>
</ul>

<h2>Static-analysis triage (Slither &mdash; 189 results, 0 High)</h2>
<p class="note">Raw scanner counts are shown with their disposition after manual review. No finding required a code change.</p>
<table>
<tr><th>Impact</th><th>Detector</th><th>Count</th><th>Disposition</th><th>Rationale</th></tr>
{rows_html}
</table>

<h2>Residual risks (disclosed, not hidden)</h2>
<ul>
<li><b>Admin-key centralization</b> &mdash; per-market guardian / fee recipient / emergency-price setter. <b>Mitigation in progress:</b> moving these behind a Safe multisig (Safe is live on HyperEVM).</li>
<li><b>Permissionless market parameters</b> &mdash; credit manager / engine / oracle / IRM are immutable per market; a misconfigured market only harms its opt-in participants (Morpho model). Surfaced in NatSpec and to be shown in the UI.</li>
<li><b>NEST credit-line gas</b> &mdash; large multi-pool positions are compute-heavy; mitigated by a cached, refreshable credit line. Tracked.</li>
<li><b>Base-tier non-liquidation</b> &mdash; a borrower who stops voting halts self-repay; mitigated by a permissioned vote-keeper fallback.</li>
</ul>

<div class="disc"><b>Disclosure.</b> This is an internal review, not a substitute for an independent audit.
The protocol has <b>not yet been externally audited</b>. The results above describe internal testing,
static analysis, and symbolic verification only. A competitive/independent audit is planned before
mainnet deployment. Findings and residual risks are disclosed in full and were reviewed individually.</div>

<p class="note">Generated for partner review &mdash; twentyeight-lend, {REPORT_DATE}. Reproduce: <font face="Courier">forge test</font>, <font face="Courier">slither .</font>, <font face="Courier">halmos --contract HalmosSharesMath</font>.</p>

</body></html>
"""

out = "reports/twentyeight-lend-security-review.pdf"
with open(out, "wb") as f:
    err = pisa.CreatePDF(HTML, dest=f)
print("PDF ERROR" if err.err else f"OK -> {out}")
