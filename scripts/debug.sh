#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { printf "${GREEN}==>${NC} %s\n" "$*"; }
log_cmd()   { printf "${CYAN}-->${NC} %s\n" "$*"; }
log_error() { printf "${RED}==>${NC} %s\n" "$*" >&2; }

# Default: subsystem-filtered logs. Use --all for process-level.
PREDICATE="subsystem BEGINSWITH \"podcasts.\""
LOG_LEVEL="debug"
STYLE="compact"
COLOR="always"

usage() {
    echo "Usage: $0 [--all] [--level <level>] [--no-color]"
    echo ""
    echo "  --all        Log entire process (log stream --process podcasts)"
    echo "  --level      Log level (default: debug)"
    echo "  --no-color   Disable ANSI colors"
    echo "  -h, --help   Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            PREDICATE=""
            PROCESS_FILTER="--process podcasts"
            ;;
        --level)
            LOG_LEVEL="$2"
            shift
            ;;
        --no-color)
            COLOR="none"
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# ── Build ───────────────────────────────────────────────────────────
log_info "Building for iOS Simulator..."
cd "$PROJECT_DIR"
make build_mac

# ── Boot simulator ──────────────────────────────────────────────────
SIMULATOR_NAME=$(xcrun simctl list devices available \
    | grep "iPhone" \
    | tail -1 \
    | sed 's/^[[:space:]]*//' \
    | sed 's/ (.*)//')

log_info "Booting simulator: $SIMULATOR_NAME"
xcrun simctl boot "$SIMULATOR_NAME" 2>/dev/null || true

# Wait for simulator to be ready
log_info "Waiting for simulator..."
until xcrun simctl list devices booted | grep -q "$SIMULATOR_NAME"; do
    sleep 1
done

# ── Install app ─────────────────────────────────────────────────────
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
    -name podcasts.app \
    -path '*/Debug-iphonesimulator/*' \
    -maxdepth 5 2>/dev/null \
    | head -1)

if [ -z "$APP_PATH" ]; then
    log_error "Could not find podcasts.app in DerivedData"
    exit 1
fi

log_info "Installing: $APP_PATH"
xcrun simctl install booted "$APP_PATH"

# ── Launch app ──────────────────────────────────────────────────────
log_info "Launching fm.auris..."
xcrun simctl launch booted fm.auris > /dev/null

sleep 1

# ── Stream logs ─────────────────────────────────────────────────────
if [ -z "$PREDICATE" ]; then
    log_cmd "log stream --process podcasts --level $LOG_LEVEL --style $STYLE --color $COLOR"
    log_info "Streaming all process logs (Ctrl-C to stop)..."
    echo ""
    log stream --process podcasts --level "$LOG_LEVEL" --style "$STYLE" --color "$COLOR"
else
    log_cmd "log stream --predicate 'subsystem BEGINSWITH \"podcasts.\"' --level $LOG_LEVEL --style $STYLE --color $COLOR"
    log_info "Streaming app subsystem logs (Ctrl-C to stop)..."
    echo ""
    log stream --predicate "$PREDICATE" --level "$LOG_LEVEL" --style "$STYLE" --color "$COLOR"
fi
