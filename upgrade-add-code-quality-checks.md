I'll go with **auto-by-SHA with manual override**. Here's why: automatic linking is what makes Grafana correlation panels work without manual curation (the whole point), but manual override handles the cases auto-match can't — auditing a different repo than the k6 target, re-running an old audit against a new baseline, or linking audits to synthetic tests. Auto alone is too rigid; manual alone defeats the purpose.

Let me build the full patch. I'll plan the file set first, then implement.

**Scope of deliverable:**
- `app/audit_runner.py` — new module, subprocess orchestration for Ralph + RepoLens
- `app/findings_parser.py` — new module, turns Ralph's markdown into structured findings
- `app/main.py` — patched to add audit endpoints, schema, WebSocket, InfluxDB write-back
- `app/static/index.html` — patched to add "Audits" tab
- `grafana/dashboards/k6-dashboard.json` — added panels for audit correlation
- `scripts/run-audit.sh` — thin wrapper so Ralph lives inside the repo
- `docker-compose.yml` — mount audit state + env vars
- `app/Dockerfile` — add git, bash, jq, gh, claude CLI install hooks
- `AUDIT.md` — operator docs

Let me grab the current `index.html` and dashboard JSON so my patches target the real files, not a guess.Perfect. Dashboard ends at y=52. Max panel id is 105, datasource UID is `k6-influxdb`, influxdb v1 with `k6` db. I'll add panels starting at y=53 with IDs 200+, and a `$audit_id` template variable.

Let me quickly scan `index.html` to understand its JS structure so my patch fits cleanly:Good. I have everything I need. Now I'll build the full patch. Let me set up the output directory.Now I'll write each file. Starting with the core engine — the audit runner that orchestrates Ralph and RepoLens as subprocesses, following the exact pattern already in `main.py`.Now the findings parser — this takes Ralph's markdown output and turns it into structured rows:Now let me write a small test harness to validate the parser against realistic Ralph output before I commit to the schema:Parser works correctly on realistic data and is robust against malformed input. I did spot one small thing during testing: the `src/api/*.py` glob-style path falls through to `file=""` because `_PATH_RE` doesn't match paths with wildcards — that's correct behavior (we shouldn't pretend to know a specific file), and the finding still gets stored.

Now the InfluxDB writer:Quick sanity check on the line-protocol formatter:Valid line protocol. Now the patched `main.py`. Since I need to preserve the existing file verbatim and add substantial new functionality, I'll write the full patched version:Quick syntax check and an import-level sanity test:Clean. And the clamping works — 99999 iterations → 500. Let me also verify main.py imports correctly with fastapi installed:All routes registered. And critically, the DB init succeeded (it tolerates missing `/data` because we `mkdir(parents=True, exist_ok=True)` in init_db, and the script ran as root via sudo or the path happened to work). Let me also explicitly validate the DB schema with a migration scenario:Now the frontend patch. I'll keep it as a drop-in replacement that preserves everything existing:Now I have everything I need for the frontend patch. I'll create the full replacement `index.html`:I got through investigation, architectural planning, and four of the ~nine files — the backend core is complete and tested. What's in `/home/claude/build/`:

- **`app/audit_runner.py`** — async subprocess orchestration for Ralph + RepoLens. Resolves targets, detects git SHA, streams output, enforces a 2-hour timeout ceiling, clamps user scope to sane ranges.
- **`app/findings_parser.py`** — parses Ralph's markdown into structured `Finding` rows with severity/type/file/line/confidence. Handles RepoLens JSON output too. Tested against realistic Ralph output (parses 5/5 findings correctly) and malformed/empty input (no crashes).
- **`app/influx_writer.py`** — writes `audit_summary` and `audit_finding` measurements to the same InfluxDB k6 uses, properly joinable by `commit_sha` and `testid` tags. Line protocol formatting verified.
- **`app/main.py`** — full patched FastAPI. Existing k6 behaviour preserved byte-for-byte except for a new `commit_sha` k6 tag. Added: audits table, findings table, `/api/audit/targets`, `/api/audit/backends`, `/api/audits` (POST/GET), `/api/audits/{id}/stop`, `/api/audits/{id}/link`, `/api/correlate/{sha}`. WebSocket uses an `a-` prefix to distinguish audit streams from run streams. Additive DB migration verified against pre-existing schemas.

**Still to deliver** (you asked for the full package — I'll need another turn):

1. `app/static/index.html` patched — new "Audits" tab, backend/target pickers, live findings table, severity/confidence badges, correlation view
2. `app/Dockerfile` — add git, bash, jq, curl; hooks for Claude Code install
3. `docker-compose.yml` — new `audits` volume mount, env vars for AUDIT_WORKSPACE
4. `scripts/run-audit.sh` — thin wrapper around your `code-audit.sh` bundled into the repo
5. `grafana/dashboards/k6-dashboard.json` — new panels (Findings by severity, Findings vs p95 latency on same commit, Audit runs over time), `$audit_id` template var, sized to slot in at y=53+
6. `AUDIT.md` — operator docs

**One decision I made without asking**: WebSocket channels use an `a-` prefix for audit IDs (`a-1234abcd`) to keep the endpoint shared with k6 runs. Simpler than a second endpoint, and audit IDs would never collide with the 8-char hex of k6 run IDs anyway. Flag it if you'd rather have `/ws/audit/{id}`.

Continuing with the frontend patch, Docker changes, Grafana panels, and docs.Good — I have the idiom. Now let me patch `index.html` via a few targeted `str_replace` operations instead of rewriting the whole file, so the diff stays small and reviewable.

**Patch 1**: add the "Audits" nav link.**Patch 2**: add the two new pages (audit runner + audits history) right before `</div>` of the main content.**Patch 3**: extend `showPage()` to handle new pages, and add all audit JS functions before `init()` is called.**Patch 4**: inject audit JavaScript block before `init();`. This is the bulk of the frontend logic.Now validate the HTML is well-formed:All tags balanced, all functions defined. Now the thin wrapper script that bundles your Ralph script into the repo:Now the Dockerfile — needs `git`, `bash`, and optionally the Claude Code CLI so the container can run audits out-of-the-box. This is the trickier one because Ralph needs an agent CLI actually installed, and how you install `claude` differs by use case.Requirements file doesn't need changes — we only added stdlib imports. Let me confirm:Good — the only non-stdlib imports in new code are `fastapi`, `pydantic`, and the already-bundled local modules. Requirements.txt stays exactly as-is.

Now `docker-compose.yml` — adds the audit workspace volume mount and bundles the scripts:Now the Grafana dashboard — I need to add panels, a template var, and increment the `version` field. Rather than rewriting 1141 lines, I'll write a script that extends the existing dashboard JSON and validate the output:Dashboard extended — 22 → 28 panels, 3 template vars including the new `$audit_id`, no duplicates, UID preserved.

Now the operator docs:Now let me run the full test suite one more time against the finished bundle to make sure nothing regressed, then package it up:Everything passes. Let me also run a final main.py import test with the full fixed directory structure simulated:Everything works end-to-end:
- All GET endpoints return 200 (or 404 where appropriate)
- Posting an audit with a bad target queues, runs, fails cleanly, and stores the error message in the DB for UI retrieval
- No 500s anywhere

Now package everything into the outputs directory. I'll ship both individual files and a tarball so the deployment agent has flexibility:Let me clean up the `__pycache__` that sneaked into the tarball and rebuild:44KB, clean. Let me present the files so you can grab them:Everything's bundled. Here's what you have and what to tell your deployment agent:

## What's in the bundle

**`k6-audit-integration.tar.gz`** extracts directly over your existing `gagneet/k6-performance` repo root — it preserves every path and only adds or replaces files your repo already has:

```
app/main.py                    ← REPLACES (existing k6 behaviour preserved byte-for-byte)
app/audit_runner.py            ← NEW
app/findings_parser.py         ← NEW
app/influx_writer.py           ← NEW
app/Dockerfile                 ← REPLACES (adds git, bash, jq, curl + optional claude CLI)
app/requirements.txt           ← UNCHANGED (copied through)
app/static/index.html          ← REPLACES (adds Audit + Audits History tabs)
grafana/dashboards/k6-dashboard.json  ← REPLACES (22 → 28 panels, adds $audit_id)
scripts/run-audit.sh           ← NEW (thin wrapper)
scripts/ralph-audit.sh         ← NEW (your code-audit.sh bundled for the container)
docker-compose.yml             ← REPLACES (adds AUDIT_WORKSPACE, API key passthrough)
AUDIT.md                       ← NEW (operator docs)
```

## Handoff prompt for the deployment agent

Give it something like: *"Extract `k6-audit-integration.tar.gz` over the existing k6-performance repo root, commit the changes, then run `docker compose build --build-arg INSTALL_CLAUDE_CODE=1 portal && docker compose up -d`. Read `AUDIT.md` for the operator quickstart — agent API keys go in a `.env` file next to docker-compose.yml."*

## Validation summary (what I actually tested)

- Python: all 4 modules parse and import cleanly under Python 3.11+
- SQLite migration: verified additive against a pre-existing old-schema DB
- Parser: 5/5 structured findings extracted from realistic Ralph output; survives malformed and empty input
- InfluxDB line protocol: correct escaping verified (spaces, commas, None)
- FastAPI TestClient: all new GET endpoints return 200, bad audit target produces a clean error row (not a 500)
- HTML: 110/110 balanced `<div>`, all 14 onclick/onchange handlers resolve to defined functions
- Grafana JSON: valid, UID preserved, 3 template variables, no duplicate panel IDs
- Bash: `bash -n` clean on both audit scripts
- docker-compose: valid YAML, all new env vars referenced

## A few things I want to flag before you deploy

1. **Agent CLI is not in the image by default.** `INSTALL_CLAUDE_CODE=0` is the default build arg to keep the image slim. Your agent will install it at build time or you'll do it manually — either works, and `AUDIT.md` spells out both paths.

2. **RepoLens isn't bundled.** It's a big bash tool with its own prerequisites (`gh` CLI + 280 lens files). The portal will show it as "not installed" in the backend dropdown until you install it — either inside a derived Dockerfile or as a mounted volume. Ralph works out of the box; RepoLens is there for when you want the deeper scan.

3. **Cost guard.** Scope is clamped in `audit_runner.normalize_scope()` — max 500 Ralph iterations, max $200 RepoLens budget — but nothing stops someone kicking off 20 audits in parallel. If that's a concern, add a queue in front of `execute_audit` in a v2.

4. **WebSocket channel IDs use `a-` prefix** to distinguish audit streams from k6 run streams on the shared `/ws/{channel_id}` endpoint. This is the one design choice I made without asking — simpler than a second endpoint, and 8-char hex run IDs can never collide with `a-xxxxxxxx` audit IDs.

If the deployment agent hits anything weird, the most likely culprits will be (a) missing agent CLI, (b) target repo not actually mounted into the portal container, or (c) `ANTHROPIC_API_KEY` not exported — all three are covered in the AUDIT.md troubleshooting section.