#!/usr/bin/env bash
# deploy.sh — build and deploy the k6 Performance Portal stack.
#
# Usage:
#   ./deploy.sh            # normal deploy (build + start)
#   ./deploy.sh --clean    # destroy volumes first, then deploy (fresh state)
#   ./deploy.sh --no-build # skip image rebuild (use cached images)
#   ./deploy.sh --help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

info()    { echo -e "${CYAN}[deploy]${RESET} $*"; }
success() { echo -e "${GREEN}[deploy]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${RESET} $*"; }
die()     { echo -e "${RED}[deploy] ERROR:${RESET} $*" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────
DO_CLEAN=false
DO_BUILD=true

for arg in "$@"; do
  case "$arg" in
    --clean)    DO_CLEAN=true ;;
    --no-build) DO_BUILD=false ;;
    --help|-h)
      cat <<EOF
Usage: ./deploy.sh [OPTIONS]

Options:
  --clean     Tear down existing containers and volumes before deploying
              (destroys all stored metrics and run history)
  --no-build  Skip rebuilding the portal Docker image
  --help      Show this help

Services started:
  portal   → http://localhost:8000
  grafana  → http://localhost:3100  (admin / admin)
  influxdb → http://localhost:8086
EOF
      exit 0
      ;;
    *) die "Unknown argument: $arg. Run with --help for usage." ;;
  esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"

# Support both 'docker compose' (v2) and 'docker-compose' (v1)
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "Neither 'docker compose' (v2) nor 'docker-compose' (v1) found"
fi

docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker and retry."

success "Docker OK (using: $DC)"

# ── Port availability checks ─────────────────────────────────────────────────
check_port() {
  local port=$1 service=$2
  if ss -tlnH "sport = :$port" 2>/dev/null | grep -q ":$port" ||
     lsof -i ":$port" -sTCP:LISTEN -t >/dev/null 2>/dev/null; then
    # Allow if it's already one of our own containers
    if ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:$port->"; then
      warn "Port $port is in use by another process (needed for $service). This may cause conflicts."
    fi
  fi
}

check_port 8000 "portal"
check_port 3100 "grafana"
check_port 8086 "influxdb"

# ── Optional: load .env if present ──────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  info "Loading .env..."
  # Export only KEY=VALUE lines; skip comments and blanks
  set -o allexport
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +o allexport
fi

# Warn if API keys look absent (non-fatal — container env defaults to empty)
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  warn "ANTHROPIC_API_KEY is not set — Claude-based audits will not work."
fi

# ── Clean (optional) ─────────────────────────────────────────────────────────
if [[ "$DO_CLEAN" == true ]]; then
  warn "--clean specified: removing existing containers and volumes..."
  $DC down -v --remove-orphans
  success "Volumes cleared."
fi

# ── Build ────────────────────────────────────────────────────────────────────
if [[ "$DO_BUILD" == true ]]; then
  info "Building portal image..."
  $DC build portal
  success "Build complete."
else
  info "Skipping build (--no-build)."
fi

# ── Start ────────────────────────────────────────────────────────────────────
info "Starting all services..."
$DC up -d
success "Containers started."

# ── Health checks ────────────────────────────────────────────────────────────
wait_healthy() {
  local container=$1 max_wait=${2:-60} elapsed=0
  info "Waiting for $container to become healthy..."
  while true; do
    status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    case "$status" in
      healthy) success "$container is healthy."; return 0 ;;
      missing) warn "$container not found — skipping health check."; return 0 ;;
    esac
    if (( elapsed >= max_wait )); then
      warn "$container did not become healthy within ${max_wait}s (status: $status). Check: docker logs $container"
      return 1
    fi
    sleep 3; (( elapsed += 3 ))
  done
}

wait_for_http() {
  local url=$1 label=$2 max_wait=${3:-45} elapsed=0
  info "Waiting for $label at $url..."
  while ! curl -sf "$url" -o /dev/null 2>/dev/null; do
    if (( elapsed >= max_wait )); then
      warn "$label did not respond at $url within ${max_wait}s. Check logs."
      return 1
    fi
    sleep 3; (( elapsed += 3 ))
  done
  success "$label is up."
}

wait_healthy "k6-influxdb" 60
wait_for_http "http://localhost:8086/ping"  "InfluxDB" 60
wait_for_http "http://localhost:8000/api/scripts" "Portal"  60
wait_for_http "http://localhost:3100/api/health" "Grafana" 60

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
success "Stack is live:"
echo -e "  ${GREEN}Portal${RESET}   → http://localhost:8000"
echo -e "  ${GREEN}Grafana${RESET}  → http://localhost:3100  (admin / admin)"
echo -e "  ${GREEN}InfluxDB${RESET} → http://localhost:8086"
echo ""
info "Tail logs:  make logs"
info "Stop stack: make down"
info "Full reset: ./deploy.sh --clean"
