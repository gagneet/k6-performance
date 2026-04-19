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
#   findings.md        Accumulated raw findings from all iterations
#   iterations/        Per-iteration AI responses (iteration-001.md, etc.)
#   FINAL_REPORT.md    Deduplicated final audit report (generated last)
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
  validate_bool PREVIEW_ONLY
  validate_bool RUN_PREFLIGHT_AI
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
    echo "# code Audit Preflight"
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

main() {
  validate_settings
  seed_prompt
  build_manifest
  build_tree
  capture_git_context
  write_preflight_files

  local total_files
  total_files="$(wc -l < "$MANIFEST" | tr -d ' ')"

  if [[ "$total_files" -eq 0 ]]; then
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
    exit 0
  fi

  if [[ "$RUN_PREFLIGHT_AI" -eq 1 ]]; then
    if ! run_preflight_ai; then
      die "Preflight AI check failed"
    fi
    log "Preflight AI report: $PREFLIGHT_AI_FILE"
  fi

  run_verify

  # Determine starting iteration from existing completed iterations
  local iteration=0
  while [[ -s "$ITER_DIR/iteration-$(printf '%03d' "$((iteration + 1))").md" ]]; do
    iteration=$((iteration + 1))
  done
  if (( iteration > 0 )); then
    log "Resuming after iteration $iteration ($iteration iterations already complete)"
  fi

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
      exit 1
    fi

    append_iteration_output "$iteration" "$out_file"
    mark_batch_reviewed
  done

  if (( iteration >= MAX_ITERATIONS )); then
    log "Hit MAX_ITERATIONS before finishing review pass."
    exit 1
  fi

  final_synthesis

  log "Done."
  log "Final report: $FINAL_REPORT"
  log "Prompt file:   $PROMPT_FILE"
  log "Findings log:  $MASTER_FINDINGS"
}

main "$@"