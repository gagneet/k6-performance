# Usage Guide — k6 Performance Portal

Complete reference for the UI, CLI tools, API, environment variables, and operational tasks.

## Contents

1. [Portal UI Walkthrough](#portal-ui-walkthrough)
2. [k6 Performance Tests](#k6-performance-tests)
3. [Code Analysis (AI audit)](#code-analysis-ai-audit)
4. [Local SAST (zero-cost audit)](#local-sast-zero-cost-audit)
5. [RepoLens (deep AI audit)](#repolens-deep-ai-audit)
6. [Monthly Dependency Check](#monthly-dependency-check)
7. [API Reference](#api-reference)
8. [Environment Variables](#environment-variables)
9. [Makefile Commands](#makefile-commands)
10. [Docker Operations](#docker-operations)
11. [Grafana Dashboards](#grafana-dashboards)
12. [Troubleshooting](#troubleshooting)

---

## Portal UI Walkthrough

Open http://localhost:8000. The nav bar has four tabs:

| Tab | Purpose |
|---|---|
| **Run Test** | Launch a k6 script, watch live output, get a Grafana link |
| **History** | Table of all k6 runs with time-scoped Grafana links |
| **Audit** | Launch a code audit (Code Analysis / Local SAST / RepoLens) |
| **Audits History** | Table of all audits with per-finding drill-down |

### Run Test tab

1. **Script** — dropdown populated from `scripts/*.js` (and any extra mounted dirs).
2. **VUs / Duration / Target URL** — forwarded to k6 as `--vus`, `--duration`, and `-e TARGET_URL=`.
3. **Commit SHA** — optional; links this k6 run to any audit on the same commit in Grafana.
4. Click **▶ Run** — live ANSI output streams in the terminal pane below.
5. On completion, a **Grafana** button appears linking directly to the time-scoped dashboard for this run.

### Audit tab

1. **Target** — repo under `/data/audits/repos/` inside the container; the dropdown is populated from `GET /api/audit/targets`.
2. **Backend** — only backends shown as "available" in `GET /api/audit/backends` are enabled:
   - **Code Analysis** — AI-driven, requires an agent CLI + API key
   - **Local SAST** — zero-cost; requires semgrep / bandit / ruff installed in the image
   - **RepoLens** — AI-driven, external install required
3. **Agent** (Code Analysis / RepoLens only) — `claude`, `codex`, or `opencode/<model>`.
4. **Scope fields** — backend-specific knobs (see per-backend sections below).
5. Click **▶ Run Audit** — output streams live. A cost warning is shown for RepoLens runs without a domain/focus scope.

### Audits History tab

- Click any row to expand: severity breakdown, findings table (file, line, message, confidence).
- **Link to k6 Run** — manually associate this audit with a performance run for Grafana correlation.
- Audit rows auto-link to k6 runs that share the same `commit_sha`.

---

## k6 Performance Tests

### Scripts

| Script | Shape | Typical use |
|---|---|---|
| `smoke-test.js` | 1 VU, 30 s | Quick sanity check |
| `load-test.js` | ramp → 10 VU steady → ramp-down | Baseline throughput |
| `stress-test.js` | staircase to 200 VU | Find the breaking point |
| `spike-test.js` | baseline → instant 200 VU spike → recovery | Burst resilience |
| `soak-test.js` | 20 VU for 4 h | Memory-leak detection |

All scripts read `__ENV.TARGET_URL` as the target. Drop additional `.js` files into `scripts/` and they appear in the UI immediately.

### CLI — direct k6

Requires k6 installed on the host (or use `make smoke` which runs the smoke test for you).

```bash
# Basic
k6 run scripts/smoke-test.js

# With InfluxDB output and target override
k6 run \
  --out influxdb=http://localhost:8086/k6 \
  --vus 20 \
  --duration 2m \
  -e TARGET_URL=https://staging.example.com \
  scripts/load-test.js

# Tag with a commit SHA for Grafana correlation
k6 run \
  --out influxdb=http://localhost:8086/k6 \
  --tag commit_sha=abc123def456 \
  -e TARGET_URL=https://staging.example.com \
  scripts/load-test.js

# Inside the container
docker compose exec portal k6 run /scripts/smoke-test.js
```

### CLI — via the API

```bash
# Start a run
curl -s -X POST http://localhost:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{
    "script":     "load-test.js",
    "vus":        20,
    "duration":   "2m",
    "target_url": "https://staging.example.com",
    "commit_sha": "abc123def456",
    "extra_tags": {"env": "staging"},
    "env_vars":   {}
  }' | python3 -m json.tool

# List recent runs
curl -s http://localhost:8000/api/runs | python3 -m json.tool

# Get a specific run (includes raw output)
curl -s http://localhost:8000/api/runs/<run_id> | python3 -m json.tool

# Stop a running test
curl -s -X DELETE http://localhost:8000/api/runs/<run_id>/stop
```

### RunRequest fields

| Field | Type | Default | Description |
|---|---|---|---|
| `script` | string | required | Filename from `GET /api/scripts` |
| `vus` | int | 10 | Virtual users |
| `duration` | string | `"30s"` | k6 duration string (`30s`, `5m`, `1h`) |
| `target_url` | string | null | Passed as `TARGET_URL` env var to k6 |
| `commit_sha` | string | null | Links run to audits on same commit |
| `extra_tags` | object | `{}` | InfluxDB tags added to all measurements |
| `env_vars` | object | `{}` | Additional env vars injected into k6 subprocess |

---

## Code Analysis (AI audit)

`scripts/code-audit.sh` walks a repository file-by-file in batches, sends each batch to a headless AI CLI, accumulates findings, then synthesises a `FINAL_REPORT.md`. Fully resumable — re-run the same command to pick up where it left off.

### Prerequisites

- An AI CLI on `PATH`: `claude` (Claude Code), `llm`, `codex`, or any command that reads a prompt on stdin and writes to stdout.
- `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` set.

### CLI — direct

```bash
# Defaults (claude, opus model, max effort)
./scripts/code-audit.sh /path/to/repo

# Use a different model
AI_MODEL=sonnet ./scripts/code-audit.sh /path/to/repo

# Use a different AI tool entirely
AI_CMD='llm -m gpt-4o' ./scripts/code-audit.sh /path/to/repo

# Run pytest first and include its output as audit context
VERIFY_CMD='pytest -q' ./scripts/code-audit.sh /path/to/repo

# Smaller batches (fewer tokens per call, more iterations)
MAX_BATCH_BYTES=30000 ./scripts/code-audit.sh /path/to/repo

# Limit iterations (cost control)
MAX_ITERATIONS=10 ./scripts/code-audit.sh /path/to/repo

# Preview only — writes manifest + preflight, exits before calling AI
PREVIEW_ONLY=1 ./scripts/code-audit.sh /path/to/repo

# Exclude extra paths
EXTRA_EXCLUDES='deployment/*,*.generated.js' ./scripts/code-audit.sh /path/to/repo

# Persist state to a custom directory
STATE_DIR=/tmp/my-audit ./scripts/code-audit.sh /path/to/repo

# Show full help
./scripts/code-audit.sh --help
```

### CLI — inside the portal container

```bash
# The portal uses run-audit.sh as a thin wrapper
docker compose exec portal bash /scripts/run-audit.sh /data/audits/repos/myapp

# With env overrides
docker compose exec -e MAX_ITERATIONS=15 -e VERIFY_CMD='make test' \
  portal bash /scripts/run-audit.sh /data/audits/repos/myapp

# Watch the state directory for progress
docker compose exec portal tail -f /data/audits/<audit_id>/code-audit.log
```

### Via the API

```bash
# Start with defaults
curl -s -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{"backend":"code","target":"myapp"}' | python3 -m json.tool

# Start with scope + agent options
curl -s -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{
    "backend":    "code",
    "target":     "myapp",
    "agent":      "claude",
    "scope": {
      "max_batch_bytes":  30000,
      "max_iterations":   20,
      "extra_excludes":   "deployment/*,*.min.js",
      "preview_only":     false
    },
    "env_vars": {
      "VERIFY_CMD": "pytest -q",
      "AI_MODEL":   "sonnet"
    }
  }' | python3 -m json.tool
```

### Code Analysis environment variables

| Variable | Default | Description |
|---|---|---|
| `AI_CMD` | `claude -p --model opus --effort max --tools "" --no-session-persistence` | Full AI command (overrides AI_MODEL/AI_EFFORT) |
| `AI_MODEL` | `opus` | Model alias passed to claude CLI |
| `AI_EFFORT` | `max` | Effort level passed to claude CLI |
| `VERIFY_CMD` | — | Command run once before audit; output included as context every iteration |
| `MAX_ITERATIONS` | 200 | Hard cap — audit aborts if exceeded |
| `MAX_BATCH_BYTES` | 90000 | Approximate source bytes per iteration |
| `MAX_FILE_BYTES` | 18000 | Files larger than this are truncated |
| `HEAD_LINES` | 220 | Lines shown from the start of truncated files |
| `TAIL_LINES` | 140 | Lines shown from the end of truncated files |
| `RECENT_FINDINGS_CHARS` | 16000 | Prior findings included as context each iteration |
| `AI_RETRIES` | 3 | Retry count on AI command failure |
| `EXTRA_EXCLUDES` | — | Comma-separated globs excluded after built-in excludes |
| `PREVIEW_ONLY` | 0 | If `1`: write manifest/preflight and exit (no AI calls) |
| `RUN_PREFLIGHT_AI` | 0 | If `1`: run one AI pass on `PREFLIGHT_PROMPT.md` before main audit |
| `STATE_DIR` | `<repo>/.code-audit` | Where audit state is persisted |

### Output structure (under `STATE_DIR`)

| File | Contents |
|---|---|
| `PROMPT.md` | System prompt sent to AI (auto-seeded, editable mid-run) |
| `PREFLIGHT.md` | Repo-shape safety review with paths worth checking |
| `manifest.txt` | All discovered source/config files |
| `reviewed.txt` | Files already reviewed (enables resume) |
| `tree.txt` | Repo file tree (included as context each iteration) |
| `git.txt` | Git status + recent log |
| `verify.txt` | Output of `VERIFY_CMD` |
| `findings.md` | Accumulated raw findings from all iterations |
| `iterations/` | Per-iteration AI responses (`iteration-001.md`, etc.) |
| `FINAL_REPORT.md` | Deduplicated final report (parsed by the portal into findings rows) |

---

## Local SAST (zero-cost audit)

`scripts/local-sast.sh` runs three static analysis tools with no AI calls and no API costs. All three tools are installed inside the portal Docker image via `requirements.txt`.

| Tool | Language scope | What it finds |
|---|---|---|
| **semgrep** (`--config=auto`) | 30+ languages | Security patterns, correctness bugs, anti-patterns |
| **bandit** | Python | Security issues (SQL injection, hardcoded secrets, unsafe calls) |
| **ruff** | Python | Code quality, style errors, security rules (S* codes via ruff-bandit) |

### CLI — inside the container (recommended)

```bash
# Run against a mounted target
docker compose exec portal bash -c \
  "STATE_DIR=/data/audits/manual-sast \
   bash /scripts/local-sast.sh /data/audits/repos/myapp"

# View the raw JSON results
docker compose exec portal cat /data/audits/manual-sast/semgrep.json | python3 -m json.tool
docker compose exec portal cat /data/audits/manual-sast/bandit.json  | python3 -m json.tool
docker compose exec portal cat /data/audits/manual-sast/ruff.json    | python3 -m json.tool
```

### CLI — on the host

Requires semgrep, bandit, and ruff installed in your local Python environment.

```bash
pip install semgrep bandit ruff

STATE_DIR=/tmp/sast-out ./scripts/local-sast.sh /path/to/repo

ls /tmp/sast-out/
# semgrep.json  bandit.json  ruff.json
```

### Via the API

```bash
# Start
curl -s -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{"backend":"local-sast","target":"myapp"}' | python3 -m json.tool

# Local SAST has no scope knobs — all tools run with defaults.
# Use env_vars to pass custom semgrep config if needed:
curl -s -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{
    "backend":  "local-sast",
    "target":   "myapp",
    "env_vars": {"SEMGREP_RULES": "p/security-audit"}
  }' | python3 -m json.tool
```

### Output files

| File | Tool | Format |
|---|---|---|
| `semgrep.json` | semgrep | `{"results": [...], "errors": [...]}` |
| `bandit.json` | bandit | `{"results": [...], "metrics": {...}}` |
| `ruff.json` | ruff | `[{"code":"E501","filename":"...","location":{"row":42},...}]` |

The portal's findings parser reads all three and normalises them into the same `Finding` schema used by Code Analysis and RepoLens, so they appear identically in the Audits History tab and Grafana panels.

---

## RepoLens (deep AI audit)

RepoLens is an external tool that runs up to 280 specialist AI lenses across 27 domains. It is **not bundled** — operators must install it separately.

> **Cost warning**: A full RepoLens audit can cost hundreds of dollars. Always set `--max-cost` or use `--domain`/`--focus` to scope the run.

### Installation

See [github.com/TheMorpheus407/RepoLens](https://github.com/TheMorpheus407/RepoLens) for install options. Once installed, set `REPOLENS_SCRIPT` to the binary path if it is not on `PATH`:

```bash
# docker-compose.yml portal service env:
REPOLENS_SCRIPT=/usr/local/bin/repolens.sh
```

### CLI — direct

```bash
# Scoped to security domain, local output only, $20 budget ceiling
repolens.sh \
  --project /path/to/repo \
  --agent claude \
  --local \
  --domain security \
  --max-cost 20 \
  --output-dir /tmp/repolens-out

# Single lens
repolens.sh --project . --local --focus injection --agent claude
```

### Via the API

```bash
curl -s -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{
    "backend": "repolens",
    "target":  "myapp",
    "agent":   "claude",
    "scope": {
      "domain":   "security",
      "max_cost": 20
    }
  }' | python3 -m json.tool
```

### RepoLens scope fields

| API scope field | RepoLens flag | Notes |
|---|---|---|
| `focus` | `--focus <lens-id>` | Single lens only |
| `domain` | `--domain <domain-id>` | One of 27 domains (e.g. `security`, `performance`) |
| `parallel` | `--parallel` | Enable parallel lens execution |
| `max_parallel` | `--max-parallel <N>` | 1–16 (clamped) |
| `max_cost` | `--max-cost <dollars>` | Hard budget ceiling; 1–200 (clamped) |
| `max_issues` | `--max-issues <N>` | Issue count limit; 1–1000 (clamped) |
| `dry_run` | `--dry-run` | Validate configuration without running |

Pass additional flags via `env_vars.REPOLENS_EXTRA_ARGS` (space-separated):

```json
{"env_vars": {"REPOLENS_EXTRA_ARGS": "--verbose --retry 2"}}
```

---

## Monthly Dependency Check

`scripts/cron/monthly-update-check.sh` checks three things:

1. **RepoLens** — latest GitHub release vs installed version
2. **strata-management** — commits behind upstream (`git fetch` + `rev-list`)
3. **k6-performance** — commits behind upstream

Exits `0` when everything is current; exits `1` (triggering a cron email) when updates are available. Logs to `logs/update-checks/YYYY-MM-DD.log`.

### Manual run

```bash
./scripts/cron/monthly-update-check.sh

# View logs
cat logs/update-checks/$(date +%Y-%m-%d).log
```

### Cron installation

```bash
crontab -e
```

Paste the contents of `scripts/cron/crontab.example`, or add the line manually:

```
MAILTO=gagneet@gmail.com
0 8 1 * *   /home/gagneet/k6-performance/scripts/cron/monthly-update-check.sh
```

This runs at 08:00 on the 1st of each month. Cron sends an email only when the script exits non-zero (i.e., when updates are found).

### Auto-pulling strata-management

`crontab.example` includes a commented-out entry that auto-pulls the strata-management repo. It is safe to enable because the container mounts it read-only (`:ro`), so a pull on the host cannot interrupt a running audit:

```
5 8 1 * *   git -C /home/gagneet/strata-management pull --ff-only --quiet
```

---

## API Reference

Base URL: `http://localhost:8000`

### k6 runs

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/scripts` | List available k6 scripts |
| `GET` | `/api/config` | Portal configuration (Grafana URL, etc.) |
| `POST` | `/api/runs` | Start a k6 run → returns `{run_id}` |
| `GET` | `/api/runs` | List runs (most recent first; `?limit=N`) |
| `GET` | `/api/runs/{run_id}` | Run detail + raw output |
| `DELETE` | `/api/runs/{run_id}/stop` | Terminate a running test |

### Audits

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/audit/backends` | Which backends are installed and available |
| `GET` | `/api/audit/targets` | Repos under `/data/audits/repos/` |
| `POST` | `/api/audits` | Start an audit → returns `{audit_id}` |
| `GET` | `/api/audits` | List audits (most recent first; `?limit=N`) |
| `GET` | `/api/audits/{audit_id}` | Audit detail + structured findings |
| `DELETE` | `/api/audits/{audit_id}/stop` | Abort a running audit |
| `POST` | `/api/audits/{audit_id}/link` | Manually link audit to a k6 run |
| `GET` | `/api/correlate/{commit_sha}` | All audits and runs for a commit SHA |

### WebSocket

| Path | Description |
|---|---|
| `ws://localhost:8000/ws/{run_id}` | Stream live k6 output (run_id is 8 hex chars) |
| `ws://localhost:8000/ws/{audit_id}` | Stream live audit output (audit_id is `a-` + 8 hex chars) |

### POST /api/audits — full payload

```json
{
  "backend":        "local-sast",
  "target":         "myapp",
  "agent":          "claude",
  "scope":          {},
  "env_vars":       {},
  "linked_run_id":  null
}
```

`backend` values: `"code"`, `"repolens"`, `"local-sast"`

`agent` values: `"claude"`, `"codex"`, `"opencode"`, `"opencode/<model>"`

### POST /api/audits/{id}/link — payload

```json
{"run_id": "a1b2c3d4"}
```

### curl one-liners

```bash
# Check which backends are ready
curl -s http://localhost:8000/api/audit/backends | python3 -m json.tool

# List audit targets
curl -s http://localhost:8000/api/audit/targets | python3 -m json.tool

# Get findings for a specific audit
curl -s http://localhost:8000/api/audits/<audit_id> | python3 -m json.tool

# Correlate by commit SHA
curl -s http://localhost:8000/api/correlate/abc123def456 | python3 -m json.tool

# Stop an audit
curl -s -X DELETE http://localhost:8000/api/audits/<audit_id>/stop
```

---

## Environment Variables

Set these in a `.env` file next to `docker-compose.yml`, or export before `make up`.

### Portal service

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required for `claude` agent CLI |
| `OPENAI_API_KEY` | — | Required for `codex` agent CLI |
| `INFLUXDB_URL` | `http://influxdb:8086/k6` | InfluxDB write endpoint (internal) |
| `GRAFANA_URL` | `http://localhost:3000` | Grafana base URL shown in the UI |
| `SCRIPTS_DIR` | `/scripts` | Primary k6 scripts directory |
| `EXTRA_SCRIPTS_DIRS` | — | Colon-separated extra script directories |
| `AUDIT_WORKSPACE` | `/data/audits` | Root for audit state and target repos |
| `RALPH_SCRIPT` | `/scripts/run-audit.sh` | Path to the Code Analysis entry-point script |
| `REPOLENS_SCRIPT` | `repolens.sh` | Path or name of the RepoLens binary |
| `LOCAL_SAST_SCRIPT` | `/scripts/local-sast.sh` | Path to the local-sast entry-point script |
| `AUDIT_MAX_SECONDS` | `7200` | Hard timeout for any audit (2 h default) |
| `AUDIT_DEFAULT_AGENT` | `claude` | Default agent used when none is specified |

### Code Analysis passthrough (set via `env_vars` in the API, or in `.env`)

See the [Code Analysis environment variables](#code-analysis-environment-variables) table above.

### InfluxDB service

| Variable | Default | Description |
|---|---|---|
| `INFLUXDB_DB` | `k6` | Database name |
| `INFLUXDB_ADMIN_USER` | — | Optional admin credentials |
| `INFLUXDB_ADMIN_PASSWORD` | — | Optional admin credentials |

---

## Makefile Commands

```bash
make up           # docker compose up -d --build  (build + start)
make down         # docker compose down
make build        # docker compose build --no-cache
make logs         # tail all service logs
make logs-portal  # tail portal service only
make status       # docker compose ps
make restart      # docker compose restart
make clean        # docker compose down -v --remove-orphans  ⚠ deletes volumes
make smoke        # k6 run smoke-test.js against InfluxDB (requires local k6)
```

---

## Docker Operations

```bash
# Rebuild portal image after editing app/ or requirements.txt
docker compose build portal && docker compose up -d portal

# Rebuild with Claude Code baked into the image
docker compose build --build-arg INSTALL_CLAUDE_CODE=1 portal

# Open a shell in the portal container
docker compose exec portal bash

# Clone an audit target into the workspace
docker compose exec portal bash -c \
  'git clone https://github.com/your/repo /data/audits/repos/myapp'

# Check InfluxDB measurements
docker compose exec influxdb influx -database k6 -execute 'SHOW MEASUREMENTS'

# Inspect audit state for a specific run
docker compose exec portal ls /data/audits/<audit_id>/
docker compose exec portal cat /data/audits/<audit_id>/FINAL_REPORT.md
```

---

## Grafana Dashboards

Grafana is available at http://localhost:3100 (admin/admin).

The dashboard UID is `k6-perf`. Template variables at the top:

| Variable | Description |
|---|---|
| `$testid` | Filter metrics to a specific k6 run |
| `$baseline` | Comparison run for side-by-side panels |
| `$audit_id` | Filter audit findings to a specific audit |

### k6 panels

Standard k6 metrics: `http_req_duration`, `http_reqs`, `vus`, `checks`, `data_sent`, `data_received`, `http_req_failed`, and derived percentiles.

### Audit panels (bottom section)

| Panel | Measurement | Description |
|---|---|---|
| Findings by severity | `audit_finding` | High / medium / low / info counts over time |
| Findings by type | `audit_finding` | security / bug / performance / architecture breakdown |
| Audit summary | `audit_summary` | Total findings, files scanned, iterations |
| Commit correlation | `audit_summary` + `http_req_duration` | Overlay audit severity on perf p95 by commit SHA |

Modifying the dashboard: edit `grafana/dashboards/k6-dashboard.json`. Grafana polls this file every 30 s (configured in `grafana/provisioning/dashboards/dashboards.yml`) — no restart required.

---

## Troubleshooting

**`local-sast` shows 0 findings**
The tools ran but found nothing, or the image was not rebuilt after adding `semgrep`/`bandit`/`ruff` to `requirements.txt`. Rebuild: `docker compose build portal`. Check availability: `curl -s http://localhost:8000/api/audit/backends`.

**`"backend binary not found: claude"`**
No agent CLI in the portal container. Rebuild with `--build-arg INSTALL_CLAUDE_CODE=1`, or install manually:
```bash
docker compose exec portal bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
```

**`"audit target not found"`**
The target resolves relative to `/data/audits/repos/` inside the container, not the host filesystem. Confirm:
```bash
docker compose exec portal ls /data/audits/repos/
```

**Audit finishes with 0 findings (Code Analysis)**
Check the raw output in the audit detail page. Common causes: (1) AI_CMD errored silently, (2) the prompt template didn't match the parser pattern. The last 8 KB of output is stored in `audits.output`.

**Grafana audit panels empty**
Confirm audit data landed in InfluxDB:
```bash
docker compose exec influxdb influx -database k6 \
  -execute 'SHOW MEASUREMENTS'
# Should list audit_summary and audit_finding
```
If missing, check the portal logs for `influx_writer` errors: `make logs-portal`.

**RepoLens cost overrun**
Always set `max_cost` in the scope, or use `--domain` or `--focus` to limit the run. The portal clamps `max_cost` to $200 maximum, but your actual spend depends on your API pricing tier.

**Monthly check can't reach GitHub API**
The script uses `curl` to hit `api.github.com`. If your host is behind a proxy, export `https_proxy` before running the script, or add `--proxy` to the curl command in `scripts/cron/monthly-update-check.sh`.

**strata-management `git fetch` fails in the cron job**
The cron environment may not have SSH keys loaded. Use HTTPS remotes, or add an `ssh-agent` invocation to the cron entry. Check `logs/update-checks/<date>.log` for the exact error.
