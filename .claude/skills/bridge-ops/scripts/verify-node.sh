#!/usr/bin/env bash
# Read-only health check for one node's bridge. Verifies the things that have
# actually bitten us: port owner identity, venv interpreter, PPID=1 detachment
# (silent-death prevention), poll forwarder liveness, and log cleanliness.
#
# Usage: verify-node.sh [node]   (default: dev)
set -euo pipefail

NODE="${1:-dev}"
NODE_DIR="$HOME/.claude/telegram/nodes/$NODE"
case "$NODE" in
  dev)  PORT="${PORT:-8270}" ;;
  test) PORT="${PORT:-8295}" ;;
  prod) PORT="${PORT:-8271}" ;;
  *)    PORT="${PORT:?set PORT for custom node}" ;;
esac

FAIL=0
note() { echo "  $1"; }
bad()  { echo "  ✗ $1"; FAIL=1; }

echo "== verify node=$NODE port=$PORT =="

PID="$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
if [[ -z "$PID" ]]; then
  bad "nothing listening on :$PORT"
else
  note "✓ listening: pid=$PID"
  REC="$(cat "$NODE_DIR/bridge.pid" 2>/dev/null || echo '?')"
  [[ "$REC" == "$PID" ]] && note "✓ bridge.pid matches" || bad "bridge.pid says $REC, port owner is $PID"
  CMD="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
  [[ "$CMD" == *".venv/bin/python"* ]] && note "✓ runs from .venv" || bad "unexpected interpreter: $CMD"
  # True detachment = no controlling terminal AND its own session (setsid).
  # PPID flips to 1 only after the launcher shell exits, so PPID alone is a
  # transiently-misleading signal right after a restart.
  read -r PPID_ SID TTY_ <<<"$(ps -o ppid=,sess=,tty= -p "$PID" | awk '{print $1, $2, $3}')"
  if [[ "$TTY_" == "?" && ( "$PPID_" == "1" || "$SID" == "$PID" ) ]]; then
    note "✓ detached (no tty, own session — SIGHUP-immune)"
  else
    bad "attached (ppid=$PPID_ sid=$SID tty=$TTY_) — a host teardown can kill it (the 07:47 death mode); relaunch with restart-node.sh"
  fi
fi

if pgrep -af 'getUpdates' >/dev/null 2>&1; then
  note "✓ poll forwarder alive (NEVER kill it — it is independent and auto-resumes)"
else
  bad "no poll forwarder found (only matters for getUpdates-mode nodes like dev)"
fi

LOG="$NODE_DIR/bridge.log"
if [[ -f "$LOG" ]]; then
  if tail -n 40 "$LOG" | grep -q 'Traceback'; then
    bad "recent Traceback in bridge.log:"
    tail -n 40 "$LOG" | grep -A4 'Traceback' | head -8 | sed 's/^/    /'
  else
    note "✓ no recent traceback in bridge.log"
  fi
  tail -n 40 "$LOG" | grep -q 'Multi-Session Bridge on' \
    && note "✓ startup banner present in recent log" || true
else
  bad "missing $LOG"
fi

exit $FAIL
