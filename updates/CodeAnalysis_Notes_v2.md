# code-audit v2 — feature notes

This is an additive upgrade to the CodeAnalysis audit script already deployed in
your k6-performance portal. Nothing in v1 behaviour changes by default; all
new features are opt-in via env vars.

## What's new

Six features, all of which feed your existing portal and Grafana pipeline
with more structured data:

| Feature | Default | Env var to enable | What it does |
|---|---|---|---|
| 1. Structured JSON output | **on** | always emitted | Writes `FINAL_REPORT.json`, `findings.json`, `metrics.json` at end of run |
| 2. Diff-only mode | off | `DIFF_ONLY=1 BASE_REF=main` | Audit only files changed vs BASE_REF; falls back to full scan on non-git |
| 3. Cost pre-flight | **on** | `COST_ESTIMATE=1` (default) | Print rough token count + dollar estimate before AI spend starts |
| 4. Static analysis pre-pass | off | `STATIC_ANALYSIS=1` | Runs semgrep/ruff/bandit/shellcheck/eslint if on PATH; adds output to AI context |
| 5. Churn-based file ordering | off | `CHURN_SORT=1 CHURN_DAYS=90` | Orders manifest by git activity so hot files get reviewed first |
| 6. Live progress JSON | **on** | `PROGRESS_JSON=1` (default) | Writes `progress.json` after each iteration; portal can poll for a progress bar |

### New env vars at a glance

```bash
# v2 additions (all optional, zero-config defaults are safe)
DIFF_ONLY=0             # 0|1 — PR-style audits
BASE_REF=main
COST_ESTIMATE=1         # 0|1 — print cost estimate
CONFIRM_COST=0          # 0|1 — require interactive y/N
PRICE_IN_PER_MTOK=15    # tune to your provider's current prices
PRICE_OUT_PER_MTOK=75
STATIC_ANALYSIS=0       # 0|1
CHURN_SORT=0            # 0|1
CHURN_DAYS=90
PROGRESS_JSON=1         # 0|1
```

### New output files in `$STATE_DIR`

```
metrics.json           — summary counts for InfluxDB/Grafana
findings.json          — structured findings, all iterations
FINAL_REPORT.json      — structured findings from final synthesis only
progress.json          — live progress (written after each iteration)
static.txt             — static analyzer output (if STATIC_ANALYSIS=1)
```

## Integration with the portal

The deployed `app/findings_parser.py` already knows about the v2 JSON
outputs. When it parses an audit's state dir, it prefers:

1. `FINAL_REPORT.json` (new, structured — `parse_confidence=1.0`)
2. `findings.json` (new, structured — `parse_confidence=1.0`)
3. `FINAL_REPORT.md` (original v1 path — regex over AI markdown)
4. `findings.md` (original v1 fallback)

This means:
- **Old audits in your DB keep working unchanged** (fall through to the v1 path)
- **New audits produce higher-quality structured findings** (no regex-on-AI-markdown fragility)
- **`metrics.json` drives summary counts directly** when present, bypassing any Python regex mismatches

## Integration with Grafana

`metrics.json` writes the same fields `influx_writer.py` pushes to
InfluxDB. No new wiring needed — the existing flow becomes more accurate
because it's now reading counts CodeAnalysis itself produced, not counts derived
from regexing AI markdown.

One new panel added to the dashboard (ID 206): *Audit Efficiency —
Findings per Iteration*. Tracks `total / iterations` by backend, useful
for catching prompt drift (if CodeAnalysis suddenly finds 0.3 findings/iter
instead of the usual 2-4, something's off).

## Validation performed before release

| Test | Result |
|---|---|
| `bash -n` syntax check | ✓ clean |
| awk extractor vs Python parser (same input) | ✓ byte-identical on 5/5 findings |
| Empty input | ✓ `[]`, no crash |
| NUL bytes + control chars in input | ✓ 0 findings, no crash |
| Unicode em-dash / en-dash / ASCII hyphen | ✓ all 3 variants parse correctly |
| 100-finding stress test | ✓ 18ms |
| End-to-end real run with fake AI | ✓ all 4 JSON outputs valid |
| v1 markdown fallback on pre-v2 state dirs | ✓ still produces 5/5 findings |
| v2 takes priority over v1 when both exist | ✓ verified |
| Empty state dir | ✓ `(0, 0)` cleanly |

## Bug caught during validation (fixed before release)

`write_final_json` used `grep -o ... | wc -l` to count severities. Under
`set -o pipefail` (line 2 of the script), grep's exit code 1 on zero
matches propagates through the pipeline and kills the script. Only
reproduces when a severity level has zero findings (typically `info`).
Fix applied: wrapped each count with `{ grep ...; || true; } | wc -l`.

If you previously ran v2 and saw `UNEXPECTED EXIT (code=1, line=1251)`,
this was the cause.

## Deployment

Drop-in replacement for your existing `scripts/code-audit.sh`:

```bash
# From the k6-performance repo root:
cp /path/to/code-audit-v2.sh scripts/code-audit.sh
chmod +x scripts/code-audit.sh
docker compose restart portal   # not strictly needed — scripts/ is read-only mounted
```

`app/findings_parser.py` is also updated (v2-aware). Copy it over and
rebuild the portal image:

```bash
cp /path/to/findings_parser.py app/findings_parser.py
docker compose build portal && docker compose up -d portal
```

`grafana/dashboards/k6-dashboard.json` has one new panel; Grafana
auto-reloads dashboards every 30s so no restart is needed.

## What was intentionally NOT added

The original proposal suggested several features I pushed back on:

- **Parallel iterations** — would break Ralph's design (each iteration's
  prompt includes a tail of prior findings; parallel iterations can't see
  each other). Parallelism belongs at the audit level (multiple repos),
  not the iteration level (single audit).
- **Entropy-based secret detection in bash** — use trufflehog/gitleaks if
  you want this, don't reimplement in bash regex.
- **10-point risk score** — fake precision. RepoLens already does proper
  deterministic scoring.
- **Import graph / dependency awareness** — real feature, but needs
  tree-sitter or language-specific parsers, not bash.
- **Incremental learning across runs** — encourages stale findings to
  propagate. The existing `reviewed.txt` resume mechanism is enough.
- **GitHub Actions annotations** — your deployment context is a portal,
  not GitHub Actions. Add later if/when needed.
