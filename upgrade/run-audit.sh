#!/usr/bin/env bash
# run-audit.sh — entry point the k6 portal invokes to start a Ralph audit.
#
# This is a thin wrapper around ralph-audit.sh (bundled alongside). It exists
# so the portal has a single, stable interface to invoke — the portal passes
# the target repo as $1 and tunes behaviour through env vars set by the
# FastAPI audit_runner module (AI_CMD, STATE_DIR, MAX_BATCH_BYTES, ...).
#
# Usage (typically invoked by the portal, not humans):
#   STATE_DIR=/data/audits/a-xxx ./run-audit.sh /data/audits/repos/myrepo
#
# All Ralph environment variables work as documented in ralph-audit.sh's own
# help (run: ./ralph-audit.sh --help).

set -Eeuo pipefail

TARGET="${1:?target repo path required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RALPH_SCRIPT="${RALPH_SCRIPT:-$SCRIPT_DIR/ralph-audit.sh}"

if [[ ! -f "$RALPH_SCRIPT" ]]; then
  echo "ralph-audit.sh not found at $RALPH_SCRIPT" >&2
  echo "Either:" >&2
  echo "  - copy your code-audit.sh to $RALPH_SCRIPT, or" >&2
  echo "  - set RALPH_SCRIPT to an absolute path" >&2
  exit 1
fi

if [[ ! -d "$TARGET" ]]; then
  echo "target not a directory: $TARGET" >&2
  exit 1
fi

# STATE_DIR is set by the portal to /data/audits/<audit_id>, so the per-audit
# working state (manifest, iterations, FINAL_REPORT.md) is preserved for
# parsing after the run ends.
export STATE_DIR="${STATE_DIR:-$TARGET/.ralph-audit}"

# Forward everything to ralph-audit.sh. It already supports resume, so if
# the portal retries with the same STATE_DIR the run picks up where it left off.
exec bash "$RALPH_SCRIPT" "$TARGET"
