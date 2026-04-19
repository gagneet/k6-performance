# Code Audit Feature

The k6 portal now has a second run type — **code audits** — alongside the existing
k6 performance runs. Audits use an AI agent to scan a git repository for logic,
security, and architecture issues, and the findings are correlated with k6 perf
results through Grafana so you can see "performance regressed on this commit,
and the audit flagged these high-severity issues on the same commit."

## Architecture

```
┌────────────────────┐          ┌──────────────────────┐
│  Portal UI (8000)  │          │   Grafana  (3100)    │
│  Run / History /   │          │   k6-perf dashboard  │
│  Audit / Audits    │          │   + audit panels     │
└─────────┬──────────┘          └───────────▲──────────┘
          │                                 │
          │ REST + WS                       │ InfluxQL
          ▼                                 │
┌────────────────────┐     line protocol    │
│   FastAPI portal   │─────────────────────▶│
│   main.py          │                      │
│   ├ audit_runner   │                 ┌────┴──────────┐
│   ├ findings_parse │                 │  InfluxDB 1.8 │
│   └ influx_writer  │                 │  db=k6        │
└─────────┬──────────┘                 │  + audit_*    │
          │ subprocess                 └───────────────┘
          ▼
┌────────────────────┐
│  code-audit.sh    │   OR    ┌────────────────────┐
│  (bundled)         │         │  repolens.sh       │
└────────────────────┘         │  (operator-install)│
                               └────────────────────┘
```

**New SQLite tables** (in `/data/runs.db` alongside existing `runs`):

- `audits` — one row per audit run (id, backend, target, commit_sha, status, linked_run_id, summary_json)
- `audit_findings` — one row per parsed finding (severity, file, line_range, message, confidence)
- `runs.commit_sha` — new nullable column on the existing k6 runs table

All schema changes are additive. Existing k6 run data is untouched.

**New InfluxDB measurements** (same `k6` db k6 already uses):

- `audit_summary` — one point per audit, tagged with `audit_id`, `backend`, `target`, `commit_sha`, `testid`
- `audit_finding` — one point per finding, tagged with `severity`, `finding_type`, `file`, `confidence`

## Quickstart

1. **Drop a repo into the audit workspace.**
   The portal's audit workspace lives in the `portal-data` volume at
   `/data/audits/repos/`. Clone the repo you want to audit into there:

   ```bash
   docker compose exec portal bash -c \
     'mkdir -p /data/audits/repos && git clone https://github.com/your/repo /data/audits/repos/myapp'
   ```

2. **Provide an agent API key.**
   Set `ANTHROPIC_API_KEY` (for Claude) or `OPENAI_API_KEY` (for Codex) in
   a `.env` file next to `docker-compose.yml`:

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```

   Or export before `make up`. The portal passes these through to the audit
   subprocess's environment; no key is stored in SQLite.

3. **Install an agent CLI in the portal image.**
   The simplest path is to rebuild with Claude Code baked in:

   ```bash
   docker compose build --build-arg INSTALL_CLAUDE_CODE=1 portal
   docker compose up -d portal
   ```

   For RepoLens, install manually in a derived Dockerfile or mount it as a
   volume — see the RepoLens repo for install options.

4. **Start an audit from the UI.**
   Open http://localhost:8000, click **Audit** in the nav, pick your target
   from the dropdown, choose **Code Analysis** (fast, cheap) or **RepoLens** (deep,
   $$$), and hit **▶ Run Audit**. Output streams live in the terminal pane.

5. **View findings.**
   Switch to the **Audits History** tab. Click an audit row to open its
   findings detail — severity, type, file, line range, confidence. Each
   audit links automatically to any k6 run that ran against the same commit
   SHA; you can override this link manually.

6. **See it in Grafana.**
   The dashboard (UID `k6-perf`) now has a new **Code Audit** section at the
   bottom with five panels. Use the `$audit_id` template variable at the top
   to pick a specific audit, and `$testid` to compare findings against the
   performance run on the same commit.

## Backends

### CodeAnalysis (`scripts/code-audit.sh`, called via `run-audit.sh`)

A read-only bash-driven audit loop that batches source files and pipes them
to an agent CLI (`claude`, `codex`, `llm`, etc.) in iterations. Produces a
`FINAL_REPORT.md` which the portal parses into structured findings.

**Cost**: low to moderate — one full pass of a 50k-LOC repo typically runs
for 20–40 iterations of `claude -p --model opus`. Budget accordingly per
your Anthropic pricing.

**Knobs** (in the UI "Run Audit" form or via env passthrough):

| UI field | Env var | Default | Notes |
|---|---|---|---|
| Max Batch Bytes | `MAX_BATCH_BYTES` | 90000 | Smaller → more iterations, less context per call |
| Max Iterations | `MAX_ITERATIONS` | 50 | Hard safety cap (audit aborts if exceeded) |
| — | `AI_CMD` | `claude -p --model opus --effort max --tools "" --no-session-persistence` | Override the full agent command |
| — | `EXTRA_EXCLUDES` | — | Comma-separated globs to exclude |

### RepoLens (`repolens.sh`)

A multi-lens tool that runs up to 280 specialist AI lenses across 27 domains.
Produces JSON or GitHub issues. The portal runs it with `--local` so findings
stay in the audit workspace rather than creating issues in a remote repo.

**⚠ Cost warning**: RepoLens' own docs note a full audit "can easily reach
hundreds of dollars on a single repo." The UI surfaces a confirmation dialog
if you start a RepoLens audit without `--focus` or `--domain` scoping.

**Knobs**:

| UI field | RepoLens flag | Notes |
|---|---|---|
| Focus | `--focus <lens-id>` | Single lens only |
| Domain | `--domain <domain-id>` | One of the 27 domains (e.g. `security`) |
| Max Cost ($) | `--max-cost <dollars>` | Hard budget ceiling |

Pass additional RepoLens flags via `REPOLENS_EXTRA_ARGS` env var.

## Correlation mechanics

Audits link to k6 runs in two ways, in order of precedence:

1. **Manual link** — operator picks a `run_id` in the UI ("Link to k6 Run"
   dropdown) or via `POST /api/audits/{id}/link`. This always wins.

2. **Auto-match by commit SHA** — when the audit target is a git repo, the
   portal captures `HEAD` and stores it as `audits.commit_sha`. If a k6 run
   has the same `commit_sha` (set via the `commit_sha` param on `POST /api/runs`),
   the portal auto-links them after the audit finishes.

For the auto-match to work, you need to tell k6 which commit it's running
against. From the portal API:

```bash
curl -X POST http://localhost:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{
    "script": "load-test.js",
    "vus": 50,
    "duration": "5m",
    "target_url": "https://staging.myapp.com",
    "commit_sha": "abc123def456"
  }'
```

The k6 subprocess also tags its InfluxDB samples with `commit_sha=<sha>`, so
Grafana can filter perf metrics by commit too.

For non-git targets or ad-hoc correlations, use the manual link.

## Security & cost reality check

These notes come straight from the upstream tools and are repeated here so
you don't miss them:

- **CodeAnalysis and RepoLens both run AI agents with shell access** against the
  target repository. RepoLens in particular runs `claude --dangerously-skip-permissions`.
  This is fine for repos you own on a machine you control — it is **not**
  a sandboxed security tool. Don't point it at untrusted code.

- **Prompt injection is trivial.** A malicious README, commit message, or
  docstring in a scanned repo can instruct the agent to do arbitrary things.
  The audit workspace is mounted into the portal container with the same
  privileges as the portal itself.

- **Cost runaway is real.** The portal clamps obvious misuse (max iterations
  ≤ 500, max cost ≤ $200) but API spend ultimately lives in your Anthropic/
  OpenAI account. Start small with a focused scope.

- **Container hard timeout.** Every audit aborts after `AUDIT_MAX_SECONDS`
  (default 2 hours). Override per-environment via docker-compose.

For complete CLI, UI, and API usage see **[USAGE.md](USAGE.md)**.

## API reference (audit endpoints)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/audit/backends` | Which backends are installed |
| `GET` | `/api/audit/targets` | Repos under `/data/audits/repos/` |
| `POST` | `/api/audits` | Start a new audit |
| `GET` | `/api/audits` | List audits (most recent first) |
| `GET` | `/api/audits/{id}` | Audit detail + structured findings |
| `DELETE` | `/api/audits/{id}/stop` | Abort a running audit |
| `POST` | `/api/audits/{id}/link` | Manually link to a k6 run |
| `GET` | `/api/correlate/{commit_sha}` | All audits + runs for a commit |
| `WS` | `/ws/{audit_id}` | Stream audit output (prefix `a-`) |

### POST /api/audits payload

```json
{
  "backend": "code",
  "target": "myapp",
  "agent": "claude",
  "scope": {
    "max_batch_bytes": 90000,
    "max_iterations": 50
  },
  "env_vars": {},
  "linked_run_id": null
}
```

For RepoLens:

```json
{
  "backend": "repolens",
  "target": "myapp",
  "agent": "claude",
  "scope": {
    "focus": "injection",
    "max_cost": 20
  }
}
```

## Troubleshooting

**"backend binary not found: claude"** — No agent CLI in the portal
container. Rebuild with `INSTALL_CLAUDE_CODE=1` or `docker compose exec
portal` + manual install.

**"audit target not found"** — The target path resolves relative to
`/data/audits/repos/`. Confirm the repo exists inside the portal container
(not just on the host).

**Audit finishes with 0 findings** — Open the audit detail and check the
raw output. Usually: (1) AI_CMD errored and fell back to empty output, or
(2) the prompt didn't match the parser's template. The last 8KB of output
is stored in `audits.output` for debugging.

**Grafana panels empty** — Check that audit summary data actually landed in
InfluxDB: `docker compose exec influxdb influx -database k6 -execute 'SHOW
MEASUREMENTS'` should list `audit_summary` and `audit_finding`. If those
are missing, `influx_writer` logs will tell you why (typically network or
URL config).
