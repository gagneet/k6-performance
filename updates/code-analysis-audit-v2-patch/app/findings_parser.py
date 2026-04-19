"""
Findings parser — turns code-audit's markdown output into structured
rows we can store in SQLite and graph in Grafana.

Ralph's FINAL_REPORT.md follows a well-defined template from its prompt
(see PROMPT.md seeded in code-audit.sh). We parse:

  ## Priority Findings
  - [severity: high] [type: confirmed] src/auth.py:42 — JWT audience check missing. Why it matters. Confidence: high

into (severity, finding_type, file, line_range, message, confidence).

Design notes
------------
Ralph's output is AI-generated markdown, so the parser is permissive:
  - tolerates extra whitespace, emojis, missing sections
  - falls back to heuristic tagging when a line doesn't match the template
  - never raises on unparseable input — returns best-effort rows + a
    "parse_confidence" score per finding so the UI can flag shaky ones

RepoLens produces GitHub issues directly; for the --local path, it writes
JSON under REPOLENS_OUTPUT_DIR. We parse that JSON schema separately.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Iterable


SEVERITY_VALUES = {"high", "medium", "low", "info"}
TYPE_VALUES = {"confirmed", "likely-risk", "hypothesis", "bug", "security",
               "performance", "architecture"}
CONFIDENCE_VALUES = {"high", "medium", "low"}


@dataclass
class Finding:
    id: str
    audit_id: str
    severity: str          # high | medium | low | info
    finding_type: str      # confirmed | likely-risk | hypothesis | bug | ...
    file: str              # relative path, or "" if unknown
    line_range: str        # e.g. "42" or "42-58" or "" if unknown
    message: str           # the finding text (first sentence, trimmed)
    confidence: str        # high | medium | low
    source_section: str    # which markdown section it came from
    raw_line: str          # original line for debugging
    parse_confidence: float  # 0..1, how sure we are the parse is correct

    def to_row(self) -> dict:
        return asdict(self)


@dataclass
class AuditSummary:
    total: int = 0
    high: int = 0
    medium: int = 0
    low: int = 0
    info: int = 0
    by_type: dict[str, int] = field(default_factory=dict)
    by_file: dict[str, int] = field(default_factory=dict)
    files_scanned: int = 0
    iterations: int = 0

    def to_dict(self) -> dict:
        return asdict(self)


# ── Ralph parser ────────────────────────────────────────────────────────────

# Matches lines like:
#   - [severity: high] [type: confirmed] src/auth.py:42 — JWT audience ... Confidence: high
#   - [severity: medium] [type: likely-risk] foo.py:10-20 (and bar.py:5) — ... Confidence: low
_FINDING_RE = re.compile(
    r"""^\s*[-*]\s*
        \[\s*severity\s*[:=]\s*(?P<sev>[a-z\-]+)\s*\]\s*
        \[\s*type\s*[:=]\s*(?P<type>[a-z\-]+)\s*\]\s*
        (?P<body>.+)$
    """,
    re.IGNORECASE | re.VERBOSE,
)

# Pulls the first "path:lines" token out of a body, allowing "(and path:lines)" after.
_PATH_RE = re.compile(
    r"(?P<path>[\w./\-]+\.[A-Za-z0-9]+)(?::(?P<lines>\d+(?:-\d+)?))?"
)

_CONFIDENCE_RE = re.compile(r"confidence\s*[:=]\s*(?P<conf>high|medium|low)", re.IGNORECASE)


def parse_code_state(state_dir: Path, audit_id: str) -> tuple[list[Finding], AuditSummary]:
    """
    Main entry point for Ralph output. Preference order:
      1. v2 FINAL_REPORT.json  — structured, produced by awk extractor
      2. v2 findings.json      — same schema, all iterations merged
      3. v1 FINAL_REPORT.md    — regex over AI markdown (original path)
      4. v1 findings.md        — regex fallback
    Always returns a (findings, summary) tuple — never raises.
    """
    state_dir = Path(state_dir)
    findings: list[Finding] = []

    # Fast-path: v2 JSON. Ralph's awk extractor produces the same schema
    # this parser defines, so we trust it directly without markdown regex.
    for json_name in ("FINAL_REPORT.json", "findings.json"):
        jp = state_dir / json_name
        if jp.exists() and jp.stat().st_size > 2:  # more than just "[]"
            try:
                findings = _parse_v2_json(jp, audit_id)
                if findings:
                    break
            except Exception:
                findings = []

    # Fallback: v1 markdown path. This stays intact so old audit runs still parse.
    if not findings:
        final_report = state_dir / "FINAL_REPORT.md"
        if final_report.exists():
            try:
                findings = list(_parse_markdown(final_report.read_text(errors="replace"), audit_id))
            except Exception:
                findings = []

    if not findings:
        master = state_dir / "findings.md"
        if master.exists():
            try:
                findings = list(_parse_markdown(master.read_text(errors="replace"), audit_id))
            except Exception:
                findings = []

    summary = _summarize(findings)
    summary.iterations = _count_iterations(state_dir)
    summary.files_scanned = _count_files_scanned(state_dir)

    # Prefer Ralph's own metrics.json for counts if present — it already knows
    # exactly what the awk extractor found, avoids double-counting edge cases.
    metrics_path = state_dir / "metrics.json"
    if metrics_path.exists():
        try:
            m = json.loads(metrics_path.read_text())
            summary.total = int(m.get("total", summary.total))
            summary.high = int(m.get("high", summary.high))
            summary.medium = int(m.get("medium", summary.medium))
            summary.low = int(m.get("low", summary.low))
            summary.info = int(m.get("info", summary.info))
            summary.files_scanned = int(m.get("files_scanned", summary.files_scanned))
            summary.iterations = int(m.get("iterations", summary.iterations))
        except (json.JSONDecodeError, ValueError, OSError):
            pass  # stick with what _summarize computed

    return findings, summary


def _parse_v2_json(path: Path, audit_id: str) -> list[Finding]:
    """
    Read Ralph v2 FINAL_REPORT.json / findings.json. Schema produced by the
    awk extractor in code-audit.sh — fields match Finding exactly except for
    id/audit_id/raw_line which this function fills in.
    """
    raw = json.loads(path.read_text(errors="replace"))
    if not isinstance(raw, list):
        return []

    out: list[Finding] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        sev = item.get("severity", "info")
        if sev not in SEVERITY_VALUES:
            sev = _coerce_severity(sev)
        out.append(Finding(
            id=str(uuid.uuid4()),
            audit_id=audit_id,
            severity=sev,
            finding_type=item.get("finding_type", "hypothesis"),
            file=item.get("file", ""),
            line_range=item.get("line_range", ""),
            message=str(item.get("message", ""))[:2000],
            confidence=item.get("confidence", "medium").lower(),
            source_section=item.get("source_section", ""),
            raw_line="",  # not preserved in v2 JSON; source_section is enough context
            parse_confidence=1.0,  # awk did structured extraction, not heuristic
        ))
    return out
    return findings, summary


def _parse_markdown(text: str, audit_id: str) -> Iterable[Finding]:
    """
    Walk the markdown line by line. Track the current H2 section so we
    can tag each finding with source_section (Priority Findings, Cross-File
    Risks, etc).
    """
    current_section = ""
    for raw in text.splitlines():
        line = raw.rstrip()

        # Section header
        if line.startswith("## "):
            current_section = line[3:].strip()
            continue

        # Look for structured finding bullets
        m = _FINDING_RE.match(line)
        if m:
            finding = _parse_finding_line(line, m, current_section, audit_id)
            if finding:
                yield finding
            continue

        # Permissive fallback — a bullet in a findings section without the
        # bracketed prefix. We still capture it at medium confidence if it
        # looks substantive.
        if current_section.lower() in ("priority findings", "high-signal findings",
                                       "cross-file risks", "cross-cutting failure modes"):
            if line.startswith(("- ", "* ")) and len(line) > 8:
                heuristic = _heuristic_finding(line, current_section, audit_id)
                if heuristic:
                    yield heuristic


def _parse_finding_line(
    line: str, m: re.Match[str], section: str, audit_id: str,
) -> Finding | None:
    sev = m.group("sev").lower()
    typ = m.group("type").lower()
    body = m.group("body").strip()

    # Normalize severity / type to expected values
    severity = sev if sev in SEVERITY_VALUES else _coerce_severity(sev)
    finding_type = typ if typ in TYPE_VALUES else typ.replace(" ", "-")

    # Split on em-dash, en-dash, or double-dash for the "—" separator
    parts = re.split(r"\s+[—–-]{1,2}\s+", body, maxsplit=1)
    path_part = parts[0].strip()
    message = parts[1].strip() if len(parts) > 1 else body

    path_match = _PATH_RE.search(path_part)
    file_path = path_match.group("path") if path_match else ""
    line_range = path_match.group("lines") if path_match and path_match.group("lines") else ""

    # Extract confidence from anywhere in the body
    conf_match = _CONFIDENCE_RE.search(body)
    confidence = conf_match.group("conf").lower() if conf_match else "medium"

    # Strip the "Confidence: ..." tail from the message for display
    message = _CONFIDENCE_RE.sub("", message).rstrip(" .;,")
    message = message.strip() or "(no description)"

    return Finding(
        id=str(uuid.uuid4()),
        audit_id=audit_id,
        severity=severity,
        finding_type=finding_type,
        file=file_path,
        line_range=line_range,
        message=message[:2000],  # hard cap on stored message length
        confidence=confidence,
        source_section=section,
        raw_line=line[:500],
        parse_confidence=1.0 if path_match else 0.7,
    )


def _heuristic_finding(line: str, section: str, audit_id: str) -> Finding | None:
    """
    Soft-match for bullets without the [severity:][type:] prefix. We mark
    them low confidence so the UI can de-emphasize them.
    """
    body = line.lstrip("-* ").strip()
    if len(body) < 10:
        return None

    path_match = _PATH_RE.search(body)
    file_path = path_match.group("path") if path_match else ""
    line_range = path_match.group("lines") if path_match and path_match.group("lines") else ""

    # Infer severity from keywords — conservative
    low = body.lower()
    if any(k in low for k in ("critical", "severe", "broken", "crash", "data loss")):
        sev = "high"
    elif any(k in low for k in ("bug", "incorrect", "wrong", "missing check", "race")):
        sev = "medium"
    else:
        sev = "low"

    return Finding(
        id=str(uuid.uuid4()),
        audit_id=audit_id,
        severity=sev,
        finding_type="hypothesis",
        file=file_path,
        line_range=line_range,
        message=body[:2000],
        confidence="low",
        source_section=section,
        raw_line=line[:500],
        parse_confidence=0.3,
    )


def _coerce_severity(raw: str) -> str:
    raw = raw.lower().strip()
    if raw in ("critical", "crit", "severe", "blocker"):
        return "high"
    if raw in ("med", "moderate", "warn", "warning"):
        return "medium"
    if raw in ("minor", "nit", "note"):
        return "low"
    return "info"


def _summarize(findings: list[Finding]) -> AuditSummary:
    s = AuditSummary(total=len(findings))
    for f in findings:
        if f.severity == "high":
            s.high += 1
        elif f.severity == "medium":
            s.medium += 1
        elif f.severity == "low":
            s.low += 1
        else:
            s.info += 1
        s.by_type[f.finding_type] = s.by_type.get(f.finding_type, 0) + 1
        if f.file:
            s.by_file[f.file] = s.by_file.get(f.file, 0) + 1
    return s


def _count_iterations(state_dir: Path) -> int:
    iter_dir = state_dir / "iterations"
    if not iter_dir.exists():
        return 0
    return sum(1 for p in iter_dir.glob("iteration-*.md") if p.stat().st_size > 0)


def _count_files_scanned(state_dir: Path) -> int:
    manifest = state_dir / "manifest.txt"
    if not manifest.exists():
        return 0
    try:
        return sum(1 for line in manifest.read_text().splitlines() if line.strip())
    except OSError:
        return 0


# ── RepoLens parser (local mode JSON output) ────────────────────────────────

def parse_repolens_state(state_dir: Path, audit_id: str) -> tuple[list[Finding], AuditSummary]:
    """
    RepoLens in --local mode writes findings as JSON files under its output
    dir. Schema varies by lens, so we look for any *.json with a 'findings'
    or 'issues' array and flatten it.

    This is a best-effort parser — RepoLens is primarily designed to create
    GitHub issues, so if you want fidelity use --local + gh issue workflow.
    """
    findings: list[Finding] = []
    if not state_dir.exists():
        return findings, AuditSummary()

    for json_path in state_dir.rglob("*.json"):
        try:
            data = json.loads(json_path.read_text(errors="replace"))
        except (json.JSONDecodeError, OSError):
            continue

        items = data.get("findings") or data.get("issues") or []
        if not isinstance(items, list):
            continue

        lens = data.get("lens") or json_path.stem
        for item in items:
            if not isinstance(item, dict):
                continue
            findings.append(Finding(
                id=str(uuid.uuid4()),
                audit_id=audit_id,
                severity=_coerce_severity(str(item.get("severity", "info"))),
                finding_type=str(item.get("type", "security")),
                file=str(item.get("file", "")),
                line_range=str(item.get("line", "") or item.get("lines", "")),
                message=str(item.get("title") or item.get("message") or "(no description)")[:2000],
                confidence=str(item.get("confidence", "medium")).lower(),
                source_section=f"lens:{lens}",
                raw_line=json.dumps(item)[:500],
                parse_confidence=0.9,
            ))

    summary = _summarize(findings)
    # We don't know files_scanned from RepoLens output; leave 0.
    return findings, summary


# ── public dispatcher ───────────────────────────────────────────────────────

def parse_audit_output(
    backend: str, state_dir: Path, audit_id: str,
) -> tuple[list[Finding], AuditSummary]:
    if backend == "code":
        return parse_code_state(state_dir, audit_id)
    if backend == "repolens":
        return parse_repolens_state(state_dir, audit_id)
    return [], AuditSummary()
