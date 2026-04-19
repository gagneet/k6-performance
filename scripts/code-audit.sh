#!/usr/bin/env bash
set -Eeuo pipefail

# code-audit.sh — AI-powered read-only codebase audit loop
#
# Walks an entire repository file-by-file in batches, sends each batch to a
# headless AI CLI for architecture/logic review, accumulates findings, then
# runs a final synthesis pass to produce a deduplicated audit report.
#
# The script is model-agnostic: any CLI that reads stdin and writes to stdout
# works (Claude Code, aider, llm, custom wrappers, etc.).
#
# How it works:
#   1. Discovers all source/config files in the repo (see is_source_or_config).
#   2. Writes a small repo-shape preflight review/prompt for exclusion tuning.
#   3. Optionally runs a one-time verification command (tests, linter, etc.).
#   4. Batches files up to MAX_BATCH_BYTES per iteration.
#   5. For each batch, assembles a prompt (repo tree, git context, verification
#      output, recent findings, and the batch's source code) and pipes it to
#      the AI command via stdin.
#   6. Persists each iteration's output and marks files as reviewed.
#   7. After all files are reviewed, runs a final synthesis pass that merges
#      and deduplicates findings into FINAL_REPORT.md.
#
# State is persisted to disk, so the audit can be interrupted and resumed.
# The prompt file (PROMPT.md) is re-read each iteration, so you can tune it
# mid-run without restarting.
#
# Prerequisites:
#   - bash 4+ (uses associative-array-style features)
#   - An AI CLI tool installed and on PATH (e.g. `claude`, `llm`, `aider`)
#   - Standard POSIX tools: find, sort, wc, nl, tail, head, sed, grep
#
# Quick start:
#   ./code-audit.sh /path/to/repo
#
# Examples:
#   # Use defaults (claude -p --model opus --effort max --tools "" --no-session-persistence)
#   ./code-audit.sh .
#
#   # Use a different AI command
#   AI_CMD='llm -m gpt-4o' ./code-audit.sh /path/to/repo
#
#   # Run pytest before the audit and include its output as context
#   VERIFY_CMD='pytest -q' ./code-audit.sh .
#
#   # Smaller batches for a model with limited context
#   MAX_BATCH_BYTES=30000 ./code-audit.sh .
#
#   # Build manifest/preflight artifacts only; do not run VERIFY_CMD or AI_CMD
#   PREVIEW_ONLY=1 ./code-audit.sh .
#
#   # Add repo-specific exclude globs without editing this script
#   EXTRA_EXCLUDES='.claude/*,deployment/*secret*' ./code-audit.sh .
#
#   # Resume an interrupted audit (just re-run the same command)
#   ./code-audit.sh /path/to/repo   # picks up where it left off
#
# Environment variables:
#   AI_CMD             Command that reads a prompt on stdin, writes response to
#                      stdout. Default: claude -p --model $AI_MODEL --effort $AI_EFFORT
#                      --tools "" --no-session-persistence
#   AI_MODEL           Model alias passed to claude CLI. Default: opus
#   AI_EFFORT          Effort level passed to claude CLI. Default: max
#   VERIFY_CMD         Optional command run once before the audit starts.
#                      Its output is included as context in every iteration.
#                      Example: 'pytest -q', 'make lint', 'cargo test'
#   MAX_ITERATIONS     Hard safety cap on iteration count. Default: 200
#   MAX_BATCH_BYTES    Approx max source bytes per batch/iteration. Default: 90000
#   MAX_FILE_BYTES     Files larger than this are truncated. Default: 18000
#   HEAD_LINES         Lines shown from the start of truncated files. Default: 220
#   TAIL_LINES         Lines shown from the end of truncated files. Default: 140
#   RECENT_FINDINGS_CHARS  Chars of prior findings included as context. Default: 16000
#   AI_RETRIES         Retry count on AI command failure. Default: 3
#   EXTRA_EXCLUDES     Comma-separated shell globs matched against repo-relative
#                      paths after the built-in excludes. Spaces within a single
#                      glob are not supported; use commas to delimit patterns.
#   PREVIEW_ONLY       If 1, write manifest/preflight artifacts and exit before
#                      running VERIFY_CMD or AI_CMD. Default: 0
#   RUN_PREFLIGHT_AI   If 1, run AI_CMD once on PREFLIGHT_PROMPT.md before the
#                      audit. Default: 0
#   STATE_DIR          Where to store audit state. Default: <repo>/.code-audit
#
# v2 feature flags:
#   DIFF_ONLY          If 1, audit only files changed vs BASE_REF. Falls back
#                      to full scan on non-git repos. Default: 0
#   BASE_REF           Reference point for DIFF_ONLY. Default: main
#   COST_ESTIMATE      If 1 (default), print a rough token+cost estimate
#                      before the audit starts. Uses PRICE_IN_PER_MTOK and
#                      PRICE_OUT_PER_MTOK; these are NOT live prices — set
#                      them to your provider's current rates for accuracy.
#   CONFIRM_COST       If 1, require interactive y/N confirmation after the
#                      cost estimate. Requires a TTY. Default: 0
#   PRICE_IN_PER_MTOK  Dollars per million input tokens for the estimate.
#                      Default: 15 (order-of-magnitude for Opus-tier)
#   PRICE_OUT_PER_MTOK Dollars per million output tokens. Default: 75
#   STATIC_ANALYSIS    If 1, run semgrep/ruff/bandit/shellcheck/eslint as
#                      available and include output in iteration context.
#                      Default: 0
#   CHURN_SORT         If 1, order manifest by git churn so frequently-changed
#                      files are audited first. Default: 0
#   CHURN_DAYS         Look-back window in days for CHURN_SORT. Default: 90
#   PROGRESS_JSON      If 1 (default), write $STATE_DIR/progress.json after
#                      each iteration. Portal UIs can poll it for a progress
#                      bar. Default: 1
#
# Output structure (all under STATE_DIR):
#   PROMPT.md          The system prompt sent to the AI (auto-seeded, editable)
#   PREFLIGHT.md       Repo-shape safety review with paths worth checking
#   PREFLIGHT_PROMPT.md  Small prompt for AI-assisted exclusion/prompt tuning
#   PREFLIGHT_AI.md    Optional output from RUN_PREFLIGHT_AI=1
#   manifest.txt       All discovered source/config files
#   reviewed.txt       Files already reviewed (enables resume)
#   tree.txt           Repo file tree (included as context)
#   git.txt            Git status + recent log
#   verify.txt         Output of VERIFY_CMD
#   static.txt         (v2) Output of STATIC_ANALYSIS=1
#   findings.md        Accumulated raw findings from all iterations
#   iterations/        Per-iteration AI responses (iteration-001.md, etc.)
#   FINAL_REPORT.md    Deduplicated final audit report (generated last)
#   FINAL_REPORT.json  (v2) Same findings in structured JSON — consumed by
#                      findings_parser.py without regex on AI markdown
#   findings.json      (v2) All iteration findings merged as JSON
#   metrics.json       (v2) Summary counts for InfluxDB/Grafana push
#   progress.json      (v2) Live progress for portal UI polling
#
# Notes:
#   - This script never edits your code, but it does stream included files to
#     AI_CMD. Inspect PREFLIGHT.md or use PREVIEW_ONLY=1 for sensitive repos.
#   - Tune PROMPT.md mid-run if needed; it is re-read each iteration.
#   - Add .code-audit/ to .gitignore if you don't want to commit state.

show_help() {
  # Print everything between line 4 (first # comment) and the first blank line
  # after the comment block, stripping the leading "# " prefix.
  sed -n '4,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p; }; }' "${BASH_SOURCE[0]}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

AI_EFFORT="${AI_EFFORT:-max}"
AI_MODEL="${AI_MODEL:-opus}"
AI_CMD="${AI_CMD:-claude -p --model $AI_MODEL --effort $AI_EFFORT --tools \"\" --no-session-persistence}"
VERIFY_CMD="${VERIFY_CMD:-}"
MAX_ITERATIONS="${MAX_ITERATIONS:-200}"
MAX_BATCH_BYTES="${MAX_BATCH_BYTES:-90000}"
MAX_FILE_BYTES="${MAX_FILE_BYTES:-18000}"
HEAD_LINES="${HEAD_LINES:-220}"
TAIL_LINES="${TAIL_LINES:-140}"
RECENT_FINDINGS_CHARS="${RECENT_FINDINGS_CHARS:-16000}"
AI_RETRIES="${AI_RETRIES:-3}"
EXTRA_EXCLUDES="${EXTRA_EXCLUDES:-}"
PREVIEW_ONLY="${PREVIEW_ONLY:-0}"
RUN_PREFLIGHT_AI="${RUN_PREFLIGHT_AI:-0}"

# ── v2 additions ─────────────────────────────────────────────────────────────
# Diff-only: scan only files changed relative to BASE_REF. Great for PR audits.
DIFF_ONLY="${DIFF_ONLY:-0}"
BASE_REF="${BASE_REF:-main}"

# Cost estimation: print rough token/cost estimate before the audit starts.
# CONFIRM_COST=1 additionally requires interactive Y/N (skip for CI).
COST_ESTIMATE="${COST_ESTIMATE:-1}"
CONFIRM_COST="${CONFIRM_COST:-0}"
# Rough per-MTok prices used for the estimate. These are user-overridable
# because prices shift — the script never claims they're current. Defaults
# are order-of-magnitude values for awareness, not billing accuracy.
PRICE_IN_PER_MTOK="${PRICE_IN_PER_MTOK:-15}"
PRICE_OUT_PER_MTOK="${PRICE_OUT_PER_MTOK:-75}"

# Static analysis pre-pass: if tools are on PATH, include their output in
# every iteration's context. Opt-in — scans add wallclock time.
STATIC_ANALYSIS="${STATIC_ANALYSIS:-0}"

# Churn sort: prioritize files with recent git activity. Files changed most
# in the last CHURN_DAYS go first in the manifest.
CHURN_SORT="${CHURN_SORT:-0}"
CHURN_DAYS="${CHURN_DAYS:-90}"

# Progress JSON: write $STATE_DIR/progress.json after each iteration so the
# portal UI can show a progress bar without scraping logs.
PROGRESS_JSON="${PROGRESS_JSON:-1}"

STATE_DIR="${STATE_DIR:-$ROOT/.code-audit}"
ITER_DIR="$STATE_DIR/iterations"
PROMPT_FILE="$STATE_DIR/PROMPT.md"
PREFLIGHT_FILE="$STATE_DIR/PREFLIGHT.md"
PREFLIGHT_PROMPT_FILE="$STATE_DIR/PREFLIGHT_PROMPT.md"
PREFLIGHT_AI_FILE="$STATE_DIR/PREFLIGHT_AI.md"
MANIFEST="$STATE_DIR/manifest.txt"
REVIEWED="$STATE_DIR/reviewed.txt"
TREE_FILE="$STATE_DIR/tree.txt"
VERIFY_FILE="$STATE_DIR/verify.txt"
GIT_FILE="$STATE_DIR/git.txt"
MASTER_FINDINGS="$STATE_DIR/findings.md"
FINAL_REPORT="$STATE_DIR/FINAL_REPORT.md"
INPUT_FILE="$STATE_DIR/input.md"
BATCH_FILE="$STATE_DIR/batch.txt"
LOG_FILE="$STATE_DIR/code-audit.log"

# v2 output files
STATIC_FILE="$STATE_DIR/static.txt"
PROGRESS_FILE="$STATE_DIR/progress.json"
METRICS_FILE="$STATE_DIR/metrics.json"
FINDINGS_JSON="$STATE_DIR/findings.json"
FINAL_REPORT_JSON="$STATE_DIR/FINAL_REPORT.json"

mkdir -p "$STATE_DIR" "$ITER_DIR"
touch "$REVIEWED" "$MASTER_FINDINGS"

log() {
  printf '[code-audit %s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2
}

trap 'log "UNEXPECTED EXIT (code=$?, line=$LINENO)"' ERR

die() {
  log "ERROR: $*"
  exit 1
}

validate_positive_int() {
  local name="$1"
  local value="${!name}"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    die "$name must be a positive integer; got '$value'"
  fi
}

validate_bool() {
  local name="$1"
  local value="${!name}"

  case "$value" in
    0|1) ;;
    *) die "$name must be 0 or 1; got '$value'" ;;
  esac
}

validate_settings() {
  validate_positive_int MAX_ITERATIONS
  validate_positive_int MAX_BATCH_BYTES
  validate_positive_int MAX_FILE_BYTES
  validate_positive_int HEAD_LINES
  validate_positive_int TAIL_LINES
  validate_positive_int RECENT_FINDINGS_CHARS
  validate_positive_int AI_RETRIES
  validate_positive_int CHURN_DAYS
  validate_bool PREVIEW_ONLY
  validate_bool RUN_PREFLIGHT_AI
  validate_bool DIFF_ONLY
  validate_bool COST_ESTIMATE
  validate_bool CONFIRM_COST
  validate_bool STATIC_ANALYSIS
  validate_bool CHURN_SORT
  validate_bool PROGRESS_JSON
}

seed_prompt() {
  if [[ -f "$PROMPT_FILE" ]]; then
    return
  fi

  cat > "$PROMPT_FILE" <<'EOF'
You are performing a READ-ONLY architecture and logic audit of a software repository.

Goal:
Find real or likely:
- logic errors
- broken invariants
- inconsistent business rules across files
- state transition bugs
- duplicated-but-diverged logic
- stale abstractions
- hidden couplings / cross-module bleed
- error handling mismatches
- test blind spots that make the above likely to survive

Important:
- Do not suggest cosmetic refactors.
- Do not waste space on naming/style nits.
- Prefer fewer, higher-signal findings.
- Separate CONFIRMED issue vs LIKELY risk vs HYPOTHESIS.
- Always cite file paths and line numbers from the provided snippets.
- Assign confidence: high / medium / low.
- When context is insufficient, explicitly name the next files or symbols to inspect.
- Think in terms of flows crossing file boundaries, not isolated files.

Output format exactly:

# Iteration Summary

## Files Reviewed
- ...

## High-Signal Findings
- [severity: high|medium|low] [type: confirmed|likely-risk|hypothesis] path[:lines] (and any related path[:lines]) — concise issue statement. Why it matters. Confidence: ...

## Cross-File Risks
- ...

## Tests / Checks To Add
- ...

## Next Files / Symbols To Review
- ...

## Short Memory For Next Iteration
- ...

Do not emit the completion marker during batch analysis.
EOF
}

is_excluded_path() {
  local rel="$1"
  if matches_extra_exclude "$rel"; then
    return 0
  fi

  case "$rel" in
    .git/*|.hg/*|.svn/*|node_modules/*|dist/*|build/*|target/*|out/*|coverage/*|vendor/*|third_party/*|\
    .venv/*|venv/*|env/*|.mypy_cache/*|__pycache__/*|.pytest_cache/*|.ruff_cache/*|\
    .next/*|.nuxt/*|.turbo/*|.idea/*|.vscode/*|.claude/*|.codex/*|.cursor/*|\
    .DS_Store|.env|.env.*|.mcp.json|*.pem|*.key|*.p12|*.pfx|*.kdbx|*.age|\
    secrets/*|secret/*|credentials/*|data/*|.code-audit/*|.code-*-audit/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

matches_extra_exclude() {
  local rel="$1"
  local normalized="${EXTRA_EXCLUDES//,/ }"
  local pattern
  local patterns=()

  [[ -n "$normalized" ]] || return 1

  read -r -a patterns <<< "$normalized"
  for pattern in "${patterns[@]}"; do
    [[ -n "$pattern" ]] || continue
    if [[ "$rel" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

find_repo_files() {
  find "$ROOT" \
    \( -type d \( \
      -name .git -o -name .hg -o -name .svn -o -name node_modules -o \
      -name dist -o -name build -o -name target -o -name out -o \
      -name coverage -o -name vendor -o -name third_party -o \
      -name .venv -o -name venv -o -name env -o -name .mypy_cache -o \
      -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache -o \
      -name .next -o -name .nuxt -o -name .turbo -o -name .idea -o \
      -name .vscode -o -name .claude -o -name .codex -o -name .cursor -o \
      -name secrets -o -name secret -o -name credentials -o \
      -name data -o -name '.code-audit' -o -name '.code-*-audit' \
    \) -prune \) -o \
    -type f -print0
}

is_source_or_config() {
  local rel="$1"
  case "$rel" in
    *.py|*.pyi|*.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|\
    *.go|*.rs|*.java|*.kt|*.kts|*.c|*.cc|*.cpp|*.h|*.hpp|\
    *.cs|*.rb|*.php|*.swift|*.scala|*.sh|*.bash|*.zsh|\
    *.sql|*.yaml|*.yml|*.toml|*.json|*.ini|*.cfg|\
    Dockerfile|docker-compose.yml|docker-compose.yaml|Makefile|Taskfile.yml|Taskfile.yaml|\
    pyproject.toml|requirements.txt|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|\
    Cargo.toml|go.mod|go.sum|tsconfig.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_manifest() {
  : > "$MANIFEST"
  while IFS= read -r -d '' abs; do
    local rel="${abs#$ROOT/}"
    if is_excluded_path "$rel"; then
      continue
    fi
    if is_source_or_config "$rel"; then
      printf '%s\n' "$rel" >> "$MANIFEST"
    fi
  done < <(find_repo_files)

  sort -u -o "$MANIFEST" "$MANIFEST"
}

build_tree() {
  : > "$TREE_FILE"
  while IFS= read -r -d '' abs; do
    local rel="${abs#$ROOT/}"
    if is_excluded_path "$rel"; then
      continue
    fi
    if is_source_or_config "$rel"; then
      printf '%s\n' "$rel" >> "$TREE_FILE"
    fi
  done < <(find_repo_files)

  sort -u "$TREE_FILE" > "$TREE_FILE.tmp"
  head -n 800 "$TREE_FILE.tmp" > "$TREE_FILE"
  rm -f "$TREE_FILE.tmp"
}

is_attention_path() {
  local rel="$1"
  local lower="${rel,,}"

  case "$lower" in
    .env|.env.*|*.env|*.env.*|\
    *secret*|*secrets*|*credential*|*credentials*|*password*|*passwd*|\
    *token*|*apikey*|*api-key*|*api_key*|*private*|*.pem|*.key|*.p12|*.pfx|*.kdbx|*.age|\
    deployment/*|deploy/*|ops/*|infra/*|.github/workflows/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_preflight_files() {
  local attention_file="$STATE_DIR/attention-paths.txt"
  local attention_count=0

  : > "$attention_file"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if is_attention_path "$rel"; then
      printf '%s\n' "$rel" >> "$attention_file"
      attention_count=$((attention_count + 1))
    fi
  done < "$MANIFEST"

  {
    echo "# Ralph Audit Preflight"
    echo
    echo "Generated before any VERIFY_CMD or AI_CMD execution."
    echo
    echo "## Summary"
    echo "- Project root: $ROOT"
    echo "- Script path: $SCRIPT_PATH"
    echo "- Manifest file: $MANIFEST"
    echo "- Source/config files selected: $(wc -l < "$MANIFEST" | tr -d ' ')"
    echo "- Paths worth checking before upload: $attention_count"
    echo "- Extra excludes: ${EXTRA_EXCLUDES:-"(none)"}"
    echo
    echo "## Paths Worth Checking"
    if (( attention_count > 0 )); then
      sed 's/^/- /' "$attention_file"
    else
      echo "- (none)"
    fi
    echo
    echo "## How To Adapt"
    echo "- To skip extra paths for this run, set EXTRA_EXCLUDES with comma/space-separated shell globs, for example:"
    echo "  EXTRA_EXCLUDES='.claude/*,deployment/*secret*' ./code-audit.sh ."
    echo "- To tune the review behavior, edit PROMPT.md before or during the audit."
    echo "- To ask an AI for repo-specific tuning advice without sending source contents, review or run PREFLIGHT_PROMPT.md."
    echo
    echo "This is intentionally advisory; the script does not rewrite itself."
  } > "$PREFLIGHT_FILE"

  {
    echo "You are tuning code-audit.sh before it runs an AI code audit over a private repository."
    echo
    echo "Task:"
    echo "- Inspect the audit script and repository manifest below."
    echo "- Identify repo-specific paths that should probably be excluded before source/config contents are sent to AI_CMD."
    echo "- Prefer minimal recommendations: EXTRA_EXCLUDES globs first, script edits only if the default should change for many repos."
    echo "- If you are acting as a code-editing agent, edit only the audit script and do not edit project source."
    echo "- Do not run project scanners, trading scripts, deploy scripts, or tests."
    echo
    echo "Output:"
    echo "1. Recommended EXTRA_EXCLUDES value, if any."
    echo "2. Recommended script changes, if any."
    echo "3. Whether the audit can proceed."
    echo
    echo "# Paths Worth Checking"
    if (( attention_count > 0 )); then
      cat "$attention_file"
    else
      echo "(none)"
    fi
    echo
    echo "# Manifest"
    cat "$MANIFEST"
    echo
    echo "# Audit Script"
    if [[ -f "$SCRIPT_PATH" ]]; then
      cat "$SCRIPT_PATH"
    else
      echo "Script path not readable: $SCRIPT_PATH"
    fi
  } > "$PREFLIGHT_PROMPT_FILE"
}

run_preflight_ai() {
  local err_file="${PREFLIGHT_AI_FILE%.md}.err"

  log "Running preflight AI check: $PREFLIGHT_AI_FILE"

  set +e
  bash -lc "$AI_CMD" < "$PREFLIGHT_PROMPT_FILE" > "$PREFLIGHT_AI_FILE" 2>"$err_file"
  local rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "Preflight AI check failed with exit $rc. See: $err_file"
    tail -20 "$err_file" | sed 's/^/  /' | tee -a "$LOG_FILE" >&2 || true
    return "$rc"
  fi

  if ! grep -q '[^[:space:]]' "$PREFLIGHT_AI_FILE"; then
    log "Preflight AI check produced empty output. See: $PREFLIGHT_AI_FILE"
    return 1
  fi

  rm -f "$err_file"
}

capture_git_context() {
  {
    echo "# Git status"
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$ROOT" status --short || true
      echo
      echo "# Recent log"
      git -C "$ROOT" log --oneline -n 20 || true
    else
      echo "Not a git repository."
    fi
  } > "$GIT_FILE"
}

run_verify() {
  {
    if [[ -z "$VERIFY_CMD" ]]; then
      echo "VERIFY_CMD not set."
      return 0
    fi

    echo "\$ $VERIFY_CMD"
    set +e
    (
      cd "$ROOT"
      bash -lc "$VERIFY_CMD"
    )
    local rc=$?
    set -e
    echo
    echo "[exit_code] $rc"
  } > "$VERIFY_FILE" 2>&1 || true
}

select_batch() {
  : > "$BATCH_FILE"
  local total=0
  local size=0
  local file=""

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if grep -Fxq "$file" "$REVIEWED" 2>/dev/null; then
      continue
    fi

    size="$(wc -c < "$ROOT/$file" 2>/dev/null | tr -d ' ' || echo 0)"

    if [[ -s "$BATCH_FILE" ]] && (( total + size > MAX_BATCH_BYTES )); then
      break
    fi

    printf '%s\n' "$file" >> "$BATCH_FILE"
    total=$((total + size))
  done < "$MANIFEST"

  [[ -s "$BATCH_FILE" ]]
}

render_file_block() {
  local rel="$1"
  local abs="$ROOT/$rel"
  local size=0

  size="$(wc -c < "$abs" 2>/dev/null | tr -d ' ' || echo 0)"

  {
    echo "## FILE: $rel"
    echo
    if (( size <= MAX_FILE_BYTES )); then
      echo '```text'
      nl -ba "$abs"
      echo '```'
    else
      echo "_Truncated. ${size} bytes. Showing first ${HEAD_LINES} and last ${TAIL_LINES} lines._"
      echo
      echo '```text'
      # Avoid SIGPIPE from `head` under `set -o pipefail` on oversized files.
      nl -ba "$abs" | sed -n "1,${HEAD_LINES}p"
      echo '... [middle omitted] ...'
      nl -ba "$abs" | tail -n "$TAIL_LINES"
      echo '```'
    fi
    echo
  } >> "$INPUT_FILE"
}

build_iteration_input() {
  local iteration="$1"
  local total_files reviewed_files remaining_files

  total_files="$(wc -l < "$MANIFEST" | tr -d ' ')"
  reviewed_files="$(wc -l < "$REVIEWED" | tr -d ' ')"
  remaining_files=$(( total_files - reviewed_files ))

  : > "$INPUT_FILE"

  cat "$PROMPT_FILE" >> "$INPUT_FILE"

  {
    echo
    echo "# Run Metadata"
    echo
    echo "- Iteration: $iteration"
    echo "- Project root: $ROOT"
    echo "- Total source/config files discovered: $total_files"
    echo "- Already reviewed: $reviewed_files"
    echo "- Remaining before this batch: $remaining_files"
    echo
    echo "# Repository Tree"
    echo
    cat "$TREE_FILE"
    echo
    echo "# Git Context"
    echo
    cat "$GIT_FILE"
    echo
    echo "# Verification Output"
    echo
    cat "$VERIFY_FILE"
    echo
    # v2: optional static-analysis output as additional context
    if [[ -s "$STATIC_FILE" ]]; then
      echo "# Static Analysis (tool findings — use as hints, verify in source)"
      echo
      cat "$STATIC_FILE"
      echo
    fi
    echo "# Recent Findings"
    echo
    if [[ -s "$MASTER_FINDINGS" ]]; then
      tail -c "$RECENT_FINDINGS_CHARS" "$MASTER_FINDINGS" || true
    else
      echo "(none yet)"
    fi
    echo
    echo "# Current Batch"
    echo
  } >> "$INPUT_FILE"

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    render_file_block "$rel"
  done < "$BATCH_FILE"
}

run_ai_once() {
  local output_file="$1"
  local err_file="${output_file%.md}.err"
  local attempt=0
  local delay=5

  while (( attempt < AI_RETRIES )); do
    attempt=$((attempt + 1))

    set +e
    bash -lc "$AI_CMD" < "$INPUT_FILE" > "$output_file" 2>"$err_file"
    local rc=$?
    set -e

    if [[ "$rc" -eq 0 ]]; then
      if ! grep -q '[^[:space:]]' "$output_file"; then
        log "AI command returned success but produced empty output."
        rc=1
      else
        rm -f "$err_file"
        return 0
      fi
    fi

    log "AI stderr (attempt $attempt/$AI_RETRIES, exit $rc):"
    tail -20 "$err_file" | sed 's/^/  /' | tee -a "$LOG_FILE" >&2

    if (( attempt < AI_RETRIES )); then
      log "Retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    else
      log "AI command failed after $AI_RETRIES attempts. See: $err_file"
      return "$rc"
    fi
  done
}

append_iteration_output() {
  local iteration="$1"
  local output_file="$2"

  {
    echo "# ITERATION $iteration"
    echo
    echo "## Files"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] && echo "- $rel"
    done < "$BATCH_FILE"
    echo
    cat "$output_file"
    echo
    echo "---"
    echo
  } >> "$MASTER_FINDINGS"
}

mark_batch_reviewed() {
  cat "$BATCH_FILE" >> "$REVIEWED"
  sort -u -o "$REVIEWED" "$REVIEWED"
}

final_synthesis() {
  local synth_input="$STATE_DIR/final-input.md"
  local synth_output="$FINAL_REPORT"

  {
    cat "$PROMPT_FILE"
    echo
    echo "# Final Synthesis Task"
    echo
    echo "You have completed the batch review pass over the repository."
    echo
    echo "Now produce a deduplicated final audit report."
    echo
    echo "Requirements:"
    echo "- Merge duplicates across iterations."
    echo "- Prioritize only the highest-signal issues."
    echo "- Group cross-file issues together."
    echo "- Distinguish confirmed issue vs likely risk vs hypothesis."
    echo "- Include the exact file paths and line refs you relied on."
    echo "- Provide a fix order."
    echo "- Provide a test plan."
    echo "- Provide a short list of modules/files that should be manually inspected next."
    echo "- End with a single line exactly: <promise>COMPLETE</promise>"
    echo
    echo "Output format exactly:"
    echo
    echo "# Final Audit Report"
    echo
    echo "## Executive Summary"
    echo "- ..."
    echo
    echo "## Priority Findings"
    echo "- [severity: ...] [type: ...] files... — ..."
    echo
    echo "## Cross-Cutting Failure Modes"
    echo "- ..."
    echo
    echo "## Recommended Fix Order"
    echo "1. ..."
    echo
    echo "## Tests To Add"
    echo "- ..."
    echo
    echo "## Manual Review Targets"
    echo "- ..."
    echo
    echo "## Repo Risk Score"
    echo "- One paragraph."
    echo
    echo "# Repository Tree"
    echo
    cat "$TREE_FILE"
    echo
    echo "# Git Context"
    echo
    cat "$GIT_FILE"
    echo
    echo "# Verification Output"
    echo
    cat "$VERIFY_FILE"
    echo
    echo "# All Iteration Findings"
    echo
    cat "$MASTER_FINDINGS"
  } > "$synth_input"

  local synth_err="${synth_output%.md}.err"

  set +e
  bash -lc "$AI_CMD" < "$synth_input" > "$synth_output" 2>"$synth_err"
  local rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "Final synthesis failed (exit $rc). See: $synth_err"
    tail -20 "$synth_err" | sed 's/^/  /' | tee -a "$LOG_FILE" >&2 || true
    return "$rc"
  fi

  rm -f "$synth_err"

  # The prompt asks the AI to end with this marker so we can detect truncation
  if ! grep -q '<promise>COMPLETE</promise>' "$synth_output"; then
    log "Warning: final synthesis did not emit completion signal (output may be truncated)."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# v2 feature functions
# ═══════════════════════════════════════════════════════════════════════════

# ── Feature 2: diff-only mode ───────────────────────────────────────────────
# Replaces the full manifest with just files changed vs BASE_REF. Silently
# falls back to full scan on non-git repos or if git fails.
apply_diff_only() {
  [[ "$DIFF_ONLY" -ne 1 ]] && return 0

  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "DIFF_ONLY=1 but $ROOT is not a git repo; falling back to full scan"
    return 0
  fi

  # merge-base ... syntax finds the point where BASE_REF diverged from HEAD,
  # then lists files changed on HEAD since then — the standard "PR" diff.
  local tmp="$STATE_DIR/manifest.diff.tmp"
  if ! git -C "$ROOT" diff --name-only --diff-filter=ACMR "${BASE_REF}...HEAD" > "$tmp" 2>/dev/null; then
    log "git diff vs $BASE_REF failed; falling back to full scan"
    rm -f "$tmp"
    return 0
  fi

  # Filter the diff list through our own exclusion rules + source/config test.
  # This way DIFF_ONLY respects EXTRA_EXCLUDES exactly like a full scan.
  local filtered="$STATE_DIR/manifest.diff.filtered"
  : > "$filtered"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    [[ ! -f "$ROOT/$rel" ]] && continue   # deleted/renamed files won't exist
    if is_excluded_path "$rel"; then
      continue
    fi
    if is_source_or_config "$rel"; then
      printf '%s\n' "$rel" >> "$filtered"
    fi
  done < "$tmp"

  local diff_count
  diff_count="$(wc -l < "$filtered" | tr -d ' ')"
  if (( diff_count == 0 )); then
    log "DIFF_ONLY=1: no source/config files changed vs $BASE_REF; nothing to audit"
    # Preserve a marker so main() can bail cleanly
    : > "$MANIFEST"
    rm -f "$tmp" "$filtered"
    return 0
  fi

  # Replace manifest with just the diff
  sort -u "$filtered" > "$MANIFEST"
  rm -f "$tmp" "$filtered"
  log "DIFF_ONLY=1: scanning $diff_count file(s) changed vs $BASE_REF"
}

# ── Feature 5: churn-based sort ─────────────────────────────────────────────
# Re-sorts $MANIFEST so the most-frequently-changed files come first. If the
# audit hits MAX_ITERATIONS mid-run, the most relevant code got reviewed.
apply_churn_sort() {
  [[ "$CHURN_SORT" -ne 1 ]] && return 0

  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "CHURN_SORT=1 but $ROOT is not a git repo; keeping alphabetical order"
    return 0
  fi

  local since="${CHURN_DAYS}.days.ago"
  local churn_file="$STATE_DIR/churn.txt"

  # "git log --name-only --since=..." lists files touched in each commit in
  # the window. sort | uniq -c | sort -rn gives: "<count> <file>" descending.
  # We then map manifest entries to their churn count, sorting manifest by
  # that count (keeping unseen files at churn=0, ordered alphabetically).
  if ! git -C "$ROOT" log --since="$since" --name-only --pretty=format: 2>/dev/null \
      | awk 'NF' | sort | uniq -c | sort -rn > "$churn_file"; then
    log "CHURN_SORT: git log failed; keeping alphabetical order"
    rm -f "$churn_file"
    return 0
  fi

  # Build: "<count> <file>" lookup, then re-score the manifest.
  local scored="$STATE_DIR/manifest.scored"
  awk -v churn="$churn_file" '
    BEGIN {
      while ((getline line < churn) > 0) {
        # "  <count> <path>" — skip leading whitespace, split on first space
        sub(/^[ \t]+/, "", line)
        n = index(line, " ")
        if (n > 0) {
          c = substr(line, 1, n - 1) + 0
          p = substr(line, n + 1)
          score[p] = c
        }
      }
      close(churn)
    }
    { s = (score[$0] ? score[$0] : 0); printf "%010d\t%s\n", s, $0 }
  ' "$MANIFEST" > "$scored"

  # sort -r on the zero-padded count column gives hottest files first; -s
  # keeps alphabetical order within same count (stable-ish behavior).
  sort -k1,1r -k2,2 "$scored" | cut -f2 > "$MANIFEST"
  rm -f "$scored" "$churn_file"
  log "CHURN_SORT=1: manifest re-sorted by git churn over last $CHURN_DAYS days"
}

# ── Feature 3: cost estimation ──────────────────────────────────────────────
# Rough pre-flight: how many tokens will this audit approximately send, and
# what's the order-of-magnitude spend? This is intentionally imprecise. The
# script warns, it doesn't promise.
estimate_cost() {
  [[ "$COST_ESTIMATE" -ne 1 ]] && return 0

  local total_bytes=0
  local file_count=0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ -f "$ROOT/$rel" ]]; then
      local sz
      sz="$(wc -c < "$ROOT/$rel" 2>/dev/null | tr -d ' ' || echo 0)"
      # File truncation cap — same logic MAX_FILE_BYTES enforces at render time
      if (( sz > MAX_FILE_BYTES )); then
        sz="$MAX_FILE_BYTES"
      fi
      total_bytes=$((total_bytes + sz))
      file_count=$((file_count + 1))
    fi
  done < "$MANIFEST"

  # Token heuristic: ~4 bytes per token on English-ish text. Off by 2x for
  # dense code but this is an awareness number, not a bill.
  local input_tokens=$((total_bytes / 4))

  # Each iteration's prompt also includes tree + git + verify + recent
  # findings context (~8KB overhead), AI responses ~2KB average → output
  # tokens scale with iteration count, not batch bytes.
  local iterations=$(( (total_bytes / MAX_BATCH_BYTES) + 1 ))
  local context_overhead=$(( iterations * 2000 ))  # per-iter context tokens
  local output_tokens=$(( iterations * 800 ))       # per-iter response

  local total_in=$(( input_tokens + context_overhead ))

  # Rough dollar estimate. Division by 1000000 using bash arithmetic loses
  # precision — do the math in cents then format.
  local cents_in=$(( (total_in * PRICE_IN_PER_MTOK) / 10000 ))
  local cents_out=$(( (output_tokens * PRICE_OUT_PER_MTOK) / 10000 ))
  local cents_total=$(( cents_in + cents_out ))
  local dollars=$(( cents_total / 100 ))
  local dollar_cents=$(( cents_total % 100 ))

  {
    echo
    echo "──── Cost estimate (rough, not a bill) ────"
    printf "  files:        %d\n" "$file_count"
    printf "  manifest:     %s bytes\n" "$total_bytes"
    printf "  iterations:   ~%d\n" "$iterations"
    printf "  input tokens: ~%d (incl. %d context overhead)\n" "$total_in" "$context_overhead"
    printf "  output tokens:~%d\n" "$output_tokens"
    printf "  est. cost:    \$%d.%02d  (at \$%d/MTok in, \$%d/MTok out)\n" \
      "$dollars" "$dollar_cents" "$PRICE_IN_PER_MTOK" "$PRICE_OUT_PER_MTOK"
    echo "  NOTE: assumes default Opus-tier pricing. Check your provider's"
    echo "        current rates. Real spend varies with retries and context reuse."
    echo "───────────────────────────────────────────"
    echo
  } | tee -a "$LOG_FILE" >&2

  if [[ "$CONFIRM_COST" -eq 1 ]]; then
    if [[ ! -t 0 ]]; then
      log "CONFIRM_COST=1 but stdin is not a TTY; aborting for safety"
      exit 1
    fi
    read -rp "Proceed with audit? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) log "Aborted by user at cost confirmation"; exit 1 ;;
    esac
  fi
}

# ── Feature 4: optional static analysis pre-pass ────────────────────────────
# Runs whichever analyzers are on PATH. Output included in every iteration's
# context so the AI gets more to work with. Additive, not a replacement.
run_static_analysis() {
  [[ "$STATIC_ANALYSIS" -ne 1 ]] && { : > "$STATIC_FILE"; return 0; }

  {
    echo "# Static Analysis Pre-Pass"
    echo "# Run from: $ROOT"
    echo

    local ran_any=0

    if command -v semgrep >/dev/null 2>&1; then
      echo "## semgrep (auto-config)"
      echo
      (cd "$ROOT" && timeout 300 semgrep --config=auto --error --quiet --no-git-ignore 2>&1 | head -400) || true
      echo
      ran_any=1
    fi

    if command -v ruff >/dev/null 2>&1 && find "$ROOT" -name '*.py' -not -path '*/node_modules/*' -print -quit | grep -q .; then
      echo "## ruff check"
      echo
      (cd "$ROOT" && timeout 60 ruff check . 2>&1 | head -200) || true
      echo
      ran_any=1
    fi

    if command -v bandit >/dev/null 2>&1 && find "$ROOT" -name '*.py' -not -path '*/node_modules/*' -print -quit | grep -q .; then
      echo "## bandit (python security)"
      echo
      (cd "$ROOT" && timeout 120 bandit -r . -ll -f txt 2>&1 | head -200) || true
      echo
      ran_any=1
    fi

    if command -v shellcheck >/dev/null 2>&1; then
      local sh_files
      sh_files="$(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -50)"
      if [[ -n "$sh_files" ]]; then
        echo "## shellcheck"
        echo
        # shellcheck handles many files; cap output to 200 lines regardless
        echo "$sh_files" | xargs -r timeout 60 shellcheck 2>&1 | head -200 || true
        echo
        ran_any=1
      fi
    fi

    if command -v eslint >/dev/null 2>&1 && [[ -f "$ROOT/package.json" ]]; then
      echo "## eslint"
      echo
      (cd "$ROOT" && timeout 120 eslint . 2>&1 | head -200) || true
      echo
      ran_any=1
    fi

    if (( ran_any == 0 )); then
      echo "(no static analyzers found on PATH: tried semgrep, ruff, bandit, shellcheck, eslint)"
    fi
  } > "$STATIC_FILE" 2>&1 || true

  local lines
  lines="$(wc -l < "$STATIC_FILE" | tr -d ' ')"
  log "Static analysis: wrote $lines lines to $STATIC_FILE"
}

# ── Feature 6: progress JSON after each iteration ───────────────────────────
# Portal UI polls $PROGRESS_FILE for a progress bar. Also appended to per-run
# log for forensic debugging.
write_progress() {
  [[ "$PROGRESS_JSON" -ne 1 ]] && return 0

  local iteration="$1"
  local total_files="$2"
  local elapsed_s="$3"

  local files_reviewed
  files_reviewed="$(wc -l < "$REVIEWED" 2>/dev/null | tr -d ' ' || echo 0)"

  # Count findings-so-far cheaply: grep the master findings for our bracket
  # pattern. Matches findings_parser.py's _FINDING_RE (kept in sync manually).
  local findings_so_far=0
  if [[ -s "$MASTER_FINDINGS" ]]; then
    findings_so_far="$(grep -cE '^\s*[-*]\s*\[\s*severity' "$MASTER_FINDINGS" 2>/dev/null || echo 0)"
  fi

  local pct=0
  if (( total_files > 0 )); then
    pct=$(( files_reviewed * 100 / total_files ))
  fi

  # Write atomically via temp+rename so UI never reads a half-written JSON.
  local tmp="$PROGRESS_FILE.tmp"
  cat > "$tmp" <<EOF
{
  "iteration": $iteration,
  "files_reviewed": $files_reviewed,
  "files_total": $total_files,
  "percent": $pct,
  "findings_so_far": $findings_so_far,
  "elapsed_s": $elapsed_s,
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  mv "$tmp" "$PROGRESS_FILE"
}

# ── Feature 1: structured findings extractor ────────────────────────────────
# Parses iteration files + FINAL_REPORT.md into findings.json. Uses the same
# regex findings_parser.py uses, so Python and bash parsers stay in lockstep.
# This is NOT a second AI call — it's pure text extraction.
extract_findings_json() {
  # Works against any file containing markdown bullets matching:
  #   - [severity: X] [type: Y] path:lines — message. Confidence: Z
  # Emits a JSON array of objects. No jq dependency — we escape manually.

  local src="$1"
  local out="$2"

  if [[ ! -s "$src" ]]; then
    echo '[]' > "$out"
    return 0
  fi

  awk -v OUT="$out" '
    function json_escape(s,    r) {
      r = s
      gsub(/\\/, "\\\\", r)
      gsub(/"/,  "\\\"", r)
      gsub(/\t/, "\\t",  r)
      gsub(/\r/, "",     r)
      gsub(/\n/, "\\n",  r)
      # Strip other control chars that would make invalid JSON
      gsub(/[\001-\010\013\014\016-\037]/, "", r)
      return r
    }
    function extract_path(body,   m, path, lines) {
      # Match first "path[.ext][:lines]" token
      if (match(body, /[A-Za-z0-9_./-]+\.[A-Za-z0-9]+(:[0-9]+(-[0-9]+)?)?/)) {
        tok = substr(body, RSTART, RLENGTH)
        colon = index(tok, ":")
        if (colon > 0) {
          PATH = substr(tok, 1, colon - 1)
          LINES = substr(tok, colon + 1)
        } else {
          PATH = tok
          LINES = ""
        }
        return 1
      }
      PATH = ""; LINES = ""
      return 0
    }
    function extract_conf(body,    m) {
      CONF = "medium"
      if (match(body, /[Cc]onfidence[[:space:]]*[:=][[:space:]]*(high|medium|low)/)) {
        tok = substr(body, RSTART, RLENGTH)
        sub(/.*[:=][[:space:]]*/, "", tok)
        CONF = tolower(tok)
      }
    }
    BEGIN {
      print "[" > OUT
      first = 1
      section = ""
    }
    /^## / {
      section = $0
      sub(/^## /, "", section)
      next
    }
    # Match the structured finding line
    /^[[:space:]]*[-*][[:space:]]*\[[[:space:]]*severity[[:space:]]*[:=]/ {
      line = $0
      # Extract severity + type via sequential matches
      if (!match(line, /\[[[:space:]]*severity[[:space:]]*[:=][[:space:]]*[a-z-]+[[:space:]]*\]/)) next
      sev_tok = substr(line, RSTART, RLENGTH)
      sub(/.*[:=][[:space:]]*/, "", sev_tok); sub(/[[:space:]]*\].*/, "", sev_tok)
      SEV = tolower(sev_tok)

      rest = substr(line, RSTART + RLENGTH)
      if (!match(rest, /\[[[:space:]]*type[[:space:]]*[:=][[:space:]]*[a-z-]+[[:space:]]*\]/)) next
      typ_tok = substr(rest, RSTART, RLENGTH)
      sub(/.*[:=][[:space:]]*/, "", typ_tok); sub(/[[:space:]]*\].*/, "", typ_tok)
      TYP = tolower(typ_tok)

      body = substr(rest, RSTART + RLENGTH)
      sub(/^[[:space:]]+/, "", body)

      extract_path(body)
      extract_conf(body)

      # Message: split on em-dash / en-dash / " - ", strip confidence tail
      msg = body
      if (match(msg, /[[:space:]]+[—–-]+[[:space:]]+/)) {
        msg = substr(msg, RSTART + RLENGTH)
      }
      sub(/[[:space:]]*[Cc]onfidence[[:space:]]*[:=].*$/, "", msg)
      sub(/[[:space:]]+$/, "", msg)

      if (!first) print "," > OUT
      first = 0
      printf "{\"severity\":\"%s\",\"finding_type\":\"%s\",\"file\":\"%s\",\"line_range\":\"%s\",\"message\":\"%s\",\"confidence\":\"%s\",\"source_section\":\"%s\"}",
        json_escape(SEV),
        json_escape(TYP),
        json_escape(PATH),
        json_escape(LINES),
        json_escape(msg),
        json_escape(CONF),
        json_escape(section) > OUT
    }
    END { print "" > OUT; print "]" > OUT }
  ' "$src"
}

# ── Feature 1 (continued) + metrics emitter ─────────────────────────────────
# Called at the end of main(). Writes:
#   findings.json        — all iteration findings merged
#   FINAL_REPORT.json    — findings from FINAL_REPORT.md only
#   metrics.json         — summary counts suitable for InfluxDB push
write_final_json() {
  extract_findings_json "$MASTER_FINDINGS" "$FINDINGS_JSON"
  extract_findings_json "$FINAL_REPORT" "$FINAL_REPORT_JSON"

  # Counts from findings.json using grep patterns — cheap and portable.
  # Each count MUST tolerate zero matches (grep exits 1) under set -o pipefail,
  # so we wrap with `|| echo 0` before wc. Without this, an audit with no
  # info-severity findings kills the script at the count step.
  local total high medium low info
  total="$( { grep -o '"severity":' "$FINDINGS_JSON" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  high="$( { grep -o '"severity":"high"' "$FINDINGS_JSON" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  medium="$( { grep -o '"severity":"medium"' "$FINDINGS_JSON" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  low="$( { grep -o '"severity":"low"' "$FINDINGS_JSON" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  info="$( { grep -o '"severity":"info"' "$FINDINGS_JSON" 2>/dev/null || true; } | wc -l | tr -d ' ')"

  local files_scanned iterations_done
  files_scanned="$(wc -l < "$MANIFEST" 2>/dev/null | tr -d ' ' || echo 0)"
  iterations_done="$(find "$ITER_DIR" -name 'iteration-*.md' -not -empty 2>/dev/null | wc -l | tr -d ' ')"

  local commit_sha="none"
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    commit_sha="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo none)"
  fi

  cat > "$METRICS_FILE" <<EOF
{
  "schema": "code-audit/v2",
  "total": $total,
  "high": $high,
  "medium": $medium,
  "low": $low,
  "info": $info,
  "files_scanned": $files_scanned,
  "iterations": $iterations_done,
  "diff_only": $DIFF_ONLY,
  "static_analysis": $STATIC_ANALYSIS,
  "commit_sha": "$commit_sha",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  log "Wrote $FINDINGS_JSON ($total findings)"
  log "Wrote $FINAL_REPORT_JSON"
  log "Wrote $METRICS_FILE (high=$high medium=$medium low=$low)"
}

main() {
  validate_settings
  seed_prompt
  build_manifest

  # v2: diff-only filter + churn sort (order matters — diff first, then sort
  # what's left so changed files still come in churn order)
  apply_diff_only
  apply_churn_sort

  build_tree
  capture_git_context
  write_preflight_files

  local total_files
  total_files="$(wc -l < "$MANIFEST" | tr -d ' ')"

  if [[ "$total_files" -eq 0 ]]; then
    if [[ "$DIFF_ONLY" -eq 1 ]]; then
      log "DIFF_ONLY=1: no source/config files changed vs $BASE_REF. Exiting cleanly."
      # Write empty metrics so the portal can render "no findings" instead of erroring
      write_final_json
      exit 0
    fi
    log "No source/config files found."
    exit 1
  fi

  log "Project root: $ROOT"
  log "Discovered files: $total_files"
  log "State dir: $STATE_DIR"
  log "AI_CMD: $AI_CMD"
  log "Preflight: $PREFLIGHT_FILE"

  if [[ "$PREVIEW_ONLY" -eq 1 ]]; then
    log "PREVIEW_ONLY=1, exiting before VERIFY_CMD or AI_CMD."
    # Even in preview mode, cost estimate and metrics are useful
    estimate_cost
    exit 0
  fi

  # v2: cost estimate before committing to AI spend
  estimate_cost

  if [[ "$RUN_PREFLIGHT_AI" -eq 1 ]]; then
    if ! run_preflight_ai; then
      die "Preflight AI check failed"
    fi
    log "Preflight AI report: $PREFLIGHT_AI_FILE"
  fi

  run_verify

  # v2: optional static analysis pre-pass; output becomes iteration context
  run_static_analysis

  # Determine starting iteration from existing completed iterations
  local iteration=0
  while [[ -s "$ITER_DIR/iteration-$(printf '%03d' "$((iteration + 1))").md" ]]; do
    iteration=$((iteration + 1))
  done
  if (( iteration > 0 )); then
    log "Resuming after iteration $iteration ($iteration iterations already complete)"
  fi

  # v2: track elapsed time for progress JSON
  local t_start
  t_start="$(date +%s)"

  while (( iteration < MAX_ITERATIONS )); do
    if ! select_batch; then
      break
    fi

    iteration=$((iteration + 1))
    local out_file="$ITER_DIR/iteration-$(printf '%03d' "$iteration").md"

    log "Iteration $iteration"
    log "Batch files:"
    sed 's/^/  - /' "$BATCH_FILE" | tee -a "$LOG_FILE"

    build_iteration_input "$iteration"

    if ! run_ai_once "$out_file"; then
      log "AI command failed on iteration $iteration. See: $out_file"
      # Remove partial output so resume retries this batch
      rm -f "$out_file"
      # v2: still write progress + metrics so portal can display partial data
      write_progress "$iteration" "$total_files" "$(( $(date +%s) - t_start ))"
      write_final_json
      exit 1
    fi

    append_iteration_output "$iteration" "$out_file"
    mark_batch_reviewed

    # v2: progress JSON for the portal UI
    write_progress "$iteration" "$total_files" "$(( $(date +%s) - t_start ))"
  done

  if (( iteration >= MAX_ITERATIONS )); then
    log "Hit MAX_ITERATIONS before finishing review pass."
    # v2: still emit structured output for partial data
    write_final_json
    exit 1
  fi

  final_synthesis

  # v2: final structured outputs — this is what findings_parser.py and
  # influx_writer.py will read via the portal.
  write_final_json

  log "Done."
  log "Final report:       $FINAL_REPORT"
  log "Final JSON:         $FINAL_REPORT_JSON"
  log "All findings JSON:  $FINDINGS_JSON"
  log "Metrics (Grafana):  $METRICS_FILE"
  log "Prompt file:        $PROMPT_FILE"
  log "Findings log:       $MASTER_FINDINGS"
}

main "$@"