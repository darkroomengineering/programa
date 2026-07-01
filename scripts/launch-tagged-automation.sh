#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/launch-tagged-automation.sh <tag> [options]

Options:
  --mode <mode>       Socket mode override. Default: automation
  --shell-log <path>  Set GHOSTTY_ZSH_INTEGRATION_LOG for shells in the tagged app.
  --wait-socket <s>   Wait for the tagged socket to appear. Default: 10
  --env KEY=VALUE     Extra environment variable to inject at launch. Repeatable.
  -h, --help          Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TAG=""
MODE="automation"
SHELL_LOG=""
WAIT_SOCKET="10"
EXTRA_ENV=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      if [[ -z "$MODE" ]]; then
        echo "error: --mode requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --env)
      if [[ -z "${2:-}" ]]; then
        echo "error: --env requires KEY=VALUE" >&2
        exit 1
      fi
      EXTRA_ENV+=("${2}")
      shift 2
      ;;
    --shell-log)
      SHELL_LOG="${2:-}"
      if [[ -z "$SHELL_LOG" ]]; then
        echo "error: --shell-log requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    --wait-socket)
      WAIT_SOCKET="${2:-}"
      if [[ -z "$WAIT_SOCKET" ]]; then
        echo "error: --wait-socket requires seconds" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$TAG" ]]; then
        TAG="$1"
        shift
      else
        echo "error: unexpected argument $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: tag is required" >&2
  usage
  exit 1
fi

TAG_ID="$(sanitize_bundle "$TAG")"
TAG_SLUG="$(sanitize_path "$TAG")"
APP="$HOME/Library/Developer/Xcode/DerivedData/programa-${TAG_SLUG}/Build/Products/Debug/Programa DEV ${TAG}.app"
BID="com.darkroom.programa.debug.${TAG_ID}"
SOCK="/tmp/programa-debug-${TAG_SLUG}.sock"
DSOCK="$HOME/Library/Application Support/programa/programad-dev-${TAG_SLUG}.sock"
LOG="/tmp/programa-debug-${TAG_SLUG}.log"

if [[ ! -d "$APP" ]]; then
  echo "error: tagged app not found at $APP" >&2
  exit 1
fi

/usr/bin/osascript -e "tell application id \"${BID}\" to quit" >/dev/null 2>&1 || true
sleep 0.5
pkill -f "Programa DEV ${TAG}.app/Contents/MacOS/Programa DEV" || true
rm -f "$SOCK" "$DSOCK"
sleep 0.5

OPEN_ENV=(
  env
  -u PROGRAMA_SOCKET_PATH
  -u PROGRAMA_SOCKET_MODE
  -u PROGRAMA_TAB_ID
  -u PROGRAMA_PANEL_ID
  -u PROGRAMA_SURFACE_ID
  -u PROGRAMA_WORKSPACE_ID
  -u PROGRAMAD_UNIX_PATH
  -u PROGRAMA_TAG
  -u PROGRAMA_PORT
  -u PROGRAMA_PORT_END
  -u PROGRAMA_PORT_RANGE
  -u PROGRAMA_DEBUG_LOG
  -u PROGRAMA_BUNDLE_ID
  -u PROGRAMA_SHELL_INTEGRATION
  -u PROGRAMA_SHELL_INTEGRATION_DIR
  -u PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
  "PROGRAMA_SOCKET_MODE=${MODE}"
  "PROGRAMA_SOCKET_PATH=${SOCK}"
  "PROGRAMAD_UNIX_PATH=${DSOCK}"
  "PROGRAMA_DEBUG_LOG=${LOG}"
)

for kv in "${EXTRA_ENV[@]}"; do
  OPEN_ENV+=("${kv}")
done
if [[ -n "$SHELL_LOG" ]]; then
  OPEN_ENV+=("GHOSTTY_ZSH_INTEGRATION_LOG=${SHELL_LOG}")
fi

"${OPEN_ENV[@]}" open -g "$APP"

if [[ "$WAIT_SOCKET" != "0" ]]; then
  deadline=$((SECONDS + WAIT_SOCKET))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCK" ]]; then
      break
    fi
    sleep 0.1
  done
fi

echo "app: $APP"
echo "bundle_id: $BID"
echo "socket: $SOCK"
echo "programad_socket: $DSOCK"
echo "log: $LOG"
echo "mode: $MODE"
echo "socket_ready: $(if [[ -S "$SOCK" ]]; then echo yes; else echo no; fi)"
if [[ -n "$SHELL_LOG" ]]; then
  echo "shell_log: $SHELL_LOG"
fi
if [[ "${#EXTRA_ENV[@]}" -gt 0 ]]; then
  echo "extra_env:"
  for kv in "${EXTRA_ENV[@]}"; do
    echo "  $kv"
  done
fi
