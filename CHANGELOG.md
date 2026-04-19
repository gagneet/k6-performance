# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [2026-04-19]

### Added

- **code-audit.sh v2** — six new features on top of the v1 loop:
  - `DIFF_ONLY=1` mode: only audit files changed since `BASE_REF` (default `main`), skipping unchanged files entirely — ideal for PR-scoped reviews.
  - Cost estimation: `COST_ESTIMATE=1` prints a token/cost preview before any AI calls; `CONFIRM_COST=1` requires interactive approval; `PRICE_IN_PER_MTOK` / `PRICE_OUT_PER_MTOK` accept custom pricing.
  - Static analysis pre-pass: `STATIC_ANALYSIS=1` runs semgrep + bandit + ruff before the AI loop and injects findings as additional context per iteration.
  - Churn sort: `CHURN_SORT=1` reorders the file manifest so recently-changed files (within `CHURN_DAYS=30`) are reviewed first.
  - Progress JSON: `PROGRESS_JSON=1` writes `progress.json` (atomically via tmp+rename) after each iteration — machine-readable progress for external monitors.
  - Structured JSON output: `extract_findings_json()` (pure-awk) emits `findings.json` and `metrics.json` alongside `FINAL_REPORT.md`.

- **`findings_parser.py` v2 fast-path** — `parse_code_state()` now prefers structured JSON over markdown:
  1. `FINAL_REPORT.json` → `findings.json` (sets `parse_confidence=1.0`)
  2. `FINAL_REPORT.md` → `findings.md` (markdown regex, `parse_confidence=0.3–1.0`)
  - `_parse_v2_json()` deserialises awk extractor output directly into `Finding` dataclass rows.
  - `metrics.json` override: when present, its `total`/`high`/`medium`/`low`/`info`/`files_scanned`/`iterations` counts replace Python-computed summary values.

- **Test suite** — 74 pytest tests across two files:
  - `tests/test_findings_parser.py` (63 tests): `_coerce_severity` pass-through and aliases, `_parse_markdown` separators and edge cases, `_parse_v2_json` fast-path, `parse_code_state` file-preference order, `summarize` totals, `parse_repolens_state`, `parse_local_sast_state` (semgrep/bandit/ruff), and the full `parse_audit_output` dispatcher.
  - `tests/test_awk_extractor.py` (11 tests): field-by-field validation that the awk `extract_findings_json` function produces output byte-compatible with `findings_parser._parse_markdown` on the same sample markdown — covering em-dash, en-dash, ASCII hyphen, no file path, no line number, missing confidence, empty markdown, and a 100-finding stress run.
  - All tests are idempotent; no persistent state outside `tmp_path`.

### Fixed

- **`_coerce_severity()` pass-through bug** — valid severity values (`high`, `medium`, `low`, `info`) were falling through to `return "info"` instead of being returned unchanged. All callers (especially `_parse_v2_json` and `_parse_repolens_state`) were silently downgrading all non-`info` findings to `info`.

- **WebSocket `__DONE__` never detected (k6 runs)** — `main.py` was broadcasting `"\n__DONE__:passed"` (leading newline); the frontend `startsWith('__DONE__:')` check therefore never matched, leaving the terminal spinner running forever. The leading newline is now stripped; broadcasts send the sentinel as a standalone message.

- **WebSocket `__DONE__` never detected (audits)** — The audit completion broadcast concatenated the summary line and the sentinel into one string (`"\n[audit complete]...\n__DONE__:passed"`). Frontend `startsWith` checks against both `'\n__DONE__:'` and `'__DONE__:'` both missed. Fixed by splitting into two separate `broadcast()` calls.

- **`GRAFANA_URL` default pointed at wrong port** — `main.py` defaulted to `http://localhost:3000` but Grafana is mapped to host port `3100` (because `3000` was already in use on the host). The default is now `http://localhost:3100`.

- **`local-sast` backend silently dropped after v2 merge** — The v2 `findings_parser.py` patch omitted `parse_local_sast_state`, `_parse_semgrep`, `_parse_bandit`, `_parse_ruff`, and the `local-sast` branch in `parse_audit_output()`. All SAST functions were retained from the original during the merge.

---

## [2026-04-19] — code-audit.sh pre-v2

### Added

- Deploy script for building and deploying the portal on Ubuntu Server.
- Code analysis audit script updated (intermediate pre-v2 iteration).

---

## [Prior releases]

### Added

- Monthly dependency check cron scripts (`scripts/cron/`): checks RepoLens release, strata-management upstream, and this repo's upstream; sends cron email on updates.
- Local SAST backend (`scripts/local-sast.sh`): zero-cost semgrep + bandit + ruff audit, no AI calls; installed in the portal Docker image.
- strata-management scripts and audit target; git SHA detection for commit correlation.
- Mount strata-management repo as an audit target and script source.
- Code audit integration: AI-driven repo analysis with k6 correlation (first full implementation).
- Grafana dashboard (`k6-perf` UID) with k6 panels and audit panels; template variables `$testid`, `$baseline`, `$audit_id`.
- Portal UI: Run Test, History, Audit, Audits History tabs; live ANSI terminal; Grafana deep-link per run.
- FastAPI portal: async k6 subprocess runner, WebSocket streaming, SQLite run history.
- k6 test scripts: `smoke-test.js`, `load-test.js`, `stress-test.js`, `spike-test.js`, `soak-test.js`.

### Fixed

- SQLite WAL mode; `shutil` top-level import; `utcnow` deprecation.
- Extra-dir scripts listed but unrunnable (script scanner path bug).
- Script scanner missed TypeScript files and subdirectory mounts.
- `.dockerignore` prevents `__pycache__` entering build context.
- Audit tab backend annotation accumulates on repeat visits.
- Hardened WebSocket routing + commit-SHA correlation field.
- strata auth: per-VU login, 401 re-auth, removed `setup()` token sharing.

### Changed

- Renamed audit tool references from "Code Analysis Audit Tool" to "Code Analysis" for consistency.
- Removed superseded `upgrade/` staging directory.
- Rewrote README and added comprehensive USAGE.md.
- Bumped `python-multipart` from 0.0.9 to 0.0.26 (security patch).
