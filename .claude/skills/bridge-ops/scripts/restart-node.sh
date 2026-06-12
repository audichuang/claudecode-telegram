#!/usr/bin/env bash
# Safely restart one node's bridge — the codified version of the CLAUDE.md rules:
# PID-file kill (never pkill), setsid detach (the 07:47 silent-death lesson),
# ss-based verification (curl shows 000 during the old bridge's graceful exit),
# and the poll forwarder is NEVER touched (it is an independent PPID-1 process).
#
# Usage: restart-node.sh [node] [--dry-run]
#   node     dev (default) | test | prod ... (prod additionally requires CONFIRM_PROD=1)
#   --dry-run  print what would happen, change nothing
set -euo pipefail

NODE="${1:-dev}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "--dry-run" ]] && NODE="dev"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NODE_DIR="$HOME/.claude/telegram/nodes/$NODE"
ENV_FILE="$HOME/.config/claudecode-telegram/$NODE.env"

# Per-node defaults (override via environment). Ports here reflect ACTUAL
# deployment on this machine, not the script defaults table.
case "$NODE" in
  dev)  PORT="${PORT:-8270}" ;;
  test) PORT="${PORT:-8295}" ;;
  prod) PORT="${PORT:-8271}" ;;
  *)    PORT="${PORT:?set PORT for custom node}" ;;
esac
TMUX_PREFIX="${TMUX_PREFIX:-claude-$NODE-}"
SESSIONS_DIR="${SESSIONS_DIR:-$NODE_DIR/sessions}"
TOPIC_ROOT="${TOPIC_ROOT:-$HOME}"

if [[ "$NODE" == "prod" && "${CONFIRM_PROD:-0}" != "1" ]]; then
  echo "REFUSED: prod restarts are the owner's call. Re-run with CONFIRM_PROD=1." >&2
  exit 2
fi
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (needs TELEGRAM_BOT_TOKEN)" >&2; exit 1; }
[[ -x "$REPO/.venv/bin/python" ]] || { echo "missing $REPO/.venv/bin/python — run 'uv sync' first" >&2; exit 1; }

OLD_PID="$(cat "$NODE_DIR/bridge.pid" 2>/dev/null || true)"
echo "node=$NODE port=$PORT repo=$REPO old_pid=${OLD_PID:-none}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] would: kill -TERM $OLD_PID; setsid relaunch; poll ss for new pid"
  exit 0
fi

# 1. Kill ONLY the recorded PID (graceful — it prints a shutdown banner).
[[ -n "$OLD_PID" ]] && kill -TERM "$OLD_PID" 2>/dev/null || true

# 2. Relaunch fully detached: setsid + </dev/null so no terminal/session
#    teardown can ever SIGHUP/SIGKILL it (PPID must end up 1).
setsid bash -c "
  set -a; source '$ENV_FILE'; set +a  # env files have no 'export' lines — without set -a the token dies at exec
  export TOPIC_ROOT='$TOPIC_ROOT' PORT='$PORT' \
         SESSIONS_DIR='$SESSIONS_DIR' TMUX_PREFIX='$TMUX_PREFIX'
  ${ADMIN_CHAT_ID:+export ADMIN_CHAT_ID='$ADMIN_CHAT_ID'}
  cd '$REPO'
  for i in \$(seq 1 120); do ss -ltn 2>/dev/null | grep -q \":$PORT \" || break; sleep 0.25; done
  exec ./.venv/bin/python -u bridge.py >> '$NODE_DIR/bridge.log' 2>&1
" </dev/null >/dev/null 2>&1 &

# 3. Verify via ss (NOT curl: the old bridge holds the port for tens of
#    seconds while sending shutdown notifications; curl 000 is a false alarm).
for i in $(seq 1 240); do
  NEW_PID="$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  if [[ -n "$NEW_PID" && "$NEW_PID" != "$OLD_PID" ]]; then
    echo "$NEW_PID" > "$NODE_DIR/bridge.pid"
    echo "NEW bridge pid=$NEW_PID (ppid=$(ps -o ppid= -p "$NEW_PID" | tr -d ' '))"
    exec "$(dirname "${BASH_SOURCE[0]}")/verify-node.sh" "$NODE"
  fi
  sleep 0.5
done
echo "TIMEOUT: no new bridge on :$PORT after 120s — check $NODE_DIR/bridge.log" >&2
exit 1
