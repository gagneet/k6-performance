#!/usr/bin/env bash
# local-sast.sh — zero-cost SAST using semgrep + bandit + ruff
#
# Called by the portal audit_runner as: bash local-sast.sh <target-path>
# Reads:  $STATE_DIR (set by audit_runner, defaults to /tmp/local-sast-$$)
# Writes: $STATE_DIR/semgrep.json, bandit.json, ruff.json
#
# All three tools exit non-zero when they find issues — that's normal behaviour.
# This script always exits 0 so the portal records status from the finding count,
# not from a bash error code.
set -euo pipefail

TARGET="${1:?Usage: local-sast.sh <repo-path>}"
STATE_DIR="${STATE_DIR:-/tmp/local-sast-$$}"
mkdir -p "$STATE_DIR"

echo "[local-sast] target : $TARGET"
echo "[local-sast] output : $STATE_DIR"
echo ""

_count_json_results() {
    local file="$1" key="${2:-results}"
    python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    items = d.get('$key', d) if isinstance(d, dict) else d
    print(len(items) if isinstance(items, list) else '?')
except Exception:
    print('?')
" 2>/dev/null
}

# ── semgrep ──────────────────────────────────────────────────────────────────
if command -v semgrep &>/dev/null; then
    echo "[semgrep] scanning with auto config (security + correctness rules)..."
    # semgrep exits 1 when findings exist — suppress with || true
    semgrep scan \
        --config=auto \
        --json \
        --output="$STATE_DIR/semgrep.json" \
        --no-rewrite-rule-ids \
        --quiet \
        "$TARGET" 2>&1 || true
    COUNT=$(_count_json_results "$STATE_DIR/semgrep.json" results)
    echo "[semgrep] done — $COUNT findings"
else
    echo "[semgrep] not installed — skipping (add 'semgrep' to requirements.txt)"
fi

echo ""

# ── bandit (Python security) ─────────────────────────────────────────────────
if command -v bandit &>/dev/null; then
    PY_CHECK=$(find "$TARGET" -maxdepth 4 -name "*.py" -not -path "*/.git/*" 2>/dev/null | head -1)
    if [ -n "$PY_CHECK" ]; then
        echo "[bandit] scanning Python files for security issues..."
        bandit -r "$TARGET" \
            --format json \
            --output "$STATE_DIR/bandit.json" \
            --quiet \
            --exclude "*/.git,*/node_modules,*/__pycache__,*/.venv,*/venv" \
            2>&1 || true  # exits 1 on findings
        COUNT=$(_count_json_results "$STATE_DIR/bandit.json" results)
        echo "[bandit] done — $COUNT findings"
    else
        echo "[bandit] no Python files in target — skipping"
    fi
else
    echo "[bandit] not installed — skipping (add 'bandit' to requirements.txt)"
fi

echo ""

# ── ruff (Python code quality) ───────────────────────────────────────────────
if command -v ruff &>/dev/null; then
    PY_CHECK=$(find "$TARGET" -maxdepth 4 -name "*.py" -not -path "*/.git/*" 2>/dev/null | head -1)
    if [ -n "$PY_CHECK" ]; then
        echo "[ruff] checking Python code quality..."
        ruff check "$TARGET" \
            --output-format json \
            --no-cache \
            > "$STATE_DIR/ruff.json" 2>&1 || true  # exits 1 on findings
        COUNT=$(_count_json_results "$STATE_DIR/ruff.json" __array__)
        echo "[ruff] done — $COUNT findings"
    else
        echo "[ruff] no Python files in target — skipping"
    fi
else
    echo "[ruff] not installed — skipping (add 'ruff' to requirements.txt)"
fi

echo ""
echo "[local-sast] complete"
exit 0
