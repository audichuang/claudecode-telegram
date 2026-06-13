#!/usr/bin/env bash
# Start the getUpdates poll forwarder for one node, fully detached (PPID=1).
# This is the delivery path for getUpdates-mode nodes (dev): it long-polls
# Telegram and POSTs each update to the local bridge. It is INDEPENDENT of the
# bridge — restart-node.sh never touches it, and it survives bridge restarts.
#
# Usage: poll-forwarder.sh [node]   (default: dev)
# Idempotent: refuses to start a second forwarder for the same bot.
set -euo pipefail

NODE="${1:-dev}"
NODE_DIR="$HOME/.claude/telegram/nodes/$NODE"
ENV_FILE="$HOME/.config/claudecode-telegram/$NODE.env"
case "$NODE" in
  dev)  PORT="${PORT:-8270}" ;;
  test) PORT="${PORT:-8295}" ;;
  prod) PORT="${PORT:-8271}" ;;
  *)    PORT="${PORT:?set PORT for custom node}" ;;
esac

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PY="$REPO/.venv/bin/python"; [[ -x "$PY" ]] || PY="python3"

# Known un-automated guard gap: pgrep -af is GNU-specific. The forwarder guard
# is still covered on the Linux nodes where this script currently runs.
if pgrep -af "getUpdates.*localhost:$PORT" >/dev/null 2>&1; then
  echo "poll forwarder for :$PORT already running — not starting a second one"
  exit 0
fi

# Telegram API base is overridable so tests can point at a fake server.
API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

# getUpdates conflicts with an active webhook — clear it first.
set -a; source "$ENV_FILE"; set +a
curl -s --max-time 10 "$API_BASE/bot$TELEGRAM_BOT_TOKEN/deleteWebhook" >/dev/null || true

setsid bash -c "
  set -a; source '$ENV_FILE'; set +a
  export TELEGRAM_API_BASE='$API_BASE'
  exec '$PY' -u -c '
import os, time, json, urllib.request
token = os.environ[\"TELEGRAM_BOT_TOKEN\"]
api_base = os.environ.get(\"TELEGRAM_API_BASE\", \"https://api.telegram.org\")
bridge = \"http://localhost:$PORT\"  # getUpdates -> localhost:$PORT forwarder
offset = 0
print(\"Poll forwarder started (bridge=\" + bridge + \")\", flush=True)
while True:
    try:
        url = f\"{api_base}/bot{token}/getUpdates?offset={offset}&timeout=30\"
        with urllib.request.urlopen(urllib.request.Request(url), timeout=35) as resp:
            data = json.loads(resp.read())
        if not data.get(\"ok\"):
            time.sleep(1)
            continue
        # Forward each update IN ORDER. Only advance the offset past an update
        # AFTER the bridge has accepted it — a failed POST must NOT lose the
        # update. On failure we sleep and re-poll the SAME offset (natural
        # redelivery), so the update is retried until it lands.
        for update in data.get(\"result\", []):
            uid = update[\"update_id\"]
            try:
                req = urllib.request.Request(
                    bridge + \"/\", data=json.dumps(update).encode(),
                    headers={\"Content-Type\": \"application/json\"}, method=\"POST\")
                urllib.request.urlopen(req, timeout=5)
            except Exception as e:
                print(f\"Forward failed {uid}: {e} — will retry same offset\", flush=True)
                break  # do NOT advance offset; re-poll this update next loop
            offset = uid + 1  # only reached on a successful POST
        else:
            # for-else: ran to completion with no break (all delivered, or
            # empty batch). Nothing to do; loop polls the advanced offset.
            continue
        # We broke out on a failed POST — back off briefly, then re-poll.
        time.sleep(1)
    except Exception as e:
        print(f\"Poll error: {e}\", flush=True)
        time.sleep(2)
' >> '$NODE_DIR/poll-fallback.log' 2>&1
" </dev/null >/dev/null 2>&1 &

sleep 2
PID="$(pgrep -f "getUpdates.*localhost:$PORT" | head -1 || true)"
if [[ -n "$PID" ]]; then
  echo "$PID" > "$NODE_DIR/poller.pid"
  echo "poll forwarder pid=$PID (ppid=$(ps -o ppid= -p "$PID" | tr -d ' ')) log=$NODE_DIR/poll-fallback.log"
else
  echo "FAILED to start poll forwarder — check $NODE_DIR/poll-fallback.log" >&2
  exit 1
fi
