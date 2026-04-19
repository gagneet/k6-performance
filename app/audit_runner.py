"""
Audit runner — spawns code-audit.sh, repolens.sh, or local-sast.sh as async
subprocesses, streams output over WebSocket, persists structured findings to
SQLite, and writes summary metrics to InfluxDB.

Mirrors the execute_run() pattern in main.py:
  - asyncio.create_subprocess_exec (non-blocking)
  - line-by-line stdout broadcast to connected WebSockets
  - final state written to SQLite, last 8000 chars of output kept

Supported backends:
  code       — ./scripts/run-audit.sh (AI-driven; wraps code-audit.sh)
  repolens   — repolens.sh (AI-driven; expects binary on PATH or REPOLENS_SCRIPT)
  local-sast — ./scripts/local-sast.sh (zero-cost; semgrep + bandit + ruff)
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Awaitable

# ── configuration ───────────────────────────────────────────────────────────

# Where the portal writes audit state. Mounted as a Docker volume in compose.
AUDIT_WORKSPACE = Path(os.getenv("AUDIT_WORKSPACE", "/data/audits"))

# Path to CodeAnalysis script. Defaults to bundled scripts/run-audit.sh.
RALPH_SCRIPT = Path(os.getenv("RALPH_SCRIPT", "/scripts/run-audit.sh"))

# Path to repolens.sh entry point. Optional — if missing, repolens backend
# returns an error at start time rather than at import.
REPOLENS_SCRIPT = os.getenv("REPOLENS_SCRIPT", "repolens.sh")

# Path to local-sast.sh. Bundled in scripts/; no external install needed.
LOCAL_SAST_SCRIPT = Path(os.getenv("LOCAL_SAST_SCRIPT", "/scripts/local-sast.sh"))

# The agent CLI passed through to both backends. Both tools understand
# "claude" out of the box. Operators override per audit via env_vars.
DEFAULT_AGENT = os.getenv("AUDIT_DEFAULT_AGENT", "claude")

# Hard safety ceilings.
MAX_OUTPUT_CHARS_STORED = 8000      # matches k6 run output cap in main.py
MAX_AUDIT_SECONDS = int(os.getenv("AUDIT_MAX_SECONDS", "7200"))  # 2h default

# Broadcast callback type — main.py supplies its broadcast() function.
BroadcastFn = Callable[[str, str], Awaitable[None]]


# ── public API ──────────────────────────────────────────────────────────────

class AuditBackend:
    RALPH = "code"
    REPOLENS = "repolens"
    LOCAL_SAST = "local-sast"


def validate_backend(name: str) -> str:
    if name not in (AuditBackend.RALPH, AuditBackend.REPOLENS, AuditBackend.LOCAL_SAST):
        raise ValueError(f"unknown audit backend: {name!r}")
    return name


def resolve_target(target: str) -> Path:
    """
    Turn a user-supplied target into an absolute path inside the container.

    Accepted inputs:
      - absolute path  → used as-is (must exist)
      - relative path  → resolved against AUDIT_WORKSPACE/repos/
      - bare repo name → same as relative

    We do NOT clone git URLs here; the portal assumes you've mounted the
    target repo into the container (via docker-compose volume) or cloned
    it into AUDIT_WORKSPACE/repos/<name> ahead of time. This keeps the
    attack surface small — an audit is a read-over operation on code you
    already trust enough to mount.
    """
    p = Path(target).expanduser()
    if not p.is_absolute():
        p = AUDIT_WORKSPACE / "repos" / target
    if not p.exists():
        raise FileNotFoundError(f"audit target not found: {p}")
    if not p.is_dir():
        raise NotADirectoryError(f"audit target must be a directory: {p}")
    return p.resolve()


def detect_git_sha(repo: Path) -> str | None:
    """
    Return the HEAD commit SHA (short form) if the target is a git repo.
    Used as the join key between audit runs and k6 runs in Grafana.
    Returns None for non-git directories — the audit still runs, but
    auto-correlation is disabled.
    """
    if not (repo / ".git").exists():
        return None
    try:
        result = subprocess.run(
            # -c safe.directory=* suppresses the "dubious ownership" error git raises
            # when a bind-mounted repo is owned by a different UID than the container user.
            ["git", "-c", "safe.directory=*", "-C", str(repo),
             "rev-parse", "--short=12", "HEAD"],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return result.stdout.strip() or None
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return None


# ── subprocess orchestration ────────────────────────────────────────────────

async def run_audit(
    audit_id: str,
    backend: str,
    target: Path,
    agent: str,
    scope: dict[str, Any],
    env_vars: dict[str, str],
    state_dir: Path,
    broadcast: BroadcastFn,
    active_audits: dict[str, asyncio.subprocess.Process],
) -> dict[str, Any]:
    """
    Spawn the backend, stream output, return a result dict.

    Caller is responsible for SQLite row creation/update and the final
    broadcast of __DONE__. This function only:
      - builds the command
      - starts the subprocess (tracked in active_audits)
      - streams stdout line-by-line to broadcast()
      - enforces MAX_AUDIT_SECONDS
      - returns {exit_code, status, output, started_at, finished_at}

    Structured findings parsing happens after this function returns,
    in main.py, via findings_parser.parse_code_state() etc.
    """
    state_dir.mkdir(parents=True, exist_ok=True)
    cmd, env = _build_command(backend, target, agent, scope, env_vars, state_dir)

    started_at = datetime.now(timezone.utc).isoformat()
    output_lines: list[str] = []

    await broadcast(audit_id, f"[{backend}] starting audit on {target}\n")
    await broadcast(audit_id, f"[cmd] {' '.join(cmd)}\n\n")

    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
            cwd=str(target),
        )
        active_audits[audit_id] = process

        async def _stream_output() -> None:
            assert process.stdout is not None
            while True:
                raw = await process.stdout.readline()
                if not raw:
                    break
                line = raw.decode(errors="replace")
                output_lines.append(line)
                await broadcast(audit_id, line)

        try:
            await asyncio.wait_for(_stream_output(), timeout=MAX_AUDIT_SECONDS)
            await process.wait()
            exit_code = process.returncode or 0
            status = "passed" if exit_code == 0 else "failed"
        except asyncio.TimeoutError:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=10)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
            exit_code = -2
            status = "timeout"
            output_lines.append(f"\n[audit] aborted after {MAX_AUDIT_SECONDS}s timeout\n")
            await broadcast(audit_id, output_lines[-1])

    except FileNotFoundError as exc:
        exit_code = -1
        status = "error"
        output_lines = [f"backend binary not found: {exc}\n"]
        await broadcast(audit_id, output_lines[0])
    except Exception as exc:
        exit_code = -1
        status = "error"
        output_lines = [f"audit runner exception: {exc}\n"]
        await broadcast(audit_id, output_lines[0])
    finally:
        active_audits.pop(audit_id, None)

    finished_at = datetime.now(timezone.utc).isoformat()
    full_output = "".join(output_lines)

    return {
        "exit_code": exit_code,
        "status": status,
        "output": full_output[-MAX_OUTPUT_CHARS_STORED:],
        "started_at": started_at,
        "finished_at": finished_at,
    }


# ── command builders ────────────────────────────────────────────────────────

def _build_command(
    backend: str,
    target: Path,
    agent: str,
    scope: dict[str, Any],
    env_vars: dict[str, str],
    state_dir: Path,
) -> tuple[list[str], dict[str, str]]:
    """Return (argv, env) for the chosen backend."""
    env = {**os.environ, **{k: str(v) for k, v in env_vars.items()}}

    if backend == AuditBackend.RALPH:
        return _build_code_cmd(target, agent, scope, state_dir, env)
    if backend == AuditBackend.REPOLENS:
        return _build_repolens_cmd(target, agent, scope, state_dir, env)
    if backend == AuditBackend.LOCAL_SAST:
        return _build_local_sast_cmd(target, state_dir, env)
    raise ValueError(f"unknown backend: {backend}")


def _build_code_cmd(
    target: Path,
    agent: str,
    scope: dict[str, Any],
    state_dir: Path,
    env: dict[str, str],
) -> tuple[list[str], dict[str, str]]:
    """
    Wrap code-audit.sh. The bundled scripts/run-audit.sh takes the repo
    path as $1 and forwards configuration through env vars (MAX_BATCH_BYTES,
    AI_CMD, STATE_DIR, etc — see the original script's help text).
    """
    script = RALPH_SCRIPT
    if not script.exists():
        raise FileNotFoundError(f"code script missing at {script}")

    env["STATE_DIR"] = str(state_dir)

    # Map agent selection → AI_CMD override. Operators can still override
    # AI_CMD entirely via env_vars.
    if "AI_CMD" not in env:
        if agent == "claude":
            # Matches the script's own default, spelled out so audit logs are clear.
            env["AI_CMD"] = 'claude -p --model opus --effort max --tools "" --no-session-persistence'
        elif agent == "codex":
            env["AI_CMD"] = "codex exec --quiet"
        elif agent.startswith("opencode"):
            # Allow opencode/<model> style
            suffix = agent.split("/", 1)[1] if "/" in agent else ""
            env["AI_CMD"] = f"opencode run {suffix}".strip()
        else:
            env["AI_CMD"] = agent  # treat as raw command

    # Scope knobs
    if "max_batch_bytes" in scope:
        env["MAX_BATCH_BYTES"] = str(scope["max_batch_bytes"])
    if "max_iterations" in scope:
        env["MAX_ITERATIONS"] = str(scope["max_iterations"])
    if scope.get("extra_excludes"):
        env["EXTRA_EXCLUDES"] = scope["extra_excludes"]
    if scope.get("preview_only"):
        env["PREVIEW_ONLY"] = "1"

    cmd = ["bash", str(script), str(target)]
    return cmd, env


def _build_repolens_cmd(
    target: Path,
    agent: str,
    scope: dict[str, Any],
    state_dir: Path,
    env: dict[str, str],
) -> tuple[list[str], dict[str, str]]:
    """
    Wrap repolens.sh. RepoLens has its own flag surface — see its README.
    We expose the common knobs (focus, domain, parallel, max-cost) and
    let operators pass the rest through env_vars (REPOLENS_EXTRA_ARGS).
    """
    binary = shutil.which(REPOLENS_SCRIPT) or REPOLENS_SCRIPT
    if not Path(binary).exists() and not shutil.which(REPOLENS_SCRIPT):
        raise FileNotFoundError(
            f"repolens not found (looked for {REPOLENS_SCRIPT}). "
            "Install from https://github.com/TheMorpheus407/RepoLens "
            "or set REPOLENS_SCRIPT to an absolute path."
        )

    cmd = [binary, "--project", str(target), "--agent", agent, "--local"]

    if focus := scope.get("focus"):
        cmd += ["--focus", str(focus)]
    if domain := scope.get("domain"):
        cmd += ["--domain", str(domain)]
    if scope.get("parallel"):
        cmd += ["--parallel"]
        if mp := scope.get("max_parallel"):
            cmd += ["--max-parallel", str(mp)]
    if cost := scope.get("max_cost"):
        cmd += ["--max-cost", str(cost)]
    if issues := scope.get("max_issues"):
        cmd += ["--max-issues", str(issues)]
    if scope.get("dry_run"):
        cmd += ["--dry-run"]

    # Passthrough for operators who want flags we haven't modelled.
    if extra := env.get("REPOLENS_EXTRA_ARGS"):
        cmd += extra.split()

    # RepoLens writes its output under the project by default. Point it at
    # state_dir so portal-managed audits don't scatter files into the repo.
    env["REPOLENS_OUTPUT_DIR"] = str(state_dir)

    return cmd, env


def _build_local_sast_cmd(
    target: Path,
    state_dir: Path,
    env: dict[str, str],
) -> tuple[list[str], dict[str, str]]:
    """
    Wrap local-sast.sh. Runs semgrep + bandit + ruff with no AI calls —
    zero external cost. Results land in state_dir as JSON files.
    """
    if not LOCAL_SAST_SCRIPT.exists():
        raise FileNotFoundError(f"local-sast script missing at {LOCAL_SAST_SCRIPT}")
    env["STATE_DIR"] = str(state_dir)
    cmd = ["bash", str(LOCAL_SAST_SCRIPT), str(target)]
    return cmd, env


# ── scope validation ────────────────────────────────────────────────────────

def normalize_scope(backend: str, raw_scope: dict[str, Any] | None) -> dict[str, Any]:
    """
    Clamp user-supplied scope to sane ranges. Prevents a 500 VU of audit
    runs: MAX_ITERATIONS=10000 scope dict kicking off a runaway spend.
    """
    scope = dict(raw_scope or {})

    if backend == AuditBackend.RALPH:
        if "max_batch_bytes" in scope:
            scope["max_batch_bytes"] = max(10_000, min(int(scope["max_batch_bytes"]), 500_000))
        if "max_iterations" in scope:
            scope["max_iterations"] = max(1, min(int(scope["max_iterations"]), 500))
    elif backend == AuditBackend.REPOLENS:
        if "max_parallel" in scope:
            scope["max_parallel"] = max(1, min(int(scope["max_parallel"]), 16))
        if "max_issues" in scope:
            scope["max_issues"] = max(1, min(int(scope["max_issues"]), 1000))
        if "max_cost" in scope:
            # dollars; default budget cap at $200
            scope["max_cost"] = max(1, min(float(scope["max_cost"]), 200))
    # local-sast: no scope knobs — tools run with defaults

    return scope


def scope_summary(backend: str, scope: dict[str, Any]) -> str:
    """Short human-readable summary stored alongside the audit row."""
    return json.dumps({"backend": backend, **scope}, sort_keys=True, default=str)
