"""
InfluxDB writer for audit summary metrics.

We write to the same InfluxDB instance k6 uses (database `k6`, configured
via INFLUXDB_URL). This keeps the join surface simple: a single Grafana
datasource, a single time-series store, queries can freely join audit
and performance data.

Schema
------
Measurement: audit_summary
  Tags:
    audit_id   — 8-char uuid prefix (matches portal's SQLite PK)
    backend    — "code" or "repolens"
    target     — short repo name (last path segment)
    commit_sha — 12-char git SHA if available, else "none"
    testid     — optional k6 run_id this audit is linked to, else "none"
  Fields:
    total i, high i, medium i, low i, info i
    files_scanned i, iterations i
    duration_s f

Measurement: audit_finding
  Tags:
    audit_id, severity, finding_type, confidence, file
  Fields:
    count i (always 1; sum over time for severity trends)
    parse_confidence f

We talk to InfluxDB 1.x via its /write line-protocol endpoint. The portal
already depends on the URL (os.getenv INFLUXDB_URL) so we reuse it.
"""

from __future__ import annotations

import logging
import urllib.parse
import urllib.request
from typing import Iterable

logger = logging.getLogger(__name__)


def _escape_tag(v: str) -> str:
    """Escape tag values per influx line protocol: commas, equals, spaces."""
    if not v:
        return "none"
    return (str(v)
            .replace("\\", "\\\\")
            .replace(" ", r"\ ")
            .replace(",", r"\,")
            .replace("=", r"\="))


def _escape_measurement(v: str) -> str:
    return str(v).replace(",", r"\,").replace(" ", r"\ ")


def _line(measurement: str, tags: dict[str, str], fields: dict[str, object]) -> str:
    tag_str = ",".join(f"{k}={_escape_tag(str(v))}" for k, v in sorted(tags.items()) if v != "")
    field_parts: list[str] = []
    for k, v in sorted(fields.items()):
        if isinstance(v, bool):
            field_parts.append(f"{k}={'true' if v else 'false'}")
        elif isinstance(v, int):
            field_parts.append(f"{k}={v}i")
        elif isinstance(v, float):
            field_parts.append(f"{k}={v}")
        else:
            # Quoted string field
            s = str(v).replace('\\', '\\\\').replace('"', '\\"')
            field_parts.append(f'{k}="{s}"')
    field_str = ",".join(field_parts)
    return f"{_escape_measurement(measurement)},{tag_str} {field_str}"


def write_audit_summary(
    influx_url: str,
    *,
    audit_id: str,
    backend: str,
    target: str,
    commit_sha: str | None,
    testid: str | None,
    summary_dict: dict,
    duration_s: float,
) -> bool:
    """
    Push one audit_summary point. Returns True on success, False on any
    failure — we never want InfluxDB hiccups to fail the audit itself.
    """
    tags = {
        "audit_id": audit_id,
        "backend": backend,
        "target": target or "unknown",
        "commit_sha": commit_sha or "none",
        "testid": testid or "none",
    }
    fields = {
        "total": int(summary_dict.get("total", 0)),
        "high": int(summary_dict.get("high", 0)),
        "medium": int(summary_dict.get("medium", 0)),
        "low": int(summary_dict.get("low", 0)),
        "info": int(summary_dict.get("info", 0)),
        "files_scanned": int(summary_dict.get("files_scanned", 0)),
        "iterations": int(summary_dict.get("iterations", 0)),
        "duration_s": float(duration_s),
    }
    line = _line("audit_summary", tags, fields)
    return _post(influx_url, [line])


def write_audit_findings(
    influx_url: str,
    *,
    audit_id: str,
    findings: Iterable,  # list[Finding]
) -> bool:
    """
    Push one point per finding so Grafana can slice by severity/type/file.
    Fire-and-forget; chunked to avoid giant POST bodies.
    """
    lines: list[str] = []
    for f in findings:
        tags = {
            "audit_id": audit_id,
            "severity": f.severity,
            "finding_type": f.finding_type,
            "confidence": f.confidence,
            "file": (f.file or "unknown")[:200],  # influx tag cardinality hygiene
        }
        fields = {
            "count": 1,
            "parse_confidence": float(f.parse_confidence),
        }
        lines.append(_line("audit_finding", tags, fields))

    if not lines:
        return True

    # Chunk to ~5000 lines per POST (well under Influx's 10MB default limit).
    ok = True
    for i in range(0, len(lines), 5000):
        chunk = lines[i:i + 5000]
        if not _post(influx_url, chunk):
            ok = False
    return ok


def _post(influx_url: str, lines: list[str]) -> bool:
    """
    POST to <influx_url>/write or the bare URL (which should already include
    the /write endpoint in some configs). main.py passes INFLUXDB_URL in the
    form "http://influxdb:8086/k6", so we need to transform that into a
    /write?db=k6 call.
    """
    try:
        parsed = urllib.parse.urlparse(influx_url)
        # Expect path like "/k6" — pull db name from it
        db = parsed.path.strip("/") or "k6"
        base = f"{parsed.scheme}://{parsed.netloc}"
        write_url = f"{base}/write?{urllib.parse.urlencode({'db': db, 'precision': 'ns'})}"

        payload = ("\n".join(lines) + "\n").encode("utf-8")
        req = urllib.request.Request(
            write_url,
            data=payload,
            headers={"Content-Type": "application/octet-stream"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            if 200 <= resp.status < 300:
                return True
            logger.warning("influx write returned %s", resp.status)
            return False
    except Exception as exc:
        logger.warning("influx write failed: %s", exc)
        return False
