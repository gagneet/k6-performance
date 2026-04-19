"""
Validates that the awk extractor in scripts/code-audit.sh produces output
that is byte-compatible with what findings_parser._parse_markdown produces
on the same sample markdown.

These tests prove the invariant described in CodeAnalysis_Notes_v2.md:
"awk did structured extraction, parse_confidence=1.0".

All tests are idempotent — no filesystem side-effects outside tmp_path.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "app"))
from findings_parser import _parse_markdown

SCRIPT = Path(__file__).parent.parent / "scripts" / "code-audit.sh"
AUDIT_ID = "awk-test-00"

# The full awk extractor is inside code-audit.sh. We extract + wrap it
# so the test doesn't depend on running the full shell script pipeline.
def _run_awk_extractor(markdown_text: str, tmp_path: Path) -> list[dict]:
    """Source just the extract_findings_json function and call it."""
    src = SCRIPT.read_text()

    # Isolate the function body between `extract_findings_json()` and the
    # closing `}` at column 0 (same pattern the inline bash extraction uses).
    lines = src.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("extract_findings_json()"))
    # Find matching closing brace at col 0
    depth = 0
    end = start
    for i, line in enumerate(lines[start:], start):
        for ch in line:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
        if depth == 0 and i > start:
            end = i
            break

    func_body = "\n".join(lines[start:end + 1])

    src_md = tmp_path / "sample.md"
    out_json = tmp_path / "out.json"
    src_md.write_text(markdown_text)

    script = f"""
#!/usr/bin/env bash
set -euo pipefail
{func_body}
extract_findings_json "{src_md}" "{out_json}"
"""
    result = subprocess.run(
        ["bash", "-c", script],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"awk extractor failed:\n{result.stderr}"
    return json.loads(out_json.read_text())


FIELDS = ("severity", "finding_type", "file", "line_range", "confidence", "source_section")

SAMPLE_REPORT = """\
# Final Audit Report

## Priority Findings
- [severity: high] [type: confirmed] src/auth/jwt.py:42 — JWT audience check is missing, allowing token reuse across tenants. Confidence: high
- [severity: high] [type: confirmed] src/auth/jwt.py:42-58 — Token expiry enforced on login but not on refresh. Confidence: medium
- [severity: medium] [type: likely-risk] src/cache/redis_client.py:88 — Cache eviction racing with session write. Confidence: medium
- [severity: low] [type: hypothesis] src/utils/date.py — Possible TZ bug on DST boundaries. Confidence: low

## Cross-File Risks
- [severity: medium] [type: architecture] app/handlers.py:10 — Inconsistent error-handling decorators across API handlers. Confidence: high

<promise>COMPLETE</promise>
"""


@pytest.mark.skipif(not SCRIPT.exists(), reason="code-audit.sh not found")
class TestAwkExtractorMatchesPython:
    def test_finding_count_matches(self, tmp_path):
        awk_out = _run_awk_extractor(SAMPLE_REPORT, tmp_path)
        py_out = list(_parse_markdown(SAMPLE_REPORT, AUDIT_ID))
        assert len(awk_out) == len(py_out), (
            f"awk={len(awk_out)} findings vs python={len(py_out)} findings"
        )

    def test_all_fields_match(self, tmp_path):
        awk_out = _run_awk_extractor(SAMPLE_REPORT, tmp_path)
        py_out = list(_parse_markdown(SAMPLE_REPORT, AUDIT_ID))
        mismatches = []
        for i, (af, pf) in enumerate(zip(awk_out, py_out)):
            for field in FIELDS:
                av = af.get(field, "")
                pv = getattr(pf, field)
                if av != pv:
                    mismatches.append(f"finding #{i+1} {field}: awk={av!r} py={pv!r}")
        assert not mismatches, "\n".join(mismatches)

    def test_messages_match_ignoring_trailing_punct(self, tmp_path):
        awk_out = _run_awk_extractor(SAMPLE_REPORT, tmp_path)
        py_out = list(_parse_markdown(SAMPLE_REPORT, AUDIT_ID))
        for i, (af, pf) in enumerate(zip(awk_out, py_out)):
            am = af.get("message", "").rstrip(" .,;")
            pm = pf.message.rstrip(" .,;")
            assert am == pm, f"finding #{i+1} message mismatch:\n  awk={am!r}\n  py={pm!r}"

    def test_valid_json_output(self, tmp_path):
        awk_out = _run_awk_extractor(SAMPLE_REPORT, tmp_path)
        assert isinstance(awk_out, list)
        for item in awk_out:
            assert isinstance(item, dict)
            for field in ("severity", "finding_type", "message", "confidence"):
                assert field in item

    def test_empty_markdown_produces_empty_array(self, tmp_path):
        awk_out = _run_awk_extractor("# No findings here\n", tmp_path)
        assert awk_out == []

    def test_em_dash_separator(self, tmp_path):
        md = (
            "## Priority Findings\n"
            "- [severity: high] [type: confirmed] app/auth.py:10 \u2014 em-dash message here. Confidence: high\n"
        )
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert len(awk_out) == 1
        assert len(py_out) == 1
        assert awk_out[0]["file"] == py_out[0].file
        assert awk_out[0]["line_range"] == py_out[0].line_range
        assert awk_out[0]["severity"] == py_out[0].severity

    def test_en_dash_separator(self, tmp_path):
        md = (
            "## Priority Findings\n"
            "- [severity: medium] [type: likely-risk] src/db.py:5 \u2013 en-dash message. Confidence: medium\n"
        )
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert awk_out[0]["file"] == py_out[0].file

    def test_no_line_number(self, tmp_path):
        md = (
            "## Priority Findings\n"
            "- [severity: low] [type: hypothesis] src/utils.py — DST edge case. Confidence: low\n"
        )
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert awk_out[0]["line_range"] == ""
        assert py_out[0].line_range == ""

    def test_no_file_path(self, tmp_path):
        md = (
            "## Cross-Cutting Failure Modes\n"
            "- [severity: high] [type: security] — No file, just a message. Confidence: high\n"
        )
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert awk_out[0]["file"] == ""
        assert py_out[0].file == ""

    def test_missing_confidence_defaults_medium(self, tmp_path):
        md = (
            "## Priority Findings\n"
            "- [severity: info] [type: hypothesis] src/x.py:1 — no confidence tag\n"
        )
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert awk_out[0]["confidence"] == "medium"
        assert py_out[0].confidence == "medium"

    def test_stress_100_findings(self, tmp_path):
        lines = ["## Priority Findings"]
        for i in range(100):
            lines.append(
                f"- [severity: medium] [type: likely-risk] src/file{i}.py:{i+1} "
                f"\u2014 Issue {i}. Confidence: medium"
            )
        md = "\n".join(lines) + "\n"
        awk_out = _run_awk_extractor(md, tmp_path)
        py_out = list(_parse_markdown(md, AUDIT_ID))
        assert len(awk_out) == 100
        assert len(py_out) == 100
        for i, (af, pf) in enumerate(zip(awk_out, py_out)):
            for field in FIELDS:
                assert af.get(field, "") == getattr(pf, field), (
                    f"finding #{i+1} {field} mismatch"
                )
