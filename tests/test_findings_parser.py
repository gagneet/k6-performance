"""
Tests for findings_parser.py — covers v1 markdown path, v2 JSON fast-path,
SAST parsers, and the public dispatcher.

All tests are idempotent: any temporary state is created inside tmp_path
(pytest fixture) and torn down automatically. No database writes.
"""

import json
import uuid
from pathlib import Path

import pytest
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "app"))

from findings_parser import (
    Finding,
    AuditSummary,
    _parse_markdown,
    _parse_v2_json,
    _coerce_severity,
    _summarize,
    _count_iterations,
    _count_files_scanned,
    parse_code_state,
    parse_repolens_state,
    parse_local_sast_state,
    parse_audit_output,
)

AUDIT_ID = "test-audit-00"

# ── fixtures / helpers ─────────────────────────────────────────────────────────

MINIMAL_FINAL_REPORT = """\
# Final Audit Report

## Priority Findings
- [severity: high] [type: confirmed] src/auth.py:42 — JWT check missing. Confidence: high
- [severity: medium] [type: likely-risk] src/db.py:10-20 — Race on session write. Confidence: medium
- [severity: low] [type: hypothesis] src/utils.py — TZ edge case. Confidence: low

## Cross-Cutting Failure Modes
- [severity: high] [type: security] app/api.py:5 — Unvalidated input reaches SQL. Confidence: high

<promise>COMPLETE</promise>
"""

MINIMAL_FINDINGS_JSON = json.dumps([
    {
        "severity": "high",
        "finding_type": "confirmed",
        "file": "src/auth.py",
        "line_range": "42",
        "message": "JWT check missing",
        "confidence": "high",
        "source_section": "Priority Findings",
    },
    {
        "severity": "medium",
        "finding_type": "likely-risk",
        "file": "src/db.py",
        "line_range": "10-20",
        "message": "Race on session write",
        "confidence": "medium",
        "source_section": "Priority Findings",
    },
])


def _make_state_dir(tmp_path: Path, **files: str) -> Path:
    state = tmp_path / "audit-state"
    state.mkdir()
    (state / "iterations").mkdir()
    for name, content in files.items():
        (state / name).write_text(content)
    return state


# ── _coerce_severity ───────────────────────────────────────────────────────────

class TestCoerceSeverity:
    def test_high_aliases(self):
        for alias in ("critical", "crit", "severe", "blocker"):
            assert _coerce_severity(alias) == "high"

    def test_medium_aliases(self):
        for alias in ("med", "moderate", "warn", "warning"):
            assert _coerce_severity(alias) == "medium"

    def test_low_aliases(self):
        for alias in ("minor", "nit", "note"):
            assert _coerce_severity(alias) == "low"

    def test_unknown_returns_info(self):
        assert _coerce_severity("unknown-xyz") == "info"

    def test_case_insensitive(self):
        assert _coerce_severity("CRITICAL") == "high"
        assert _coerce_severity("WARN") == "medium"


# ── _parse_markdown ────────────────────────────────────────────────────────────

class TestParseMarkdown:
    def test_structured_findings_parsed(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        assert len(findings) == 4

    def test_severity_and_type_extracted(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        high = [f for f in findings if f.severity == "high"]
        assert len(high) == 2

    def test_file_and_line_range(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        auth = next(f for f in findings if "auth.py" in f.file)
        assert auth.file == "src/auth.py"
        assert auth.line_range == "42"

    def test_line_range_with_dash(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        db = next(f for f in findings if "db.py" in f.file)
        assert db.line_range == "10-20"

    def test_confidence_extracted(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        auth = next(f for f in findings if "auth.py" in f.file)
        assert auth.confidence == "high"

    def test_source_section_tracked(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        xfile = next(f for f in findings if f.source_section == "Cross-Cutting Failure Modes")
        assert xfile is not None

    def test_empty_input_returns_empty(self):
        assert list(_parse_markdown("", AUDIT_ID)) == []

    def test_no_findings_section_returns_empty(self):
        text = "# Final Audit Report\n## Executive Summary\n- Nothing.\n"
        assert list(_parse_markdown(text, AUDIT_ID)) == []

    def test_em_dash_separator(self):
        text = "## Priority Findings\n- [severity: high] [type: confirmed] app/x.py:1 \u2014 em-dash msg. Confidence: high\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert len(findings) == 1
        assert "em-dash msg" in findings[0].message
        assert "\u2014" not in findings[0].message

    def test_en_dash_separator(self):
        text = "## Priority Findings\n- [severity: medium] [type: likely-risk] app/y.py:2 \u2013 en-dash msg. Confidence: medium\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert len(findings) == 1
        assert "en-dash msg" in findings[0].message

    def test_missing_confidence_defaults_medium(self):
        text = "## Priority Findings\n- [severity: low] [type: hypothesis] app/z.py — no confidence here\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert findings[0].confidence == "medium"

    def test_parse_confidence_full_when_path_found(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        for f in findings:
            if f.file:
                assert f.parse_confidence == 1.0

    def test_parse_confidence_reduced_without_path(self):
        text = "## Priority Findings\n- [severity: high] [type: confirmed] — no file at all. Confidence: high\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert findings[0].parse_confidence == 0.7

    def test_heuristic_fallback_in_findings_sections(self):
        text = (
            "## Priority Findings\n"
            "- critical: broken auth logic crashes on null session\n"
        )
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert len(findings) == 1
        assert findings[0].parse_confidence == 0.3
        assert findings[0].finding_type == "hypothesis"

    def test_heuristic_not_triggered_outside_findings_sections(self):
        text = (
            "## Executive Summary\n"
            "- critical: broken auth logic crashes on null session\n"
        )
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert len(findings) == 0

    def test_message_confidence_tail_stripped(self):
        text = "## Priority Findings\n- [severity: high] [type: confirmed] src/a.py:1 — auth bug. Confidence: high\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        assert "Confidence" not in findings[0].message

    def test_nul_bytes_dont_crash(self):
        text = "## Priority Findings\n- [severity: high] [type: confirmed] src/a.py\x00:1 — nul msg. Confidence: high\n"
        findings = list(_parse_markdown(text, AUDIT_ID))
        # Should not raise; may produce zero or one finding
        assert isinstance(findings, list)

    def test_audit_id_propagated(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        assert all(f.audit_id == AUDIT_ID for f in findings)

    def test_unique_ids(self):
        findings = list(_parse_markdown(MINIMAL_FINAL_REPORT, AUDIT_ID))
        ids = [f.id for f in findings]
        assert len(ids) == len(set(ids))


# ── _parse_v2_json ─────────────────────────────────────────────────────────────

class TestParseV2Json:
    def test_basic_parsing(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text(MINIMAL_FINDINGS_JSON)
        findings = _parse_v2_json(jp, AUDIT_ID)
        assert len(findings) == 2

    def test_parse_confidence_is_one(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text(MINIMAL_FINDINGS_JSON)
        findings = _parse_v2_json(jp, AUDIT_ID)
        assert all(f.parse_confidence == 1.0 for f in findings)

    def test_fields_populated(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text(MINIMAL_FINDINGS_JSON)
        findings = _parse_v2_json(jp, AUDIT_ID)
        f = findings[0]
        assert f.severity == "high"
        assert f.finding_type == "confirmed"
        assert f.file == "src/auth.py"
        assert f.line_range == "42"
        assert f.confidence == "high"

    def test_empty_array_returns_empty(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text("[]")
        assert _parse_v2_json(jp, AUDIT_ID) == []

    def test_invalid_json_raises(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text("{not json}")
        with pytest.raises(Exception):
            _parse_v2_json(jp, AUDIT_ID)

    def test_non_list_json_returns_empty(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text('{"severity": "high"}')
        assert _parse_v2_json(jp, AUDIT_ID) == []

    def test_unknown_severity_coerced(self, tmp_path):
        data = [{"severity": "critical", "finding_type": "confirmed", "file": "",
                 "line_range": "", "message": "x", "confidence": "high",
                 "source_section": ""}]
        jp = tmp_path / "findings.json"
        jp.write_text(json.dumps(data))
        findings = _parse_v2_json(jp, AUDIT_ID)
        assert findings[0].severity == "high"

    def test_message_capped_at_2000(self, tmp_path):
        data = [{"severity": "low", "finding_type": "hypothesis", "file": "",
                 "line_range": "", "message": "x" * 3000, "confidence": "low",
                 "source_section": ""}]
        jp = tmp_path / "findings.json"
        jp.write_text(json.dumps(data))
        findings = _parse_v2_json(jp, AUDIT_ID)
        assert len(findings[0].message) == 2000

    def test_audit_id_set(self, tmp_path):
        jp = tmp_path / "findings.json"
        jp.write_text(MINIMAL_FINDINGS_JSON)
        findings = _parse_v2_json(jp, "custom-id")
        assert all(f.audit_id == "custom-id" for f in findings)


# ── parse_code_state (v2 fast-path + v1 fallback) ─────────────────────────────

class TestParseCodeState:
    def test_v2_json_preferred_over_markdown(self, tmp_path):
        state = _make_state_dir(
            tmp_path,
            # Both present; JSON should win
            **{"FINAL_REPORT.json": MINIMAL_FINDINGS_JSON,
               "FINAL_REPORT.md": MINIMAL_FINAL_REPORT},
        )
        findings, summary = parse_code_state(state, AUDIT_ID)
        # v2 JSON has 2 findings; v1 markdown has 4 — confirms JSON won
        assert len(findings) == 2
        assert all(f.parse_confidence == 1.0 for f in findings)

    def test_v1_markdown_fallback_when_no_json(self, tmp_path):
        state = _make_state_dir(tmp_path, **{"FINAL_REPORT.md": MINIMAL_FINAL_REPORT})
        findings, summary = parse_code_state(state, AUDIT_ID)
        assert len(findings) == 4

    def test_findings_json_used_when_final_report_json_empty(self, tmp_path):
        state = _make_state_dir(
            tmp_path,
            **{"FINAL_REPORT.json": "[]", "findings.json": MINIMAL_FINDINGS_JSON},
        )
        findings, _ = parse_code_state(state, AUDIT_ID)
        assert len(findings) == 2

    def test_empty_state_dir_returns_empty(self, tmp_path):
        state = _make_state_dir(tmp_path)
        findings, summary = parse_code_state(state, AUDIT_ID)
        assert findings == []
        assert summary.total == 0

    def test_metrics_json_overrides_summary(self, tmp_path):
        metrics = {
            "schema": "code-audit/v2",
            "total": 99, "high": 10, "medium": 20, "low": 30, "info": 39,
            "files_scanned": 42, "iterations": 7,
        }
        state = _make_state_dir(
            tmp_path,
            **{"FINAL_REPORT.json": MINIMAL_FINDINGS_JSON,
               "metrics.json": json.dumps(metrics)},
        )
        _, summary = parse_code_state(state, AUDIT_ID)
        assert summary.total == 99
        assert summary.high == 10
        assert summary.files_scanned == 42
        assert summary.iterations == 7

    def test_corrupt_metrics_json_doesnt_crash(self, tmp_path):
        state = _make_state_dir(
            tmp_path,
            **{"FINAL_REPORT.json": MINIMAL_FINDINGS_JSON,
               "metrics.json": "{not valid json}"},
        )
        findings, summary = parse_code_state(state, AUDIT_ID)
        assert len(findings) == 2
        assert summary.total == 2

    def test_never_raises_on_corrupt_input(self, tmp_path):
        state = _make_state_dir(
            tmp_path,
            **{"FINAL_REPORT.md": "## Priority Findings\n" + "\x00" * 100},
        )
        findings, summary = parse_code_state(state, AUDIT_ID)
        assert isinstance(findings, list)
        assert isinstance(summary, AuditSummary)

    def test_files_scanned_counted_from_manifest(self, tmp_path):
        state = _make_state_dir(
            tmp_path,
            **{"FINAL_REPORT.json": "[]",
               "manifest.txt": "app/main.py\napp/models.py\napp/views.py\n"},
        )
        _, summary = parse_code_state(state, AUDIT_ID)
        assert summary.files_scanned == 3

    def test_iterations_counted_from_iter_dir(self, tmp_path):
        state = _make_state_dir(tmp_path, **{"FINAL_REPORT.json": "[]"})
        for i in range(3):
            f = state / "iterations" / f"iteration-{i+1:03d}.md"
            f.write_text("# content\n")
        _, summary = parse_code_state(state, AUDIT_ID)
        assert summary.iterations == 3


# ── _summarize ─────────────────────────────────────────────────────────────────

class TestSummarize:
    def _make_finding(self, severity: str, finding_type: str = "confirmed",
                      file: str = "app/x.py") -> Finding:
        return Finding(
            id=str(uuid.uuid4()), audit_id=AUDIT_ID, severity=severity,
            finding_type=finding_type, file=file, line_range="1",
            message="msg", confidence="high", source_section="",
            raw_line="", parse_confidence=1.0,
        )

    def test_totals(self):
        findings = [
            self._make_finding("high"),
            self._make_finding("medium"),
            self._make_finding("low"),
            self._make_finding("info"),
        ]
        s = _summarize(findings)
        assert s.total == 4
        assert s.high == 1
        assert s.medium == 1
        assert s.low == 1
        assert s.info == 1

    def test_by_type_aggregated(self):
        findings = [
            self._make_finding("high", "confirmed"),
            self._make_finding("medium", "confirmed"),
            self._make_finding("low", "hypothesis"),
        ]
        s = _summarize(findings)
        assert s.by_type["confirmed"] == 2
        assert s.by_type["hypothesis"] == 1

    def test_by_file_aggregated(self):
        findings = [
            self._make_finding("high", file="app/auth.py"),
            self._make_finding("medium", file="app/auth.py"),
            self._make_finding("low", file="app/db.py"),
        ]
        s = _summarize(findings)
        assert s.by_file["app/auth.py"] == 2
        assert s.by_file["app/db.py"] == 1

    def test_empty_input(self):
        s = _summarize([])
        assert s.total == 0

    def test_to_dict_is_json_serializable(self):
        findings = [self._make_finding("high")]
        s = _summarize(findings)
        d = s.to_dict()
        json.dumps(d)  # must not raise


# ── parse_repolens_state ───────────────────────────────────────────────────────

class TestParseRepolensState:
    def test_reads_findings_array(self, tmp_path):
        data = {"lens": "injection", "findings": [
            {"severity": "high", "type": "security", "file": "src/db.py",
             "line": 42, "title": "SQL injection", "confidence": "high"},
        ]}
        (tmp_path / "injection.json").write_text(json.dumps(data))
        findings, summary = parse_repolens_state(tmp_path, AUDIT_ID)
        assert len(findings) == 1
        assert findings[0].severity == "high"
        assert findings[0].file == "src/db.py"

    def test_reads_issues_array_fallback(self, tmp_path):
        data = {"issues": [{"severity": "medium", "type": "bug",
                             "message": "off-by-one", "confidence": "medium"}]}
        (tmp_path / "out.json").write_text(json.dumps(data))
        findings, _ = parse_repolens_state(tmp_path, AUDIT_ID)
        assert len(findings) == 1

    def test_source_section_includes_lens_name(self, tmp_path):
        data = {"lens": "xss", "findings": [
            {"severity": "high", "type": "security", "title": "XSS"}
        ]}
        (tmp_path / "xss.json").write_text(json.dumps(data))
        findings, _ = parse_repolens_state(tmp_path, AUDIT_ID)
        assert findings[0].source_section == "lens:xss"

    def test_parse_confidence_is_0_9(self, tmp_path):
        data = {"findings": [{"severity": "low", "type": "hypothesis",
                               "title": "test"}]}
        (tmp_path / "r.json").write_text(json.dumps(data))
        findings, _ = parse_repolens_state(tmp_path, AUDIT_ID)
        assert findings[0].parse_confidence == 0.9

    def test_nonexistent_dir_returns_empty(self, tmp_path):
        findings, summary = parse_repolens_state(tmp_path / "no-such-dir", AUDIT_ID)
        assert findings == []

    def test_malformed_json_skipped(self, tmp_path):
        (tmp_path / "bad.json").write_text("{not json}")
        findings, _ = parse_repolens_state(tmp_path, AUDIT_ID)
        assert findings == []


# ── parse_local_sast_state (semgrep + bandit + ruff) ──────────────────────────

class TestParseLocalSastState:
    def test_semgrep_results_parsed(self, tmp_path):
        data = {"results": [{
            "path": "src/app.py",
            "start": {"line": 10},
            "check_id": "python.security.injection",
            "extra": {
                "severity": "ERROR",
                "message": "SQL injection risk",
                "metadata": {"confidence": "HIGH", "category": "security"},
            },
        }]}
        (tmp_path / "semgrep.json").write_text(json.dumps(data))
        findings, summary = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert len(findings) == 1
        assert findings[0].severity == "high"
        assert findings[0].source_section == "semgrep"
        assert findings[0].parse_confidence == 0.95

    def test_bandit_results_parsed(self, tmp_path):
        data = {"results": [{
            "filename": "app/views.py",
            "line_number": 25,
            "issue_text": "Use of assert detected",
            "issue_severity": "LOW",
            "issue_confidence": "HIGH",
            "test_id": "B101",
        }]}
        (tmp_path / "bandit.json").write_text(json.dumps(data))
        findings, _ = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert len(findings) == 1
        assert findings[0].finding_type == "security"
        assert findings[0].file == "app/views.py"
        assert findings[0].line_range == "25"

    def test_ruff_results_parsed(self, tmp_path):
        data = [
            {"filename": "app/utils.py", "code": "S101",
             "message": "assert statement", "location": {"row": 5}},
            {"filename": "app/utils.py", "code": "F401",
             "message": "unused import", "location": {"row": 1}},
        ]
        (tmp_path / "ruff.json").write_text(json.dumps(data))
        findings, _ = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert len(findings) == 2
        s_finding = next(f for f in findings if "S101" in f.message)
        assert s_finding.severity == "high"

    def test_all_three_combined(self, tmp_path):
        (tmp_path / "semgrep.json").write_text('{"results": []}')
        (tmp_path / "bandit.json").write_text('{"results": [{"filename": "x.py", "line_number": 1, "issue_text": "t", "issue_severity": "HIGH", "issue_confidence": "HIGH", "test_id": "B999"}]}')
        (tmp_path / "ruff.json").write_text('[{"filename": "y.py", "code": "E501", "message": "line too long", "location": {"row": 2}}]')
        findings, _ = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert len(findings) == 2

    def test_missing_files_return_empty(self, tmp_path):
        findings, summary = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert findings == []
        assert summary.total == 0

    def test_malformed_json_skipped(self, tmp_path):
        (tmp_path / "semgrep.json").write_text("{garbage}")
        findings, _ = parse_local_sast_state(tmp_path, AUDIT_ID)
        assert findings == []


# ── parse_audit_output dispatcher ─────────────────────────────────────────────

class TestParseAuditOutputDispatcher:
    def test_code_backend_dispatches_correctly(self, tmp_path):
        state = _make_state_dir(tmp_path, **{"FINAL_REPORT.json": MINIMAL_FINDINGS_JSON})
        findings, _ = parse_audit_output("code", state, AUDIT_ID)
        assert len(findings) == 2

    def test_repolens_backend_dispatches_correctly(self, tmp_path):
        data = {"findings": [{"severity": "high", "type": "security", "title": "XSS"}]}
        (tmp_path / "r.json").write_text(json.dumps(data))
        findings, _ = parse_audit_output("repolens", tmp_path, AUDIT_ID)
        assert len(findings) == 1

    def test_local_sast_backend_dispatches_correctly(self, tmp_path):
        data = [{"filename": "app/x.py", "code": "S101",
                 "message": "assert", "location": {"row": 1}}]
        (tmp_path / "ruff.json").write_text(json.dumps(data))
        findings, _ = parse_audit_output("local-sast", tmp_path, AUDIT_ID)
        assert len(findings) == 1

    def test_unknown_backend_returns_empty(self, tmp_path):
        findings, summary = parse_audit_output("unknown-backend", tmp_path, AUDIT_ID)
        assert findings == []
        assert summary.total == 0
