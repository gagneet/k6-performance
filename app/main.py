import asyncio
import json
import os
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, BackgroundTasks, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(title="k6 Performance Portal")

SCRIPTS_DIR = Path(os.getenv("SCRIPTS_DIR", "/scripts"))
DB_PATH = Path("/data/runs.db")
INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://localhost:8086/k6")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://localhost:3000")

# run_id -> asyncio.subprocess.Process
active_runs: dict[str, asyncio.subprocess.Process] = {}
# run_id -> list of connected websockets
ws_connections: dict[str, list[WebSocket]] = {}


def get_db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = get_db()
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
    conn.commit()
    conn.close()


init_db()


class RunRequest(BaseModel):
    script: str
    vus: int = 10
    duration: str = "30s"
    target_url: Optional[str] = None
    extra_tags: dict = {}
    env_vars: dict = {}  # injected into k6 subprocess env (e.g. STRATA_EMAIL, STRATA_PASSWORD)


# ── helpers ──────────────────────────────────────────────────────────────────

async def broadcast(run_id: str, message: str):
    dead = []
    for ws in ws_connections.get(run_id, []):
        try:
            await ws.send_text(message)
        except Exception:
            dead.append(ws)
    for ws in dead:
        ws_connections[run_id].remove(ws)


def db_update_run(run_id: str, **kwargs):
    conn = get_db()
    sets = ", ".join(f"{k}=?" for k in kwargs)
    vals = list(kwargs.values()) + [run_id]
    conn.execute(f"UPDATE runs SET {sets} WHERE id=?", vals)
    conn.commit()
    conn.close()


# ── background task ──────────────────────────────────────────────────────────

def _script_has_stages(script_path: Path) -> bool:
    """Return True if the script defines options.stages — if so, --vus/--duration must not be passed."""
    try:
        content = script_path.read_text(errors="replace")
        return "stages" in content and "options" in content
    except OSError:
        return False


async def execute_run(run_id: str, req: RunRequest):
    script_path = SCRIPTS_DIR / req.script
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

    # --vus / --duration override options.stages in the script, breaking staged tests.
    # Only pass them when the script has no stages block.
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


# ── API ───────────────────────────────────────────────────────────────────────

@app.get("/api/config")
def get_config():
    return {"grafana_url": GRAFANA_URL}


@app.get("/api/scripts")
def list_scripts():
    if not SCRIPTS_DIR.exists():
        return []
    return [
        {"name": f.name, "size": f.stat().st_size}
        for f in sorted(SCRIPTS_DIR.glob("*.js"))
    ]


@app.post("/api/runs")
async def start_run(req: RunRequest, background_tasks: BackgroundTasks):
    script_path = SCRIPTS_DIR / req.script
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    run_id = str(uuid.uuid4())[:8]
    conn = get_db()
    conn.execute(
        "INSERT INTO runs (id, script, status, vus, duration, target_url, extra_tags, started_at) VALUES (?,?,?,?,?,?,?,?)",
        (run_id, req.script, "running", req.vus, req.duration,
         req.target_url, json.dumps(req.extra_tags), datetime.utcnow().isoformat()),
    )
    conn.commit()
    conn.close()

    background_tasks.add_task(execute_run, run_id, req)
    return {"run_id": run_id, "status": "started"}


@app.get("/api/runs")
def list_runs(limit: int = 100):
    conn = get_db()
    rows = conn.execute(
        "SELECT id, script, status, vus, duration, target_url, started_at, finished_at, exit_code "
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


@app.websocket("/ws/{run_id}")
async def ws_endpoint(websocket: WebSocket, run_id: str):
    await websocket.accept()
    # If run already finished, stream stored output then close
    conn = get_db()
    row = conn.execute("SELECT status, output FROM runs WHERE id=?", (run_id,)).fetchone()
    conn.close()
    if row and row["status"] not in ("running",):
        if row["output"]:
            await websocket.send_text(row["output"])
        await websocket.send_text(f"\n__DONE__:{row['status']}")
        await websocket.close()
        return

    ws_connections.setdefault(run_id, []).append(websocket)
    try:
        while True:
            await websocket.receive_text()
    except (WebSocketDisconnect, Exception):
        conns = ws_connections.get(run_id, [])
        if websocket in conns:
            conns.remove(websocket)


# ── static files (must be last) ───────────────────────────────────────────────
app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
