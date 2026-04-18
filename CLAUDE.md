# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Three Docker services managed via `docker-compose.yml`:

| Service | Image | Host Port | Role |
|---|---|---|---|
| `portal` | built from `app/` | 8000 | FastAPI API + serves the SPA |
| `grafana` | `grafana/grafana-oss` | **3100** (not 3000 — already in use) | Dashboards |
| `influxdb` | `influxdb:1.8` | 8086 | Metrics storage (db=`k6`) |

## Common commands

```bash
make up          # build + start all three services
make down        # stop
make logs        # tail all logs
make logs-portal # tail portal only
make clean       # stop + delete volumes (destructive)

# Rebuild portal image after editing app/
docker compose build portal && docker compose up -d portal
```

Portal API is available immediately at http://localhost:8000. Grafana at http://localhost:3100 (admin/admin).

## Architecture

### Data flow
`Browser → Portal UI (port 8000) → FastAPI → k6 subprocess → InfluxDB (port 8086) → Grafana (port 3100)`

Each test run is tagged `testid=<run_id>` in InfluxDB so the Grafana dashboard can filter per-run and compare across runs.

### Portal backend (`app/main.py`)
- Runs k6 as an **async subprocess** (`asyncio.create_subprocess_exec`) — never blocking.
- Active runs stored in `active_runs: dict[str, asyncio.subprocess.Process]`.
- Live output streamed to browsers over **WebSocket** at `/ws/{run_id}`.
- Run history persisted in **SQLite** at `/data/runs.db` (Docker volume `portal-data`).
- `/api/scripts` — scans `/scripts/*.js` inside the container (mounted from `./scripts/` on host).
- `/api/runs` POST — starts run, returns `run_id`; DELETE `/{id}/stop` — terminates process.
- Static SPA served last via `StaticFiles(directory="/app/static")`.

### Portal frontend (`app/static/index.html`)
Single self-contained HTML/CSS/JS file (no build step). Two views toggled in-page:
- **Run Test** — script picker, VU/duration/URL form, live ANSI terminal, deep-link to Grafana per run.
- **History** — table of all runs with Grafana time-scoped links.

### Grafana (`grafana/`)
- Datasource auto-provisioned from `grafana/provisioning/datasources/influxdb.yml` (points to `http://influxdb:8086`, db=`k6`).
- Dashboard auto-provisioned from `grafana/provisioning/dashboards/dashboards.yml`, loads `grafana/dashboards/k6-dashboard.json`.
- Dashboard UID is `k6-perf`. Template variables: `$testid` (current run) and `$baseline` (comparison run) — both populated from InfluxDB tag values.

### k6 scripts (`scripts/`)
All scripts read `__ENV.TARGET_URL` as the target (overridable from the portal UI). Pattern: `options` block sets stages/thresholds, default function does HTTP + `check()` + `sleep()`.

| Script | Shape |
|---|---|
| `smoke-test.js` | 1 VU, 30 s — quick validation |
| `load-test.js` | ramp-up → 10 VU steady → ramp-down |
| `stress-test.js` | staircase to 200 VU |
| `spike-test.js` | baseline → instant spike to 200 VU → recovery |
| `soak-test.js` | 20 VU for 4 h (memory-leak detection) |

## Adding a new k6 script
Drop a `.js` file into `scripts/` — it appears in the portal sidebar on next page load (no restart needed; the directory is scanned live).

## Modifying the Grafana dashboard
Edit `grafana/dashboards/k6-dashboard.json`. Grafana polls this file every 30 s (`updateIntervalSeconds: 30` in the provisioning YAML), so changes appear without restart. All InfluxDB queries use InfluxQL against the `k6` database; measurements match k6's built-in metric names (e.g. `http_req_duration`, `vus`, `http_reqs`).

## InfluxDB schema
- **Database:** `k6`
- **Measurements:** one per k6 metric (`http_req_duration`, `http_reqs`, `vus`, `checks`, `data_sent`, `data_received`, `http_req_blocked`, `http_req_connecting`, `http_req_tls_handshaking`, `http_req_sending`, `http_req_waiting`, `http_req_failed`, `http_req_receiving`, `iteration_duration`, `iterations`, `vus_max`)
- **Tag used for run isolation:** `testid` (8-char UUID prefix set via `--tag testid=<run_id>`)
