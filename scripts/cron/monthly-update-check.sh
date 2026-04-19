#!/usr/bin/env bash
# monthly-update-check.sh — checks for updates to external dependencies
#
# Reports on:
#   - RepoLens (github.com/TheMorpheus407/RepoLens) latest release vs installed
#   - strata-management repo — commits behind upstream
#   - k6-performance repo itself — commits behind upstream
#
# Exits 0 when everything is current; exits 1 when updates are available so
# cron sends an email notification (configure MAILTO in crontab.example).
#
# Logs are written to <project>/logs/update-checks/YYYY-MM-DD.log
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/update-checks"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }

log "=== Monthly dependency check: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
log "    project: $PROJECT_ROOT"
NEEDS_ACTION=0

# ── RepoLens ──────────────────────────────────────────────────────────────────
log ""
log "--- RepoLens (github.com/TheMorpheus407/RepoLens) ---"
LATEST_RL=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/TheMorpheus407/RepoLens/releases/latest" \
    2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name','unknown'))" \
    2>/dev/null || echo "fetch-failed")

INSTALLED_RL="not-installed"
if command -v repolens.sh &>/dev/null; then
    INSTALLED_RL=$(repolens.sh --version 2>/dev/null | head -1 || echo "version-unknown")
fi

log "  Latest release : $LATEST_RL"
log "  Installed      : $INSTALLED_RL"

if [ "$LATEST_RL" = "fetch-failed" ]; then
    log "  STATUS: could not reach GitHub API (network issue?)"
elif [ "$INSTALLED_RL" = "not-installed" ]; then
    log "  STATUS: not installed — latest available is $LATEST_RL"
elif [ "$INSTALLED_RL" = "version-unknown" ]; then
    log "  STATUS: installed but could not determine version (latest: $LATEST_RL)"
elif [ "$LATEST_RL" != "$INSTALLED_RL" ]; then
    log "  STATUS: UPDATE AVAILABLE  $INSTALLED_RL  →  $LATEST_RL"
    NEEDS_ACTION=1
else
    log "  STATUS: up to date"
fi

# ── strata-management ─────────────────────────────────────────────────────────
STRATA_DIR="/home/gagneet/strata-management"
log ""
log "--- strata-management ($STRATA_DIR) ---"
if [ -d "$STRATA_DIR/.git" ]; then
    git -c safe.directory="$STRATA_DIR" -C "$STRATA_DIR" fetch --quiet 2>&1 || true
    BEHIND=$(git -c safe.directory="$STRATA_DIR" -C "$STRATA_DIR" \
        rev-list --count "HEAD..@{u}" 2>/dev/null || echo "unknown")
    LAST_COMMIT=$(git -c safe.directory="$STRATA_DIR" -C "$STRATA_DIR" \
        log -1 --format="%h %s (%ar)" 2>/dev/null || echo "unknown")
    log "  Local HEAD     : $LAST_COMMIT"
    log "  Commits behind : $BEHIND"
    if [ "$BEHIND" != "unknown" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
        log "  STATUS: $BEHIND new commit(s) — run: git -C $STRATA_DIR pull"
        NEEDS_ACTION=1
    else
        log "  STATUS: up to date"
    fi
else
    log "  STATUS: not found or not a git repo — skipping"
fi

# ── k6-performance repo ───────────────────────────────────────────────────────
log ""
log "--- k6-performance ($PROJECT_ROOT) ---"
cd "$PROJECT_ROOT"
git fetch --quiet 2>&1 || true
BEHIND=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git log -1 --format="%h %s (%ar)" 2>/dev/null || echo "unknown")
log "  Local HEAD     : $LAST_COMMIT"
log "  Commits behind : $BEHIND"
if [ "$BEHIND" != "unknown" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
    log "  STATUS: $BEHIND new commit(s) upstream"
    NEEDS_ACTION=1
else
    log "  STATUS: up to date"
fi

# ── summary ───────────────────────────────────────────────────────────────────
log ""
log "--- Summary ---"
log "  Log: $LOG_FILE"
if [ "$NEEDS_ACTION" -eq 1 ]; then
    log "  RESULT: updates available — review log above"
    exit 1
else
    log "  RESULT: all dependencies up to date"
    exit 0
fi
