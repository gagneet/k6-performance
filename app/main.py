import asyncio
import json
import os
import re
import sqlite3
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, BackgroundTasks, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# Audit modules (new)
import audit_runner
import findings_parser
import influx_writer

app = FastAPI(title="k6 Performance Portal")

SCRIPTS_DIR = Path(os.getenv("SCRIPTS_DIR", "/scripts"))
# Optional extra script directories (colon-separated), e.g. /strata-scripts
_extra = os.getenv("EXTRA_SCRIPTS_DIRS", "")
EXTRA_SCRIPTS_DIRS: list[Path] = [Path(d) for d in _extra.split(":") if d.strip()]
DB_PATH = Path("/data/runs.db")
INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://localhost:8086/k6")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://localhost:3000")

# Audit state lives in /data/audits/<audit_id>/
AUDIT_ROOT = Path(os.getenv("AUDIT_WORKSPACE", "/data/audits"))

# audit_ids are "a-" + 8 hex chars; run_ids are 8 hex chars with no dash.
# uuid4()[:8] can never produce a "-" so the prefix is unambiguous, but we
# require the full pattern so a bare "a-" channel can't slip through.
_AUDIT_CHANNEL_RE = re.compile(r'^a-[0-9a-f]{8}$')

# run_id -> asyncio.subprocess.Process
active_runs: dict[str, asyncio.subprocess.Process] = {}
# audit_id -> asyncio.subprocess.Process
active_audits: dict[str, asyncio.subprocess.Process] = {}
# run_id OR audit_id -> list of connected websockets (shared namespace is fine;
# IDs don't collide — run_ids are 8 chars, audit_ids are "a-" prefixed)
ws_connections: dict[str, list[WebSocket]] = {}


def get_db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    AUDIT_ROOT.mkdir(parents=True, exist_ok=True)
    conn = get_db()
    # Existing k6 runs table — preserved as-is, plus one new nullable column
    # so k6 runs can record the git SHA they were executed against.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id          TEXT PRIMARY KEY,
            script      TEXT NOT NULL,
            status      TEXT NOT NULL DEFAULT 'running',
            vus         INTEGER,
            duration    TEXT,
            target_url  TEXT,
            extra_tags  TEXT,
            started_at  TEXT,
            finished_at TEXT,
            exit_code   INTEGER,
            output      TEXT
        )
    """)
    # Additive migration: commit_sha on existing runs. Safe on old DBs.
    cols = {r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()}
    if "commit_sha" not in cols:
        conn.execute("ALTER TABLE runs ADD COLUMN commit_sha TEXT")

    conn.execute("""
        CREATE TABLE IF NOT EXISTS audits (
            id            TEXT PRIMARY KEY,
            backend       TEXT NOT NULL,        -- 'ralph' | 'repolens'
            target        TEXT NOT NULL,        -- resolved absolute path
            target_name   TEXT,                 -- display name (basename)
            agent         TEXT,                 -- claude | codex | opencode/...
            scope         TEXT,                 -- JSON blob
            status        TEXT NOT NULL DEFAULT 'running',
            commit_sha    TEXT,                 -- git HEAD at audit time
            linked_run_id TEXT,                 -- manual link to a k6 run
            started_at    TEXT,
            finished_at   TEXT,
            exit_code     INTEGER,
            output        TEXT,                 -- last 8KB
            summary_json  TEXT                  -- AuditSummary as JSON
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS audit_findings (
            id                TEXT PRIMARY KEY,
            audit_id          TEXT NOT NULL,
            severity          TEXT NOT NULL,    -- high | medium | low | info
            finding_type      TEXT NOT NULL,
            file              TEXT,
            line_range        TEXT,
            message           TEXT,
            confidence        TEXT,
            source_section    TEXT,
            parse_confidence  REAL,
            FOREIGN KEY (audit_id) REFERENCES audits(id) ON DELETE CASCADE
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_findings_audit ON audit_findings(audit_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_findings_severity ON audit_findings(severity)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_audits_commit ON audits(commit_sha)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_runs_commit ON runs(commit_sha)")
    conn.commit()
    conn.close()


init_db()


class RunRequest(BaseModel):
    script: str
    vus: int = 10
    duration: str = "30s"
    target_url: Optional[str] = None
    extra_tags: dict = {}
    env_vars: dict = {}  # injected into k6 subprocess env
    # NEW: optional git SHA so k6 runs can correlate with audits on same commit.
    # The UI fills this in automatically when a local repo is being audited;
    # for remote targets, operators can pass it explicitly.
    commit_sha: Optional[str] = None


class AuditRequest(BaseModel):
    backend: str                       # 'ralph' | 'repolens'
    target: str                        # path or repo name under AUDIT_WORKSPACE/repos/
    agent: str = "claude"              # claude | codex | opencode | opencode/<model>
    scope: dict = {}                   # backend-specific knobs (see audit_runner.normalize_scope)
    env_vars: dict = {}                # passthrough env (e.g. ANTHROPIC_API_KEY)
    linked_run_id: Optional[str] = None  # manual link to a k6 run


# ── helpers (shared) ─────────────────────────────────────────────────────────

async def broadcast(channel_id: str, message: str):
    dead = []
    for ws in ws_connections.get(channel_id, []):
        try:
            await ws.send_text(message)
        except Exception:
            dead.append(ws)
    for ws in dead:
        ws_connections[channel_id].remove(ws)


def db_update_run(run_id: str, **kwargs):
    conn = get_db()
    sets = ", ".join(f"{k}=?" for k in kwargs)
    vals = list(kwargs.values()) + [run_id]
    conn.execute(f"UPDATE runs SET {sets} WHERE id=?", vals)
    conn.commit()
    conn.close()


def db_update_audit(audit_id: str, **kwargs):
    conn = get_db()
    sets = ", ".join(f"{k}=?" for k in kwargs)
    vals = list(kwargs.values()) + [audit_id]
    conn.execute(f"UPDATE audits SET {sets} WHERE id=?", vals)
    conn.commit()
    conn.close()


# ── k6 run execution (unchanged behaviour) ───────────────────────────────────

def _script_has_stages(script_path: Path) -> bool:
    try:
        content = script_path.read_text(errors="replace")
        return "stages" in content and "options" in content
    except OSError:
        return False


async def execute_run(run_id: str, req: RunRequest):
    script_path = _resolve_script(req.script) or (SCRIPTS_DIR / req.script)
    env = {**os.environ}
    if req.target_url:
        env["TARGET_URL"] = req.target_url
    for k, v in req.env_vars.items():
        env[k] = v

    cmd = [
        "k6", "run",
        f"--out=influxdb={INFLUXDB_URL}",
        f"--tag=testid={run_id}",
    ]
    # Tag with commit_sha so Grafana can join audits ↔ perf runs on same commit.
    if req.commit_sha:
        cmd.append(f"--tag=commit_sha={req.commit_sha}")

    if not _script_has_stages(script_path):
        cmd += [f"--vus={req.vus}", f"--duration={req.duration}"]

    for k, v in req.extra_tags.items():
        cmd.append(f"--tag={k}={v}")
    cmd.append(str(script_path))

    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
        )
        active_runs[run_id] = process

        output_lines: list[str] = []
        while True:
            raw = await process.stdout.readline()
            if not raw:
                break
            line = raw.decode(errors="replace")
            output_lines.append(line)
            await broadcast(run_id, line)

        await process.wait()
        exit_code = process.returncode
        status = "passed" if exit_code == 0 else "failed"
    except Exception as exc:
        exit_code = -1
        status = "error"
        output_lines = [str(exc)]
    finally:
        active_runs.pop(run_id, None)

    full_output = "".join(output_lines)
    db_update_run(
        run_id,
        status=status,
        exit_code=exit_code,
        finished_at=datetime.utcnow().isoformat(),
        output=full_output[-8000:],
    )
    await broadcast(run_id, f"\n__DONE__:{status}")


# ── audit execution (new) ────────────────────────────────────────────────────

async def execute_audit(audit_id: str, req: AuditRequest):
    """
    Run an audit end-to-end:
      1. resolve target + detect git SHA
      2. spawn backend subprocess (ralph or repolens)
      3. parse structured findings from state dir
      4. persist findings to SQLite
      5. push summary + per-finding points to InfluxDB
      6. auto-link to a k6 run on the same commit SHA if no manual link given
    """
    state_dir = AUDIT_ROOT / audit_id
    t_start = datetime.now(timezone.utc)

    try:
        target_path = audit_runner.resolve_target(req.target)
    except (FileNotFoundError, NotADirectoryError) as exc:
        db_update_audit(
            audit_id, status="error",
            finished_at=datetime.now(timezone.utc).isoformat(),
            exit_code=-1, output=str(exc),
        )
        await broadcast(audit_id, f"[error] {exc}\n__DONE__:error")
        return

    commit_sha = audit_runner.detect_git_sha(target_path)
    scope = audit_runner.normalize_scope(req.backend, req.scope)

    # Reflect resolved values back into the row before the run starts
    db_update_audit(
        audit_id,
        target=str(target_path),
        target_name=target_path.name,
        commit_sha=commit_sha,
        scope=audit_runner.scope_summary(req.backend, scope),
    )

    result = await audit_runner.run_audit(
        audit_id=audit_id,
        backend=req.backend,
        target=target_path,
        agent=req.agent,
        scope=scope,
        env_vars=req.env_vars,
        state_dir=state_dir,
        broadcast=broadcast,
        active_audits=active_audits,
    )

    # Parse structured findings regardless of exit code — partial data is
    # better than none, and Ralph often produces useful findings even on
    # non-zero exits (e.g. rate-limited mid-run).
    findings, summary = findings_parser.parse_audit_output(
        req.backend, state_dir, audit_id,
    )

    # Persist findings
    if findings:
        conn = get_db()
        conn.executemany(
            "INSERT INTO audit_findings "
            "(id, audit_id, severity, finding_type, file, line_range, message, "
            " confidence, source_section, parse_confidence) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            [
                (f.id, f.audit_id, f.severity, f.finding_type, f.file,
                 f.line_range, f.message, f.confidence, f.source_section,
                 f.parse_confidence)
                for f in findings
            ],
        )
        conn.commit()
        conn.close()

    # Auto-link to k6 run on same commit if no manual link provided
    linked_run_id = req.linked_run_id
    if not linked_run_id and commit_sha:
        conn = get_db()
        row = conn.execute(
            "SELECT id FROM runs WHERE commit_sha=? ORDER BY started_at DESC LIMIT 1",
            (commit_sha,),
        ).fetchone()
        conn.close()
        if row:
            linked_run_id = row["id"]

    duration_s = (datetime.now(timezone.utc) - t_start).total_seconds()

    # Push to InfluxDB (fire-and-forget; failures logged, don't affect audit status)
    influx_writer.write_audit_summary(
        INFLUXDB_URL,
        audit_id=audit_id,
        backend=req.backend,
        target=target_path.name,
        commit_sha=commit_sha,
        testid=linked_run_id,
        summary_dict=summary.to_dict(),
        duration_s=duration_s,
    )
    influx_writer.write_audit_findings(
        INFLUXDB_URL, audit_id=audit_id, findings=findings,
    )

    db_update_audit(
        audit_id,
        status=result["status"],
        exit_code=result["exit_code"],
        started_at=result["started_at"],
        finished_at=result["finished_at"],
        output=result["output"],
        linked_run_id=linked_run_id,
        summary_json=json.dumps(summary.to_dict()),
    )
    await broadcast(
        audit_id,
        f"\n[audit complete] total={summary.total} "
        f"high={summary.high} medium={summary.medium} low={summary.low}\n"
        f"__DONE__:{result['status']}"
    )


# ── API: k6 runs (existing, one addition) ────────────────────────────────────

@app.get("/api/config")
def get_config():
    return {"grafana_url": GRAFANA_URL}


def _scan_scripts(base: Path, prefix: str = "") -> list[dict]:
    if not base.exists():
        return []
    result = []
    for ext in ("*.js", "*.ts"):
        for f in sorted(base.glob(ext)):
            name = (prefix + "/" + f.name) if prefix else f.name
            result.append({"name": name, "path": str(f), "size": f.stat().st_size})
    return result


def _resolve_script(name: str) -> Path | None:
    """
    Resolve a script name (as returned by /api/scripts) to an absolute Path.
    Checks SCRIPTS_DIR first, then EXTRA_SCRIPTS_DIRS matched by their
    directory name prefix.  Returns None if not found in any location.
    """
    # Direct path under the primary scripts directory
    p = SCRIPTS_DIR / name
    if p.exists():
        return p
    # Extra dirs: name is "<dirbasename>/<filename>", strip prefix and look there
    for extra_dir in EXTRA_SCRIPTS_DIRS:
        dir_prefix = extra_dir.name + "/"
        if name.startswith(dir_prefix):
            p = extra_dir / name[len(dir_prefix):]
            if p.exists():
                return p
    return None


@app.get("/api/scripts")
def list_scripts():
    scripts = _scan_scripts(SCRIPTS_DIR)
    for extra_dir in EXTRA_SCRIPTS_DIRS:
        scripts.extend(_scan_scripts(extra_dir, prefix=extra_dir.name))
    return scripts


@app.post("/api/runs")
async def start_run(req: RunRequest, background_tasks: BackgroundTasks):
    script_path = _resolve_script(req.script)
    if not script_path:
        raise HTTPException(status_code=404, detail="Script not found")

    run_id = str(uuid.uuid4())[:8]
    conn = get_db()
    conn.execute(
        "INSERT INTO runs (id, script, status, vus, duration, target_url, "
        "extra_tags, commit_sha, started_at) VALUES (?,?,?,?,?,?,?,?,?)",
        (run_id, req.script, "running", req.vus, req.duration,
         req.target_url, json.dumps(req.extra_tags), req.commit_sha,
         datetime.utcnow().isoformat()),
    )
    conn.commit()
    conn.close()

    background_tasks.add_task(execute_run, run_id, req)
    return {"run_id": run_id, "status": "started"}


@app.get("/api/runs")
def list_runs(limit: int = 100):
    conn = get_db()
    rows = conn.execute(
        "SELECT id, script, status, vus, duration, target_url, commit_sha, "
        "started_at, finished_at, exit_code "
        "FROM runs ORDER BY started_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.get("/api/runs/{run_id}")
def get_run(run_id: str):
    conn = get_db()
    row = conn.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Run not found")
    return dict(row)


@app.delete("/api/runs/{run_id}/stop")
async def stop_run(run_id: str):
    proc = active_runs.get(run_id)
    if not proc:
        raise HTTPException(status_code=404, detail="Run not active")
    proc.terminate()
    db_update_run(run_id, status="aborted", finished_at=datetime.utcnow().isoformat())
    return {"status": "aborted"}


# ── API: audits (new) ────────────────────────────────────────────────────────

@app.get("/api/audit/targets")
def list_audit_targets():
    """
    Enumerate directories under AUDIT_WORKSPACE/repos/ so the UI can offer
    a picker instead of making users type paths. Adding a new target is
    an ops step (clone into the mounted volume).
    """
    repos_dir = AUDIT_ROOT / "repos"
    if not repos_dir.exists():
        return []
    targets = []
    for p in sorted(repos_dir.iterdir()):
        if not p.is_dir():
            continue
        sha = audit_runner.detect_git_sha(p)
        targets.append({
            "name": p.name,
            "path": str(p),
            "git": sha is not None,
            "commit_sha": sha,
        })
    return targets


@app.get("/api/audit/backends")
def list_audit_backends():
    """Which backends are actually installed on this host."""
    ralph_ok = audit_runner.RALPH_SCRIPT.exists()
    repolens_ok = False
    try:
        # shutil.which is cheap; if REPOLENS_SCRIPT is a bare name, check PATH
        import shutil
        repolens_ok = shutil.which(audit_runner.REPOLENS_SCRIPT) is not None \
            or Path(audit_runner.REPOLENS_SCRIPT).exists()
    except Exception:
        pass
    return {
        "ralph": {"available": ralph_ok, "path": str(audit_runner.RALPH_SCRIPT)},
        "repolens": {"available": repolens_ok, "path": audit_runner.REPOLENS_SCRIPT},
    }


@app.post("/api/audits")
async def start_audit(req: AuditRequest, background_tasks: BackgroundTasks):
    try:
        audit_runner.validate_backend(req.backend)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    audit_id = "a-" + str(uuid.uuid4())[:8]
    conn = get_db()
    conn.execute(
        "INSERT INTO audits (id, backend, target, agent, scope, status, "
        "linked_run_id, started_at) VALUES (?,?,?,?,?,?,?,?)",
        (audit_id, req.backend, req.target, req.agent,
         json.dumps(req.scope), "running", req.linked_run_id,
         datetime.utcnow().isoformat()),
    )
    conn.commit()
    conn.close()

    background_tasks.add_task(execute_audit, audit_id, req)
    return {"audit_id": audit_id, "status": "started"}


@app.get("/api/audits")
def list_audits(limit: int = 100):
    conn = get_db()
    rows = conn.execute(
        "SELECT id, backend, target_name, agent, status, commit_sha, "
        "linked_run_id, started_at, finished_at, exit_code, summary_json "
        "FROM audits ORDER BY started_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    results = []
    for r in rows:
        d = dict(r)
        try:
            d["summary"] = json.loads(d.pop("summary_json") or "{}")
        except json.JSONDecodeError:
            d["summary"] = {}
        results.append(d)
    return results


@app.get("/api/audits/{audit_id}")
def get_audit(audit_id: str):
    conn = get_db()
    row = conn.execute("SELECT * FROM audits WHERE id=?", (audit_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Audit not found")
    audit = dict(row)
    findings = conn.execute(
        "SELECT * FROM audit_findings WHERE audit_id=? "
        "ORDER BY CASE severity WHEN 'high' THEN 1 WHEN 'medium' THEN 2 "
        "  WHEN 'low' THEN 3 ELSE 4 END, file",
        (audit_id,),
    ).fetchall()
    conn.close()
    try:
        audit["summary"] = json.loads(audit.pop("summary_json") or "{}")
    except json.JSONDecodeError:
        audit["summary"] = {}
    audit["findings"] = [dict(f) for f in findings]
    return audit


@app.delete("/api/audits/{audit_id}/stop")
async def stop_audit(audit_id: str):
    proc = active_audits.get(audit_id)
    if not proc:
        raise HTTPException(status_code=404, detail="Audit not active")
    proc.terminate()
    db_update_audit(
        audit_id, status="aborted",
        finished_at=datetime.utcnow().isoformat(),
    )
    return {"status": "aborted"}


@app.post("/api/audits/{audit_id}/link")
async def link_audit_to_run(audit_id: str, payload: dict):
    """
    Manual override for the audit ↔ k6-run link. Use when auto-match by
    commit SHA is wrong or unavailable.
    """
    run_id = payload.get("run_id")
    if not run_id:
        raise HTTPException(status_code=400, detail="run_id required")

    conn = get_db()
    audit = conn.execute("SELECT id FROM audits WHERE id=?", (audit_id,)).fetchone()
    run = conn.execute("SELECT id FROM runs WHERE id=?", (run_id,)).fetchone()
    if not audit or not run:
        conn.close()
        raise HTTPException(status_code=404, detail="audit or run not found")
    conn.execute("UPDATE audits SET linked_run_id=? WHERE id=?", (run_id, audit_id))
    conn.commit()
    conn.close()
    return {"audit_id": audit_id, "linked_run_id": run_id}


@app.get("/api/correlate/{commit_sha}")
def correlate_by_commit(commit_sha: str):
    """
    Given a commit SHA, return the k6 runs and audits that ran against it.
    Used by the Grafana-adjacent view on the portal.
    """
    conn = get_db()
    runs = conn.execute(
        "SELECT id, script, status, started_at FROM runs WHERE commit_sha=? "
        "ORDER BY started_at DESC",
        (commit_sha,),
    ).fetchall()
    audits = conn.execute(
        "SELECT id, backend, target_name, status, started_at, summary_json "
        "FROM audits WHERE commit_sha=? ORDER BY started_at DESC",
        (commit_sha,),
    ).fetchall()
    conn.close()
    return {
        "commit_sha": commit_sha,
        "runs": [dict(r) for r in runs],
        "audits": [
            {**{k: v for k, v in dict(a).items() if k != "summary_json"},
             "summary": json.loads(a["summary_json"] or "{}")}
            for a in audits
        ],
    }


# ── WebSocket (shared between runs and audits) ───────────────────────────────

@app.websocket("/ws/{channel_id}")
async def ws_endpoint(websocket: WebSocket, channel_id: str):
    await websocket.accept()

    conn = get_db()
    if _AUDIT_CHANNEL_RE.fullmatch(channel_id):
        row = conn.execute(
            "SELECT status, output FROM audits WHERE id=?", (channel_id,)
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT status, output FROM runs WHERE id=?", (channel_id,)
        ).fetchone()
    conn.close()

    if row and row["status"] not in ("running",):
        if row["output"]:
            await websocket.send_text(row["output"])
        await websocket.send_text(f"\n__DONE__:{row['status']}")
        await websocket.close()
        return

    ws_connections.setdefault(channel_id, []).append(websocket)
    try:
        while True:
            await websocket.receive_text()
    except (WebSocketDisconnect, Exception):
        conns = ws_connections.get(channel_id, [])
        if websocket in conns:
            conns.remove(websocket)


# ── static files (must be last) ───────────────────────────────────────────────
app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
