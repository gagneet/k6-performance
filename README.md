# k6 Performance Portal

A self-hosted portal for running k6 load tests and AI-powered code audits, with live streaming output, run history, and Grafana dashboards.

## Services

| Service | URL | Role |
|---|---|---|
| Portal | http://localhost:8000 | UI + REST API + WebSocket |
| Grafana | http://localhost:3100 | Dashboards (admin/admin) |
| InfluxDB | http://localhost:8086 | Metrics storage (db=`k6`) |

## Quick start

```bash
make up          # build images and start all three services
```

Open http://localhost:8000. From there you can run k6 scripts, start code audits, and view history.

```bash
make down        # stop
make logs        # tail all logs
make clean       # stop + delete volumes (destructive)
```

---

## Running k6 tests

### Via the UI

1. Click **Run Test** in the nav.
2. Pick a script from the dropdown (scripts in `scripts/*.js`).
3. Set VUs, duration, and target URL, then click **▶ Run**.
4. Output streams live. A Grafana link appears on completion.

### Via the CLI (direct k6)

```bash
# Requires k6 installed locally
k6 run --vus 10 --duration 30s \
       --out influxdb=http://localhost:8086/k6 \
       -e TARGET_URL=https://example.com \
       scripts/smoke-test.js
```

Available scripts: `smoke-test.js`, `load-test.js`, `stress-test.js`, `spike-test.js`, `soak-test.js`

### Via the API

```bash
curl -X POST http://localhost:8000/api/runs \
  -H 'Content-Type: application/json' \
  -d '{"script":"smoke-test.js","vus":10,"duration":"30s","target_url":"https://example.com"}'
```

---

## Running code audits

Three backends are available — choose based on cost and depth:

| Backend | Cost | What it does |
|---|---|---|
| `local-sast` | Free | semgrep + bandit + ruff — no AI, no API calls |
| `code` | Low–moderate | AI-driven deep audit (requires Claude/Codex API key) |
| `repolens` | High ($$$) | Multi-lens AI audit with up to 280 specialist lenses |

### Via the UI

1. Click **Audit** in the nav.
2. Pick a target repo from the dropdown.
3. Choose a backend and click **▶ Run Audit**.

### Via the CLI — Local SAST (zero cost)

```bash
# Inside the portal container (tools pre-installed)
docker compose exec portal bash -c \
  "STATE_DIR=/data/audits/manual bash /scripts/local-sast.sh /data/audits/repos/myapp"

# On the host (requires: pip install semgrep bandit ruff)
STATE_DIR=/tmp/sast-out ./scripts/local-sast.sh /path/to/repo
ls /tmp/sast-out/   # semgrep.json, bandit.json, ruff.json
```

### Via the CLI — Code Analysis (AI)

```bash
# Requires claude CLI and ANTHROPIC_API_KEY
./scripts/code-audit.sh /path/to/repo

# With options
MAX_BATCH_BYTES=30000 MAX_ITERATIONS=10 \
VERIFY_CMD='pytest -q' \
  ./scripts/code-audit.sh /path/to/repo

# v2: audit only files changed since main (fast PR review)
DIFF_ONLY=1 BASE_REF=main ./scripts/code-audit.sh /path/to/repo

# v2: preview cost before spending anything
COST_ESTIMATE=1 CONFIRM_COST=1 ./scripts/code-audit.sh /path/to/repo

# v2: run semgrep/bandit/ruff before AI loop and inject as context
STATIC_ANALYSIS=1 ./scripts/code-audit.sh /path/to/repo

# v2: review recently-changed files first
CHURN_SORT=1 CHURN_DAYS=14 ./scripts/code-audit.sh /path/to/repo

# Inside the container
docker compose exec portal bash /scripts/run-audit.sh /data/audits/repos/myapp
```

See all options: `./scripts/code-audit.sh --help`

### Via the API

```bash
# Local SAST
curl -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{"backend":"local-sast","target":"myapp"}'

# Code Analysis with scoping
curl -X POST http://localhost:8000/api/audits \
  -H 'Content-Type: application/json' \
  -d '{"backend":"code","target":"myapp","agent":"claude","scope":{"max_iterations":20}}'
```

---

## Monthly dependency check

```bash
# Run manually
./scripts/cron/monthly-update-check.sh

# Install as a monthly cron job
crontab -e   # then paste from scripts/cron/crontab.example
```

Checks: RepoLens latest GitHub release, strata-management commits behind upstream, this repo's upstream commits.

---

## Adding a k6 script

Drop a `.js` file into `scripts/` — it appears in the portal immediately (directory is scanned live, no restart needed).

---

## Tests

```bash
pytest tests/
```

74 pytest tests covering `findings_parser.py` (severity coercion, markdown and JSON parsing, SAST backends) and `tests/test_awk_extractor.py` (validates that the awk-based `extract_findings_json` in `code-audit.sh` produces output field-by-field identical to the Python parser). All tests are idempotent and leave no filesystem state.

---

## Detailed reference

- **[USAGE.md](USAGE.md)** — complete guide: all CLI options, all env vars, all API endpoints, UI walkthrough, Grafana setup, cron configuration
- **[AUDIT.md](AUDIT.md)** — audit feature architecture, backend details, correlation mechanics, security notes
- **[CHANGELOG.md](CHANGELOG.md)** — full history of changes
