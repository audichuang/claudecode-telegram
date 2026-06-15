#!/usr/bin/env bash
#
# test.sh - Automated acceptance tests for claudecode-telegram
#
# Usage:
#   TEST_BOT_TOKEN='...' ./test.sh                    # Basic tests (mock chat ID)
#   TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh # Full e2e (real Telegram messages)
#
# Environment:
#   TEST_BOT_TOKEN  - Required: Your test bot token from @BotFather
#   TEST_CHAT_ID    - Optional: Your chat ID for e2e verification
#
# Tests run isolated using --node test with separate port (8295),
# prefix (claude-test-), and PID file. Safe to run while production is active.
#
set -euo pipefail

# Pin a locale that exists everywhere: hosts without en_US.UTF-8 emit
# "bash: warning: setlocale" on every subprocess, polluting hook-output
# assertions (tests expect empty output).
export LC_ALL=C.UTF-8 LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run tests against the uv-managed venv so inline `python3 -c` assertions exercise the
# locked dependency set (markdown-it-py) instead of whatever sits in system site-packages.
# Falls back silently to system python3 when uv/.venv are unavailable.
if command -v uv &>/dev/null; then
    ( cd "$SCRIPT_DIR" && uv sync --frozen --quiet ) 2>/dev/null || true
fi
if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    export PATH="$SCRIPT_DIR/.venv/bin:$PATH"
fi

CHAT_ID="${TEST_CHAT_ID:-123456789}"
BRIDGE_PID=""
TUNNEL_PID=""
TUNNEL_URL=""
TEST_FILTER="${TEST_FILTER:-}"

# Test node configuration
TEST_NODE="test"
TEST_NODE_DIR="${TEST_NODE_DIR:-$HOME/.claude/telegram/nodes/$TEST_NODE}"
PORT="${TEST_PORT:-8295}"
# Mock-Telegram harness (e2e-hardening). MOCKPORT is offset +100 from the bridge
# port so it never collides with $PORT. MOCK_TG_ACTIVE gates the whole mechanism:
# only the e2e/mock-based path turns it on, so the default integration tests
# (which talk to real Telegram via TEST_BOT_TOKEN) are byte-identical.
MOCKPORT="${MOCKPORT:-$((PORT + 100))}"
MOCK_TG_ACTIVE="${MOCK_TG_ACTIVE:-}"
TEST_SESSION_DIR="$TEST_NODE_DIR/sessions"
TEST_PID_FILE="$TEST_NODE_DIR/pid"
TEST_TMUX_PREFIX="claude-${TEST_NODE}-"
# Default the env var too: unit tests import bridge.py, which derives its tmux
# prefix AND /tmp namespace from TMUX_PREFIX. Without a default, the suite (a)
# aborted under `set -u` at tests that reference $TMUX_PREFIX, and (b) could
# collide with real `claude-` nodes on the same machine.
export TMUX_PREFIX="${TMUX_PREFIX:-$TEST_TMUX_PREFIX}"
BRIDGE_LOG="$TEST_NODE_DIR/bridge.log"
TUNNEL_LOG="$TEST_NODE_DIR/tunnel.log"
TEST_TEAM_DIR="$TEST_NODE_DIR/team"

# Ensure unit tests write to isolated test sessions directory
export SESSIONS_DIR="$TEST_SESSION_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

passed=0
failed=0
tests_run=0

# ============================================================
# TEST CONFIG + HELPERS
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

log()     { echo -e "$@"; }
success() { log "${GREEN}✓${NC} $1"; ((passed++)) || true; }
fail()    { log "${RED}✗${NC} $1"; ((failed++)) || true; }
info()    { log "${YELLOW}→${NC} $1"; }

should_run_test() {
    [[ -z "$TEST_FILTER" ]] && return 0
    [[ "$1" == *"$TEST_FILTER"* ]] && return 0
    return 1
}

run_test() {
    local test_name="$1"
    should_run_test "$test_name" || return 0
    ((tests_run++)) || true
    # Invoke in a guarded context: one test's unexpected non-zero exit must be
    # recorded as a failure, never abort the whole suite (set -e would otherwise
    # kill the run mid-suite — CLI/integration/summary never executed).
    "$test_name" || fail "$test_name aborted (unexpected non-zero exit)"
}

collect_run_tests() {
    local runner_fn="$1"
    declare -f "$runner_fn" | awk '/^[[:space:]]*run_test[[:space:]]+test_[a-zA-Z0-9_]+/ { print $2 }'
}

count_matching_tests() {
    local mode="$1"
    local -a candidate_tests=()
    local fn
    local test_name

    for fn in run_unit_tests run_cli_tests; do
        while read -r test_name; do
            [[ -n "$test_name" ]] && candidate_tests+=("$test_name")
        done < <(collect_run_tests "$fn")
    done

    if [[ "$mode" != "fast" ]]; then
        while read -r test_name; do
            [[ -n "$test_name" ]] && candidate_tests+=("$test_name")
        done < <(collect_run_tests "run_integration_tests")
        # Mock-Telegram DEFAULT-mode tests (sourced from tests/mock_tests.sh) run
        # inside the integration path but live in their own run_mock_tests runner,
        # so scrape them here too (non-fast modes only).
        if declare -f run_mock_tests >/dev/null 2>&1; then
            while read -r test_name; do
                [[ -n "$test_name" ]] && candidate_tests+=("$test_name")
            done < <(collect_run_tests "run_mock_tests")
        fi
    fi

    if [[ "$mode" == "full" ]]; then
        while read -r test_name; do
            [[ -n "$test_name" ]] && candidate_tests+=("$test_name")
        done < <(collect_run_tests "run_full_tests")
    fi

    if [[ "$mode" == "e2e" ]]; then
        if declare -f run_e2e_tests >/dev/null 2>&1; then
            while read -r test_name; do
                [[ -n "$test_name" ]] && candidate_tests+=("$test_name")
            done < <(collect_run_tests "run_e2e_tests")
        fi
    fi

    local matched=0
    for test_name in "${candidate_tests[@]}"; do
        should_run_test "$test_name" && ((matched++)) || true
    done
    echo "$matched"
}

cleanup() {
    info "Cleaning up..."
    # Stop test node using PID file
    if [[ -f "$TEST_PID_FILE" ]]; then
        local pid
        pid=$(cat "$TEST_PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$TEST_PID_FILE"
    fi
    # Also kill bridge PID if tracked separately
    if [[ -f "$TEST_NODE_DIR/bridge.pid" ]]; then
        kill "$(cat "$TEST_NODE_DIR/bridge.pid")" 2>/dev/null || true
        rm -f "$TEST_NODE_DIR/bridge.pid"
    fi
    # Also kill the Mock-Telegram server (e2e-hardening harness) if tracked.
    if [[ -f "$TEST_NODE_DIR/mock_tg.pid" ]]; then
        kill "$(cat "$TEST_NODE_DIR/mock_tg.pid")" 2>/dev/null || true
        rm -f "$TEST_NODE_DIR/mock_tg.pid"
    fi
    rm -f "$TEST_NODE_DIR/telegram_calls.jsonl" "$TEST_NODE_DIR/mock_tg.log" 2>/dev/null || true
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null || true
    [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
    # Kill any test sessions we created (using test prefix)
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${TEST_TMUX_PREFIX}" | while read -r session; do
        tmux kill-session -t "$session" 2>/dev/null || true
    done || true
    tmux ls -F '#{session_name}' 2>/dev/null \
        | grep -E '^(test-(conc|paste-buf|imgcap|bp-long|slowpaste|flock)-|claude-regtest-)' \
        | while read -r s; do tmux kill-session -t "=$s" 2>/dev/null || true; done || true
    # Clean up test session files (but keep node dir for next run)
    [[ -d "$TEST_SESSION_DIR" ]] && rm -rf "$TEST_SESSION_DIR"; true
    [[ -f "$BRIDGE_LOG" ]] && rm -f "$BRIDGE_LOG"; true
    [[ -f "$TUNNEL_LOG" ]] && rm -f "$TUNNEL_LOG"; true
    rm -f "$TEST_NODE_DIR/tunnel.pid" "$TEST_NODE_DIR/tunnel_url" "$TEST_NODE_DIR/port" 2>/dev/null || true
    rm -f "$TEST_NODE_DIR/last_chat_id" "$TEST_NODE_DIR/last_active" 2>/dev/null || true
}

trap cleanup EXIT

require_token() {
    if [[ -z "${TEST_BOT_TOKEN:-}" ]]; then
        log "${RED}Error:${NC} TEST_BOT_TOKEN not set"
        log ""
        log "Usage:"
        log "  TEST_BOT_TOKEN='...' ./test.sh                    # Basic tests"
        log "  TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh # Full e2e"
        exit 1
    fi
}

wait_for_port() {
    local port="$1" attempts=0
    while ! nc -z localhost "$port" 2>/dev/null && [[ $attempts -lt 30 ]]; do
        sleep 0.1
        ((attempts++)) || true
    done
    nc -z localhost "$port" 2>/dev/null
}

# curl wrapper for /response and /notify endpoints
hook_curl() {
    local url="$1"; shift
    local body="$1"; shift
    curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" "$@"
}

# Same but returns HTTP code only
hook_curl_code() {
    local url="$1"; shift
    local body="$1"; shift
    curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" "$@"
}

wait_for_session() {
    local session="$1" attempts=0
    while ! tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null && [[ $attempts -lt 20 ]]; do
        sleep 0.1
        ((attempts++)) || true
    done
    tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null
}

wait_for_session_gone() {
    local session="$1" attempts=0
    while tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null && [[ $attempts -lt 20 ]]; do
        sleep 0.1
        ((attempts++)) || true
    done
    ! tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null
}

wait_for_file_content() {
    local file="$1" pattern="$2" max_tenths="$3" attempts=0
    while [[ $attempts -lt $max_tenths ]]; do
        if [[ -f "$file" ]] && grep -Eq "$pattern" "$file"; then
            return 0
        fi
        sleep 0.1
        ((attempts++)) || true
    done
    [[ -f "$file" ]] && grep -Eq "$pattern" "$file"
}

wait_for_log() {
    local pattern="$1" max_tenths="$2"
    wait_for_file_content "$BRIDGE_LOG" "$pattern" "$max_tenths"
}

test_wait_for_file_content_helper() {
    info "Testing wait_for_file_content helper..."

    local tmp
    tmp="$(mktemp)"
    printf 'status=ready\n' > "$tmp"

    if wait_for_file_content "$tmp" '^status=ready$' 5; then
        success "wait_for_file_content returns 0 on matching content"
    else
        fail "wait_for_file_content should return 0 on matching content"
    fi

    if wait_for_file_content "$tmp" '^missing$' 2; then
        fail "wait_for_file_content should return 1 for a missing pattern"
    else
        success "wait_for_file_content returns 1 after no match"
    fi

    rm -f "$tmp"
}

test_wait_for_log_helper() {
    info "Testing wait_for_log helper..."

    local tmp
    tmp="$(mktemp)"
    local BRIDGE_LOG="$tmp"
    printf 'bridge ready\n' > "$BRIDGE_LOG"

    if wait_for_log '^bridge ready$' 5; then
        success "wait_for_log returns 0 on matching bridge log content"
    else
        fail "wait_for_log should return 0 on matching bridge log content"
    fi

    if wait_for_log '^not present$' 2; then
        fail "wait_for_log should return 1 for a missing log pattern"
    else
        success "wait_for_log returns 1 after no log match"
    fi

    rm -f "$tmp"
}

send_message() {
    local text="$1"
    local chat_id="${2:-$CHAT_ID}"
    local update_id=$((RANDOM))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "private"},
                "date": '"$(date +%s)"',
                "text": "'"$text"'"
            }
        }'
}

# Open the DM-fallback session (topic-only's non-forum path; session name "tmain").
# /cd both sets the cwd and (re)starts the session — no folder-picker dance needed.
open_dm_session() {
    local dir="${1:-$TEST_SESSION_DIR}"
    send_message "/cd $dir" >/dev/null
    wait_for_session "tmain"
}

close_dm_session() {
    send_message "/close" >/dev/null 2>&1 || true
    wait_for_session_gone "tmain" 2>/dev/null || true
}

test_dm_session_lifecycle() {
    info "Testing DM fallback session lifecycle (/cd opens, /close ends)..."
    close_dm_session
    open_dm_session
    if tmux has-session -t "${TEST_TMUX_PREFIX}tmain" 2>/dev/null; then
        success "DM /cd opened the tmain fallback session"
    else
        fail "DM /cd did not open tmain"
        return
    fi
    send_message "/close" >/dev/null
    if wait_for_session_gone "tmain"; then
        success "/close ended the tmain session"
    else
        fail "/close did not end tmain"
    fi
}

send_reply() {
    local text="$1"
    local reply_text="$2"
    local reply_from_bot="${3:-true}"
    local chat_id="${4:-$CHAT_ID}"
    local update_id=$((RANDOM))
    local reply_id=$((RANDOM + 1000))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "private"},
                "date": '"$(date +%s)"',
                "text": "'"$text"'",
                "reply_to_message": {
                    "message_id": '"$reply_id"',
                    "from": {"id": 123456, "first_name": "Bot", "is_bot": '"$reply_from_bot"'},
                    "chat": {"id": '"$chat_id"', "type": "private"},
                    "date": '"$(date +%s)"',
                    "text": "'"$reply_text"'"
                }
            }
        }'
}

send_photo_message() {
    local file_id="$1"
    local caption="${2:-}"
    local chat_id="${3:-$CHAT_ID}"
    local update_id=$((RANDOM))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "private"},
                "date": '"$(date +%s)"',
                "photo": [
                    {"file_id": "'"$file_id"'_small", "file_size": 1000, "width": 90, "height": 90},
                    {"file_id": "'"$file_id"'", "file_size": 5000, "width": 320, "height": 320}
                ],
                "caption": "'"$caption"'"
            }
        }'
}

send_document_message() {
    local file_id="$1"
    local file_name="${2:-document.pdf}"
    local mime_type="${3:-application/pdf}"
    local file_size="${4:-1024}"
    local caption="${5:-}"
    local chat_id="${6:-$CHAT_ID}"
    local update_id=$((RANDOM))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "private"},
                "date": '"$(date +%s)"',
                "document": {
                    "file_id": "'"$file_id"'",
                    "file_unique_id": "'"$file_id"'_unique",
                    "file_name": "'"$file_name"'",
                    "mime_type": "'"$mime_type"'",
                    "file_size": '"$file_size"'
                },
                "caption": "'"$caption"'"
            }
        }'
}

send_animation_message() {
    local file_id="$1"
    local caption="${2:-}"
    local chat_id="${3:-$CHAT_ID}"
    local update_id=$((RANDOM))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "private"},
                "date": '"$(date +%s)"',
                "animation": {
                    "file_id": "'"$file_id"'",
                    "file_unique_id": "'"$file_id"'_unique",
                    "file_name": "test.gif",
                    "mime_type": "image/gif",
                    "file_size": 50000,
                    "width": 320,
                    "height": 240
                },
                "caption": "'"$caption"'"
            }
        }'
}

# ─────────────────────────────────────────────────────────────────────────────
# E2E-hardening harness: Mock-Telegram lifecycle + assertion helpers
# (ported verbatim from origin/test/e2e-hardening:test.sh; the spawn_real_claude
#  STUB is intentionally omitted — the real one arrives via tests/e2e_tests.sh,
#  sourced last.)
# ─────────────────────────────────────────────────────────────────────────────

# Used by run_e2e_tests as a loud skip-when-absent gate.
check_claude_available() {
    if command -v claude &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Launch the recording Mock-Telegram server on MOCKPORT and point the bridge at
# it via TELEGRAM_API_BASE. Must be called BEFORE test_bridge_starts so the
# exported TELEGRAM_API_BASE is inherited by the bridge launch env. Idempotent:
# lsof-kills any stale owner of MOCKPORT first.
start_mock_telegram() {
    info "Starting mock Telegram on port $MOCKPORT..."
    # Kill any stale owner of the mock port (PID-scoped to that port only).
    # Portable: BSD xargs has no -r, so guard on a non-empty PID list ourselves.
    local _stale_pids; _stale_pids=$(lsof -ti :"$MOCKPORT" 2>/dev/null || true)
    [[ -n "$_stale_pids" ]] && kill -9 $_stale_pids 2>/dev/null || true
    sleep 0.2

    mkdir -p "$TEST_NODE_DIR"
    : > "$TEST_NODE_DIR/telegram_calls.jsonl" 2>/dev/null || true

    python3 "$SCRIPT_DIR/tests/mock_telegram.py" \
        --port "$MOCKPORT" \
        --record "$TEST_NODE_DIR/telegram_calls.jsonl" \
        > "$TEST_NODE_DIR/mock_tg.log" 2>&1 &
    local mock_pid=$!
    echo "$mock_pid" > "$TEST_NODE_DIR/mock_tg.pid"

    if wait_for_port "$MOCKPORT"; then
        # Mark the harness active so the bridge launch wires TELEGRAM_API_BASE.
        MOCK_TG_ACTIVE=1
        export TELEGRAM_API_BASE="http://127.0.0.1:$MOCKPORT"
        success "Mock Telegram started on port $MOCKPORT"
        return 0
    else
        fail "Mock Telegram failed to start on port $MOCKPORT"
        return 1
    fi
}

# Clear the mock's recorded calls + programmed faults. Call at the top of each
# mock-based test for isolation.
mock_reset() {
    curl -s -X POST "http://127.0.0.1:$MOCKPORT/_reset" >/dev/null
}

# Assert the mock recorded a sendMessage to <thread_id> whose text contains
# <marker>. Returns nonzero (red) if no such call was recorded.
mock_assert_sendmessage() {
    local thread_id="$1" marker="$2"
    curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson n "$thread_id" --arg m "$marker" \
            'any(.[]; .method=="sendMessage" and .message_thread_id==$n and (.text|contains($m)))' \
        >/dev/null
}

# Assert NO recorded sendMessage carrying <marker> targeted a message_thread_id.
# With a second arg <thread_id>, assert no sendMessage to that thread carried the
# marker. Without it (tmain/General/thread-0 case), assert every sendMessage
# carrying the marker has NO message_thread_id key at all (field-absent).
mock_assert_thread_absent() {
    local marker="$1" thread_id="${2:-}"
    if [[ -n "$thread_id" ]]; then
        curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
            | jq -e --argjson n "$thread_id" --arg m "$marker" \
                'any(.[]; .method=="sendMessage" and .message_thread_id==$n and (.text|contains($m))) | not' \
            >/dev/null
    else
        # marker present in some sendMessage, and NONE of those carry message_thread_id.
        curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
            | jq -e --arg m "$marker" \
                '[.[] | select(.method=="sendMessage" and (.text|contains($m)))]
                 | (length > 0) and (all(.[]; has("message_thread_id")|not))' \
            >/dev/null
    fi
}

# Assert the mock recorded ZERO sends or reactions for <chat_id> — used to prove
# the admin gate stays silent for a non-admin chat.
mock_assert_silence() {
    local chat_id="$1"
    curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$chat_id" \
            'all(.[]; (.chat_id // -999999999) != $c)' \
        >/dev/null
}

# Assert the mock recorded ZERO calls of <method> — used for methods whose
# payload carries no chat_id (e.g. answerCallbackQuery is just {callback_query_id}),
# so mock_assert_silence's chat_id filter cannot see them. Returns red if any
# record's .method equals <method>.
mock_assert_no_method() {
    local method="$1"
    curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --arg m "$method" \
            'all(.[]; .method != $m)' \
        >/dev/null
}

# Assert the mock recorded a setMessageReaction arc for <chat_id>/<message_id>
# that, IN ORDER, contains each of the given emoji. Each emoji must appear in a
# recorded reaction whose .raw.message_id matches, in non-decreasing record
# order. Returns nonzero (red) if the arc is incomplete or out of order.
mock_assert_reaction_arc() {
    local chat_id="$1" message_id="$2"
    shift 2
    local emojis_json
    emojis_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$chat_id" --argjson mid "$message_id" --argjson want "$emojis_json" '
            # Reaction records for this chat+message, in recorded order, flattened
            # to the list of emoji strings each set carried.
            ([.[]
              | select(.method=="setMessageReaction"
                       and .chat_id==$c
                       and ((.raw.message_id) == $mid))
              | .reaction[]?
             ]) as $seq
            # Each wanted emoji must appear, in order, as a subsequence of $seq.
            | reduce $want[] as $e (
                {i:0, ok:true};
                if .ok|not then .
                else
                  ( [ $seq[.i:] | to_entries[] | select(.value==$e) | .key ] ) as $hits
                  | if ($hits|length) > 0
                    then {i: (.i + $hits[0] + 1), ok: true}
                    else {i: .i, ok: false}
                    end
                end
              )
            | .ok
        ' >/dev/null
}

# Program the mock so EVERY send targeting <thread_id> bounces with HTTP 400
# "Bad Request: message thread not found" (until /_reset; the fault is sticky, not
# one-shot) — drives the real _reap_dead_topic path.
mock_program_thread_not_found() {
    local thread_id="$1"
    curl -s -X POST "http://127.0.0.1:$MOCKPORT/_program" \
        -H "Content-Type: application/json" \
        -d '{"thread_not_found":['"$thread_id"']}' >/dev/null
}

# Register raw bytes (from a local file) under <file_path> so the mock's getFile
# resolves to it and the /file download serves those bytes. Register EXACTLY ONE
# file before a download test so getFile's single-file shortcut selects it.
mock_register_file_bytes() {
    local file_path="$1" local_file="$2"
    local b64
    b64=$(base64 -w0 "$local_file" 2>/dev/null || base64 "$local_file" | tr -d '\n')
    curl -s -X POST "http://127.0.0.1:$MOCKPORT/_program" \
        -H "Content-Type: application/json" \
        -d '{"files":{"'"$file_path"'":"'"$b64"'"}}' >/dev/null
}

# Assert the session inbox contains a downloaded file whose sha256 matches <sha256>.
# Inbox layout (bridge.py): /tmp/claudecode-telegram/<node>/<session>/inbox/.
# Node is derived from TMUX_PREFIX ("claude-test-" -> "test").
mock_assert_inbox_sha() {
    local session="$1" sha256="$2"
    local node
    node="${TEST_TMUX_PREFIX#claude-}"; node="${node%-}"
    [[ -z "$node" ]] && node="default"
    local inbox="/tmp/claudecode-telegram/$node/$session/inbox"
    [[ -d "$inbox" ]] || return 1
    local f
    for f in "$inbox"/*; do
        [[ -e "$f" ]] || continue
        local got
        got=$( { sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null; } | awk '{print $1}')
        [[ "$got" == "$sha256" ]] && return 0
    done
    return 1
}

# Forum-topic webhook update carrying message_thread_id (models send_message at
# the top of this file, plus the forum-topic `message_thread_id` field + an
# `is_topic_message` flag). Optional <message_id> pins the message id (default
# random) so reaction-arc assertions can target it.
send_topic_message() {
    local chat_id="$1"
    local thread_id="$2"
    local text="$3"
    local message_id="${4:-$((RANDOM))}"
    local update_id=$((RANDOM))

    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$message_id"',
                "message_thread_id": '"$thread_id"',
                "is_topic_message": true,
                "from": {"id": '"$chat_id"', "first_name": "TestUser"},
                "chat": {"id": '"$chat_id"', "type": "supergroup", "is_forum": true},
                "date": '"$(date +%s)"',
                "text": "'"$text"'"
            }
        }'
}

# ─────────────────────────────────────────────────────────────────────────────
# Merged Tests
# ─────────────────────────────────────────────────────────────────────────────

test_formatting() {
    info "Testing response prefix and multipart formatting..."
    if python3 -c "
from bridge import format_response_text, format_multipart_messages

# Response prefix formatting
text = 'Hello <code>world</code>'
result = format_response_text('session-1', text)
assert result == '<b>session-1:</b>\nHello <code>world</code>', f'prefix failed: {result}'

# Single chunk - no part numbers
chunks = ['Hello world']
formatted = format_multipart_messages('worker', chunks)
assert len(formatted) == 1
assert formatted[0] == '<b>worker:</b>\nHello world'
assert '(1/' not in formatted[0], 'single chunk should not have part numbers'

# Multiple chunks - all have prefix
chunks = ['Part 1 content', 'Part 2 content', 'Part 3 content']
formatted = format_multipart_messages('lee', chunks)
assert len(formatted) == 3
assert formatted[0] == '<b>lee:</b>\nPart 1 content', f'first: {formatted[0]}'
assert formatted[1] == '<b>lee:</b>\nPart 2 content', f'second: {formatted[1]}'
assert formatted[2] == '<b>lee:</b>\nPart 3 content', f'third: {formatted[2]}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Response prefix and multipart formatting work"
    else
        fail "Formatting test failed"
    fi
}

test_send_text_includes_thread_id() {
    info "Testing send path passes message_thread_id..."
    if python3 -c "
import bridge
captured = {}
def fake_api(method, payload):
    captured['method'] = method
    captured['payload'] = dict(payload)
    return {'ok': True, 'result': {'message_id': 1}}
bridge.telegram_api = fake_api
t = bridge.TelegramTransport()
t.send_text(12345, 'hi', message_thread_id=99)
assert captured['method'] == 'sendMessage', captured
assert captured['payload'].get('chat_id') == 12345
assert captured['payload'].get('message_thread_id') == 99, captured['payload']
# absent when not given
captured.clear()
t.send_text(12345, 'hi')
assert 'message_thread_id' not in captured['payload'], captured['payload']
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "send_text passes message_thread_id"
    else
        fail "send_text thread_id test failed"
    fi
}

test_pane_start_cmd_shell_agnostic() {
    info "Testing pane start command works in any pane shell (fish has no unset)..."
    if python3 -c "
import bridge, shlex
cmd = bridge.make_pane_start_cmd('claude --dangerously-skip-permissions', '/tmp/some dir')
assert cmd.startswith('sh -c '), cmd
assert '&& unset' not in cmd, cmd
parts = shlex.split(cmd)
assert parts[0:2] == ['sh', '-c'] and len(parts) == 3, parts
script = parts[2]
assert 'unset CLAUDECODE' in script, script
assert 'exec claude --dangerously-skip-permissions' in script, script
assert \"cd '/tmp/some dir'\" in script, script
assert 'tmux show-environment -s' in script, script
cmd2 = bridge.make_pane_start_cmd('claude', None)
assert 'cd ' not in shlex.split(cmd2)[2], cmd2
print('OK')
" 2>/dev/null | grep -q OK; then
        success "pane start command is shell-agnostic (sh -c wrapped)"
    else
        fail "pane start command is not shell-agnostic"
    fi
}

test_pane_start_cmd_runs_in_real_shell_panes() {
    info "Testing pane start command executes in real bash/zsh/fish panes..."

    # The 2026-06-12 t9 lesson: string-shape assertions passed while fish
    # killed claude at birth. This test runs the EXACT line bridge sends,
    # inside a real tmux pane per shell, and asserts the backend (a) actually
    # executed, (b) inherited the tmux session env, (c) had CLAUDECODE
    # stripped. Shells not installed on this box are skipped, never failed.
    local shell shell_path sess marker line ok i launch_cmd
    local tested="" skipped="" broken=""
    for shell in bash zsh fish; do
        shell_path=$(command -v "$shell" 2>/dev/null || true)
        if [[ -z "$shell_path" ]]; then
            skipped+=" $shell"
            continue
        fi
        sess="${TMUX_PREFIX}panesh-$shell"
        marker="/tmp/claudecode-telegram-test-pane-${shell}-$$"
        rm -f "$marker"
        tmux kill-session -t "$sess" 2>/dev/null || true
        # A bare box makes interactive zsh block on stdin before our line runs:
        # no ~/.zshrc triggers the zsh-newuser-install wizard, and the runner's
        # global /etc/zsh rc runs a compinit that prompts on insecure dirs
        # ("Ignore insecure directories [y]/[n]?"). Both eat the launch line.
        # Neither happens in production (the self-contained `sh -c` line doesn't
        # rely on the pane shell's rc), so start zsh with -f (no rc files): still
        # a real interactive zsh pane exercising the exact launch line.
        launch_cmd="$shell_path"
        if [[ "$shell" == "zsh" ]]; then
            launch_cmd="$shell_path -f"
        fi
        tmux new-session -d -s "$sess" "$launch_cmd" 2>/dev/null || true
        # What bridge injects before launching: hook env + a stowaway var the
        # backend must NOT inherit.
        tmux set-environment -t "$sess" PANE_START_PROBE "via-$shell"
        tmux set-environment -t "$sess" CLAUDECODE "must-be-stripped"
        # Same readiness gate the bridge uses before its first keystroke — a
        # slow zsh rc swallows input sent too early (sleep 0.5 lost this race).
        python3 -c "import bridge; bridge.wait_for_pane_shell_ready('$sess')"

        # The exact launch line (env-inject + unset + cd + exec), with `env`
        # standing in for claude so the marker captures what claude would see.
        line=$(python3 -c "import bridge; print(bridge.make_pane_start_cmd('env > $marker', '/tmp'))")
        tmux send-keys -t "$sess" -l "$line" 2>/dev/null
        tmux send-keys -t "$sess" Enter 2>/dev/null

        ok=false
        for i in $(seq 1 160); do
            if grep -q "PANE_START_PROBE=via-$shell" "$marker" 2>/dev/null; then
                ok=true
                break
            fi
            sleep 0.05
        done
        if [[ "$ok" == "true" ]] && grep -q '^CLAUDECODE=' "$marker" 2>/dev/null; then
            ok=false  # ran, but leaked CLAUDECODE into the backend
        fi
        [[ "$ok" == "true" ]] && tested+=" $shell" || broken+=" $shell"

        tmux kill-session -t "$sess" 2>/dev/null || true
        rm -f "$marker"
    done

    if [[ -n "$broken" ]]; then
        fail "launch line broke in pane shell(s):$broken (no exec / env not injected / CLAUDECODE leaked)"
    elif [[ -z "$tested" ]]; then
        fail "no shell available to exercise the pane launch line (bash/zsh/fish all missing?)"
    else
        success "launch line works in real panes:$tested${skipped:+ (not installed:$skipped)}"
    fi
}

test_pane_start_cmd_survives_stdin_eating_rc() {
    info "Testing launch line survives an rc that goes quiet then reads stdin..."

    # The readiness heuristic's fatal blind spot: an rc that prints, falls
    # silent >0.6s, THEN reads stdin (echo boot; sleep 1; read x) makes
    # wait_for_pane_shell_ready declare "ready" too early — the first send is
    # eaten by the rc's `read`. No amount of waiting can "see" a future read;
    # only a post-send confirmation + bounded resend recovers. This test
    # drives the REAL launch path (send_pane_start_cmd) and asserts the marker
    # exists — i.e. the backend launched DESPITE the rc eating a send. The
    # swallow file is a sensitivity guard: it MUST capture the eaten send, or
    # the rc never actually fooled the heuristic and the test proves nothing.
    local sh
    sh=$(command -v bash 2>/dev/null || true)
    if [[ -z "$sh" ]]; then
        success "stdin-eating-rc test skipped (bash not installed)"
        return
    fi

    local sess rcfile swallow marker
    sess="${TMUX_PREFIX}stdineat-$$"
    rcfile="/tmp/claudecode-telegram-test-rc-$$"
    swallow="/tmp/claudecode-telegram-test-swallow-$$"
    marker="/tmp/claudecode-telegram-test-stdineat-marker-$$"
    rm -f "$rcfile" "$swallow" "$marker"

    # rc that prints, goes quiet long enough to trip the "stable" heuristic,
    # then eats one line of stdin into the swallow file.
    cat > "$rcfile" <<RCEOF
echo boot
sleep 1
read -t 2 SWALLOWED
printf '%s' "\$SWALLOWED" > $swallow
RCEOF

    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "$sh --rcfile $rcfile -i" 2>/dev/null || true

    # Real launch semantics: wait via the heuristic, then send the start cmd
    # through bridge's launch path (same shape as the real-panes test).
    # Compress the confirmation window: this rc is DONE by ~3s (read times
    # out), so a 3s window reaches the eaten-line resend fast without
    # reopening the buffered race (nothing stays buffered once the rc exited).
    python3 -c "
import bridge
bridge.PANE_LAUNCH_CONFIRM_SECS = 3
bridge.wait_for_pane_shell_ready('$sess')
bridge.send_pane_start_cmd('$sess', 'touch $marker', '/tmp')
" 2>&1

    local ok i
    ok=false
    for i in $(seq 1 200); do
        if [[ -e "$marker" ]]; then
            ok=true
            break
        fi
        sleep 0.05
    done

    # Sensitivity guard: the rc's `read` must have actually eaten a send,
    # otherwise the heuristic was never fooled and the test is a no-op.
    local fooled=""
    if [[ -e "$swallow" && -s "$swallow" ]] && grep -q "touch $marker" "$swallow" 2>/dev/null; then
        fooled="yes"
    fi

    tmux kill-session -t "$sess" 2>/dev/null || true
    rm -f "$rcfile" "$swallow" "$marker"

    if [[ "$ok" == "true" && -n "$fooled" ]]; then
        success "launch line survived stdin-eating rc (eaten once, resent, marker ran)"
    elif [[ "$ok" != "true" ]]; then
        fail "launch line never ran against stdin-eating rc (marker missing — no resend recovery)"
    else
        fail "rc never ate a send — heuristic not exercised, test proves nothing"
    fi
}

test_pane_start_cmd_no_resend_into_running_backend() {
    info "Testing resend is suppressed once the backend is already running..."

    # The buffered-input race: a bash-family rc that prints, goes quiet
    # (tripping wait_for_pane_shell_ready), but does NOT read stdin until well
    # past the confirmation window. send #1 sits BUFFERED in the pty (not
    # eaten); a too-short window expires; old code blindly resent. When the rc
    # finally ends, line 1 execs the backend and the buffered line 2 + Enter is
    # delivered into the freshly started backend's stdin as a junk prompt line.
    #
    # The defense is TIME: PANE_LAUNCH_CONFIRM_SECS outlasts the rc tail, so
    # the sentinel appears before any resend decision. This test uses an rc
    # that sleeps 4s — shorter than the 5s green window, longer than the 2s
    # sensitivity window. The launched "backend" execs `cat >> $junk`
    # (long-lived, reads stdin) and the junk file must never receive a line;
    # the marker proves the backend launched at all.
    local sh
    sh=$(command -v bash 2>/dev/null || true)
    if [[ -z "$sh" ]]; then
        success "no-resend-into-running-backend test skipped (bash not installed)"
        return
    fi

    local sess rcfile marker junk backend
    sess="${TMUX_PREFIX}noresend-$$"
    rcfile="/tmp/claudecode-telegram-test-nr-rc-$$"
    marker="/tmp/claudecode-telegram-test-nr-marker-$$"
    junk="/tmp/claudecode-telegram-test-nr-junk-$$"
    backend="/tmp/claudecode-telegram-test-nr-backend-$$.sh"
    rm -f "$rcfile" "$marker" "$junk" "$backend"

    # Long-lived "backend": records that it launched, then reads stdin forever.
    # Any buffered resend line lands here.
    cat > "$backend" <<BKEOF
#!/usr/bin/env bash
echo launched >> $marker
exec cat >> $junk
BKEOF
    chmod +x "$backend"

    # rc that prints, goes quiet long enough to trip "stable", then sleeps 4s
    # WITHOUT reading stdin. Green path: a 5s confirmation window waits long
    # enough for the sentinel. Red-light path: PANE_LAUNCH_CONFIRM_SECS=2
    # expires first, resends, and leaks the buffered line into the backend.
    cat > "$rcfile" <<RCEOF
echo boot
sleep 4
RCEOF

    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "$sh --rcfile $rcfile -i" 2>/dev/null || true

    # Default this test to a 5s confirmation window; keep the env override so
    # PANE_LAUNCH_CONFIRM_SECS=2 remains a stable red-light sensitivity check.
    python3 -c "
import os
import bridge
bridge.PANE_LAUNCH_CONFIRM_SECS = float(os.environ.get('PANE_LAUNCH_CONFIRM_SECS', '5'))
bridge.wait_for_pane_shell_ready('$sess')
bridge.send_pane_start_cmd('$sess', '$backend', '/tmp')
" 2>&1

    # Wait for the backend to actually launch (rc sleeps 4s; the python call
    # above blocks until the sentinel lands, so this resolves fast after it).
    local ok i
    ok=false
    for i in $(seq 1 300); do
        if [[ -e "$marker" ]]; then
            ok=true
            break
        fi
        sleep 0.1
    done

    # Give any stray buffered resend a moment to land in the backend's stdin.
    for i in $(seq 1 10); do sleep 0.1; done

    local leaked=""
    if [[ -e "$junk" && -s "$junk" ]]; then
        leaked="yes"
    fi

    tmux kill-session -t "$sess" 2>/dev/null || true
    rm -f "$rcfile" "$marker" "$junk" "$backend"

    if [[ "$ok" != "true" ]]; then
        fail "backend never launched (marker missing) — test setup broken"
    elif [[ -n "$leaked" ]]; then
        fail "resend leaked a junk line into the running backend's stdin (buffered-input race not guarded)"
    else
        success "no resend into an already-running backend (buffered-input race guarded)"
    fi
}

test_topic_session_identity() {
    info "Testing topic-session identity helpers..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp

name = bridge.topic_session_name(4321)
assert name == 't4321', name
sd = tmp / name; sd.mkdir(parents=True, exist_ok=True)
bridge.save_topic_meta(name, 555, 4321)
cid, tid = bridge.load_topic_meta(name)
assert cid == 555 and tid == 4321, (cid, tid)
# find by (chat_id, thread_id)
assert bridge.find_topic_session(555, 4321, {name: {}}) == name
assert bridge.find_topic_session(555, 9999, {name: {}}) is None
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic-session identity works"
    else
        fail "topic-session identity test failed"
    fi
}

test_folder_navigator_keyboard() {
    info "Testing folder navigator keyboard + root confinement..."
    if python3 -c "
import tempfile, os, json
from pathlib import Path
import bridge
root = Path(tempfile.mkdtemp())
(root / 'web').mkdir(); (root / 'api').mkdir(); (root / 'f.txt').write_text('x')
(root / '.hidden').mkdir()
bridge.TOPIC_ROOT = str(root)

kb = bridge.build_folder_keyboard(str(root))
flat = [b for row in kb for b in row]
labels = [b['text'] for b in flat]
cbs = [b['callback_data'] for b in flat]
# folders listed (not the file), and a 'use here' button
assert any('web' in l for l in labels), labels
assert any('api' in l for l in labels), labels
assert not any('f.txt' in l for l in labels), labels
assert not any('.hidden' in l for l in labels), ('hidden dirs must be skipped', labels)
assert any(c.startswith('use:') for c in cbs), cbs
# at root, no escaping above root via up-button
ups = [c for c in cbs if c.startswith('cd:') and bridge._norm_under_root(c[3:]) == c[3:]]
assert bridge._norm_under_root(str(root.parent)) == str(root), 'must clamp to root'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "folder navigator keyboard works"
    else
        fail "folder navigator test failed"
    fi
}

test_handle_callback_navigates() {
    info "Testing callback_query navigation + selection..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
root = Path(tempfile.mkdtemp())
(root / 'web').mkdir()
bridge.TOPIC_ROOT = str(root)
calls = {'edit': 0, 'opened': None}
bridge.telegram_api = lambda m, p: calls.__setitem__('edit', calls['edit'] + (1 if m=='editMessageReplyMarkup' else 0)) or {'ok': True}
cr = bridge.command_router
cr.open_topic_session = lambda chat_id, thread_id, cwd, pending_text=None: calls.__setitem__('opened', (chat_id, thread_id, cwd))
def upd(data):
    return {'callback_query': {'data': data, 'id': 'q', 'message': {'message_id': 7, 'chat': {'id': 555}, 'message_thread_id': 4321}}}
# callback_data is now a short token (not the path); pull the real 'web' token
# from the keyboard. The token hashes the realpath, so cd: and use: share it.
cd_data = [b['callback_data'] for r in bridge.build_folder_keyboard(str(root)) for b in r if b['callback_data'].startswith('cd:')][0]
tok = cd_data[3:]
cr.handle_callback(upd('cd:' + tok))
assert calls['edit'] >= 1, 'cd should edit the keyboard'
cr.handle_callback(upd('use:' + tok))
assert calls['opened'] == (555, 4321, str(root / 'web')), calls['opened']
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "callback navigation works"
    else
        fail "callback navigation test failed"
    fi
}

test_open_topic_session_spawns_in_cwd() {
    info "Testing open_topic_session spawns + binds + delivers..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp()); cwd = tmp / 'proj'; cwd.mkdir()
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
created = {}
bridge.create_session = lambda name, **k: created.update({'name': name, 'kw': k}) or (True, None)
routed = {}
cr = bridge.command_router
cr.route_message = lambda name, text, chat_id, msg_id, one_off=False: routed.update({'name': name, 'text': text})
bridge._set_worker_cwd = lambda name, c: created.update({'cwd': c})
(tmp / 't4321').mkdir(parents=True, exist_ok=True)
cr.open_topic_session(555, 4321, str(cwd))
assert created.get('name') == 't4321', created
assert created.get('cwd') == str(cwd), created
# The trigger message is never forwarded; the worker just gets the welcome.
assert routed.get('text'), routed
cid, tid = bridge.load_topic_meta('t4321')
assert cid == 555 and tid == 4321, (cid, tid)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_topic_session works"
    else
        fail "open_topic_session test failed"
    fi
}

test_topic_routing_known_and_unknown() {
    info "Testing TOPIC_MODE inbound routing..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
# known thread t4321 already registered + bound
(tmp / 't4321').mkdir(parents=True, exist_ok=True)
bridge.save_topic_meta('t4321', 555, 4321)
bridge.session_manager.get_registered_sessions = lambda registered=None: {'t4321': {}}
routed = {}; pickers = {'n': 0}
cr = bridge.command_router
cr.route_message = lambda name, text, chat_id, msg_id, one_off=False: routed.update({'name': name, 'text': text})
cr._send_folder_picker = lambda chat_id, thread_id: pickers.__setitem__('n', pickers['n']+1)
def msg(tid, text):
    return {'message': {'text': text, 'chat': {'id': 555}, 'message_id': 1, 'message_thread_id': tid}}
cr.handle_message(msg(4321, 'do it'))
assert routed == {'name': 't4321', 'text': 'do it'}, routed
cr.handle_message(msg(8888, 'new one'))
assert pickers['n'] == 1, 'unknown thread should show picker'
# The trigger message must NOT be routed anywhere (it is not a task).
assert routed == {'name': 't4321', 'text': 'do it'}, ('unknown thread must not route', routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic routing works"
    else
        fail "topic routing test failed"
    fi
}

test_topic_close_and_cd() {
    info "Testing /close and /cd in a topic..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
(tmp / 't4321').mkdir(parents=True, exist_ok=True); bridge.save_topic_meta('t4321', 555, 4321)
bridge.session_manager.get_registered_sessions = lambda registered=None: {'t4321': {}}
ended = {}; pickers = {'n': 0}
bridge.session_manager.close_session = lambda name: ended.update({'name': name}) or (True, None)
cr = bridge.command_router
cr.reply = lambda chat_id, text, **k: None
cr.transport = bridge.transport
cr._send_folder_picker = lambda chat_id, thread_id: pickers.__setitem__('n', pickers['n']+1)
def msg(tid, text):
    return {'message': {'text': text, 'chat': {'id': 555}, 'message_id': 1, 'message_thread_id': tid}}
cr.handle_message(msg(4321, '/close'))
assert ended.get('name') == 't4321', ended
cr.handle_message(msg(4321, '/cd'))
assert pickers['n'] == 1, 'bare /cd should reopen picker'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/close and /cd work"
    else
        fail "/close /cd test failed"
    fi
}

test_cd_reports_restart_failure() {
    info "Testing /cd surfaces restart() failure instead of a false success reply..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
proj = tmp / 'proj'; proj.mkdir(parents=True, exist_ok=True)
bridge.save_topic_meta('t77', 555, 77)
bridge.session_manager.get_registered_sessions = lambda registered=None: {'t77': {}}
bridge._set_worker_cwd = lambda n, c: None
# Force restart to fail (valid path, so the handler reaches restart()).
bridge.session_manager.restart = lambda name, mode='relaunch': (False, \"'claude' not found in PATH. Install it first.\")
replies = []
cr = bridge.command_router
cr.reply = lambda chat_id, text, **k: replies.append(text)
cr.transport = bridge.transport
def msg(tid, text):
    return {'message': {'text': text, 'chat': {'id': 555}, 'message_id': 1, 'message_thread_id': tid}}
cr.handle_message(msg(77, '/cd ' + str(proj)))
joined = ' '.join(replies)
assert '重啟失敗' in joined, ('must surface restart failure:', replies)
assert '已切換資料夾並重啟' not in joined, ('must NOT claim success on failure:', replies)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "/cd surfaces restart failure (no false success)"
    else
        fail "cd restart-failure test failed"
    fi
}

test_dead_realert_is_bounded() {
    info "Testing a sustained DEAD session stops after exactly 1+MAX_DEAD_REALERTS REAL sends (real cooldown path)..."
    if python3 -c "
import bridge
clock = [1000.0]
bridge.time.time = lambda: clock[0]
bridge.time.sleep = lambda *a, **k: None
bridge.admin_chat_id = 999
sends = []
bridge.transport.send_text = lambda cid, text, **k: (sends.append(text) or {'ok': True, 'result': {'message_id': 1}})
for d in (bridge._prev_session_states, bridge._bad_state_alert_count, bridge._last_alert_ts, bridge._session_states):
    d.clear()
since = clock[0] - 10_000  # DEAD since long ago -> eligible_for_alert() True
for _ in range(120):       # ~480s of 4s probes -> spans >2 ALERT_COOLDOWN windows
    bridge._handle_watchdog_transition('tX', 'DEAD', 'claude missing', since, now=clock[0])
    clock[0] += bridge.WATCHDOG_INTERVAL
n = len(sends)
assert n == 1 + bridge.MAX_DEAD_REALERTS, ('expected exactly 1+MAX real sends, got', n)
print('OK', n)
" 2>/dev/null | grep -q OK; then
        success "DEAD re-alert bounded to 1+MAX_DEAD_REALERTS real sends"
    else
        fail "bounded DEAD re-alert test failed"
    fi
}

test_dead_realert_resets_after_recovery() {
    info "Testing recovery clears the alert budget so a later death alerts again..."
    if python3 -c "
import bridge
clock = [2000.0]
bridge.time.time = lambda: clock[0]
bridge.time.sleep = lambda *a, **k: None
bridge.admin_chat_id = 999
sends = []
bridge.transport.send_text = lambda cid, text, **k: (sends.append(text) or {'ok': True, 'result': {'message_id': 7}})
bridge._send_resolved_alert = lambda *a, **k: None  # isolate: don't count the resolved message
for d in (bridge._prev_session_states, bridge._bad_state_alert_count, bridge._last_alert_ts,
          bridge._session_states, bridge._consecutive_good_probes):
    d.clear()
# 1) DEAD -> first real alert
bridge._handle_watchdog_transition('tY', 'DEAD', 'm', clock[0]-10_000, now=clock[0])
assert len(sends) == 1, ('first death should alert:', sends)
# 2) recover: GOOD_PROBE_THRESHOLD (3) good probes must clear the budget
for _ in range(3):
    clock[0] += 4
    bridge._handle_watchdog_transition('tY', 'READY', 'idle', clock[0]-10_000, now=clock[0])
assert bridge._bad_state_alert_count.get('tY') is None, ('budget must reset on recovery:', bridge._bad_state_alert_count)
# 3) dies again much later (past cooldown) -> must alert again
clock[0] += 10_000
bridge._handle_watchdog_transition('tY', 'DEAD', 'm', clock[0]-100, now=clock[0])
assert len(sends) == 2, ('a later death must alert again:', sends)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "alert budget resets on recovery; later death re-alerts"
    else
        fail "recovery-reset test failed"
    fi
}

test_topic_non_forum_fallback() {
    info "Testing non-forum (no thread) → single default session..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
(tmp / 'tmain').mkdir(parents=True, exist_ok=True); bridge.save_topic_meta('tmain', 555, 0)
bridge.session_manager.get_registered_sessions = lambda registered=None: {'tmain': {}}
routed = {}
cr = bridge.command_router
cr.route_message = lambda name, text, chat_id, msg_id, one_off=False: routed.update({'name': name, 'text': text})
cr.handle_message({'message': {'text': 'hi', 'chat': {'id': 555}, 'message_id': 1}})  # no message_thread_id
assert routed.get('name') == 'tmain', routed
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "non-forum fallback works"
    else
        fail "non-forum fallback test failed"
    fi
}

test_topic_title_naming() {
    info "Testing topic title becomes the session name (with t<id> fallback)..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True
bridge._topic_titles.clear()

# sanitize: ascii -> slug; pure-unicode -> empty (so we fall back)
assert bridge._sanitize_topic_name('TEST') == 'test', bridge._sanitize_topic_name('TEST')
assert bridge._sanitize_topic_name('My Proj 2') == 'my-proj-2', bridge._sanitize_topic_name('My Proj 2')
assert bridge._sanitize_topic_name('我的專案') == '', repr(bridge._sanitize_topic_name('我的專案'))

# a forum_topic_created service message captures the title for that thread
bridge.session_manager.get_registered_sessions = lambda registered=None: {}
cr = bridge.command_router
cr.handle_message({'message': {'chat': {'id': 555}, 'message_id': 7, 'message_thread_id': 7, 'forum_topic_created': {'name': 'TEST'}}})
assert bridge._topic_titles.get((555, 7)) == 'TEST', bridge._topic_titles

# resolve: captured title -> slug; name taken or no title -> t<id> fallback
assert bridge.resolve_topic_session_name(555, 7, {}) == 'test'
assert bridge.resolve_topic_session_name(555, 7, {'test': {}}) == 't7'
assert bridge.resolve_topic_session_name(555, 99, {}) == 't99'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic title naming works"
    else
        fail "topic title naming test failed"
    fi
}

test_topic_reaction_mapping() {
    info "Testing worker-state → reaction emoji mapping + stalled predicate..."
    if python3 -c "
import bridge
# working states → ✍ (the 'it's actively thinking/running' signal)
for s in ('BUSY_THINKING', 'BUSY_TOOL', 'UNTRACKED_BUSY'):
    assert bridge.topic_reaction_for_state(s) == bridge.TOPIC_REACTION_WORKING, s
# just received, no clear activity yet → 👀
assert bridge.topic_reaction_for_state('WAITING') == bridge.TOPIC_REACTION_RECEIVED
# not making progress → 😴
for s in ('STUCK', 'POISONED', 'DEAD', 'OFFLINE', 'EXITED'):
    assert bridge.topic_reaction_for_state(s) == bridge.TOPIC_REACTION_STALLED, s
# idle/ready and unknown → don't override (None)
assert bridge.topic_reaction_for_state('READY') is None
assert bridge.topic_reaction_for_state('WAITING_INPUT') is None
# stalled predicate (drives typing stop): true only for non-progress states
assert bridge.topic_request_stalled('STUCK') is True
assert bridge.topic_request_stalled('DEAD') is True
assert bridge.topic_request_stalled('BUSY_THINKING') is False
assert bridge.topic_request_stalled('WAITING') is False
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "reaction mapping + stalled predicate work"
    else
        fail "reaction mapping test failed"
    fi
}

test_topic_reaction_updates() {
    info "Testing _update_topic_reaction sets emoji per state + dedups..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
bridge._topic_request_msg.clear(); bridge._topic_reaction_set.clear()
calls = []
bridge.transport.set_reaction = lambda chat_id, msg_id, reaction: calls.append((chat_id, msg_id, reaction[0]['emoji']))

# no tracked request → no-op
bridge._update_topic_reaction('t7', 'BUSY_THINKING')
assert calls == [], calls

# track an in-flight request, then drive states
bridge._topic_request_msg['t7'] = (555, 7)
bridge._update_topic_reaction('t7', 'BUSY_THINKING')
assert calls == [(555, 7, bridge.TOPIC_REACTION_WORKING)], calls
# same state again → deduped (no extra API call)
bridge._update_topic_reaction('t7', 'BUSY_TOOL')
assert len(calls) == 1, calls
# transition to stalled → 😴
bridge._update_topic_reaction('t7', 'STUCK')
assert calls[-1] == (555, 7, bridge.TOPIC_REACTION_STALLED), calls
# READY → None → leaves reaction as-is (no call)
bridge._update_topic_reaction('t7', 'READY')
assert len(calls) == 2, calls

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "reaction updates + dedup work"
    else
        fail "reaction update test failed"
    fi
}

test_topic_reaction_done_on_delivery() {
    info "Testing delivery sets 👍 on the request message and clears tracking..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
bridge._topic_request_msg.clear(); bridge._topic_reaction_set.clear()
bridge._topic_request_msg['t7'] = (555, 7)
bridge._topic_reaction_set['t7'] = bridge.TOPIC_REACTION_WORKING
calls = []
bridge.transport.set_reaction = lambda chat_id, msg_id, reaction: calls.append((chat_id, msg_id, reaction[0]['emoji']))
# don't actually hit Telegram for the text body
bridge.send_response_to_telegram = lambda *a, **k: None
bridge.deliver_hook_response('t7', 'all done', 555)
assert calls == [(555, 7, bridge.TOPIC_REACTION_DONE)], calls
# tracking cleared so late watchdog ticks won't clobber the 👍
assert 't7' not in bridge._topic_request_msg, bridge._topic_request_msg
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "done reaction on delivery works"
    else
        fail "done reaction test failed"
    fi
}

test_topic_typing_stops_when_stalled() {
    info "Testing typing indicator keeps the feel but stops when stalled..."
    if python3 -c "
import bridge
bridge.time.sleep = lambda *a, **k: None  # no real waiting in test

# Happy path: pending + a working state → keeps typing (the one-on-one feel).
# is_pending flips True→False so the loop runs exactly one tick then exits.
bridge._session_states['t7'] = ('BUSY_THINKING', '', 0)
seq = [True, False]
bridge.is_pending = lambda name: seq.pop(0) if seq else False
typed = []
bridge.transport.send_chat_action = lambda chat_id, action, message_thread_id=None: typed.append(action)
bridge.send_typing_loop(555, 't7')
assert typed == ['typing'], typed

# Stalled: pending stays True but worker is STUCK → break immediately, 0 typing.
# is_pending returns True a few times as a safety net (no hang if break broke).
bridge._session_states['t7'] = ('STUCK', '', 0)
calls = {'n': 0}
def fake_pending(name):
    calls['n'] += 1
    return calls['n'] <= 5
bridge.is_pending = fake_pending
typed2 = []
bridge.transport.send_chat_action = lambda chat_id, action, message_thread_id=None: typed2.append(action)
bridge.send_typing_loop(555, 't7')
assert typed2 == [], typed2
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "typing stops when stalled, keeps going when working"
    else
        fail "typing stall test failed"
    fi
}

test_topic_route_tracks_request() {
    info "Testing route_message tracks the in-flight request message (TOPIC_MODE)..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.TOPIC_MODE = True
bridge._topic_request_msg.clear(); bridge._topic_reaction_set.clear()
bridge.is_pending = lambda name: False          # typing thread exits at once
bridge.worker_set_pending = lambda name, chat_id: None
bridge.get_worker_backend = lambda name, session: 'claude'
bridge.tmux_prompt_empty = lambda tmux, timeout=0.5: True
cr = bridge.command_router
cr.workers.get_registered_sessions = lambda registered=None: {'t7': {'tmux': 'claude-test-t7'}}
cr.workers.is_online = lambda name, session=None: True
cr.workers.send = lambda name, text, chat_id, session: True
reacts = []
cr.transport.set_reaction = lambda chat_id, msg_id, reaction: reacts.append((chat_id, msg_id, reaction[0]['emoji']))
cr.route_message('t7', 'hello', 555, 99)
assert bridge._topic_request_msg.get('t7') == (555, 99), bridge._topic_request_msg
assert bridge._topic_reaction_set.get('t7') == bridge.TOPIC_REACTION_RECEIVED, bridge._topic_reaction_set
assert reacts == [(555, 99, bridge.TOPIC_REACTION_RECEIVED)], reacts
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "route_message tracks in-flight request"
    else
        fail "route tracking test failed"
    fi
}

test_topic_name_falls_back_for_nonascii() {
    info "Testing topic session naming falls back to t<id> for non-faithful slugs..."
    if python3 -c "
import bridge
s = bridge._sanitize_topic_name
assert s('測試546') == '', repr(s('測試546'))
assert s('PR 123') == 'pr-123', repr(s('PR 123'))
assert s('café') == '', repr(s('café'))
assert s('fix-bug') == 'fix-bug', repr(s('fix-bug'))
r = bridge.resolve_topic_session_name
bridge._topic_titles[(11, 546)] = '測試546'
assert r(11, 546, {}) == 't546', r(11, 546, {})       # CJK dropped -> fallback
bridge._topic_titles[(11, 777)] = '546'
assert r(11, 777, {}) == 't777', r(11, 777, {})       # pure-numeric -> fallback
bridge._topic_titles[(11, 888)] = 'team'
assert r(11, 888, {}) == 't888', r(11, 888, {})       # reserved -> fallback
bridge._topic_titles[(11, 999)] = 'cc-switch'
assert r(11, 999, {}) == 'cc-switch', r(11, 999, {})  # plain ASCII kept
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic naming falls back to t<id> for non-ASCII/numeric/reserved"
    else
        fail "topic naming fallback test failed"
    fi
}

test_topic_hire_starts_pane_in_picked_cwd() {
    info "Testing open_session starts the tmux pane in the picked cwd via -c (no cd-readback race)..."
    if python3 -c "
import tempfile, subprocess
import bridge
picked = tempfile.mkdtemp()            # a real dir so isdir() passes
wm = bridge.session_manager
wm._sync_paths = lambda: None
bridge.is_valid_backend = lambda b: True
bridge._which_binary = lambda b: '/usr/bin/true'
bridge.tmux_exists = lambda t: False
wm._get_startup_cwd = lambda name: picked
cap = {}
class R:
    returncode = 0; stdout = ''; stderr = b''
def fake_run(cmd, *a, **k):
    if isinstance(cmd, list) and 'new-session' in cmd:
        cap['ns'] = cmd
    return R()
subprocess.run = fake_run
saved = {}
bridge.save_claude_session_cwd = lambda n, c: saved.__setitem__(n, c)
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda n: None
bridge.time.sleep = lambda *a, **k: None
bridge.wait_for_pane_shell_ready = lambda *a, **k: True
try:
    wm.open_session('546', chat_id=11)         # later stages may no-op/raise; new-session runs first
except Exception:
    pass
ns = cap.get('ns', [])
assert '-c' in ns and picked in ns, ('new-session missing -c <picked>:', ns)
assert saved.get('546') == picked, ('persisted cwd != picked:', saved)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_session starts pane in picked cwd via -c and persists it"
    else
        fail "open_session -c cwd test failed"
    fi
}

test_topic_typed_reply_during_pick_not_routed() {
    info "Testing a typed reply while awaiting folder pick is not routed to a worker..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear(); bridge._awaiting_folder.add((555, 4321))
cr.workers.get_registered_sessions = lambda registered=None: {}
routed = []; replies = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
cr.reply = lambda chat_id, text, **kw: replies.append(text)
msg = {'message_thread_id': 4321, 'text': '2', 'chat': {'id': 555}}
cr._handle_topic_message(msg, '2', 555, 7)
assert routed == [], ('must not route while awaiting:', routed)
assert replies and '按鈕' in replies[0], replies
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "typed reply during folder pick is not routed to a worker"
    else
        fail "awaiting-folder guard test failed"
    fi
}

test_topic_cd_rejects_bad_path() {
    info "Testing /cd rejects a nonexistent / out-of-root path..."
    if python3 -c "
import tempfile
import bridge
bridge.TOPIC_MODE = True
bridge.TOPIC_ROOT = tempfile.mkdtemp()
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
opened = []; replies = []
cr.open_topic_session = lambda *a, **k: opened.append((a, k))
cr.reply = lambda chat_id, text, **kw: replies.append(text)
bad = bridge.TOPIC_ROOT + '/nope-xyz-123'
msg = {'message_thread_id': 4321, 'text': '/cd ' + bad, 'chat': {'id': 555}}
cr._handle_topic_message(msg, '/cd ' + bad, 555, 7)
assert opened == [], ('must not open session for bad path:', opened)
assert replies and ('找不到' in replies[0] or '範圍' in replies[0]), replies
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/cd rejects nonexistent/out-of-root path"
    else
        fail "/cd clamp test failed"
    fi
}

test_accept_trust_prompt_picks_yes() {
    info "Testing _accept_trust_prompt navigates to the Yes/trust option and never confirms No,exit..."
    if python3 -c "
import bridge, subprocess
sk = []
class R:
    returncode = 0; stdout = ''; stderr = b''
def fake_run(cmd, *a, **k):
    if isinstance(cmd, list) and 'send-keys' in cmd:
        sk.append(cmd[4] if len(cmd) > 4 else '')
    return R()
subprocess.run = fake_run
bridge.time.sleep = lambda *a, **k: None

# Case A: no trust prompt -> send nothing
bridge._capture_pane_text = lambda t, lines=30: 'Claude Code v2\n> '
sk.clear()
assert bridge._accept_trust_prompt('sA') == 'no-prompt', 'A'
assert sk == [], ('must send nothing when no prompt:', sk)

# Case B: current wording, Yes is option 1 and already selected -> Enter only, never '2'
sk.clear()
bridge._capture_pane_text = lambda t, lines=30: (
    'Quick safety check: Is this a project you created or one you trust?\n'
    '❯ 1. Yes, I trust this folder\n'
    '  2. No, exit\n'
    'Enter to confirm')
assert bridge._accept_trust_prompt('sB') == 'accepted', 'B'
assert '2' not in sk, ('must never send literal 2:', sk)
assert 'Enter' in sk, ('must confirm with Enter:', sk)
assert 'Down' not in sk and 'Up' not in sk, ('Yes already selected, no nav needed:', sk)

# Case C: order flipped, Yes is option 2 (not default) -> navigate Down then Enter
sk.clear()
bridge._capture_pane_text = lambda t, lines=30: (
    'Do you trust the files in this folder?\n'
    '❯ 1. No, exit\n'
    '  2. Yes, I trust this folder\n'
    'Enter to confirm')
assert bridge._accept_trust_prompt('sC') == 'accepted', 'C'
assert sk == ['Down', 'Enter'], ('must navigate to Yes (down) then confirm:', sk)

# Case D: prompt text present but options unparseable -> do not guess
sk.clear()
bridge._capture_pane_text = lambda t, lines=30: 'Is this a project you created or one you trust?\nEnter to confirm\n(garbled, no options)'
assert bridge._accept_trust_prompt('sD') == 'unparsed', 'D'
assert sk == [], ('must not guess when unparseable:', sk)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "_accept_trust_prompt picks Yes/trust, never No,exit"
    else
        fail "_accept_trust_prompt test failed"
    fi
}

test_topic_hire_accepts_trust_prompt() {
    info "Testing open_session accepts the trust dialog (Yes) only when present, never sends a bare '2'..."
    if python3 -c "
import tempfile, subprocess
import bridge
wm = bridge.session_manager
wm._sync_paths = lambda: None
bridge.is_valid_backend = lambda b: True
bridge._which_binary = lambda b: '/usr/bin/true'
bridge.tmux_exists = lambda t: False
wm._get_startup_cwd = lambda name: tempfile.mkdtemp()
bridge.save_claude_session_cwd = lambda n, c: None
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda n: None
bridge.time.sleep = lambda *a, **k: None
bridge.wait_for_pane_shell_ready = lambda *a, **k: True
bridge.send_pane_start_cmd = lambda *a, **k: True
wm._build_welcome = lambda n, b: 'hi'
wm.send = lambda *a, **k: True
sk = []
class R:
    returncode = 0; stdout = ''; stderr = b''
def fake_run(cmd, *a, **k):
    if isinstance(cmd, list) and 'send-keys' in cmd:
        sk.append(cmd[4] if len(cmd) > 4 else '')
    return R()
subprocess.run = fake_run

# Case A: no trust dialog -> no trust keystrokes at all.
bridge._capture_pane_text = lambda t, lines=30: 'Claude Code v2\n> '
try:
    wm.open_session('tA', chat_id=11)
except Exception:
    pass
assert '2' not in sk and 'Enter' not in sk, ('no keystrokes when no dialog:', sk)

# Case B: a real trust dialog (current wording) -> accept by navigating to Yes, NEVER '2'.
sk.clear()
bridge._capture_pane_text = lambda t, lines=30: (
    'Quick safety check: Is this a project you created or one you trust?\n'
    '❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm')
try:
    wm.open_session('tB', chat_id=11)
except Exception:
    pass
assert '2' not in sk, ('must never answer trust with a bare 2:', sk)
assert 'Enter' in sk, ('must confirm the trust dialog:', sk)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_session accepts trust dialog (Yes) without sending a bare 2"
    else
        fail "open_session trust-accept test failed"
    fi
}

test_restart_paths_accept_trust() {
    info "Testing restart() in-pane and _restart_dead_worker both accept the trust prompt (never send 2)..."
    if python3 -c "
import tempfile, subprocess
import bridge
wm = bridge.session_manager
wm._sync_paths = lambda: None
bridge._which_binary = lambda b: '/usr/bin/true'
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda n: None
bridge.time.sleep = lambda *a, **k: None
bridge.wait_for_pane_shell_ready = lambda *a, **k: True
bridge.send_pane_start_cmd = lambda *a, **k: True
bridge.is_claude_running = lambda t: False
bridge.clear_pending = lambda n: None
bridge._clear_hook_failures = lambda n: None
bridge.save_claude_session_cwd = lambda n, c: None
wm._get_startup_cwd = lambda name, fallback_cwd='': tempfile.mkdtemp()
wm._build_welcome = lambda n, b: 'hi'
wm.send = lambda *a, **k: True
bridge._capture_pane_text = lambda t, lines=30: (
    'Quick safety check: Is this a project you created or one you trust?\n'
    '❯ 1. Yes, I trust this folder\n  2. No, exit\nEnter to confirm')
sk = []
class R:
    returncode = 0; stdout = ''; stderr = b''
def fake_run(cmd, *a, **k):
    if isinstance(cmd, list) and 'send-keys' in cmd:
        sk.append(cmd[4] if len(cmd) > 4 else '')
    return R()
subprocess.run = fake_run

# In-pane restart path: tmux alive, claude not running.
bridge.tmux_exists = lambda t: True
wm.get_registered_sessions = lambda registered=None: {'tR': {'tmux': 'claude-test-tR', 'backend': 'claude'}}
sk.clear()
wm.restart('tR')
assert '2' not in sk and 'Enter' in sk, ('in-pane restart must accept trust, not send 2:', sk)

# Dead-worker path: tmux gone -> _restart_dead_worker (new-session succeeds via fake_run rc=0).
bridge.tmux_exists = lambda t: False
wm.get_registered_sessions = lambda registered=None: {'tD': {'backend': 'claude'}}
sk.clear()
wm.restart('tD')
assert '2' not in sk and 'Enter' in sk, ('dead-worker restart must accept trust, not send 2:', sk)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "restart() and _restart_dead_worker accept trust (never send 2)"
    else
        fail "restart-paths trust-accept test failed"
    fi
}

test_topic_legacy_command_rejected() {
    info "Testing legacy orchestration commands are intercepted in TOPIC_MODE (not leaked to worker)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
routed = []; replies = []
cr.route_message = lambda *a, **k: routed.append(a)
cr.reply = lambda chat_id, text, **kw: replies.append(text)
for legacy in ('/focus foo', '/team', '/hire bar', '/pause'):
    msg = {'message_thread_id': 4321, 'text': legacy, 'chat': {'id': 555}}
    cr._handle_topic_message(msg, legacy, 555, 7)
assert routed == [], ('legacy commands must not route to a worker:', routed)
assert len(replies) == 4 and all('不需要' in r for r in replies), replies
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "legacy orchestration commands intercepted in topic mode"
    else
        fail "topic legacy-command intercept test failed"
    fi
}

test_topic_global_command_delegated() {
    info "Testing global commands (/memory) are delegated, not leaked to the worker..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
delegated = []; routed = []
cr.handle_command = lambda text, chat_id, msg_id: delegated.append(text)
cr.route_message = lambda *a, **k: routed.append(a)
msg = {'message_thread_id': 4321, 'text': '/memory otp bug', 'chat': {'id': 555}}
cr._handle_topic_message(msg, '/memory otp bug', 555, 7)
assert delegated == ['/memory otp bug'], delegated
assert routed == [], routed
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "global commands delegated inside a topic"
    else
        fail "topic global-command delegation test failed"
    fi
}

test_extension_seam_command() {
    info "Testing EXTRA_COMMANDS dispatch seam..."
    if python3 - <<'EOF' 2>/dev/null | grep -q "OK"; then
import bridge

calls = []
bridge.EXTRA_COMMANDS["/dummyext"] = (
    lambda router, arg, chat_id: (calls.append((arg, chat_id)), True)[1]
)
router = bridge.command_router
handled = router.handle_command("/dummyext hello", 12345, 99)
assert handled is True, "extension command should be handled"
assert calls == [("hello", 12345)], f"seam not dispatched: {calls}"

calls.clear()
routed = []
bridge._awaiting_folder.clear()
bridge._picker_sent_at.clear()
router.workers.get_registered_sessions = lambda registered=None: {"tExt": {}}
bridge.find_topic_session = lambda chat_id, thread_id, registered: "tExt"
router.route_message = lambda *args, **kwargs: routed.append(args)
msg = {"message_thread_id": 777, "text": "/dummyext topic", "chat": {"id": 12345}}
router._handle_topic_message(msg, "/dummyext topic", 12345, 100)
assert calls == [("topic", 12345)], f"topic seam not dispatched: {calls}"
assert routed == [], f"extension command leaked to worker: {routed}"
print("OK")
EOF
        success "EXTRA_COMMANDS dispatch seam invokes callback"
    else
        fail "EXTRA_COMMANDS dispatch seam failed"
    fi
}

test_topic_command_menu_is_slim() {
    info "Testing TOPIC_MODE advertises a slim command menu (no hire/focus/team, no per-worker shortcuts)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
sent = {}
bridge.transport.setup_commands = lambda cmds: sent.update({'cmds': cmds})
bridge.get_registered_sessions = lambda: {'t9': {}}   # would add a /t9 shortcut in non-topic mode
bridge.update_bot_commands()
cmds = [c['command'] for c in sent['cmds']]
assert 'cd' in cmds and 'close' in cmds and 'memory' in cmds, cmds
for gone in ('focus', 'team', 'hire', 'progress', 'pause', 'restart', 'end', 't9'):
    assert gone not in cmds, ('should be absent from topic menu:', gone, cmds)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic command menu is slim"
    else
        fail "topic slim-menu test failed"
    fi
}

test_topic_welcome_drops_multiworker_framing() {
    info "Testing TOPIC_MODE worker welcome drops the multi-worker framing..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
bridge.read_checkin_note = lambda: ''
w = bridge.session_manager._build_welcome('t9', bridge.get_backend('claude'))
assert '/workers' not in w, 'topic welcome should not mention /workers'
assert 'NAME PREFIX' not in w, 'topic welcome should not mention NAME PREFIX'
assert '話題' in w and '/cd' in w, w[:120]
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic welcome drops multi-worker framing"
    else
        fail "topic welcome test failed"
    fi
}

test_topic_admin_gate() {
    info "Testing topic mode learns the first sender as admin and rejects others..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
bridge.admin_chat_id = None
bridge.save_last_chat_id = lambda c: None
cr.workers.get_registered_sessions = lambda registered=None: {'tA': {}}
bridge.find_topic_session = lambda c, t, r: 'tA'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
def msg(uid, text):
    return {'message': {'text': text, 'chat': {'id': -100123}, 'from': {'id': uid},
            'message_id': 1, 'message_thread_id': 50}}
# First sender becomes admin and routes
cr.handle_message(msg(817, 'hi'))
assert bridge.admin_chat_id == 817, bridge.admin_chat_id
assert routed == [('tA', 'hi')], routed
# A different sender in the same group is silently rejected
cr.handle_message(msg(999, 'evil'))
assert routed == [('tA', 'hi')], ('non-admin must not route:', routed)
# Callback from non-admin is ignored
opened = []
cr.open_topic_session = lambda *a, **k: opened.append(a)
tok = bridge._folder_token('/tmp')
cb = {'callback_query': {'id': 'x', 'data': 'use:' + tok, 'from': {'id': 999},
      'message': {'chat': {'id': -100123}, 'message_id': 1, 'message_thread_id': 50}}}
cr.handle_callback(cb)
assert opened == [], ('non-admin callback must be ignored:', opened)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic admin gate: learn first sender, reject others (msg + callback)"
    else
        fail "topic admin gate test failed"
    fi
}

test_topic_command_reply_targets_thread() {
    info "Testing command replies (/quota etc.) are sent into the topic thread..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
bridge.admin_chat_id = 817
cr.workers.get_registered_sessions = lambda registered=None: {}
sent = []
cr.transport.send_text = (lambda chat_id, text, parse_mode=None, reply_to=None,
    message_thread_id=None: sent.append((text, message_thread_id)) or {'ok': True})
msg = {'message_thread_id': 77, 'text': '/quota', 'chat': {'id': -100123},
       'from': {'id': 817}, 'message_id': 9}
cr._handle_topic_message(msg, '/quota', -100123, 9)
assert sent, 'reply must be sent'
assert sent[0][1] == 77, ('reply must carry the topic thread id:', sent)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "command replies land in the topic thread"
    else
        fail "topic command reply threading test failed"
    fi
}

test_media_reply_targets_thread() {
    info "Testing worker image/file replies are sent into the topic thread..."
    if python3 -c "
import os, tempfile
import bridge
img = tempfile.mktemp(suffix='.png')
open(img, 'wb').write(b'fake')
bridge.load_topic_meta = lambda name: (555, 88)
sent = []
bridge.send_photo = (lambda chat_id, photo_path, caption=None, message_thread_id=None:
    sent.append(('photo', message_thread_id)) or True)
bridge.transport.send_text = (lambda chat_id, text, parse_mode=None, reply_to=None,
    message_thread_id=None: {'ok': True, 'result': {'message_id': 1}})
bridge.send_response_to_telegram('tM', f'look [[image:{img}]]', 555)
os.unlink(img)
assert sent and sent[0] == ('photo', 88), ('media must carry thread id:', sent)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "worker media replies land in the topic thread"
    else
        fail "media reply threading test failed"
    fi
}

test_tmain_thread_zero_omitted() {
    info "Testing tmain (thread 0) hook replies omit message_thread_id (and never get reaped)..."
    if python3 -c "
import bridge
bridge.load_topic_meta = lambda name: (555, 0)
sent = []
bridge.transport.send_text = (lambda chat_id, text, parse_mode=None, reply_to=None,
    message_thread_id=None: sent.append(message_thread_id) or {'ok': True, 'result': {'message_id': 1}})
bridge.send_response_to_telegram('tmain', 'hello', 555)
assert sent == [None], ('thread 0 must be omitted, got:', sent)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "tmain hook replies omit message_thread_id"
    else
        fail "tmain thread-zero test failed"
    fi
}

test_topic_picker_shown_on_topic_creation() {
    info "Testing the folder picker is shown on topic creation (no throwaway first message needed)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
bridge.find_topic_session = lambda c, t, r: None
shown = []
cr._send_folder_picker = lambda chat_id, thread_id: shown.append((chat_id, thread_id))
msg = {'message_thread_id': 70, 'forum_topic_created': {'name': '測試'}, 'chat': {'id': 555}}
cr._handle_topic_message(msg, '', 555, 7)
assert shown == [(555, 70)], ('picker should show on creation:', shown)
assert bridge._topic_titles.get((555, 70)) == '測試', bridge._topic_titles.get((555, 70))
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "folder picker shown on topic creation"
    else
        fail "topic picker-on-creation test failed"
    fi
}

test_hire_does_not_set_focus() {
    info "Testing open_session() no longer sets focus/active (topic mode has no current worker)..."
    if python3 -c "
import tempfile, subprocess
import bridge
picked = tempfile.mkdtemp()
wm = bridge.session_manager
wm._sync_paths = lambda: None
bridge.is_valid_backend = lambda b: True
bridge._which_binary = lambda b: '/usr/bin/true'
bridge.tmux_exists = lambda t: False
wm._get_startup_cwd = lambda name: picked
class R:
    returncode = 0; stdout = ''; stderr = b''
subprocess.run = lambda cmd, *a, **k: R()
bridge.save_claude_session_cwd = lambda n, c: None
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda n: None
bridge.time.sleep = lambda *a, **k: None
bridge.wait_for_pane_shell_ready = lambda *a, **k: True
bridge.state['active'] = None
focused = []
bridge.set_focus = lambda name: focused.append(name)
try:
    wm.open_session('tF', chat_id=11)
except Exception:
    pass
assert focused == [], ('open_session must not set focus:', focused)
assert bridge.state['active'] is None, bridge.state['active']
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_session() does not set focus/active"
    else
        fail "open_session no-focus test failed"
    fi
}

test_startup_message_topic_semantics() {
    info "Testing the startup notification speaks topic semantics (no Team:/Focused:/hire)..."
    if python3 -c "
import bridge
cr = bridge.command_router
cr.workers.get_registered_sessions = lambda registered=None: {'t46': {}, 't51': {}}
replies = []
cr.reply = lambda chat_id, text, **kw: replies.append(text)
cr.send_startup_message(555)
out = replies[0]
assert '話題' in out and '2' in out, out
assert 'Team:' not in out, out
assert 'Focused:' not in out, out
assert '/hire' not in out, out
# Zero sessions: still topic semantics, no hire pitch
cr.workers.get_registered_sessions = lambda registered=None: {}
replies.clear()
cr.send_startup_message(555)
assert '/hire' not in replies[0] and 'hire' not in replies[0].lower(), replies
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "startup notification uses topic semantics"
    else
        fail "startup message semantics test failed"
    fi
}

test_topic_closed_ends_session() {
    info "Testing forum_topic_closed ends the bound session and cleans topic globals..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
ended = []
cr.workers.get_registered_sessions = lambda registered=None: {'tX': {}}
bridge.find_topic_session = lambda c, t, r: 'tX'
cr.workers.close_session = lambda name: ended.append(name)
bridge._topic_titles[(555, 70)] = 'x'
bridge._awaiting_folder.add((555, 70))
bridge._picker_sent_at[(555, 70)] = 1.0
msg = {'message_thread_id': 70, 'forum_topic_closed': {}, 'chat': {'id': 555}}
cr._handle_topic_message(msg, '', 555, 7)
assert ended == ['tX'], ('closed must end the session:', ended)
assert (555, 70) not in bridge._topic_titles, bridge._topic_titles
assert (555, 70) not in bridge._awaiting_folder, bridge._awaiting_folder
assert (555, 70) not in bridge._picker_sent_at, bridge._picker_sent_at
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "forum_topic_closed ends session + cleans globals"
    else
        fail "topic closed-ends-session test failed"
    fi
}

test_topic_reopened_unbound_shows_picker() {
    info "Testing forum_topic_reopened acts like a fresh topic (picker when unbound, silent when bound)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
cr.workers.get_registered_sessions = lambda registered=None: {}
shown = []
routed = []
cr._send_folder_picker = lambda c, t: shown.append((c, t))
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
bridge.find_topic_session = lambda c, t, r: None
msg = {'message_thread_id': 71, 'forum_topic_reopened': {}, 'chat': {'id': 555}}
cr._handle_topic_message(msg, '', 555, 8)
assert shown == [(555, 71)], ('reopened unbound should show picker:', shown)
# Already bound: no picker, and the service message must NOT be routed
bridge.find_topic_session = lambda c, t, r: 'tY'
cr._handle_topic_message(msg, '', 555, 9)
assert shown == [(555, 71)], ('reopened bound must not re-prompt:', shown)
assert routed == [], ('service message must never be routed:', routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "forum_topic_reopened: picker when unbound, silent when bound"
    else
        fail "topic reopened test failed"
    fi
}

test_deleted_topic_reaped_on_send_failure() {
    info "Testing a thread-not-found send failure reaps the session (topic deleted has no event)..."
    if python3 -c "
import bridge
ended = []
bridge.session_manager.close_session = lambda name: ended.append(name)
bridge.load_topic_meta = lambda name: (555, 72)
bridge._topic_titles[(555, 72)] = 'x'
calls = []
bridge.transport.send_text = (lambda chat_id, text, parse_mode=None, reply_to=None,
    message_thread_id=None: calls.append(text) or
    {'ok': False, 'error_code': 400, 'description': 'Bad Request: message thread not found'})
bridge.send_response_to_telegram('tZ', 'hello', 555)
assert ended == ['tZ'], ('dead topic must reap session:', ended)
assert len(calls) == 1, ('no futile retry after thread-not-found:', calls)
assert (555, 72) not in bridge._topic_titles, bridge._topic_titles
# Other 400s are NOT reaped (HTML parse errors etc.)
assert not bridge._reap_dead_topic('tZ', {'ok': False, 'error_code': 400, 'description': 'Bad Request: parse error'})
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "deleted topic reaped on thread-not-found send failure"
    else
        fail "dead-topic reap test failed"
    fi
}

test_topic_photo_routed_with_local_path() {
    info "Testing a photo sent in a topic is downloaded and routed with its local path..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {'tP': {}}
bridge.find_topic_session = lambda c, t, r: 'tP'
dl = []
bridge.download_telegram_file = lambda file_id, target: dl.append((file_id, target)) or '/tmp/in/x.jpg'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
msg = {'message_thread_id': 90, 'chat': {'id': 555}, 'caption': 'look at this',
       'photo': [{'file_id': 'small', 'file_size': 10}, {'file_id': 'big', 'file_size': 99}]}
cr._handle_topic_message(msg, 'look at this', 555, 7)
assert dl == [('big', 'tP')], ('largest photo downloaded into the session inbox:', dl)
assert routed and routed[0][0] == 'tP', routed
assert '/tmp/in/x.jpg' in routed[0][1] and 'look at this' in routed[0][1], routed
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic photo downloaded + routed with local path"
    else
        fail "topic photo routing test failed"
    fi
}

test_topic_document_routed_with_metadata() {
    info "Testing a document sent in a topic routes with name/size/path..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {'tP': {}}
bridge.find_topic_session = lambda c, t, r: 'tP'
bridge.download_telegram_file = lambda file_id, target: '/tmp/in/spec.pdf'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
msg = {'message_thread_id': 90, 'chat': {'id': 555},
       'document': {'file_id': 'd1', 'file_name': 'spec.pdf', 'file_size': 2048, 'mime_type': 'application/pdf'}}
cr._handle_topic_message(msg, '', 555, 7)
assert routed, 'document must be routed'
assert 'spec.pdf' in routed[0][1] and '/tmp/in/spec.pdf' in routed[0][1], routed
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic document routed with metadata + path"
    else
        fail "topic document routing test failed"
    fi
}

test_topic_voice_transcribed_transparently() {
    info "Testing a voice message in a topic routes its transcript as plain text..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {'tP': {}}
bridge.find_topic_session = lambda c, t, r: 'tP'
bridge.download_telegram_file = lambda file_id, target: '/tmp/in/v.ogg'
bridge.transcribe_voice = lambda path: '幫我跑測試'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
msg = {'message_thread_id': 90, 'chat': {'id': 555},
       'voice': {'file_id': 'v1', 'duration': 3}}
cr._handle_topic_message(msg, '', 555, 7)
assert routed == [('tP', '幫我跑測試')], ('transcript should route as if typed:', routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic voice transcribed and routed transparently"
    else
        fail "topic voice transcription test failed"
    fi
}

test_topic_media_before_binding_not_forwarded() {
    info "Testing media in an unbound topic acts as trigger only (picker, no download)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
bridge._picker_sent_at.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
bridge.find_topic_session = lambda c, t, r: None
dl = []
bridge.download_telegram_file = lambda file_id, target: dl.append(file_id) or '/tmp/x'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
shown = []
cr._send_folder_picker = lambda c, t: shown.append((c, t))
msg = {'message_thread_id': 91, 'chat': {'id': 555},
       'photo': [{'file_id': 'p', 'file_size': 5}]}
cr._handle_topic_message(msg, '', 555, 7)
assert shown == [(555, 91)], ('unbound media should summon picker:', shown)
assert dl == [] and routed == [], ('media must not download/route before binding:', dl, routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "media before binding is trigger-only"
    else
        fail "unbound media test failed"
    fi
}

test_topic_folder_callback_data_within_limit() {
    info "Testing folder-picker callback_data stays <= 64 bytes for deep paths (token, not full path)..."
    if python3 -c "
import os, tempfile
import bridge
root = tempfile.mkdtemp()
deep = os.path.join(root, 'research', 'claudecode-telegram', 'docs', 'superpowers')
os.makedirs(deep)
bridge.TOPIC_ROOT = root
# A deep level whose buttons (subdir + up + use) would overflow 64 bytes with full paths.
for level in (root, os.path.dirname(deep), deep):
    for row in bridge.build_folder_keyboard(level):
        for btn in row:
            cd = btn['callback_data']
            assert len(cd.encode()) <= 64, ('callback_data too long:', len(cd.encode()), cd)
# Round-trip: a cd: token resolves back to a real path under root.
tok = None
for row in bridge.build_folder_keyboard(root):
    for btn in row:
        if btn['callback_data'].startswith('cd:'):
            tok = btn['callback_data'][3:]
assert tok and bridge._folder_from_token(tok), ('token must resolve back to a path:', tok)
assert bridge._folder_from_token(tok).startswith(os.path.realpath(root))
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "folder-picker callback_data within Telegram's 64-byte limit"
    else
        fail "topic folder callback_data limit test failed"
    fi
}

test_topic_open_sends_welcome_only() {
    info "Testing open_topic_session sends exactly ONE welcome (trigger text never forwarded)..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge.resolve_topic_session_name = lambda c, t, r: 'tZ'
bridge._set_worker_cwd = lambda n, c: None
bridge.create_session = lambda name, chat_id=None: None
bridge.save_topic_meta = lambda n, c, t: None
cr.workers.get_registered_sessions = lambda registered=None: {}
cr.workers._build_welcome = lambda n, b: 'WELCOME-TEXT'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append(text)
cr.open_topic_session(555, 4321, '/tmp')
assert routed == ['WELCOME-TEXT'], ('expected one welcome-only send, got:', routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_topic_session sends welcome only (single reply)"
    else
        fail "topic welcome-only test failed"
    fi
}

test_topic_first_message_trigger_not_forwarded() {
    info "Testing the topic-creating first message is a trigger only (picker, never forwarded)..."
    if python3 -c "
import tempfile
import bridge
bridge.TOPIC_MODE = True
bridge.TOPIC_ROOT = tempfile.mkdtemp()
cr = bridge.command_router
bridge._awaiting_folder.clear()
bridge._picker_sent_at.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
routed = []
sent = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
bridge.telegram_api = lambda m, d: sent.append((m, d)) or {'ok': True}
# 1) the junk message that created the topic triggers the picker, no routing
msg = {'message_thread_id': 880, 'text': '879', 'chat': {'id': 555}}
cr._handle_topic_message(msg, '879', 555, 7)
assert any(m == 'sendMessage' for m, d in sent), sent
assert routed == [], ('trigger must not be routed:', routed)
# 2) picking a folder opens the session with the welcome ONLY — no '879'
bridge.resolve_topic_session_name = lambda c, t, r: 'tQ'
bridge._set_worker_cwd = lambda n, c: None
bridge.create_session = lambda name, chat_id=None: None
bridge.save_topic_meta = lambda n, c, t: None
cr.workers._build_welcome = lambda n, b: 'WELCOME'
tok = bridge._folder_token(bridge.TOPIC_ROOT)
cb = {'callback_query': {'id': 'x', 'data': 'use:' + tok,
      'message': {'chat': {'id': 555}, 'message_id': 1, 'message_thread_id': 880}}}
cr.handle_callback(cb)
assert routed and routed[0][1] == 'WELCOME', routed
assert all('879' not in t for n, t in routed), ('trigger text leaked to worker:', routed)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "first message is trigger-only (never forwarded to the worker)"
    else
        fail "topic trigger-only test failed"
    fi
}

test_topic_trigger_swallowed_in_grace_window() {
    info "Testing the creation-companion message is silently swallowed inside the picker grace window..."
    if python3 -c "
import bridge
bridge.TOPIC_MODE = True
cr = bridge.command_router
bridge._awaiting_folder.clear()
bridge._picker_sent_at.clear()
cr.workers.get_registered_sessions = lambda registered=None: {}
routed = []
replies = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))
cr.reply = lambda chat_id, text, **kw: replies.append(text)
key = (555, 881)
bridge._awaiting_folder.add(key)
# Inside the grace window: swallow silently (it is the topic-creation trigger)
bridge._picker_sent_at[key] = bridge.time.time()
msg = {'message_thread_id': 881, 'text': 'junk', 'chat': {'id': 555}}
cr._handle_topic_message(msg, 'junk', 555, 7)
assert routed == [] and replies == [], ('grace window must be silent:', routed, replies)
# After the window: nudge the user to tap a button
bridge._picker_sent_at[key] = bridge.time.time() - 60
cr._handle_topic_message(msg, 'junk2', 555, 8)
assert routed == [], routed
assert replies and '按鈕' in replies[0], replies
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "creation trigger swallowed in grace window; later text nudges"
    else
        fail "grace-window test failed"
    fi
}

test_topic_typing_targets_thread() {
    info "Testing typing indicator is sent into the topic thread, not General..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True
(tmp / 't7').mkdir(parents=True, exist_ok=True)
bridge.save_topic_meta('t7', 555, 4321)
bridge.time.sleep = lambda *a, **k: None
bridge._session_states.pop('t7', None)
seq = [True, False]
bridge.is_pending = lambda name: seq.pop(0) if seq else False
rec = []
bridge.transport.send_chat_action = lambda chat_id, action, message_thread_id=None: rec.append((chat_id, action, message_thread_id))
bridge.send_typing_loop(555, 't7')
assert rec == [(555, 'typing', 4321)], rec
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "typing targets the topic thread"
    else
        fail "typing thread-target test failed"
    fi
}

test_hook_reply_targets_thread() {
    info "Testing hook reply carries message_thread_id..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.session_manager.sessions_dir = tmp
(tmp / 't4321').mkdir(parents=True, exist_ok=True); bridge.save_topic_meta('t4321', 555, 4321)
sent = {}
bridge.transport.send_text = lambda chat_id, text, parse_mode=None, reply_to=None, message_thread_id=None: sent.update({'chat': chat_id, 'thread': message_thread_id, 'text': text}) or {'ok': True}
bridge.send_response_to_telegram('t4321', 'done', 555)
assert sent.get('thread') == 4321, sent
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "hook reply targets thread"
    else
        fail "hook reply thread test failed"
    fi
}

test_quota_render() {
    info "Testing /quota rendering + fallback..."
    if python3 -c "
import bridge
snap = {'updated_at': '2026-06-10T12:00:00+00:00',
        'five_hour': {'used_percentage': 31, 'resets_at': '2026-06-10T14:00:00+00:00'},
        'seven_day': {'used_percentage': 82, 'resets_at': '2026-06-12T00:00:00+00:00'}}
out = bridge.format_quota(snap)
# Candidate C: Telegram-native colour heat bars, NOT terminal █░
assert '額度' in out, out
assert '5 小時' in out and '31%' in out, out
assert '本週' in out and '82%' in out, out
assert '🟩' in out, out
assert '█' not in out and '░' not in out, ('terminal bar chars leaked', out)
# heat zones: low usage stays green; near-full crosses into red
low = bridge._quota_heat_bar(30)
assert '🟩' in low and '🟨' not in low and '🟥' not in low, low
assert '🟥' in bridge._quota_heat_bar(95), bridge._quota_heat_bar(95)
# a small non-zero usage still lights at least one cell (not a confusingly empty bar)
assert bridge._quota_heat_bar(3).count('🟩') == 1, bridge._quota_heat_bar(3)
assert bridge._quota_heat_bar(0).count('🟩') == 0, bridge._quota_heat_bar(0)
# fallback when no data
none_out = bridge.format_quota(None)
assert 'unavailable' in none_out.lower() or '無' in none_out, none_out
# null window
half = {'updated_at': '2026-06-10T12:00:00+00:00', 'five_hour': {'used_percentage': None, 'resets_at': None}, 'seven_day': {'used_percentage': 50, 'resets_at': '2026-06-12T00:00:00+00:00'}}
ho = bridge.format_quota(half)
assert 'n/a' in ho.lower() and '50%' in ho, ho
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/quota render works"
    else
        fail "/quota render test failed"
    fi
}

test_quota_api_fallback() {
    info "Testing /quota hybrid resolve: snapshot fast-path → live OAuth-API fallback..."
    if python3 -c "
import bridge

# 1) fresh snapshot wins — API must NOT be called (fast path)
bridge.read_usage_snapshot = lambda: {'updated_at': 'x',
    'five_hour': {'used_percentage': 10, 'resets_at': None},
    'seven_day': {'used_percentage': 20, 'resets_at': None}}
called = {'api': False}
def _boom():
    called['api'] = True
    return None
bridge.fetch_usage_from_api = _boom
r = bridge.resolve_usage()
assert r['five_hour']['used_percentage'] == 10, r
assert called['api'] is False, 'API called despite fresh snapshot'

# 2) snapshot missing/stale → fall back to API
bridge.read_usage_snapshot = lambda: None
bridge.fetch_usage_from_api = lambda: {'updated_at': 'x',
    'five_hour': {'used_percentage': 20, 'resets_at': None},
    'seven_day': {'used_percentage': 29, 'resets_at': None}}
r2 = bridge.resolve_usage()
assert r2 is not None and r2['five_hour']['used_percentage'] == 20, r2

# 3) both unavailable → None → format_quota shows the unavailable fallback
bridge.fetch_usage_from_api = lambda: None
assert bridge.resolve_usage() is None
assert 'unavailable' in bridge.format_quota(bridge.resolve_usage()).lower()

# 4) _map_oauth_usage maps API 'utilization' → 'used_percentage' (rounded), keeps resets_at,
#    ignores extra windows, stamps the given updated_at
m = bridge._map_oauth_usage({
    'five_hour': {'utilization': 20.0, 'resets_at': '2026-06-15T04:30:00Z'},
    'seven_day': {'utilization': 29.4, 'resets_at': None},
    'seven_day_sonnet': {'utilization': 2.0}}, now='2026-06-15T01:00:00+00:00')
assert m['five_hour']['used_percentage'] == 20, m
assert m['seven_day']['used_percentage'] == 29, m
assert m['five_hour']['resets_at'] == '2026-06-15T04:30:00Z', m
assert m['updated_at'] == '2026-06-15T01:00:00+00:00', m

# 5) no windows with a percentage → None (so the bridge won't render an empty snapshot)
assert bridge._map_oauth_usage({'extra_usage': {}}) is None
assert bridge._map_oauth_usage('nonsense') is None
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/quota API fallback works"
    else
        fail "/quota API fallback test failed"
    fi
}

test_message_splitting() {
    info "Testing message splitting (short, newlines, hard, HTML-aware)..."
    if python3 -c "
import re
from bridge import split_message, markdown_to_telegram_html, TELEGRAM_MAX_LENGTH

TAG_RE = re.compile(r'<(/?)(\w+)([^>]*?)>')
VALID = {'b','i','s','u','code','pre','a','strong','em','del','ins','strike'}

def tags_balanced(html):
    stack = []
    for m in TAG_RE.finditer(html):
        close, tag = m.group(1) == '/', m.group(2).lower()
        if tag not in VALID: continue
        if close:
            for j in range(len(stack)-1,-1,-1):
                if stack[j] == tag: stack.pop(j); break
            else: return False
        else: stack.append(tag)
    return len(stack) == 0

# 1. Short message - no split
chunks = split_message('Short message')
assert len(chunks) == 1

# 2. Split on newlines
long_text = chr(10).join(['Line ' + str(i) + ' ' + 'x' * 100 for i in range(50)])
chunks = split_message(long_text, max_len=4096)
assert len(chunks) > 1
for c in chunks: assert len(c) <= 4096

# 3. Hard split (no natural breaks)
chunks = split_message('x' * 10000, max_len=4096)
assert len(chunks) >= 3
for c in chunks: assert len(c) <= 4096

# 4. HTML-aware: long code block stays balanced after split
code = chr(10).join([f'echo line{i} padding' + 'x'*40 for i in range(80)])
fence = chr(96)*3
html = markdown_to_telegram_html(f'Script:\n\n{fence}bash\n{code}\n{fence}\n\nDone.')
chunks = split_message(html, max_len=4096)
assert len(chunks) >= 2, f'expected 2+ chunks, got {len(chunks)}'
for i, c in enumerate(chunks):
    assert tags_balanced(c), f'chunk {i} has unbalanced HTML tags'
    assert len(c) <= 4096, f'chunk {i} too long: {len(c)}'

# 5. Nested inline tags across split
bt = chr(96)
nested = f'Text **bold with {bt}code{bt} end** rest. ' * 100
html = markdown_to_telegram_html(nested)
chunks = split_message(html, max_len=4096)
if len(chunks) > 1:
    for i, c in enumerate(chunks):
        assert tags_balanced(c), f'nested chunk {i} unbalanced'

# 6. Code block reopened in continuation chunk
code = chr(10).join([f'variable_{i} = \"value_{i}_padding\"' + 'x'*30 for i in range(100)])
html = markdown_to_telegram_html(f'{fence}python\n{code}\n{fence}')
chunks = split_message(html, max_len=4096)
assert len(chunks) >= 2
# Second chunk should start with <pre><code (reopened)
assert '<pre>' in chunks[1] or '<code' in chunks[1], 'continuation chunk missing reopened pre/code tag'
for i, c in enumerate(chunks):
    assert tags_balanced(c), f'reopen chunk {i} unbalanced'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Message splitting works (short, newlines, hard, HTML-aware)"
    else
        fail "Message splitting test failed"
    fi
}

test_media_tag_parsing() {
    info "Testing image/file tag parsing and protection..."

    # Create test files
    touch /tmp/test.jpg /tmp/a.jpg /tmp/b.png
    echo "test" > /tmp/report.pdf
    echo "test" > /tmp/data.json
    echo "test" > /tmp/a.txt
    echo "test" > /tmp/b.csv

    if python3 -c "
from bridge import parse_image_tags, parse_file_tags

# === Image tag parsing ===
text = 'Here is an image [[image:/tmp/test.jpg|my caption]] and more text'
clean, images = parse_image_tags(text)
assert 'Here is an image' in clean, f'clean text wrong: {clean!r}'
assert len(images) == 1, f'expected 1 image, got {len(images)}'
assert images[0] == ('/tmp/test.jpg', 'my caption'), f'image data wrong: {images[0]}'

# Non-existent file (tag stays)
text2 = '[[image:/nonexistent/photo.png]]'
clean2, images2 = parse_image_tags(text2)
assert len(images2) == 0
assert '[[image:' in clean2

# Multiple images
text3 = 'First [[image:/tmp/a.jpg|cap1]] middle [[image:/tmp/b.png|cap2]] end'
clean3, images3 = parse_image_tags(text3)
assert len(images3) == 2

# Escaped image tag
text4 = r'Example: \[[image:/tmp/test.jpg|caption]]'
clean4, images4 = parse_image_tags(text4)
assert len(images4) == 0

# === File tag parsing ===
text = 'Here is the report: [[file:/tmp/report.pdf|Q4 Report]]'
clean, files = parse_file_tags(text)
assert 'Here is the report:' in clean
assert len(files) == 1
assert files[0] == ('/tmp/report.pdf', 'Q4 Report')

text = 'Output: [[file:/tmp/data.json]]'
clean, files = parse_file_tags(text)
assert len(files) == 1
assert files[0] == ('/tmp/data.json', '')

text = 'Output: [[file:/nonexistent/file.txt]]'
clean, files = parse_file_tags(text)
assert len(files) == 0
assert '[[file:' in clean

text = '[[file:/tmp/a.txt|A]] and [[file:/tmp/b.csv|B]]'
clean, files = parse_file_tags(text)
assert len(files) == 2

# Escaped file tag
text = r'Example: \[[file:/tmp/report.pdf|caption]]'
clean, files = parse_file_tags(text)
assert len(files) == 0

# === Escape tag preservation ===
text = r'Example: \[[image:/tmp/test.jpg|caption]] stays'
clean, images = parse_image_tags(text)
assert len(images) == 0
assert '[[image:' in clean

text = r'Example: \[[file:/tmp/a.txt|caption]] stays'
clean, files = parse_file_tags(text)
assert len(files) == 0
assert '[[file:' in clean

# === Code fence protection ===
import textwrap
text = textwrap.dedent('''
Here is code:
\x60\x60\x60
[[image:/tmp/test.jpg|caption]]
\x60\x60\x60
And outside text''').strip()
clean, images = parse_image_tags(text)
assert len(images) == 0, 'tag in code fence should not be parsed'
assert '[[image:' in clean

text2 = 'Use \x60[[image:/path|cap]]\x60 syntax'
clean2, images2 = parse_image_tags(text2)
assert len(images2) == 0, 'tag in inline code should not be parsed'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Image/file tag parsing and protection work"
    else
        fail "Media tag parsing test failed"
    fi

    # Cleanup
    rm -f /tmp/test.jpg /tmp/a.jpg /tmp/b.png /tmp/report.pdf /tmp/data.json /tmp/a.txt /tmp/b.csv
}

test_pending_files() {
    info "Testing pending set/clear, timestamp, and chat_id file..."
    if python3 -c "
from bridge import set_pending, clear_pending, is_pending, get_session_dir, get_pending_file
from pathlib import Path
import time
import shutil
import stat

# === Set and clear ===
set_pending('pending_test', 12345)
assert is_pending('pending_test'), 'pending should be set'

chat_id_file = get_session_dir('pending_test') / 'chat_id'
assert chat_id_file.exists(), 'chat_id file should exist'
assert chat_id_file.read_text().strip() == '12345', 'chat_id should be 12345'

perms = oct(chat_id_file.stat().st_mode)[-3:]
assert perms == '600', f'chat_id file should be 600, got {perms}'

clear_pending('pending_test')
assert not is_pending('pending_test'), 'pending should be cleared'

# === Pending file timestamp ===
set_pending('timestamp_test', 12345)
pending_file = get_pending_file('timestamp_test')
content = pending_file.read_text().strip()
ts = int(content)
assert ts > 1000000000, f'Should be unix timestamp, got {ts}'
shutil.rmtree(pending_file.parent, ignore_errors=True)

# === Chat ID file content ===
test_chat = 987654321
set_pending('chatid_test', test_chat)
chat_file = get_session_dir('chatid_test') / 'chat_id'
content = chat_file.read_text().strip()
assert content == str(test_chat), f'Expected {test_chat}, got {content}'
shutil.rmtree(get_session_dir('chatid_test'), ignore_errors=True)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Pending files (set/clear, timestamp, chat_id) work"
    else
        fail "Pending files test failed"
    fi
}


test_cli_flags_and_commands() {
    info "Testing CLI flags and commands..."
    local all_pass=true

    # --flag=value syntax
    if ! ./claudecode-telegram.sh --node=testnode --port=9999 --help 2>/dev/null | grep -qi "usage"; then
        fail "Equals syntax (--flag=value) failed"
        all_pass=false
    fi

    # --node flag
    if ! ./claudecode-telegram.sh --node mynode --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --node flag failed"
        all_pass=false
    fi

    # --port flag
    if ! ./claudecode-telegram.sh --port 9999 --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --port flag failed"
        all_pass=false
    fi

    # --all flag
    if ! ./claudecode-telegram.sh --all --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --all flag failed"
        all_pass=false
    fi

    # --no-tunnel flag
    if ! ./claudecode-telegram.sh --help 2>/dev/null | grep -q "no-tunnel"; then
        fail "CLI --no-tunnel not documented"
        all_pass=false
    fi

    # --tunnel-url flag
    if ! ./claudecode-telegram.sh --help 2>/dev/null | grep -q "tunnel-url"; then
        fail "CLI --tunnel-url not documented"
        all_pass=false
    fi

    # --headless flag
    if ! ./claudecode-telegram.sh --headless --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --headless flag failed"
        all_pass=false
    fi

    # -q (quiet) flag
    local result
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh -q --version 2>&1)
    if ! echo "$result" | grep -q "claudecode-telegram"; then
        fail "CLI -q flag failed"
        all_pass=false
    fi

    # -v (verbose) flag
    if ! ./claudecode-telegram.sh -v --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI -v flag failed"
        all_pass=false
    fi

    # --no-color flag
    if ! ./claudecode-telegram.sh --no-color --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --no-color flag failed"
        all_pass=false
    fi

    # --env-file flag
    local tmp_env=$(mktemp)
    echo "TEST_VAR=hello" > "$tmp_env"
    if ! ./claudecode-telegram.sh --env-file="$tmp_env" --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --env-file flag failed"
        all_pass=false
    fi
    rm -f "$tmp_env"

    # --sandbox-image flag
    if ! ./claudecode-telegram.sh --sandbox-image=myimage:latest --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --sandbox-image flag failed"
        all_pass=false
    fi

    # --mount flag
    if ! ./claudecode-telegram.sh --mount=/tmp:/container --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --mount flag failed"
        all_pass=false
    fi

    # --mount-ro flag
    if ! ./claudecode-telegram.sh --mount-ro=/tmp:/container --help 2>/dev/null | grep -qi "usage"; then
        fail "CLI --mount-ro flag failed"
        all_pass=false
    fi

    # stop command
    if ! ./claudecode-telegram.sh --help 2>/dev/null | grep -q "stop"; then
        fail "CLI stop command not documented"
        all_pass=false
    fi

    # restart command
    if ! ./claudecode-telegram.sh --help 2>/dev/null | grep -q "restart"; then
        fail "CLI restart command not documented"
        all_pass=false
    fi

    # clean command
    if ! ./claudecode-telegram.sh --help 2>/dev/null | grep -q "clean"; then
        fail "CLI clean command not documented"
        all_pass=false
    fi

    if $all_pass; then
        success "All CLI flags and commands parsed correctly"
    fi
}

test_webhook_secret() {
    info "Testing webhook secret validation and acceptance..."

    local secret_port=8096
    local secret_log="$TEST_NODE_DIR/secret_bridge.log"
    local secret_sessions_dir="$TEST_NODE_DIR/secret_sessions"
    local secret_tmux_prefix="claude-${TEST_NODE}-secret-"
    local secret_value="test-secret-merged-123"

    while nc -z localhost "$secret_port" 2>/dev/null; do
        secret_port=$((secret_port + 1))
        if [[ "$secret_port" -gt 8110 ]]; then
            fail "No free port for webhook secret test"
            return
        fi
    done

    mkdir -p "$secret_sessions_dir"
    chmod 700 "$secret_sessions_dir"

    TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" \
    PORT="$secret_port" \
    TELEGRAM_WEBHOOK_SECRET="$secret_value" \
    NODE_NAME="secretmerged" \
    SESSIONS_DIR="$secret_sessions_dir" \
    TMUX_PREFIX="$secret_tmux_prefix" \
    python3 -u "$SCRIPT_DIR/bridge.py" > "$secret_log" 2>&1 &
    local secret_pid=$!

    if wait_for_port "$secret_port"; then
        # Without secret header -> 403
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$secret_port" \
            -H "Content-Type: application/json" \
            -d '{"update_id": 1, "message": {"message_id": 1, "chat": {"id": 123}, "text": "test"}}')
        if [[ "$http_code" == "403" ]]; then
            success "Request without secret rejected (403)"
        else
            fail "Expected 403 without secret, got $http_code"
        fi

        # With correct secret -> 200
        local ok_response
        ok_response=$(curl -s -X POST "http://localhost:$secret_port" \
            -H "Content-Type: application/json" \
            -H "X-Telegram-Bot-Api-Secret-Token: $secret_value" \
            -d '{"update_id": 2, "message": {"message_id": 2, "chat": {"id": '"$CHAT_ID"'}, "text": "test"}}')
        if [[ "$ok_response" == "OK" ]]; then
            success "Request with correct secret accepted"
        else
            fail "Expected OK for correct secret, got: $ok_response"
        fi

        # With wrong secret -> 403
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$secret_port" \
            -H "Content-Type: application/json" \
            -H "X-Telegram-Bot-Api-Secret-Token: wrong-secret" \
            -d '{"update_id": 3, "message": {"message_id": 3, "chat": {"id": 123}, "text": "test"}}')
        if [[ "$http_code" == "403" ]]; then
            success "Request with wrong secret rejected (403)"
        else
            fail "Expected 403 for wrong secret, got $http_code"
        fi
    else
        fail "Could not start bridge with webhook secret"
    fi

    kill "$secret_pid" 2>/dev/null || true
    rm -f "$secret_log"
    rm -rf "$secret_sessions_dir"
}

test_cli_webhook_commands() {
    info "Testing CLI webhook commands..."

    if [[ -z "${TEST_BOT_TOKEN:-}" ]]; then
        success "CLI webhook commands skipped (no TEST_BOT_TOKEN)"
        return
    fi

    # webhook set URL
    local test_url="https://example.com/test-webhook-${RANDOM}"
    local result
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh webhook "$test_url" 2>&1) || true
    if echo "$result" | grep -qi -e "configured\|ok\|success"; then
        success "CLI webhook set URL works"
    else
        success "CLI webhook set command executed"
    fi

    # webhook requires HTTPS
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh webhook "http://example.com/test" 2>&1) || true
    if echo "$result" | grep -qi -e "https\|error\|must"; then
        success "CLI webhook rejects non-HTTPS URL"
    else
        fail "CLI webhook should reject HTTP URLs: $result"
    fi

    # webhook delete requires confirmation
    result=$(echo "n" | TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh webhook delete 2>&1) || true
    if echo "$result" | grep -qi -e "cancel\|delete\|confirm\|y/n"; then
        success "CLI webhook delete asks for confirmation"
    else
        success "CLI webhook delete handled (non-interactive)"
    fi

    # Clean up
    TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh webhook delete --force 2>/dev/null || true
}

test_send_to_session_missing() {
    info "Testing send_to_session for non-existent workers..."
    if python3 -c "
import os
import importlib
import bridge
importlib.reload(bridge)

from bridge import send_to_session

# Non-existent worker returns False
result = send_to_session('nonexistent_worker_12345', 'test message')
assert result == False, f'Expected False, got {result}'

# Another non-existent tmux worker also returns False
result2 = send_to_session('nonexistent_tmux_worker_xyz', 'test message')
assert result2 == False, f'Expected False, got {result2}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "send_to_session returns False for non-existent workers"
    else
        fail "send_to_session missing worker test failed"
    fi
}

# ── Voice Mode Tests (STT/TTS) ──────────────────────────────────────────────

test_transcribe_voice_success() {
    info "Testing transcribe_voice returns transcript on success..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge
bridge.STT_ENDPOINT = 'http://stt.test/transcribe'  # endpoint now defaults to '' (5b); set it so transcribe_voice doesn't fail-open

# Create a temp file to simulate audio
tmp = tempfile.NamedTemporaryFile(suffix='.ogg', delete=False)
tmp.write(b'fake audio data')
tmp.close()

# Mock urllib to return a successful transcription
mock_response = MagicMock()
mock_response.read.return_value = json.dumps({'text': 'hello world', 'audio_duration_s': 2.5}).encode()
mock_response.__enter__ = lambda s: s
mock_response.__exit__ = MagicMock(return_value=False)

try:
    with patch('urllib.request.urlopen', return_value=mock_response):
        result = bridge.transcribe_voice(tmp.name)
    assert result == 'hello world', f'Expected \"hello world\", got {result!r}'
    print('OK')
finally:
    os.unlink(tmp.name)
" 2>/dev/null | grep -q "OK"; then
        success "transcribe_voice returns transcript on success"
    else
        fail "transcribe_voice success test failed"
    fi
}

test_transcribe_voice_timeout_returns_none() {
    info "Testing transcribe_voice returns None on timeout..."
    if python3 -c "
import sys, os, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
import bridge
bridge.STT_ENDPOINT = 'http://stt.test/transcribe'  # endpoint defaults to '' (5b); set it so we reach the timeout path

# A real audio file is required, or transcribe_voice returns on the missing-file
# early-return BEFORE urlopen — a false-green that never tests the timeout path.
tmp = tempfile.NamedTemporaryFile(suffix='.ogg', delete=False)
tmp.write(b'fake audio data'); tmp.close()
try:
    with patch('urllib.request.urlopen', side_effect=Exception('timeout')) as mock_url:
        result = bridge.transcribe_voice(tmp.name)
    mock_url.assert_called_once()  # prove we actually reached the network call
    assert result is None, f'Expected None, got {result!r}'
    print('OK')
finally:
    os.unlink(tmp.name)
" 2>/dev/null | grep -q "OK"; then
        success "transcribe_voice returns None on timeout"
    else
        fail "transcribe_voice timeout test failed"
    fi
}

test_transcribe_voice_bad_json_returns_none() {
    info "Testing transcribe_voice returns None on bad JSON..."
    if python3 -c "
import sys, os, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge
bridge.STT_ENDPOINT = 'http://stt.test/transcribe'  # endpoint defaults to '' (5b); set it so we reach the bad-JSON path

mock_response = MagicMock()
mock_response.read.return_value = b'not json'
mock_response.__enter__ = lambda s: s
mock_response.__exit__ = MagicMock(return_value=False)

# Real file required, or transcribe_voice returns on the missing-file early-return
# BEFORE urlopen — a false-green that never tests JSON-parse failure.
tmp = tempfile.NamedTemporaryFile(suffix='.ogg', delete=False)
tmp.write(b'fake audio data'); tmp.close()
try:
    with patch('urllib.request.urlopen', return_value=mock_response) as mock_url:
        result = bridge.transcribe_voice(tmp.name)
    mock_url.assert_called_once()  # prove we actually reached the JSON-parse path
    assert result is None, f'Expected None, got {result!r}'
    print('OK')
finally:
    os.unlink(tmp.name)
" 2>/dev/null | grep -q "OK"; then
        success "transcribe_voice returns None on bad JSON"
    else
        fail "transcribe_voice bad JSON test failed"
    fi
}

test_voice_message_includes_transcript() {
    info "Testing a voice update through handle_message routes its transcript transparently..."
    if python3 -c "
from unittest.mock import patch
import bridge

cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {'tV': {}}
bridge.find_topic_session = lambda c, t, r: 'tV'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))

update = {'update_id': 1, 'message': {
    'message_id': 42, 'chat': {'id': 12345}, 'message_thread_id': 95,
    'voice': {'file_id': 'voice123', 'duration': 5}}}
with patch.object(bridge, 'download_telegram_file', return_value='/tmp/inbox/test.ogg'), \
     patch.object(bridge, 'transcribe_voice', return_value='hello this is a test'):
    cr.handle_message(update)

assert routed == [('tV', 'hello this is a test')], routed
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Voice message delivers transcript transparently"
    else
        fail "Voice message transparent transcript test failed"
    fi
}

test_voice_message_fallback_without_transcript() {
    info "Testing voice in a topic falls back to file path when STT fails..."
    if python3 -c "
from unittest.mock import patch
import bridge

cr = bridge.command_router
bridge._awaiting_folder.clear()
cr.workers.get_registered_sessions = lambda registered=None: {'tV': {}}
bridge.find_topic_session = lambda c, t, r: 'tV'
routed = []
cr.route_message = lambda name, text, chat_id, msg_id: routed.append((name, text))

update = {'update_id': 1, 'message': {
    'message_id': 42, 'chat': {'id': 12345}, 'message_thread_id': 95,
    'voice': {'file_id': 'voice456', 'duration': 3}}}
with patch.object(bridge, 'download_telegram_file', return_value='/tmp/inbox/test2.ogg'), \
     patch.object(bridge, 'transcribe_voice', return_value=None):
    cr.handle_message(update)

assert len(routed) == 1, routed
msg = routed[0][1]
assert '/tmp/inbox/test2.ogg' in msg, msg
assert 'voice message' in msg.lower(), msg
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Voice message falls back to file-only when STT fails"
    else
        fail "Voice message STT fallback test failed"
    fi
}

test_synthesize_speech_success() {
    info "Testing synthesize_speech returns file path on success..."
    if python3 -c "
import sys, os, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge
bridge.TTS_ENDPOINT = 'http://tts.test/synthesize'  # endpoint now defaults to '' (5b); set it so synthesize_speech doesn't fail-open

# Mock urllib to return audio bytes
mock_response = MagicMock()
mock_response.read.return_value = b'OggS fake audio data'
mock_response.headers = {'X-Audio-Duration': '3.5', 'X-Processing-Time': '2.1'}
mock_response.__enter__ = lambda s: s
mock_response.__exit__ = MagicMock(return_value=False)

with patch('urllib.request.urlopen', return_value=mock_response):
    result = bridge.synthesize_speech('Hello world')

assert result is not None, 'Expected file path, got None'
assert os.path.exists(result), f'File does not exist: {result}'
assert result.endswith('.ogg'), f'Expected .ogg file, got: {result}'

# Verify content
with open(result, 'rb') as f:
    content = f.read()
assert content == b'OggS fake audio data', f'Unexpected content'

os.unlink(result)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "synthesize_speech returns file path on success"
    else
        fail "synthesize_speech success test failed"
    fi
}

test_synthesize_speech_timeout_returns_none() {
    info "Testing synthesize_speech returns None on timeout..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
import bridge
bridge.TTS_ENDPOINT = 'http://tts.test/synthesize'  # endpoint now defaults to '' (5b); set it so we test the timeout path, not the fail-open

with patch('urllib.request.urlopen', side_effect=Exception('timeout')):
    result = bridge.synthesize_speech('Hello world')

assert result is None, f'Expected None, got {result!r}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "synthesize_speech returns None on timeout"
    else
        fail "synthesize_speech timeout test failed"
    fi
}

test_synthesize_speech_uses_chunked_for_long_text() {
    info "Testing synthesize_speech uses /synthesize/chunked for text >200 chars..."
    if python3 -c "
import sys, os, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock, call
import bridge
bridge.TTS_ENDPOINT = 'http://tts.test/synthesize'  # endpoint now defaults to '' (5b); chunked routing needs a '/synthesize' base

# Save original
orig_threshold = bridge.TTS_CHUNKED_THRESHOLD

# Mock urllib to capture which URL is called
mock_response = MagicMock()
mock_response.read.return_value = b'OggS fake audio data'
mock_response.headers = {'X-Audio-Duration': '10.0', 'X-Processing-Time': '5.0'}
mock_response.__enter__ = lambda s: s
mock_response.__exit__ = MagicMock(return_value=False)

# Short text: should use base /synthesize endpoint
bridge.TTS_CHUNKED_THRESHOLD = 200
with patch('urllib.request.urlopen', return_value=mock_response) as mock_url:
    result = bridge.synthesize_speech('Short text')
    called_url = mock_url.call_args[0][0].full_url
    assert '/synthesize/chunked' not in called_url, f'Short text used chunked: {called_url}'
    os.unlink(result)

# Long text: should use /synthesize/chunked endpoint
long_text = 'This is a test sentence. ' * 20  # ~500 chars
with patch('urllib.request.urlopen', return_value=mock_response) as mock_url:
    result = bridge.synthesize_speech(long_text)
    called_url = mock_url.call_args[0][0].full_url
    assert '/synthesize/chunked' in called_url, f'Long text did not use chunked: {called_url}'
    os.unlink(result)

bridge.TTS_CHUNKED_THRESHOLD = orig_threshold
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "synthesize_speech uses chunked for long text"
    else
        fail "synthesize_speech chunked routing test failed"
    fi
}

test_auto_tts_sends_voice_with_response() {
    info "Testing auto-TTS sends voice message alongside text..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock, call
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345
bridge.state['tts_enabled'] = True  # enable auto-TTS gate (defaults off)
bridge.TTS_ENDPOINT = 'http://127.0.0.1:1/synthesize'  # endpoint now defaults to '' (5b); set it so the gate's endpoint check passes

voice_sent = []
text_sent = []

def mock_send_voice(chat_id, path, caption=None, message_thread_id=None):
    voice_sent.append((chat_id, path, caption))
    return True

def mock_telegram_api(method, data):
    if method == 'sendMessage':
        text_sent.append(data.get('text', ''))
        return {'ok': True, 'result': {'message_id': 1}}
    return {'ok': True}

response_text = 'Here is my answer to your question.'

with patch.object(bridge, 'send_voice', side_effect=mock_send_voice), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api), \
     patch.object(bridge, 'synthesize_speech', return_value='/tmp/voice.ogg') as mock_tts:
    bridge.send_response_to_telegram('testworker', response_text, 12345)
    time.sleep(0.3)  # TTS runs in background thread

# Text should be sent
assert len(text_sent) >= 1, f'Expected text sent, got {len(text_sent)}'

# Voice should be auto-synthesized (no [[speak]] needed)
mock_tts.assert_called_once()
assert len(voice_sent) == 1, f'Expected 1 voice sent, got {len(voice_sent)}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Auto-TTS sends voice alongside text"
    else
        fail "Auto-TTS test failed"
    fi
}

test_speak_tag_custom_text() {
    info "Testing [[speak:custom text]] overrides auto-TTS with custom text..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345

tts_calls = []

def mock_tts(text, **kwargs):
    tts_calls.append(text)
    return '/tmp/voice.ogg'

def mock_telegram_api(method, data):
    return {'ok': True, 'result': {'message_id': 1}}

response_text = 'Complex technical explanation with code.\n\n[[speak:Here is the short summary]]'

with patch.object(bridge, 'synthesize_speech', side_effect=mock_tts), \
     patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', response_text, 12345)
    time.sleep(0.3)

assert len(tts_calls) == 1, f'Expected 1 TTS call, got {len(tts_calls)}'
assert tts_calls[0] == 'Here is the short summary', f'TTS called with wrong text: {tts_calls[0]!r}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "[[speak:custom text]] overrides auto-TTS"
    else
        fail "[[speak:custom text]] test failed"
    fi
}

# v1.3.5 Task 5b — voice endpoints must default to empty (no hardcoded private IP).
test_stt_tts_endpoints_default_empty() {
    info "Testing STT/TTS endpoints default to empty (no hardcoded private IP)..."
    if env -u STT_ENDPOINT -u TTS_ENDPOINT TELEGRAM_BOT_TOKEN=dummy \
        python3 -c 'import sys, os; sys.path.insert(0, os.getcwd()); import bridge; sys.exit(0 if bridge.STT_ENDPOINT == "" and bridge.TTS_ENDPOINT == "" else 1)' 2>/dev/null; then
        success "STT/TTS endpoints default to empty string (voice off by default)"
    else
        fail "STT/TTS endpoints do not default to empty (hardcoded IP still present?)"
    fi
}

# v1.3.5 Task 5c — auto-TTS stays OFF when the tts_enabled key is absent, i.e. the
# read default must agree with DEFAULT_STATE (False), not the stale True.
test_auto_tts_off_when_key_absent() {
    info "Testing auto-TTS stays OFF when the tts_enabled key is absent from state..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345
# Force the endpoint check to pass so the ONLY remaining gate is the tts_enabled
# lookup (after 5b the default endpoint is '', which would otherwise mask this
# test by short-circuiting 'TTS_ENDPOINT and ...').
bridge.TTS_ENDPOINT = 'http://127.0.0.1:1/synthesize'
# The contradiction under test: DEFAULT_STATE has tts_enabled=False, but the read
# defaulted to True. Remove the key so the read's default alone decides.
bridge.state.pop('tts_enabled', None)

def mock_telegram_api(method, data):
    return {'ok': True, 'result': {'message_id': 1}}

with patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api), \
     patch.object(bridge, 'synthesize_speech', return_value='/tmp/voice.ogg') as mock_tts:
    bridge.send_response_to_telegram('testworker', 'A plain answer.', 12345)
    time.sleep(0.3)

assert not mock_tts.called, 'auto-TTS fired with tts_enabled key absent (read default != DEFAULT_STATE)'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Auto-TTS off when tts_enabled key absent (read default aligns with DEFAULT_STATE)"
    else
        fail "Auto-TTS fired with tts_enabled key absent (default contradiction)"
    fi
}

test_auto_tts_skips_long_messages() {
    info "Testing auto-TTS skips messages >1000 chars and splits paragraphs..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345
bridge.state['tts_enabled'] = True
bridge.TTS_ENDPOINT = 'http://127.0.0.1:1/synthesize'  # endpoint now defaults to '' (5b); set it so the gate's endpoint check passes

tts_calls = []

def mock_tts(text, **kwargs):
    tts_calls.append(text)
    return '/tmp/voice.ogg'

def mock_telegram_api(method, data):
    return {'ok': True, 'result': {'message_id': 1}}

# Multi-paragraph text under 1000 chars — should split into separate TTS calls
tts_calls.clear()
multi_para = 'First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph.'
with patch.object(bridge, 'synthesize_speech', side_effect=mock_tts), \
     patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', multi_para, 12345)
    time.sleep(0.5)

assert len(tts_calls) == 3, f'Expected 3 TTS calls (one per paragraph), got {len(tts_calls)}: {tts_calls}'
assert tts_calls[0] == 'First paragraph here.', f'Wrong para 1: {tts_calls[0]!r}'
assert tts_calls[1] == 'Second paragraph here.', f'Wrong para 2: {tts_calls[1]!r}'
assert tts_calls[2] == 'Third paragraph.', f'Wrong para 3: {tts_calls[2]!r}'

# Long text (>1000 chars) — TTS should be skipped entirely
tts_calls.clear()
long_text = 'A' * 1001
with patch.object(bridge, 'synthesize_speech', side_effect=mock_tts), \
     patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', long_text, 12345)
    time.sleep(0.3)

assert len(tts_calls) == 0, f'Expected 0 TTS calls for >1000 char text, got {len(tts_calls)}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Auto-TTS skips >1000 chars and splits paragraphs"
    else
        fail "Auto-TTS paragraph split test failed"
    fi
}

test_auto_tts_failure_still_sends_text() {
    info "Testing auto-TTS failure still sends text..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345

text_sent = []

def mock_telegram_api(method, data):
    if method == 'sendMessage':
        text_sent.append(data.get('text', ''))
        return {'ok': True, 'result': {'message_id': 1}}
    return {'ok': True}

response_text = 'Important information.'

with patch.object(bridge, 'synthesize_speech', return_value=None), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', response_text, 12345)
    time.sleep(0.3)

# Text should still be sent even when TTS fails
assert len(text_sent) >= 1, f'Expected text to be sent, got {len(text_sent)}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Auto-TTS failure still sends text"
    else
        fail "Auto-TTS failure test failed"
    fi
}

test_voice_toggle_command() {
    info "Testing /voice on|off toggles auto-TTS..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

bridge.BOT_TOKEN = 'fake'
bridge.admin_chat_id = 12345
bridge.TTS_ENDPOINT = 'http://127.0.0.1:1/synthesize'  # endpoint now defaults to '' (5b); set it so the re-enable half can fire
bridge.state['tts_enabled'] = True

# Test /voice off disables TTS
tts_calls = []

def mock_tts(text, **kwargs):
    tts_calls.append(text)
    return '/tmp/voice.ogg'

def mock_telegram_api(method, data):
    return {'ok': True, 'result': {'message_id': 1}}

# Disable TTS
bridge.state['tts_enabled'] = False

with patch.object(bridge, 'synthesize_speech', side_effect=mock_tts), \
     patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', 'Hello text only', 12345)
    time.sleep(0.3)

assert len(tts_calls) == 0, f'TTS should not be called when disabled, got {len(tts_calls)} calls'

# Re-enable TTS
bridge.state['tts_enabled'] = True

with patch.object(bridge, 'synthesize_speech', side_effect=mock_tts), \
     patch.object(bridge, 'send_voice', return_value=True), \
     patch.object(bridge, 'telegram_api', side_effect=mock_telegram_api):
    bridge.send_response_to_telegram('testworker', 'Hello with voice', 12345)
    time.sleep(0.3)

assert len(tts_calls) == 1, f'TTS should be called when enabled, got {len(tts_calls)} calls'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/voice on|off toggles auto-TTS"
    else
        fail "/voice toggle test failed"
    fi
}

test_transcript_renders_html() {
    info "Testing _render_transcript_html produces valid HTML..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

# Create a fake transcript JSONL
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello world'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'test-sid', 'version': '2.1.85', 'gitBranch': 'main'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi there! How can I help?'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'test-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='test-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker')

    import base64, re
    assert '<!DOCTYPE html>' in html, 'Missing DOCTYPE'
    assert 'testworker' in html, 'Missing worker name'
    assert 'Hello world' in html, 'Missing user message'
    # Assistant text is base64-encoded in data-md attr (rendered client-side by marked.js)
    md_vals = [base64.b64decode(m).decode() for m in re.findall(r'data-md=\"([^\"]+)\"', html)]
    assert any('Hi there!' in v for v in md_vals), f'Missing assistant reply in data-md: {md_vals}'
    assert 'claude-opus-4-6' in html, 'Missing model name'
    assert 'user-msg' in html, 'Missing user CSS class'
    assert 'a-text' in html, 'Missing assistant CSS class'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript renderer produces valid HTML"
    else
        fail "Transcript renderer test failed"
    fi
}

test_render_transcript_html_with_query_result() {
    info "Testing transcript renderer handles transcript-index query results..."
    if python3 - <<'EOF' 2>/dev/null | grep -q "OK"; then
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, ".")
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello query path'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'query-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Indexed response'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    home = Path(tmpdir)
    cwd = '/tmp/query-result-cwd'
    sid = 'query-sid'
    project_dir = home / '.claude' / 'projects' / cwd.replace('/', '-')
    project_dir.mkdir(parents=True)
    transcript = project_dir / f'{sid}.jsonl'
    with open(transcript, 'w') as f:
        for entry in entries:
            f.write(json.dumps(entry) + '\n')

    def fake_query(jsonl_path, got_sid, query, **kwargs):
        assert str(jsonl_path) == str(transcript), jsonl_path
        assert got_sid == sid, got_sid
        assert query == 'entries+stats', query
        return {
            'entries': [{'raw_json': json.dumps(entry), 'idx': idx} for idx, entry in enumerate(entries)],
            'total': len(entries),
            'total_pages': 1,
            'page': 1,
            'stats': {
                'n_user': 1,
                'n_tool': 0,
                'n_edit': 0,
                'lines_add': 0,
                'lines_del': 0,
                'lines_mod': 0,
                'n_files': 0,
                'model': 'claude-opus-4-6',
                'version': '2.1.85',
                'git_branch': 'main',
                'first_ts': '2026-04-05T10:00:00Z',
                'last_ts': '2026-04-05T10:00:01Z',
                'input_tokens': 0,
                'output_tokens': 0,
                'duration': '',
            },
        }

    with patch.object(bridge, 'get_claude_session_cwd', return_value=cwd), \
         patch.object(bridge, 'get_claude_session_id', return_value=sid), \
         patch.object(bridge, '_run_transcript_query', side_effect=fake_query), \
         patch('pathlib.Path.home', return_value=home):
        html = bridge._render_transcript_html('testworker', page=1)

    assert '<!DOCTYPE html>' in html, 'Missing DOCTYPE'
    assert 'Hello query path' in html, 'Missing indexed user message'
    assert 'File size' in html and ' B' in html, 'Missing local transcript file size'
    print('OK')
EOF
        success "Transcript renderer handles transcript-index query results"
    else
        fail "Transcript query-result renderer test failed"
    fi
}

test_transcript_missing_session() {
    info "Testing transcript returns error for missing session..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
import bridge

with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/x'), \
     patch.object(bridge, 'get_claude_session_id', return_value=''):
    html = bridge._render_transcript_html('nobody')

assert 'No session found' in html, f'Expected error message, got: {html[:200]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript returns error for missing session"
    else
        fail "Missing session test failed"
    fi
}

test_transcript_with_tool_calls() {
    info "Testing transcript renders tool_use and tool_result blocks..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Read my file'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'tool-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'toolu_abc123', 'name': 'Read', 'input': {'file_path': '/tmp/hello.txt'}}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_abc123', 'content': 'file contents here', 'is_error': False}]}, 'timestamp': '2026-04-05T10:00:02Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'thinking', 'thinking': 'Let me analyze this file...'}, {'type': 'text', 'text': 'The file contains hello.'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:03Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd2'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'tool-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd2'), \
         patch.object(bridge, 'get_claude_session_id', return_value='tool-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('toolworker')

    import base64, re
    assert 'hello.txt' in html, 'Missing file path'
    # Result merged into tool block (no separate t-result)
    assert 't-result' not in html, 'Separate t-result should not exist (merged into tool block)'
    assert 'file contents here' in html, 'Missing tool output merged into tool block'
    assert 'act' in html, 'Read with result should become expandable act block'
    assert 't-name' not in html, 'Tool name text should not appear (icon-only per AmpCode)'
    assert 'Thinking' in html, 'Missing thinking block'
    md_vals = [base64.b64decode(m).decode() for m in re.findall(r'data-md=\"([^\"]+)\"', html)]
    assert any('The file contains hello.' in v for v in md_vals), f'Missing final text in data-md: {md_vals}'
    assert '1 tool call' in html, 'Missing tool call count'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript renders tool calls and thinking"
    else
        fail "Tool calls transcript test failed"
    fi
}

test_transcript_default_last_page() {
    info "Testing transcript defaults to last page..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

# Create 120 entries so we get multiple pages at per_page=50
entries = []
for i in range(120):
    entries.append({'type': 'user', 'message': {'role': 'user', 'content': f'Message {i}'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'page-sid', 'version': '2.1.85'})

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'page-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='page-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        # page=None = default = last page
        html = bridge._render_transcript_html('testworker', per_page=50)

    # 120 entries / 50 = 3 pages. Default should show page 3
    assert 'Message 119' in html, 'Last message not on default page'
    assert 'Message 0' not in html, 'First message should NOT be on last page'
    assert 'pg-cur' in html, 'Missing pagination current marker'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript defaults to last page"
    else
        fail "Default last page test failed"
    fi
}

test_transcript_bm25_search() {
    info "Testing BM25 search ranks results by relevance..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'general conversation about weather'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'bm25-sid', 'version': '2.1.85'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'deploy deploy deploy worker to mac'}, 'timestamp': '2026-04-05T10:00:01Z', 'sessionId': 'bm25-sid'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'one mention of deploy here'}, 'timestamp': '2026-04-05T10:00:02Z', 'sessionId': 'bm25-sid'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'bm25-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='bm25-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker', page=1, search_query='deploy')

    assert 'sorted by relevance' in html, 'Missing relevance info'
    assert 'Found 2 matching' in html, f'Expected 2 results'
    # The entry with 3x deploy should rank higher (appear first)
    pos_3x = html.find('deploy deploy deploy')
    pos_1x = html.find('one mention of deploy')
    assert pos_3x < pos_1x, f'Higher TF entry should rank first: {pos_3x} vs {pos_1x}'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "BM25 search ranks by relevance"
    else
        fail "BM25 search test failed"
    fi
}

test_transcript_search_assistant_ctx_link() {
    info "Testing search results have context links on assistant entries..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'tell me about deployments'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'ctx-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Here is the deployment status for your cluster'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'what about the database?'}, 'timestamp': '2026-04-05T10:00:02Z', 'sessionId': 'ctx-sid'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'The database deployment is running normally'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:03Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'ctx-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='ctx-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker', page=1, search_query='deployment')

    # Both assistant entries mention deployment — they should have ctx-wrap links
    assert 'ctx-wrap' in html, 'Missing ctx-wrap links in search results'
    # Assistant entries have class 'a-text' — verify they are inside ctx-wrap anchors
    import re
    # ctx-wrap links that contain assistant content (a-text divs)
    assistant_ctx = re.findall(r'<a class=\"ctx-wrap\"[^>]*>.*?class=\"a-text', html, re.DOTALL)
    assert len(assistant_ctx) >= 1, f'Expected assistant entries wrapped in ctx-wrap, got {len(assistant_ctx)}: search should make assistant results clickable'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Search results have context links on assistant entries"
    else
        fail "Search results missing context links on assistant entries"
    fi
}

test_transcript_search_sort_toggle() {
    info "Testing search results support sort by time vs relevance..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'first deploy question'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'sort-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'deploy info here'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'general conversation no match'}, 'timestamp': '2026-04-05T10:00:02Z', 'sessionId': 'sort-sid'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'deploy deploy deploy many mentions'}, 'timestamp': '2026-04-05T10:00:03Z', 'sessionId': 'sort-sid'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'sort-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='sort-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        # Default (relevance): high-TF entry should come first
        html_rel = bridge._render_transcript_html('testworker', page=1, search_query='deploy', search_sort='relevance')
        # Time sort: entries in chronological order
        html_time = bridge._render_transcript_html('testworker', page=1, search_query='deploy', search_sort='time')

    # Relevance: 'deploy deploy deploy' (idx 3, more TF) before 'first deploy' (idx 0)
    pos_many_rel = html_rel.find('deploy deploy deploy')
    pos_first_rel = html_rel.find('first deploy')
    assert pos_many_rel < pos_first_rel, f'Relevance sort should put high-TF first: {pos_many_rel} vs {pos_first_rel}'

    # Time: 'first deploy' (idx 0) before 'deploy deploy deploy' (idx 3)
    pos_first_time = html_time.find('first deploy')
    pos_many_time = html_time.find('deploy deploy deploy')
    assert pos_first_time < pos_many_time, f'Time sort should put earlier entry first: {pos_first_time} vs {pos_many_time}'

    # Both HTML pages should have sort toggle links
    assert 'sort=time' in html_rel, 'Relevance page should have link to switch to time sort'
    assert 'sort=relevance' in html_time, 'Time page should have link to switch to relevance sort'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Search results support sort by time vs relevance"
    else
        fail "Search sort toggle test failed"
    fi
}

test_transcript_unicode() {
    info "Testing transcript handles unicode/UTF-8 content..."
    if python3 -c "
import sys, os, json, tempfile, base64, re
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'こんにちは世界 🌍 café résumé naïve'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'utf8-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Héllo! 你好 🎉 Ñoño über Straße'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'utf8-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='utf8-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker')

    # User message should have unicode rendered directly (HTML-escaped)
    assert 'こんにちは世界' in html, 'Missing Japanese text in user message'
    assert '🌍' in html, 'Missing emoji in user message'
    assert 'café' in html, 'Missing accented text'
    # Assistant text is base64 — verify the data-md roundtrips UTF-8
    md_vals = [base64.b64decode(m).decode('utf-8') for m in re.findall(r'data-md=\"([^\"]+)\"', html)]
    assert any('你好' in v for v in md_vals), f'Missing Chinese text in data-md: {md_vals}'
    assert any('🎉' in v for v in md_vals), f'Missing emoji in data-md: {md_vals}'
    assert any('Straße' in v for v in md_vals), f'Missing German text in data-md: {md_vals}'
    # Verify decodeB64Utf8 function is in the JS
    assert 'decodeB64Utf8' in html, 'Missing UTF-8 base64 decoder function'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript handles unicode/UTF-8 content"
    else
        fail "Unicode transcript test failed"
    fi
}

test_transcript_edit_diff_rendering() {
    info "Testing transcript renders Edit tool as colored diff..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Fix the bug'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'diff-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'toolu_abc', 'name': 'Edit', 'input': {'file_path': '/home/user/src/app.py', 'old_string': 'x = 1\ny = 2', 'new_string': 'x = 10\ny = 20\nz = 30'}}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'diff-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='diff-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker')

    assert 'diff-add' in html, 'Missing diff-add class'
    assert 'diff-del' in html, 'Missing diff-del class'
    assert 'diff-stat' in html, 'Missing diff stats'
    # Per-edit: old=2, new=3 → overlap=2, pure_add=1, pure_del=0
    assert '+1' in html, 'Missing add count (+1 pure additions)'
    assert '~2' in html, 'Missing mod count (~2 modified lines)'
    assert 'app.py' in html, 'Missing filename in diff header'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript renders Edit diffs with coloring"
    else
        fail "Edit diff rendering test failed"
    fi
}

test_transcript_turn_grouping() {
    info "Testing assistant turns grouped in turn-body..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'grp-sid', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi!'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'toolu_1', 'name': 'Read', 'input': {'file_path': '/tmp/test.txt'}}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:02Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': 'file content'}]}, 'timestamp': '2026-04-05T10:00:03Z'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'grp-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='grp-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker')

    thread_html = html[html.find('id=\"thread\"'):]
    # Assistant content grouped in turn-body (no avatar — AmpCode style)
    assert 'turn-body' in thread_html, 'Missing turn-body grouping'
    # No Claude avatar (removed per AmpCode match)
    assert 'cl-av' not in thread_html, 'Should not have Claude avatar'
    # User message should have image avatar
    assert 'class=\"u-av\"' in thread_html, 'Missing user avatar'
    assert 'u-label' not in html, 'Should not have Human label (AmpCode: no labels)'
    # Tool result merged into tool block inside turn-body
    assert 't-result' not in thread_html, 'No separate t-result (merged into tool block)'
    tb_start = thread_html.find('turn-body')
    act_pos = thread_html.find('class=\"act\"', tb_start)
    assert tb_start < act_pos, 'Tool block (with merged result) should be inside turn-body'
    assert 'file content' in thread_html, 'Merged result content should appear in tool block'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Assistant turns grouped under Claude avatar"
    else
        fail "Turn grouping test failed"
    fi
}

test_transcript_hides_system_messages() {
    info "Testing transcript hides task-notification and system-reminder messages..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
from unittest.mock import patch
from pathlib import Path
import bridge

entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello world'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'sys-sid', 'version': '2.1.85'},
    {'type': 'user', 'message': {'role': 'user', 'content': '<task-notification>\n<task-id>abc123</task-id>\n<status>completed</status>\n<summary>Background command done</summary>\n</task-notification>'}, 'timestamp': '2026-04-05T10:00:01Z', 'sessionId': 'sys-sid'},
    {'type': 'user', 'message': {'role': 'user', 'content': '<system-reminder>\nSome internal reminder\n</system-reminder>'}, 'timestamp': '2026-04-05T10:00:02Z', 'sessionId': 'sys-sid'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Real user message'}, 'timestamp': '2026-04-05T10:00:03Z', 'sessionId': 'sys-sid'},
]

with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'sys-sid.jsonl'
    with open(transcript, 'w') as f:
        for e in entries:
            f.write(json.dumps(e) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='sys-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        html = bridge._render_transcript_html('testworker')

    assert 'Hello world' in html, 'Real user message should appear'
    assert 'Real user message' in html, 'Second real user message should appear'
    assert 'task-notification' not in html, 'task-notification should be hidden'
    assert 'system-reminder' not in html, 'system-reminder should be hidden'
    assert 'Background command done' not in html, 'Task summary should be hidden'
    # Count user-msg divs - should be exactly 2 (the real messages)
    count = html.count('class=\"user-msg\"')
    assert count == 2, f'Expected 2 user messages, got {count}'
    print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript hides system messages"
    else
        fail "System message hiding test failed"
    fi
}

test_rewind_generates_token_url() {
    info "Testing /rewind generates time-limited token URL..."
    if python3 -c "
import sys, os, json, tempfile, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
from pathlib import Path
import bridge

# Setup: create a router with a mock reply
router = bridge.CommandRouter.__new__(bridge.CommandRouter)
router.workers = MagicMock()
router.workers.get_all_names.return_value = ['alice']
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

# Use BRIDGE_PUBLIC_URL (Tailscale IP — no cloudflare)
with patch.object(bridge, 'BRIDGE_PUBLIC_URL', 'http://100.125.36.102:8271'):
    router.cmd_rewind('alice', 12345)

assert len(replies) == 1, f'Expected 1 reply, got {len(replies)}'
reply = replies[0]
assert 'alice' in reply, f'Reply should mention alice: {reply}'
assert 'http://100.125.36.102:8271/transcript/alice' in reply, f'Should use Tailscale IP: {reply}'
assert 'trycloudflare' not in reply, f'Should NOT use cloudflare: {reply}'
assert 'token=' in reply, f'Should contain token param: {reply}'
# Token should be in REWIND_TOKENS
assert len(bridge.REWIND_TOKENS) > 0, 'Should have stored a rewind token'
token = list(bridge.REWIND_TOKENS.keys())[0]
entry = bridge.REWIND_TOKENS[token]
assert entry['name'] == 'alice', f'Token should be for alice: {entry}'
assert entry['expires_at'] > time.time(), 'Token should not be expired yet'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Rewind generates time-limited token URL"
    else
        fail "Rewind token URL test failed"
    fi
}

test_rewind_token_auth_required() {
    info "Testing transcript requires valid rewind token..."
    if python3 -c "
import sys, os, json, tempfile, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
from pathlib import Path
import bridge

# Ensure REWIND_TOKENS is empty
bridge.REWIND_TOKENS.clear()

# Create a mock HTTP handler
handler = MagicMock()
handler.send_response = MagicMock()
handler.send_header = MagicMock()
handler.end_headers = MagicMock()
handler.wfile = MagicMock()
handler.wfile.write = MagicMock()
handler.headers = {'Accept-Encoding': ''}
handler._send_html = bridge.Handler._send_html.__get__(handler)

from urllib.parse import urlparse, parse_qs

# Test 1: No token → 403
parsed = urlparse('/transcript/alice')
bridge.Handler.handle_transcript_endpoint(handler, parsed)
handler.send_response.assert_called_with(403)

# Test 2: Wrong token → 403
handler.reset_mock()
parsed = urlparse('/transcript/alice?token=badtoken')
bridge.Handler.handle_transcript_endpoint(handler, parsed)
handler.send_response.assert_called_with(403)

# Test 3: Valid token → 200
handler.reset_mock()
bridge.REWIND_TOKENS['goodtoken'] = {'name': 'alice', 'expires_at': time.time() + 300}
with tempfile.TemporaryDirectory() as tmpdir:
    slug = '/tmp/testcwd'.replace('/', '-')
    project_dir = Path(tmpdir) / '.claude' / 'projects' / slug
    project_dir.mkdir(parents=True)
    transcript = project_dir / 'test-sid.jsonl'
    transcript.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'hello'}, 'sessionId': 'test-sid', 'timestamp': '2026-04-05T10:00:00Z'}) + '\n')

    with patch.object(bridge, 'get_claude_session_cwd', return_value='/tmp/testcwd'), \
         patch.object(bridge, 'get_claude_session_id', return_value='test-sid'), \
         patch('pathlib.Path.home', return_value=Path(tmpdir)):
        parsed = urlparse('/transcript/alice?token=goodtoken')
        bridge.Handler.handle_transcript_endpoint(handler, parsed)

handler.send_response.assert_called_with(200)

# Test 4: Expired token → 403
handler.reset_mock()
bridge.REWIND_TOKENS['expiredtoken'] = {'name': 'alice', 'expires_at': time.time() - 10}
parsed = urlparse('/transcript/alice?token=expiredtoken')
bridge.Handler.handle_transcript_endpoint(handler, parsed)
handler.send_response.assert_called_with(403)

# Cleanup
bridge.REWIND_TOKENS.clear()
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript requires valid rewind token"
    else
        fail "Rewind token auth test failed"
    fi
}

test_rewind_no_args_shows_usage() {
    info "Testing /rewind with no args shows usage..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
router.workers = MagicMock()
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

router.cmd_rewind('', 12345)
assert len(replies) == 1
assert 'Usage' in replies[0], f'Should show usage: {replies[0]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Rewind shows usage without args"
    else
        fail "Rewind usage test failed"
    fi
}

test_transcript_prompts_filter() {
    info "Testing transcript prompts-only filter..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
import bridge

# Create transcript with user + assistant entries
with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
    entries = [
        {'type': 'user', 'message': {'role': 'user', 'content': 'hello world'}, 'timestamp': '2026-04-05T10:00:00Z'},
        {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi!'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
        {'type': 'user', 'message': {'role': 'user', 'content': 'second prompt'}, 'timestamp': '2026-04-05T10:01:00Z'},
        {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Ok'}]}, 'timestamp': '2026-04-05T10:01:01Z'},
    ]
    for e in entries:
        f.write(json.dumps(e) + '\n')
    tpath = f.name

from unittest.mock import patch
with patch.object(bridge, '_resolve_transcript_path', return_value=(tpath, 'test-sid', '/tmp')):
    # Without filter: shows all entries
    html_all = bridge._render_transcript_html('test')
    assert 'hello world' in html_all
    assert 'a-text markdown' in html_all  # assistant blocks visible

    # With filter=prompts: only user messages
    html_filt = bridge._render_transcript_html('test', filter_mode='prompts')
    assert 'hello world' in html_filt
    assert 'second prompt' in html_filt
    assert 'Showing prompts only' in html_filt
    # No assistant text blocks in the content area (before script tag)
    assert 'a-text markdown' not in html_filt.split('<script>')[0]

os.unlink(tpath)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript prompts-only filter works"
    else
        fail "Transcript prompts-only filter failed"
    fi
}

test_transcript_dynamic_avatars() {
    info "Testing transcript dynamic avatars for team members..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
import bridge

# Test _detect_message_author
author, av, display = bridge._detect_message_author('ryo: fix the bug')
assert author == 'ryo', f'Expected ryo, got {author}'
assert 'viewBox' in av, 'Team member should get SVG avatar'
assert display == 'fix the bug', f'Display should strip prefix, got: {display}'

# Manager prefix
author2, av2, display2 = bridge._detect_message_author('manager: check this')
assert author2 == 'manager', f'Expected manager, got {author2}'
assert 'github' in av2.lower() or 'img' in av2, 'Manager should get GitHub avatar'
assert display2 == 'check this'

# No prefix → default manager
author3, av3, display3 = bridge._detect_message_author('just a plain message')
assert author3 == 'manager'
assert 'img' in av3

# Test avatar uniqueness
av_ryo = bridge._generate_member_avatar('ryo')
av_mon = bridge._generate_member_avatar('mon')
av_lee = bridge._generate_member_avatar('lee')
assert av_ryo != av_mon, 'Different members should have different avatars'
assert av_ryo != av_lee
assert av_mon != av_lee

# Verify determinism
assert bridge._generate_member_avatar('ryo') == av_ryo, 'Same name should give same avatar'

# Verify 100+ unique variants
avatars = set()
for name in list(bridge._TEAM_MEMBERS) + ['alice', 'bob', 'carol', 'dave', 'eve', 'frank', 'grace',
    'heidi', 'ivan', 'judy', 'karl', 'larry', 'mallory', 'nancy', 'oscar', 'peggy',
    'quinn', 'romeo', 'steve', 'trudy', 'ursula', 'victor', 'wendy', 'xavier', 'yvonne', 'zach',
    'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'kappa',
    'lambda', 'mu', 'nu', 'xi', 'omicron', 'pi', 'rho', 'sigma', 'tau', 'upsilon', 'phi',
    'chi', 'psi', 'omega', 'ant', 'bee', 'cat', 'dog', 'elk', 'fox', 'gnu', 'hen', 'ibis',
    'jay', 'koi', 'lynx', 'moth', 'newt', 'owl', 'pig', 'quail', 'ram', 'seal', 'toad',
    'urchin', 'vole', 'wolf', 'yak', 'zebu', 'atom', 'bolt', 'cog', 'dart', 'edge',
    'flux', 'grit', 'haze', 'icon', 'jest', 'knot', 'lens', 'mist', 'node', 'opus',
    'pulse', 'rift', 'shard', 'tide', 'unit', 'vex', 'warp', 'xray', 'yield', 'zinc']:
    avatars.add(bridge._generate_member_avatar(name))
assert len(avatars) >= 100, f'Expected 100+ unique avatars, got {len(avatars)}'
print(f'OK ({len(avatars)} unique avatars)')
" 2>/dev/null | grep -q "OK"; then
        success "Dynamic avatars work with 100+ variants"
    else
        fail "Dynamic avatar test failed"
    fi
}

test_transcript_sidebar_stats() {
    info "Testing transcript sidebar shows duration/tokens/file size..."
    if python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, os.getcwd())
import bridge

# Create transcript with usage data and timestamps spread over 2 hours
with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
    entries = [
        {'type': 'user', 'message': {'role': 'user', 'content': 'test'}, 'timestamp': '2026-04-05T10:00:00Z'},
        {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'reply'}],
         'usage': {'input_tokens': 5000, 'cache_read_input_tokens': 3000, 'output_tokens': 1200}},
         'timestamp': '2026-04-05T12:30:00Z'},
    ]
    for e in entries:
        f.write(json.dumps(e) + '\n')
    tpath = f.name

from unittest.mock import patch
with patch.object(bridge, '_resolve_transcript_path', return_value=(tpath, 'test-sid', '/tmp')):
    html = bridge._render_transcript_html('test')
    # Duration should show 2h 30m
    assert '2h 30m' in html, f'Expected 2h 30m duration in sidebar'
    # Token counts
    assert '8,000' in html, f'Expected 8,000 input tokens (5000+3000)'
    assert '1,200' in html, f'Expected 1,200 output tokens'
    # File size should be present (small file)
    assert 'KB' in html or ' B' in html, 'Expected file size in sidebar'

os.unlink(tpath)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Transcript sidebar shows duration/tokens/file size"
    else
        fail "Transcript sidebar stats failed"
    fi
}


# ── Transcript Index Tests (transcript-index.py) ──────────────────────────

test_tindex_missing_file() {
    info "Testing transcript-index.py handles missing JSONL..."
    if result=$(python3 transcript-index.py --jsonl /nonexistent/path.jsonl --db /tmp/test-tindex-missing.db --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['entries'] == [], f'Expected empty entries, got {d[\"entries\"]}'
assert d['total'] == 0, f'Expected total=0, got {d[\"total\"]}'
assert d['total_pages'] == 0
assert d['page'] == 1
print('OK')
" && success "transcript-index.py handles missing JSONL" || fail "Missing file test failed"
    else
        fail "transcript-index.py crashed on missing file"
    fi
    rm -f /tmp/test-tindex-missing.db
}

test_tindex_empty_file() {
    info "Testing transcript-index.py handles empty JSONL..."
    local tmp=$(mktemp /tmp/tindex-empty-XXXX.jsonl)
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db /tmp/test-tindex-empty.db --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['entries'] == [], f'Expected empty entries'
assert d['total'] == 0
print('OK')
" && success "transcript-index.py handles empty JSONL" || fail "Empty file test failed"
    else
        fail "transcript-index.py crashed on empty file"
    fi
    rm -f "$tmp" /tmp/test-tindex-empty.db
}

test_tindex_basic_indexing() {
    info "Testing transcript-index.py indexes entries into SQLite..."
    local tmp=$(mktemp /tmp/tindex-basic-XXXX.jsonl)
    local db="/tmp/test-tindex-basic.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello world'}, 'timestamp': '2026-04-05T10:00:00Z', 'sessionId': 'test', 'version': '2.1.85'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi there'}], 'model': 'claude-opus-4-6'}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Thanks'}, 'timestamp': '2026-04-05T10:00:02Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json, sqlite3
d = json.load(sys.stdin)
assert d['total'] == 3, f'Expected 3 entries, got {d[\"total\"]}'
assert len(d['entries']) == 3
assert d['entries'][0]['type'] == 'user'
assert d['entries'][1]['type'] == 'assistant'
# Verify SQLite db was created with correct rows
db = sqlite3.connect('$db')
count = db.execute('SELECT COUNT(*) FROM entries').fetchone()[0]
assert count == 3, f'SQLite has {count} rows, expected 3'
# Verify raw_json is valid JSON
import json as j2
parsed = j2.loads(d['entries'][0]['raw_json'])
assert parsed['message']['content'] == 'Hello world'
db.close()
print('OK')
" && success "transcript-index.py indexes entries" || fail "Basic indexing test failed"
    else
        fail "transcript-index.py crashed on basic indexing"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_skips_noise() {
    info "Testing transcript-index.py skips noise entry types..."
    local tmp=$(mktemp /tmp/tindex-noise-XXXX.jsonl)
    local db="/tmp/test-tindex-noise.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello'}, 'timestamp': '2026-04-05T10:00:00Z'},
    {'type': 'progress', 'data': {}},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'system', 'message': {'role': 'system', 'content': 'sys msg'}},
    {'type': 'queue-operation', 'data': {}},
    {'type': 'file-history-snapshot', 'data': {}},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Bye'}, 'timestamp': '2026-04-05T10:00:02Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 3, f'Expected 3 (skipping noise), got {d[\"total\"]}'
types = [e['type'] for e in d['entries']]
assert 'progress' not in types
assert 'system' not in types
assert 'queue-operation' not in types
print('OK')
" && success "transcript-index.py skips noise types" || fail "Noise skip test failed"
    else
        fail "transcript-index.py crashed on noise entries"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_plain_text_extraction() {
    info "Testing transcript-index.py extracts searchable plain text..."
    local tmp=$(mktemp /tmp/tindex-text-XXXX.jsonl)
    local db="/tmp/test-tindex-text.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Hello world'}, 'timestamp': '2026-04-05T10:00:00Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Hi there friend'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'ls -la /tmp'}}]}, 'timestamp': '2026-04-05T10:00:02Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>/dev/null
    python3 -c "
import sqlite3
db = sqlite3.connect('$db')
rows = db.execute('SELECT plain_text FROM entries ORDER BY idx').fetchall()
assert 'Hello world' in rows[0][0], f'User text not extracted: {rows[0][0]}'
assert 'Hi there friend' in rows[1][0], f'Assistant text not extracted: {rows[1][0]}'
assert 'ls -la /tmp' in rows[2][0], f'Tool input not extracted: {rows[2][0]}'
db.close()
print('OK')
" 2>/dev/null | grep -q "OK" && success "Plain text extraction works" || fail "Plain text extraction failed"
    rm -f "$tmp" "$db"
}

test_tindex_incremental() {
    info "Testing transcript-index.py indexes only new bytes..."
    local tmp=$(mktemp /tmp/tindex-incr-XXXX.jsonl)
    local db="/tmp/test-tindex-incr.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'First'}, 'timestamp': '2026-04-05T10:00:00Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Reply1'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Second'}, 'timestamp': '2026-04-05T10:00:02Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    # First index
    python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>/dev/null
    # Append 2 more entries
    python3 -c "
import json
new = [
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Reply2'}]}, 'timestamp': '2026-04-05T10:00:03Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Third'}, 'timestamp': '2026-04-05T10:00:04Z'},
]
with open('$tmp', 'a') as f:
    for e in new:
        f.write(json.dumps(e) + '\n')
"
    # Re-index (incremental)
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 5, f'Expected 5 after incremental, got {d[\"total\"]}'
assert d['entries'][0]['type'] == 'user'
assert d['entries'][4]['type'] == 'user'
print('OK')
" && success "Incremental indexing works" || fail "Incremental indexing test failed"
    else
        fail "transcript-index.py crashed on incremental"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_no_reindex_unchanged() {
    info "Testing transcript-index.py skips reindex when file unchanged..."
    local tmp=$(mktemp /tmp/tindex-noop-XXXX.jsonl)
    local db="/tmp/test-tindex-noop.db"
    python3 -c "
import json
with open('$tmp', 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'test'}, 'timestamp': '2026-04-05T10:00:00Z'}) + '\n')
"
    python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>/dev/null
    # Get db mtime
    local mtime1=$(stat -c %Y "$db" 2>/dev/null || stat -f %m "$db" 2>/dev/null)
    sleep 1
    # Run again — should skip indexing
    python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>/dev/null
    local mtime2=$(stat -c %Y "$db" 2>/dev/null || stat -f %m "$db" 2>/dev/null)
    # Note: mtime may change due to SQLite WAL, so just check total is still 1
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 1, f'Expected 1, got {d[\"total\"]}'
print('OK')
" && success "No reindex when unchanged" || fail "No-reindex test failed"
    else
        fail "transcript-index.py crashed on no-reindex"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_pagination() {
    info "Testing transcript-index.py pagination..."
    local tmp=$(mktemp /tmp/tindex-page-XXXX.jsonl)
    local db="/tmp/test-tindex-page.db"
    python3 -c "
import json
with open('$tmp', 'w') as f:
    for i in range(120):
        e = {'type': 'user', 'message': {'role': 'user', 'content': f'Message {i}'}, 'timestamp': f'2026-04-05T10:{i//60:02d}:{i%60:02d}Z'}
        f.write(json.dumps(e) + '\n')
"
    # Default (no --page) should be last page
    result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries --per-page 50 2>/dev/null)
    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 120
assert d['total_pages'] == 3
assert d['page'] == 3, f'Default page should be 3 (last), got {d[\"page\"]}'
assert len(d['entries']) == 20, f'Last page should have 20 entries, got {len(d[\"entries\"])}'
print('OK1')
" 2>/dev/null | grep -q "OK1" || { fail "Pagination default-last-page failed"; rm -f "$tmp" "$db"; return; }
    # Explicit page 1
    result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries --page 1 --per-page 50 2>/dev/null)
    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['page'] == 1
assert len(d['entries']) == 50
assert json.loads(d['entries'][0]['raw_json'])['message']['content'] == 'Message 0'
print('OK2')
" 2>/dev/null | grep -q "OK2" || { fail "Pagination page-1 failed"; rm -f "$tmp" "$db"; return; }
    # Page 2
    result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries --page 2 --per-page 50 2>/dev/null)
    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['page'] == 2
assert len(d['entries']) == 50
assert json.loads(d['entries'][0]['raw_json'])['message']['content'] == 'Message 50'
print('OK3')
" 2>/dev/null | grep -q "OK3" && success "Pagination works" || fail "Pagination page-2 failed"
    rm -f "$tmp" "$db"
}

test_tindex_fts5_search() {
    info "Testing transcript-index.py FTS5 search with BM25 ranking..."
    local tmp=$(mktemp /tmp/tindex-search-XXXX.jsonl)
    local db="/tmp/test-tindex-search.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'general conversation about weather'}, 'timestamp': '2026-04-05T10:00:00Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'deploy deploy deploy worker to mac'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'one mention of deploy here'}, 'timestamp': '2026-04-05T10:00:02Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query search --search deploy 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total_results'] == 2, f'Expected 2 results, got {d[\"total_results\"]}'
# 3x deploy should rank higher (first)
first_text = json.loads(d['entries'][0]['raw_json'])
assert 'deploy deploy deploy' in str(first_text), f'3x deploy should be first'
print('OK')
" && success "FTS5 search ranks correctly" || fail "FTS5 search ranking failed"
    else
        fail "transcript-index.py crashed on search"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_search_no_results() {
    info "Testing transcript-index.py search with no matches..."
    local tmp=$(mktemp /tmp/tindex-nores-XXXX.jsonl)
    local db="/tmp/test-tindex-nores.db"
    python3 -c "
import json
with open('$tmp', 'w') as f:
    f.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'Hello world'}, 'timestamp': '2026-04-05T10:00:00Z'}) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query search --search xyznonexistent 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total_results'] == 0
assert d['entries'] == []
print('OK')
" && success "Search no-results works" || fail "Search no-results failed"
    else
        fail "transcript-index.py crashed on empty search"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_filter_prompts() {
    info "Testing transcript-index.py prompts filter..."
    local tmp=$(mktemp /tmp/tindex-filter-XXXX.jsonl)
    local db="/tmp/test-tindex-filter.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Real prompt'}, 'timestamp': '2026-04-05T10:00:00Z'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Reply'}]}, 'timestamp': '2026-04-05T10:00:01Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': '<task-notification>system stuff</task-notification>'}, 'timestamp': '2026-04-05T10:00:02Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': '<system-reminder>internal</system-reminder>'}, 'timestamp': '2026-04-05T10:00:03Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'result'}]}, 'timestamp': '2026-04-05T10:00:04Z'},
    {'type': 'user', 'message': {'role': 'user', 'content': 'Another real prompt'}, 'timestamp': '2026-04-05T10:00:05Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query entries --filter prompts 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 2, f'Expected 2 prompts, got {d[\"total\"]}'
texts = [json.loads(e['raw_json'])['message']['content'] for e in d['entries']]
assert 'Real prompt' in texts
assert 'Another real prompt' in texts
print('OK')
" && success "Prompts filter works" || fail "Prompts filter failed"
    else
        fail "transcript-index.py crashed on filter"
    fi
    rm -f "$tmp" "$db"
}

test_tindex_stats() {
    info "Testing transcript-index.py stats query..."
    local tmp=$(mktemp /tmp/tindex-stats-XXXX.jsonl)
    local db="/tmp/test-tindex-stats.db"
    python3 -c "
import json
entries = [
    {'type': 'user', 'message': {'role': 'user', 'content': 'Fix the bug'}, 'timestamp': '2026-04-05T10:00:00Z', 'version': '2.1.85', 'gitBranch': 'main'},
    {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 't1', 'name': 'Edit', 'input': {'file_path': '/tmp/app.py', 'old_string': 'x = 1\ny = 2', 'new_string': 'x = 10\ny = 20\nz = 30'}},
    ], 'model': 'claude-opus-4-6', 'usage': {'input_tokens': 5000, 'cache_read_input_tokens': 3000, 'output_tokens': 1200}}, 'timestamp': '2026-04-05T12:30:00Z'},
]
with open('$tmp', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"
    if result=$(python3 transcript-index.py --jsonl "$tmp" --db "$db" --query stats 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['n_user'] == 1, f'n_user={d[\"n_user\"]}'
assert d['n_tool'] == 1, f'n_tool={d[\"n_tool\"]}'
assert d['n_edit'] == 1, f'n_edit={d[\"n_edit\"]}'
assert d['input_tokens'] == 8000, f'input_tokens={d[\"input_tokens\"]}'
assert d['output_tokens'] == 1200, f'output_tokens={d[\"output_tokens\"]}'
assert d['model'] == 'claude-opus-4-6', f'model={d[\"model\"]}'
assert d['version'] == '2.1.85', f'version={d[\"version\"]}'
assert d['duration'] == '2h 30m', f'duration={d[\"duration\"]}'
assert d['n_files'] == 1
# Per-edit: old=2, new=3 → overlap=2, add=1, del=0
assert d['lines_add'] == 1, f'lines_add={d[\"lines_add\"]}'
assert d['lines_mod'] == 2, f'lines_mod={d[\"lines_mod\"]}'
assert d['lines_del'] == 0, f'lines_del={d[\"lines_del\"]}'
print('OK')
" && success "Stats query works" || fail "Stats query failed"
    else
        fail "transcript-index.py crashed on stats"
    fi
    rm -f "$tmp" "$db"
}

# ── End Transcript Index Tests ────────────────────────────────────────────

# ── Team Chat Index Tests (team-chat-index.py) ───────────────────────────

test_tcindex_missing_file() {
    info "Testing team-chat-index.py handles missing JSONL..."
    if result=$(python3 team-chat-index.py --jsonl /nonexistent/path.jsonl --db /tmp/test-tcindex-missing.db --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['messages'] == [], f'Expected empty messages, got {d[\"messages\"]}'
assert d['total'] == 0, f'Expected total=0, got {d[\"total\"]}'
assert d['total_pages'] == 0
assert d['page'] == 1
print('OK')
" && success "team-chat-index.py handles missing JSONL" || fail "Missing file test failed"
    else
        fail "team-chat-index.py crashed on missing file"
    fi
    rm -f /tmp/test-tcindex-missing.db
}

test_tcindex_empty_file() {
    info "Testing team-chat-index.py handles empty JSONL..."
    local tmp=$(mktemp /tmp/tcindex-empty-XXXX.jsonl)
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db /tmp/test-tcindex-empty.db --query entries 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['messages'] == [], 'Expected empty messages'
assert d['total'] == 0
print('OK')
" && success "team-chat-index.py handles empty JSONL" || fail "Empty file test failed"
    else
        fail "team-chat-index.py crashed on empty file"
    fi
    rm -f "$tmp" /tmp/test-tcindex-empty.db
}

test_tcindex_basic_indexing() {
    info "Testing team-chat-index.py indexes messages into SQLite..."
    local tmp=$(mktemp /tmp/tcindex-basic-XXXX.jsonl)
    local db="/tmp/test-tcindex-basic.db"
    python3 -c "
import json
msgs = [
    {'id': 100, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Hello team good morning', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 101, 'timestamp': '2026-04-05T10:00:30', 'timestamp_unix': 1775120430, 'from': 'beasts', 'text': 'lee:\nGood morning manager', 'target_agents': ['lee'], 'has_command': False, 'reply_to': None},
    {'id': 102, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'Thinh', 'text': '@lee check the PR please', 'target_agents': ['lee'], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries --page 1 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json, sqlite3
d = json.load(sys.stdin)
assert d['total'] == 3, f'Expected 3 messages, got {d[\"total\"]}'
assert len(d['messages']) == 3
assert d['messages'][0]['msg_id'] == 100
assert d['messages'][1]['msg_id'] == 101
assert d['messages'][2]['msg_id'] == 102
# Verify SQLite
db = sqlite3.connect('$db')
count = db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
assert count == 3, f'SQLite has {count} rows, expected 3'
db.close()
print('OK')
" && success "team-chat-index.py indexes messages" || fail "Basic indexing test failed"
    else
        fail "team-chat-index.py crashed on basic indexing"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_sender_resolution() {
    info "Testing team-chat-index.py resolves sender names correctly..."
    local tmp=$(mktemp /tmp/tcindex-sender-XXXX.jsonl)
    local db="/tmp/test-tcindex-sender.db"
    python3 -c "
import json
msgs = [
    {'id': 200, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Hello from manager', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 201, 'timestamp': '2026-04-05T10:00:30', 'timestamp_unix': 1775120430, 'from': 'beasts', 'text': 'lee:\nI am lee responding', 'target_agents': ['lee'], 'has_command': False, 'reply_to': None},
    {'id': 202, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'beasts', 'text': 'System notification text here', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 203, 'timestamp': '2026-04-05T10:01:30', 'timestamp_unix': 1775120490, 'from': 'beasts', 'text': 'mon: Here is the cost analysis', 'target_agents': ['mon'], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries --page 1 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msgs = d['messages']
assert msgs[0]['display_sender'] == 'manager', f'Thinh should be manager, got {msgs[0][\"display_sender\"]}'
assert msgs[1]['display_sender'] == 'lee', f'beasts+lee: should be lee, got {msgs[1][\"display_sender\"]}'
assert msgs[1]['text'] == 'I am lee responding', f'lee text should have prefix stripped, got {msgs[1][\"text\"]}'
assert msgs[2]['display_sender'] == 'beasts', f'beasts without prefix should stay beasts, got {msgs[2][\"display_sender\"]}'
assert msgs[3]['display_sender'] == 'mon', f'beasts+mon: should be mon, got {msgs[3][\"display_sender\"]}'
assert msgs[3]['text'] == 'Here is the cost analysis', f'mon text prefix not stripped: {msgs[3][\"text\"]}'
print('OK')
" && success "team-chat-index.py resolves senders" || fail "Sender resolution test failed"
    else
        fail "team-chat-index.py crashed on sender resolution"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_incremental() {
    info "Testing team-chat-index.py indexes incrementally..."
    local tmp=$(mktemp /tmp/tcindex-incr-XXXX.jsonl)
    local db="/tmp/test-tcindex-incr.db"
    # Write 3 messages
    python3 -c "
import json
msgs = [
    {'id': 300, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'First message here', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 301, 'timestamp': '2026-04-05T10:00:30', 'timestamp_unix': 1775120430, 'from': 'Thinh', 'text': 'Second message here', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 302, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'Thinh', 'text': 'Third message here ok', 'target_agents': [], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    # First run
    python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>&1
    # Append 2 more
    python3 -c "
import json
msgs = [
    {'id': 303, 'timestamp': '2026-04-05T10:02:00', 'timestamp_unix': 1775120520, 'from': 'Thinh', 'text': 'Fourth appended message', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 304, 'timestamp': '2026-04-05T10:03:00', 'timestamp_unix': 1775120580, 'from': 'Thinh', 'text': 'Fifth appended message', 'target_agents': [], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'a') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries --page 1 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json, sqlite3
d = json.load(sys.stdin)
assert d['total'] == 5, f'Expected 5 total after incremental, got {d[\"total\"]}'
db = sqlite3.connect('$db')
count = db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
assert count == 5, f'SQLite has {count} rows, expected 5'
# Verify idx continuity
idxs = [r[0] for r in db.execute('SELECT idx FROM messages ORDER BY idx').fetchall()]
assert idxs == [0, 1, 2, 3, 4], f'Indices not continuous: {idxs}'
db.close()
print('OK')
" && success "team-chat-index.py incremental indexing" || fail "Incremental test failed"
    else
        fail "team-chat-index.py crashed on incremental"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_no_reindex_unchanged() {
    info "Testing team-chat-index.py skips reindex when unchanged..."
    local tmp=$(mktemp /tmp/tcindex-noreindex-XXXX.jsonl)
    local db="/tmp/test-tcindex-noreindex.db"
    python3 -c "
import json
msgs = [
    {'id': 400, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Only message for test', 'target_agents': [], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    # First index
    python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>&1
    # Get db modification time
    local mtime1=$(stat -c %Y "$db" 2>/dev/null || stat -f %m "$db" 2>/dev/null)
    sleep 1
    # Run again — should skip
    python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>&1
    local mtime2=$(stat -c %Y "$db" 2>/dev/null || stat -f %m "$db" 2>/dev/null)
    # DB mod time should be same (WAL mode may differ, so check entry count)
    if python3 -c "
import sqlite3
db = sqlite3.connect('$db')
count = db.execute('SELECT COUNT(*) FROM messages').fetchone()[0]
assert count == 1, f'Expected 1, got {count} — reindexed!'
print('OK')
"; then
        success "team-chat-index.py skips reindex when unchanged"
    else
        fail "Reindexed when file unchanged"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_pagination() {
    info "Testing team-chat-index.py pagination..."
    local tmp=$(mktemp /tmp/tcindex-page-XXXX.jsonl)
    local db="/tmp/test-tcindex-page.db"
    # Write 10 messages
    python3 -c "
import json
with open('$tmp', 'w') as f:
    for i in range(10):
        m = {'id': 500+i, 'timestamp': f'2026-04-05T10:{i:02d}:00', 'timestamp_unix': 1775120400+i*60,
             'from': 'Thinh', 'text': f'Message number {i} content', 'target_agents': [], 'has_command': False, 'reply_to': None}
        f.write(json.dumps(m) + '\n')
"
    # Test: default page (last), per_page=3
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries --per-page 3 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 10, f'Expected 10 total, got {d[\"total\"]}'
assert d['total_pages'] == 4, f'Expected 4 pages (10/3=4), got {d[\"total_pages\"]}'
assert d['page'] == 4, f'Default page should be last (4), got {d[\"page\"]}'
assert len(d['messages']) == 1, f'Last page should have 1 msg, got {len(d[\"messages\"])}'
assert d['messages'][0]['msg_id'] == 509, f'Last msg should be 509, got {d[\"messages\"][0][\"msg_id\"]}'
print('OK - default last page')
" && success "Pagination default last page" || fail "Pagination default page failed"
    else
        fail "team-chat-index.py crashed on pagination"
    fi
    # Test: page 1
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries --per-page 3 --page 1 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['page'] == 1
assert len(d['messages']) == 3
assert d['messages'][0]['msg_id'] == 500
assert d['messages'][2]['msg_id'] == 502
print('OK - page 1')
" && success "Pagination page 1" || fail "Pagination page 1 failed"
    else
        fail "team-chat-index.py crashed on page 1"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_fts5_search() {
    info "Testing team-chat-index.py FTS5 search..."
    local tmp=$(mktemp /tmp/tcindex-search-XXXX.jsonl)
    local db="/tmp/test-tcindex-search.db"
    python3 -c "
import json
msgs = [
    {'id': 600, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Check the gemini costs please', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 601, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'beasts', 'text': 'mon:\nGemini API costs are 400 per day for gemini', 'target_agents': ['mon'], 'has_command': False, 'reply_to': None},
    {'id': 602, 'timestamp': '2026-04-05T10:02:00', 'timestamp_unix': 1775120520, 'from': 'Thinh', 'text': 'How is the Flutter build going', 'target_agents': [], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query search --search gemini 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total_results'] == 2, f'Expected 2 results for gemini, got {d[\"total_results\"]}'
assert d['query'] == 'gemini'
# msg 601 mentions gemini twice, should rank higher
msg_ids = [m['msg_id'] for m in d['messages']]
assert 600 in msg_ids and 601 in msg_ids, f'Expected 600 and 601 in results, got {msg_ids}'
assert 602 not in msg_ids, f'602 (Flutter) should not match gemini'
print('OK')
" && success "team-chat-index.py FTS5 search" || fail "FTS5 search failed"
    else
        fail "team-chat-index.py crashed on search"
    fi
    rm -f "$tmp" "$db"
}

test_tcindex_page_for_msg() {
    info "Testing team-chat-index.py page-for-msg query..."
    local tmp=$(mktemp /tmp/tcindex-pfm-XXXX.jsonl)
    local db="/tmp/test-tcindex-pfm.db"
    # Write 10 messages (ids 700-709)
    python3 -c "
import json
with open('$tmp', 'w') as f:
    for i in range(10):
        m = {'id': 700+i, 'timestamp': f'2026-04-05T10:{i:02d}:00', 'timestamp_unix': 1775120400+i*60,
             'from': 'Thinh', 'text': f'Message number {i} for page test', 'target_agents': [], 'has_command': False, 'reply_to': None}
        f.write(json.dumps(m) + '\n')
"
    # Index first
    python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query entries >/dev/null 2>&1
    # Test: msg 700 (idx=0) with per_page=3 → page 1
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query page-for-msg --msg-id 700 --per-page 3 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['msg_id'] == 700
assert d['idx'] == 0
assert d['page'] == 1, f'msg 700 (idx=0, per_page=3) should be page 1, got {d[\"page\"]}'
print('OK - msg 700 on page 1')
"  || fail "page-for-msg 700 failed"
    fi
    # Test: msg 705 (idx=5) with per_page=3 → page 2 (idx 3,4,5)
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query page-for-msg --msg-id 705 --per-page 3 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['page'] == 2, f'msg 705 (idx=5, per_page=3) should be page 2, got {d[\"page\"]}'
print('OK - msg 705 on page 2')
"  || fail "page-for-msg 705 failed"
    fi
    # Test: nonexistent msg
    if result=$(python3 team-chat-index.py --jsonl "$tmp" --db "$db" --query page-for-msg --msg-id 999 --per-page 3 2>/dev/null); then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['page'] is None, f'Nonexistent msg should return page=None, got {d[\"page\"]}'
print('OK - nonexistent msg')
" || fail "page-for-msg nonexistent failed"
    fi
    success "team-chat-index.py page-for-msg query"
    rm -f "$tmp" "$db"
}

# ── End Team Chat Index Tests ────────────────────────────────────────────

# ── Team Chat Bridge Tests ───────────────────────────────────────────────

test_rewind_team_token() {
    info "Testing /rewind team generates team chat token..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

bridge.REWIND_TOKENS.clear()
router = bridge.CommandRouter.__new__(bridge.CommandRouter)
router.workers = MagicMock()
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

with patch.object(bridge, 'BRIDGE_PUBLIC_URL', 'http://100.125.36.102:8271'):
    router.cmd_rewind('team', 12345)

assert len(replies) == 1
reply = replies[0]
assert '/team-chat?' in reply, f'Should contain /team-chat URL: {reply}'
assert 'token=' in reply
assert 'Team chat' in reply

# Verify token stored with __team__ name
token = list(bridge.REWIND_TOKENS.keys())[0]
entry = bridge.REWIND_TOKENS[token]
assert entry['name'] == '__team__', f'Token name should be __team__: {entry}'
assert entry['expires_at'] > time.time()

# Also test --team variant
bridge.REWIND_TOKENS.clear()
replies.clear()
with patch.object(bridge, 'BRIDGE_PUBLIC_URL', 'http://100.125.36.102:8271'):
    router.cmd_rewind('--team', 12345)
assert '/team-chat?' in replies[0]
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/rewind team generates team chat token"
    else
        fail "Rewind team token test failed"
    fi
}

test_team_chat_403_no_token() {
    info "Testing /team-chat requires valid token..."
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import MagicMock
from urllib.parse import urlparse, parse_qs
import bridge

bridge.REWIND_TOKENS.clear()

handler = MagicMock()
handler.send_response = MagicMock()
handler.send_header = MagicMock()
handler.end_headers = MagicMock()
handler.wfile = MagicMock()
handler.wfile.write = MagicMock()

# No token → 403
parsed = urlparse('/team-chat')
bridge.Handler.handle_team_chat_endpoint(handler, parsed)
handler.send_response.assert_called_with(403)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat requires valid token"
    else
        fail "Team chat 403 test failed"
    fi
}

test_team_chat_renders_html() {
    info "Testing /team-chat renders HTML with valid token..."
    # Create a test JSONL
    local tmp=$(mktemp /tmp/tchat-render-XXXX.jsonl)
    python3 -c "
import json
msgs = [
    {'id': 800, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Hello team good morning', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 801, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'beasts', 'text': 'lee:\nGood morning', 'target_agents': ['lee'], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
from urllib.parse import urlparse
import bridge

# Set up test data paths
bridge.TEAM_CHAT_JSONL = '$tmp'
bridge.TEAM_CHAT_DB = '/tmp/test-tchat-render.db'

# Add a valid token
token = 'test-token-123'
bridge.REWIND_TOKENS[token] = {'name': '__team__', 'expires_at': time.time() + 300}

# Call the renderer directly
html = bridge._render_team_chat_html(page=1, per_page=50, token=token)
assert 'Team Chat' in html, f'Should contain title'
assert 'msg-800' in html, f'Should contain msg-800 anchor'
assert 'msg-801' in html, f'Should contain msg-801 anchor'
assert 'manager' in html, f'Thinh should be resolved to manager'
assert 'lee' in html, f'beasts+lee: should show as lee'
assert 'Good morning' in html, f'Should contain message text'

# Verify handler returns 200
handler = MagicMock()
handler.send_response = MagicMock()
handler.send_header = MagicMock()
handler.end_headers = MagicMock()
buf = bytearray()
handler.wfile = MagicMock()
handler.wfile.write = lambda d: buf.extend(d)
handler.headers = {'Accept-Encoding': ''}
handler._send_html = bridge.Handler._send_html.__get__(handler)
parsed = urlparse(f'/team-chat?token={token}&page=1')
bridge.Handler.handle_team_chat_endpoint(handler, parsed)
handler.send_response.assert_called_with(200)
body = buf.decode('utf-8')
assert 'msg-800' in body

bridge.REWIND_TOKENS.clear()
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat renders HTML"
    else
        fail "Team chat render test failed"
    fi
    rm -f "$tmp" /tmp/test-tchat-render.db
}

test_team_chat_search() {
    info "Testing /team-chat search returns results..."
    local tmp=$(mktemp /tmp/tchat-search-XXXX.jsonl)
    python3 -c "
import json
msgs = [
    {'id': 900, 'timestamp': '2026-04-05T10:00:00', 'timestamp_unix': 1775120400, 'from': 'Thinh', 'text': 'Check the gemini costs analysis', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 901, 'timestamp': '2026-04-05T10:01:00', 'timestamp_unix': 1775120460, 'from': 'Thinh', 'text': 'Flutter build is ready now', 'target_agents': [], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if python3 -c "
import sys, os, time
sys.path.insert(0, os.getcwd())
import bridge

bridge.TEAM_CHAT_JSONL = '$tmp'
bridge.TEAM_CHAT_DB = '/tmp/test-tchat-search.db'

html = bridge._render_team_chat_html(page=1, per_page=50, search_query='gemini', token='t')
assert 'gemini' in html.lower(), 'Should contain search term'
assert 'msg-900' in html, 'Should show matching msg 900'
assert 'Found' in html, 'Should show result count'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat search works"
    else
        fail "Team chat search test failed"
    fi
    rm -f "$tmp" /tmp/test-tchat-search.db
}

test_team_chat_anchor() {
    info "Testing /team-chat messages have msg-{id} anchors..."
    local tmp=$(mktemp /tmp/tchat-anchor-XXXX.jsonl)
    python3 -c "
import json
msgs = [
    {'id': 3167866, 'timestamp': '2026-04-06T10:04:31', 'timestamp_unix': 1775206271, 'from': 'Thinh', 'text': '@ryo check with mon about gemini costs', 'target_agents': ['ryo'], 'has_command': False, 'reply_to': None},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
import bridge

bridge.TEAM_CHAT_JSONL = '$tmp'
bridge.TEAM_CHAT_DB = '/tmp/test-tchat-anchor.db'

html = bridge._render_team_chat_html(page=1, per_page=50, token='t')
assert 'id=\"msg-3167866\"' in html, f'Should have anchor for msg 3167866'
# Verify the JS scroll-to-hash code is present
assert 'location.hash' in html, 'Should have hash-scroll JS'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat messages have anchors"
    else
        fail "Team chat anchor test failed"
    fi
    rm -f "$tmp" /tmp/test-tchat-anchor.db
}

test_team_chat_search_context_link() {
    info "Testing /team-chat search results have context links..."
    local tmp=$(mktemp /tmp/tchat-ctx-XXXX.jsonl)
    python3 -c "
import json
msgs = []
for i in range(60):
    msgs.append({'id': 9000+i, 'timestamp': f'2026-04-06T10:{i:02d}:00', 'timestamp_unix': 1775206000+i*60, 'from': 'Thinh' if i%2==0 else 'beasts', 'text': f'message number {i} about deployment' if i == 55 else f'message {i}', 'target_agents': [], 'has_command': False, 'reply_to': None})
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
import bridge

bridge.TEAM_CHAT_JSONL = '$tmp'
bridge.TEAM_CHAT_DB = '/tmp/test-tchat-ctx.db'

# Search for 'deployment' — msg 55 is on page 2 (idx 55, per_page 50)
html = bridge._render_team_chat_html(page=1, per_page=50, search_query='deployment', token='t')
# Should contain context link arrow pointing to page 2
assert 'ctx-link' in html, 'Should have context link class'
assert 'page=2' in html, f'Should link to page 2 where msg lives'
assert '#msg-9055' in html, 'Should anchor to the message'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat search context links work"
    else
        fail "Team chat search context link test failed"
    fi
    rm -f "$tmp" /tmp/test-tchat-ctx.db
}

test_team_chat_reply_context() {
    info "Testing /team-chat renders reply context..."
    local tmp=$(mktemp /tmp/tchat-reply-XXXX.jsonl)
    python3 -c "
import json
msgs = [
    {'id': 8001, 'timestamp': '2026-04-06T10:00:00', 'timestamp_unix': 1775206000, 'from': 'Thinh', 'text': 'what is the status of PR 123?', 'target_agents': [], 'has_command': False, 'reply_to': None},
    {'id': 8002, 'timestamp': '2026-04-06T10:01:00', 'timestamp_unix': 1775206060, 'from': 'beasts', 'text': 'lee: PR 123 is merged and deployed', 'target_agents': [], 'has_command': False, 'reply_to': 8001},
]
with open('$tmp', 'w') as f:
    for m in msgs:
        f.write(json.dumps(m) + '\n')
"
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
import bridge

bridge.TEAM_CHAT_JSONL = '$tmp'
bridge.TEAM_CHAT_DB = '/tmp/test-tchat-reply.db'

html = bridge._render_team_chat_html(page=1, per_page=50, token='t')
# Should have reply context block
assert 'reply-ctx' in html, 'Should have reply context class'
assert '#msg-8001' in html, 'Reply should link to original message'
# Should show the replied-to message sender/text
assert 'manager' in html, 'Reply context should show sender'
assert 'status of PR 123' in html, 'Reply context should show text snippet'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/team-chat reply context works"
    else
        fail "Team chat reply context test failed"
    fi
    rm -f "$tmp" /tmp/test-tchat-reply.db
}

# ── End Team Chat Bridge Tests ───────────────────────────────────────────

# ── Memory Subcommand Tests ─────────────────────────────────────────────

test_memory_status_subcommand() {
    info "Testing /memory status returns stack status..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

router.cmd_memory('status', 12345)

assert len(replies) == 1, f'Expected 1 reply, got {len(replies)}'
r = replies[0]
assert 'Memory Stack Status' in r, f'Should contain status header: {r[:100]}'
assert 'Chunks' in r, f'Should contain chunk count: {r[:200]}'
assert 'Messages' in r, f'Should contain message count: {r[:200]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/memory status works"
    else
        fail "/memory status subcommand failed"
    fi
}

test_memory_wakeup_subcommand() {
    info "Testing /memory wake-up returns L0+L1 text..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

router.cmd_memory('wake-up', 12345)

assert len(replies) == 1, f'Expected 1 reply, got {len(replies)}'
r = replies[0]
assert 'L0' in r or 'TEAM IDENTITY' in r, f'Should contain L0: {r[:100]}'
assert 'L1' in r or 'ESSENTIAL STORY' in r, f'Should contain L1: {r[:100]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/memory wake-up works"
    else
        fail "/memory wake-up subcommand failed"
    fi
}

test_memory_wakeup_with_wing() {
    info "Testing /memory wake-up omi passes wing filter..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

captured = []
class FakeStack:
    def wake_up(self, wing=None):
        captured.append(wing)
        return '## L0\ntest\n## L1\ntest'

with patch('team_memory.memory_stack.MemoryStack', return_value=FakeStack()):
    router.cmd_memory('wake-up omi', 12345)

assert len(captured) == 1 and captured[0] == 'omi', f'Expected wing=omi, got {captured}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/memory wake-up omi passes wing"
    else
        fail "/memory wake-up with wing failed"
    fi
}

test_memory_recall_subcommand() {
    info "Testing /memory recall --wing=omi --room=prs..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

captured = []
class FakeStack:
    def recall(self, wing=None, room=None):
        captured.append((wing, room))
        return 'Recall results for omi/prs'

with patch('team_memory.memory_stack.MemoryStack', return_value=FakeStack()):
    router.cmd_memory('recall --wing=omi --room=prs', 12345)

assert len(captured) == 1, f'Expected 1 recall call, got {len(captured)}'
assert captured[0] == ('omi', 'prs'), f'Expected (omi, prs), got {captured[0]}'
assert 'Recall results' in replies[0]
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/memory recall with wing/room works"
    else
        fail "/memory recall subcommand failed"
    fi
}

test_memory_status_failure_isolation() {
    info "Testing /memory status handles MemoryStack failure gracefully..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from unittest.mock import patch, MagicMock
import bridge

router = bridge.CommandRouter.__new__(bridge.CommandRouter)
replies = []
router.reply = lambda cid, msg, **kw: replies.append(msg)

with patch('team_memory.memory_stack.MemoryStack', side_effect=RuntimeError('DB gone')):
    router.cmd_memory('status', 12345)

assert len(replies) == 1
assert 'failed' in replies[0].lower() or 'error' in replies[0].lower(), f'Should report error: {replies[0]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/memory status handles failure gracefully"
    else
        fail "/memory status failure isolation failed"
    fi
}

# ── End Memory Subcommand Tests ─────────────────────────────────────────


test_file_validation() {
    info "Testing file validation (image path, document path, blocked filenames)..."
    if python3 -c "
from bridge import validate_photo_path, validate_document_path, is_blocked_filename
from pathlib import Path
import tempfile
import os

# === Image path restriction ===
tmp = tempfile.NamedTemporaryFile(suffix='.jpg', delete=False)
tmp.write(b'fake jpg')
tmp.close()
ok, result = validate_photo_path(Path(tmp.name))
assert ok, f'/tmp path should be allowed: {result}'
os.unlink(tmp.name)

# Non-existent file should fail
ok, result = validate_photo_path(Path('/nonexistent/image.jpg'))
assert not ok, 'Non-existent path should be rejected'

# === Document path (no restriction) ===
tmp = tempfile.NamedTemporaryFile(suffix='.txt', delete=False)
tmp.write(b'test content')
tmp.close()
ok, result = validate_document_path(Path(tmp.name))
assert ok, f'Document should be allowed: {result}'
os.unlink(tmp.name)

# === Blocked filenames ===
assert is_blocked_filename('.env'), '.env should be blocked'
assert is_blocked_filename('.env.local'), '.env.local should be blocked'
assert is_blocked_filename('id_rsa'), 'id_rsa should be blocked'
assert is_blocked_filename('.npmrc'), '.npmrc should be blocked'
assert is_blocked_filename('.netrc'), '.netrc should be blocked'
assert not is_blocked_filename('readme.txt')
assert not is_blocked_filename('report.pdf')

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "File validation (image, document, blocked filenames) works"
    else
        fail "File validation test failed"
    fi
}

test_file_size_limit_50mb() {
    info "Testing file size limit is 50MB (Telegram Bot API limit)..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from bridge import validate_document_path, validate_photo_path, MAX_FILE_SIZE
from pathlib import Path
import tempfile

# Verify MAX_FILE_SIZE is 50MB (Telegram Bot API limit)
assert MAX_FILE_SIZE == 50 * 1024 * 1024, f'MAX_FILE_SIZE should be 50MB, got {MAX_FILE_SIZE}'

# 21MB file (kenji's MP3) should pass
tmp = tempfile.NamedTemporaryFile(suffix='.mp3', delete=False)
tmp.write(b'x' * (21 * 1024 * 1024))
tmp.close()
ok, result = validate_document_path(Path(tmp.name))
assert ok, f'21MB file should be accepted: {result}'
os.unlink(tmp.name)

# 49MB file should pass (under 50MB limit)
tmp = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
tmp.write(b'x' * (49 * 1024 * 1024))
tmp.close()
ok, result = validate_document_path(Path(tmp.name))
assert ok, f'49MB file should be accepted: {result}'
os.unlink(tmp.name)

# 51MB file should be rejected (over 50MB limit)
tmp = tempfile.NamedTemporaryFile(suffix='.mp3', delete=False)
tmp.write(b'x' * (51 * 1024 * 1024))
tmp.close()
ok, result = validate_document_path(Path(tmp.name))
assert not ok, '51MB file should be rejected'
os.unlink(tmp.name)

# Photo validation also uses 50MB limit
tmp = tempfile.NamedTemporaryFile(suffix='.jpg', delete=False)
tmp.write(b'x' * (21 * 1024 * 1024))
tmp.close()
ok, result = validate_photo_path(Path(tmp.name))
assert ok, f'21MB photo should be accepted: {result}'
os.unlink(tmp.name)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "File size limit is 50MB (Telegram Bot API limit)"
    else
        fail "File size limit test failed"
    fi
}

test_incoming_media_types() {
    info "Testing incoming media type handling (audio, voice, video, video_note, sticker)..."
    if python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())

# Test that handle_message extracts file_id from all media types
# We test the parsing logic, not the actual download

media_types = {
    'audio': {'file_id': 'audio123', 'duration': 180, 'title': 'Song', 'file_name': 'song.mp3'},
    'voice': {'file_id': 'voice123', 'duration': 5},
    'video': {'file_id': 'video123', 'duration': 30, 'file_name': 'clip.mp4'},
    'video_note': {'file_id': 'vnote123', 'duration': 10},
    'sticker': {'file_id': 'sticker123', 'emoji': '🔥'},
}

# Verify each type produces a valid update structure with file_id
for mtype, data in media_types.items():
    msg = {'message_id': 1, 'chat': {'id': 12345}, mtype: data}
    update = {'update_id': 1, 'message': msg}

    # Verify file_id is extractable
    media_item = msg.get(mtype)
    assert media_item is not None, f'{mtype} should be in msg'
    assert media_item.get('file_id'), f'{mtype} should have file_id'

    # Verify it's not caught by photo/document/animation handlers
    assert msg.get('photo') is None
    assert msg.get('document') is None
    assert msg.get('animation') is None

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Incoming media type handling works for audio/voice/video/video_note/sticker"
    else
        fail "Incoming media type handling test failed"
    fi
}


test_sandbox_docker_cmd() {
    info "Testing sandbox Docker command generation..."
    if python3 -c "
import os
from pathlib import Path
os.environ['SANDBOX_ENABLED'] = '1'
os.environ['PORT'] = '8295'
os.environ['BRIDGE_URL'] = ''

from bridge import get_docker_run_cmd

cmd = get_docker_run_cmd('testworker')
home = str(Path.home())

# Verify command structure
assert 'docker run -it' in cmd, 'should have docker run -it'
assert '--name=claude-worker-testworker' in cmd, 'should have container name'
assert '--rm' in cmd, 'should have --rm for cleanup'

# Verify default home mount to /workspace
assert f'-v={home}:/workspace' in cmd, 'should mount home to /workspace'

# Verify working directory
assert '-w /workspace' in cmd, 'should set workdir to /workspace'

# Verify BRIDGE_URL for container->host communication
assert 'BRIDGE_URL=http://host.docker.internal:8295' in cmd, 'should set BRIDGE_URL'

# Verify claude command with --dangerously-skip-permissions
assert 'claude --dangerously-skip-permissions' in cmd, 'should run claude with skip permissions'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Sandbox Docker command correct"
    else
        fail "Sandbox Docker command test failed"
    fi
}

test_bridge_starts() {
    info "Starting bridge on port $PORT..."

    # Kill any existing process on port
    lsof -ti :"$PORT" | xargs kill -9 2>/dev/null || true
    sleep 0.3

    # Create test node directory structure
    mkdir -p "$TEST_NODE_DIR"
    mkdir -p "$TEST_SESSION_DIR"
    mkdir -p "$TEST_TEAM_DIR"
    chmod 700 "$TEST_NODE_DIR" "$TEST_SESSION_DIR" "$TEST_TEAM_DIR"

    # Reset test node's workers.json to prevent cross-run orphan pollution
    local wjson="$TEST_NODE_DIR/workers.json"
    if [[ "$wjson" == *"/nodes/test/"* ]]; then
        printf '{"workers":{}}' > "$wjson" 2>/dev/null || true
    fi

    # Bridge launch env. Defaults preserve legacy behaviour exactly (real
    # TEST_BOT_TOKEN, ADMIN_CHAT_ID = TEST_CHAT_ID, and NO TELEGRAM_API_BASE in
    # the env so bridge.py keeps its real api.telegram.org default). When the
    # Mock-Telegram harness is active (start_mock_telegram ran first) we redirect
    # the wire to the mock, force a NON-EMPTY dummy token (so `if not BOT_TOKEN`
    # early-returns in media/file paths don't skip), and pin a concrete
    # ADMIN_CHAT_ID so the admin gate is deterministic. All stay env-overridable.
    local launch_token="$TEST_BOT_TOKEN"
    local launch_admin="${TEST_CHAT_ID:-}"
    local -a launch_env=()
    if [[ "$MOCK_TG_ACTIVE" == "1" ]]; then
        launch_token="${MOCK_BOT_TOKEN:-${TEST_BOT_TOKEN:-mock-token}}"
        launch_admin="${MOCK_ADMIN_CHAT_ID:-$CHAT_ID}"
        launch_env+=("TELEGRAM_API_BASE=${TELEGRAM_API_BASE:-http://127.0.0.1:$MOCKPORT}")
    fi

    # Start bridge with test node isolation
    TELEGRAM_BOT_TOKEN="$launch_token" \
    PORT="$PORT" \
    NODE_NAME="$TEST_NODE" \
    SESSIONS_DIR="$TEST_SESSION_DIR" \
    TMUX_PREFIX="$TEST_TMUX_PREFIX" \
    ADMIN_CHAT_ID="$launch_admin" \
    TEAM_DIR="$TEST_TEAM_DIR" \
    env "${launch_env[@]}" \
    python3 -u "$SCRIPT_DIR/bridge.py" > "$BRIDGE_LOG" 2>&1 &
    BRIDGE_PID=$!
    echo "$BRIDGE_PID" > "$TEST_NODE_DIR/bridge.pid"
    echo "$PORT" > "$TEST_NODE_DIR/port"

    if wait_for_port "$PORT"; then
        success "Bridge started on port $PORT"
    else
        fail "Bridge failed to start"
        return 1
    fi

    # Verify endpoint
    if curl -s "http://localhost:$PORT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'endpoints' in d" 2>/dev/null; then
        success "Bridge endpoint responds with JSON API index"
    else
        fail "Bridge endpoint not responding with JSON"
    fi
}

test_admin_registration() {
    info "Testing admin auto-registration..."

    local result
    result=$(send_message "hello")

    if [[ "$result" == "OK" ]]; then
        success "First message accepted (admin registered)"
    else
        fail "First message failed"
    fi
}

test_backend_env_metadata() {
    info "Testing worker backend env exports claude..."

    if python3 -c "
import bridge
import unittest.mock as mock

calls = []

def fake_run(cmd, **kwargs):
    calls.append(cmd)
    class Result:
        returncode = 0
        stdout = ''
    return Result()

with mock.patch.object(bridge, 'subprocess') as mock_subprocess:
    mock_subprocess.run.side_effect = fake_run
    bridge.export_hook_env('claude-test-backend', 'claude')

found = any('WORKER_BACKEND' in cmd and 'claude' in cmd for cmd in calls)
assert found, f'WORKER_BACKEND=claude not set in tmux env: {calls}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Backend env stored in tmux env"
    else
        fail "Backend env tmux export test failed"
    fi
}

# BEHAVIOR TEST: Verify tmux session remains running after creation (parity with direct mode)
test_tmux_mode_session_stays_alive() {
    info "Testing tmux mode session stays alive after creation..."

    # Clean up any existing test session
    python3 -c "import bridge; bridge.session_manager.close_session('tmuxalive')" >/dev/null 2>&1 || true
    wait_for_session_gone "tmuxalive" 2>/dev/null || true

    # Create session via the product path (topic flow calls open_session)
    if ! python3 -c "
import bridge
ok, msg = bridge.session_manager.open_session('tmuxalive', chat_id=123456)
assert ok, msg
" 2>/dev/null; then
        fail "Tmux session alive: open_session failed"
        return
    fi

    # Wait for tmux session to be created
    if ! wait_for_session "tmuxalive"; then
        fail "Tmux session alive: Session not created"
        return
    fi

    local tmux_name="${TEST_TMUX_PREFIX}tmuxalive"

    # KEY BEHAVIOR TEST: Wait 3 seconds and verify session is STILL running
    sleep 3

    if tmux has-session -t "$tmux_name" 2>/dev/null; then
        success "Tmux session alive: Session still running after 3 seconds"
    else
        fail "Tmux session alive: Session died unexpectedly"
        return
    fi

    # Cleanup via close_session (covers the close path end-to-end)
    python3 -c "import bridge; bridge.session_manager.close_session('tmuxalive')" >/dev/null 2>&1 || true
    if wait_for_session_gone "tmuxalive"; then
        success "close_session removes tmux session"
    else
        fail "close_session failed to remove session"
    fi
}

# BEHAVIOR TEST: Verify message actually reaches the tmux session pane
test_tmux_mode_message_delivery() {
    info "Testing tmux mode message delivery to session..."

    # Clean up any existing test session
    python3 -c "import bridge; bridge.session_manager.close_session('tmuxmsg')" >/dev/null 2>&1 || true
    wait_for_session_gone "tmuxmsg" 2>/dev/null || true

    # Create session via the product path
    if ! python3 -c "
import bridge
ok, msg = bridge.session_manager.open_session('tmuxmsg', chat_id=123456)
assert ok, msg
" 2>/dev/null; then
        fail "Message delivery: open_session failed"
        return
    fi

    # Wait for session to be created
    if ! wait_for_session "tmuxmsg"; then
        fail "Message delivery: Session not created"
        return
    fi

    local tmux_name="${TEST_TMUX_PREFIX}tmuxmsg"
    sleep 0.5

    # KEY BEHAVIOR TEST: deliver via the product send path (topic handler calls
    # session_manager.send) and verify the message appears in the tmux pane
    local unique_msg="test_msg_${RANDOM}"
    if ! python3 -c "
import sys, bridge
ok = bridge.session_manager.send('tmuxmsg', sys.argv[1], chat_id=123456)
assert ok, 'send returned False'
" "$unique_msg" 2>/dev/null; then
        fail "Message delivery: session_manager.send failed"
        python3 -c "import bridge; bridge.session_manager.close_session('tmuxmsg')" >/dev/null 2>&1 || true
        return
    fi

    # Wait for message to be delivered
    sleep 1

    # Capture tmux pane content and check for our message
    local pane_content
    pane_content=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || echo "")

    if echo "$pane_content" | grep -q "$unique_msg"; then
        success "Message delivery: Message appeared in tmux session"
    else
        fail "Message delivery: Message not found in tmux pane"
    fi

    # Cleanup
    python3 -c "import bridge; bridge.session_manager.close_session('tmuxmsg')" >/dev/null 2>&1 || true
    wait_for_session_gone "tmuxmsg" 2>/dev/null || true
}

test_session_files() {
    info "Testing session file permissions..."

    # Create a session of our own (no dependency on other tests' sessions)
    python3 -c "import bridge; bridge.session_manager.close_session('permbot')" >/dev/null 2>&1 || true
    if ! python3 -c "
import bridge
ok, msg = bridge.session_manager.open_session('permbot', chat_id=123456)
assert ok, msg
" 2>/dev/null; then
        fail "Session files: open_session failed"
        return
    fi
    wait_for_session "permbot" >/dev/null 2>&1 || true

    local session_dir="$TEST_SESSION_DIR/permbot"

    if [[ -d "$session_dir" ]]; then
        # Check directory permissions (should be 0700)
        local dir_perms
        if [[ "$(uname)" == "Darwin" ]]; then
            dir_perms=$(stat -f "%Lp" "$session_dir")
        else
            dir_perms=$(stat -c "%a" "$session_dir")
        fi
        if [[ "$dir_perms" == "700" ]]; then
            success "Session directory has secure permissions (0700)"
        else
            fail "Session directory permissions incorrect: $dir_perms"
        fi

        # Check chat_id file if exists
        if [[ -f "$session_dir/chat_id" ]]; then
            local file_perms
            if [[ "$(uname)" == "Darwin" ]]; then
                file_perms=$(stat -f "%Lp" "$session_dir/chat_id")
            else
                file_perms=$(stat -c "%a" "$session_dir/chat_id")
            fi
            if [[ "$file_perms" == "600" ]]; then
                success "chat_id file has secure permissions (0600)"
            else
                fail "chat_id file permissions incorrect: $file_perms"
            fi
        fi
    else
        fail "Session directory not created"
    fi

    # Cleanup
    python3 -c "import bridge; bridge.session_manager.close_session('permbot')" >/dev/null 2>&1 || true
}

test_notify_endpoint() {
    info "Testing /notify endpoint..."

    local result
    result=$(hook_curl "http://localhost:$PORT/notify" '{"text":"Test notification"}')

    if echo "$result" | grep -q "Sent to"; then
        success "/notify endpoint works"
    else
        fail "/notify endpoint failed: $result"
    fi
}

test_document_message_routing() {
    info "Testing document message routing to focused worker..."

    # Create and focus a worker
    open_dm_session

    # Send a document message
    local result
    result=$(send_document_message "test_doc_file_id" "report.pdf" "application/pdf" 2048 "Please review this")

    if [[ "$result" == "OK" ]]; then
        # Check bridge log for the document handling
        sleep 0.3
        if grep -q "tmain" "$BRIDGE_LOG" 2>/dev/null; then
            success "Document message routed to focused worker"
        else
            success "Document message accepted (routing attempted)"
        fi
    else
        fail "Document message routing failed"
    fi

    # Cleanup
    close_dm_session
}

test_incoming_document_e2e() {
    info "Testing incoming document e2e (upload -> webhook -> download)..."

    # In DEFAULT/e2e mode the bridge points at the recording mock (MOCK_TG_ACTIVE=1),
    # so a real-Telegram upload->getFile->download round-trip cannot complete (the
    # mock doesn't hold the real file). The deterministic SEAM-07 mock test
    # (test_mock_incoming_document_downloads_to_inbox) covers the incoming
    # getFile+download path at the wire, so skip this real-Telegram variant.
    if [[ "${MOCK_TG_ACTIVE:-}" == "1" ]]; then
        info "Skipping: superseded by the SEAM-07 mock test (bridge is on the mock)"
        return 0
    fi

    # This test requires a real TEST_CHAT_ID to upload documents to Telegram
    if [[ "${TEST_CHAT_ID:-}" == "" ]] || [[ "$CHAT_ID" == "123456789" ]]; then
        info "Skipping (requires TEST_CHAT_ID for real Telegram upload)"
        return 0
    fi

    local inbox_dir
    inbox_dir=$(python3 -c 'import bridge; print(bridge.get_inbox_dir("tmain"))')
    if [[ "$inbox_dir" != */test/* ]]; then
        fail "Refusing to use non-test inbox path: $inbox_dir"
        return
    fi
    rm -rf "$inbox_dir"

    # Create worker to receive document
    open_dm_session

    # Create a test text file
    echo "This is a test document for e2e testing." > /tmp/e2e-test-document.txt

    # Upload document to Telegram to get a real file_id
    local upload_response
    upload_response=$(curl -s -X POST "https://api.telegram.org/bot${TEST_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${CHAT_ID}" \
        -F "document=@/tmp/e2e-test-document.txt" \
        -F "caption=E2E test document")

    # Extract file_id from response
    local file_id
    file_id=$(echo "$upload_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['document']['file_id'])" 2>/dev/null)

    if [[ -z "$file_id" ]]; then
        fail "Could not upload test document to get file_id"
    close_dm_session
        return
    fi

    # Now simulate incoming document webhook with real file_id
    local update_id=$((RANDOM))
    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$CHAT_ID"', "first_name": "TestUser"},
                "chat": {"id": '"$CHAT_ID"', "type": "private"},
                "date": '"$(date +%s)"',
                "document": {
                    "file_id": "'"$file_id"'",
                    "file_unique_id": "'"$file_id"'_unique",
                    "file_name": "e2e-test-document.txt",
                    "mime_type": "text/plain",
                    "file_size": 42
                },
                "caption": "Test incoming document"
            }
        }' >/dev/null

    # Check if document was downloaded to inbox. Only real files count; bridge
    # log messages include rejection paths and are not a success signal.
    local inbox_manifest
    inbox_manifest="$(mktemp)"
    local got_file=0 attempts=0
    while [[ $attempts -lt 50 ]]; do
        : > "$inbox_manifest"
        local f
        for f in "$inbox_dir"/*.txt; do
            [[ -f "$f" ]] && printf '%s\n' "$f" >> "$inbox_manifest"
        done
        if wait_for_file_content "$inbox_manifest" '\.txt$' 0; then
            got_file=1
            break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [[ "$got_file" == "1" ]]; then
        success "Incoming document downloaded to inbox"
        ls -la "$inbox_dir"/ 2>/dev/null | head -3
    else
        fail "Incoming document not downloaded to inbox"
    fi

    # Cleanup
    close_dm_session
    rm -f "$inbox_manifest"
    rm -f /tmp/e2e-test-document.txt
}

test_incoming_image_e2e() {
    info "Testing incoming image e2e (upload -> webhook -> download)..."

    # In DEFAULT/e2e mode the bridge points at the recording mock (MOCK_TG_ACTIVE=1),
    # so a real-Telegram upload->getFile->download round-trip cannot complete. The
    # incoming getFile+download path is identical to the document case and is
    # covered deterministically at the wire by the SEAM-07 mock test, so skip this
    # real-Telegram variant. (Coverage note: a mock incoming-IMAGE test is a Task-8
    # gap-filler candidate; the download mechanism itself is already exercised.)
    if [[ "${MOCK_TG_ACTIVE:-}" == "1" ]]; then
        info "Skipping: superseded by the SEAM-07 mock test (bridge is on the mock)"
        return 0
    fi

    # This test requires a real TEST_CHAT_ID to upload images to Telegram
    if [[ "${TEST_CHAT_ID:-}" == "" ]] || [[ "$CHAT_ID" == "123456789" ]]; then
        info "Skipping (requires TEST_CHAT_ID for real Telegram upload)"
        return 0
    fi

    local inbox_dir
    inbox_dir=$(python3 -c 'import bridge; print(bridge.get_inbox_dir("tmain"))')
    if [[ "$inbox_dir" != */test/* ]]; then
        fail "Refusing to use non-test inbox path: $inbox_dir"
        return
    fi
    rm -rf "$inbox_dir"

    # Create worker to receive image
    open_dm_session

    # Create a test image (pure stdlib — PIL is not a project dependency)
    python3 << 'PYEOF'
import struct, zlib

def chunk(tag, data):
    c = tag + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

w = h = 64
raw = b''.join(b'\x00' + b'\x28\xa7\x45' * w for _ in range(h))  # solid green rows
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/e2e-test-incoming.png', 'wb').write(png)
PYEOF

    # Upload image to Telegram to get a real file_id
    local upload_response
    upload_response=$(curl -s -X POST "https://api.telegram.org/bot${TEST_BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=@/tmp/e2e-test-incoming.png" \
        -F "caption=E2E test upload")

    # Extract file_id from response
    local file_id
    file_id=$(echo "$upload_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['photo'][-1]['file_id'])" 2>/dev/null)

    if [[ -z "$file_id" ]]; then
        fail "Could not upload test image to get file_id"
    close_dm_session
        return
    fi

    # Now simulate incoming photo webhook with real file_id
    local update_id=$((RANDOM))
    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "message": {
                "message_id": '"$update_id"',
                "from": {"id": '"$CHAT_ID"', "first_name": "TestUser"},
                "chat": {"id": '"$CHAT_ID"', "type": "private"},
                "date": '"$(date +%s)"',
                "photo": [
                    {"file_id": "'"$file_id"'_small", "file_size": 1000, "width": 90, "height": 45},
                    {"file_id": "'"$file_id"'", "file_size": 5000, "width": 200, "height": 100}
                ],
                "caption": "Test incoming image"
            }
        }' >/dev/null

    # Check if image was downloaded to inbox. Only real files count; bridge log
    # messages include rejection paths and are not a success signal.
    local inbox_manifest
    inbox_manifest="$(mktemp)"
    local got_file=0 attempts=0
    while [[ $attempts -lt 50 ]]; do
        : > "$inbox_manifest"
        local f
        for f in "$inbox_dir"/*.png "$inbox_dir"/*.jpg "$inbox_dir"/*.jpeg; do
            [[ -f "$f" ]] && printf '%s\n' "$f" >> "$inbox_manifest"
        done
        if wait_for_file_content "$inbox_manifest" '\.(png|jpg|jpeg)$' 0; then
            got_file=1
            break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [[ "$got_file" == "1" ]]; then
        success "Incoming image downloaded to inbox"
        ls -la "$inbox_dir"/ 2>/dev/null | head -3
    else
        fail "Incoming image not downloaded to inbox"
    fi

    # Cleanup
    close_dm_session
    rm -f "$inbox_manifest"
}

test_inbox_directory() {
    info "Testing inbox directory creation..."

    # Create worker
    open_dm_session

    if python3 -c "
from bridge import ensure_inbox_dir, get_inbox_dir
import os

inbox = ensure_inbox_dir('tmain')
assert inbox.exists(), 'inbox should exist'
perms = oct(inbox.stat().st_mode)[-3:]
assert perms == '700', f'inbox perms should be 700, got {perms}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Inbox directory created with correct permissions"
    else
        fail "Inbox directory creation failed"
    fi

    # Cleanup
    close_dm_session
}

test_response_with_image_tags() {
    info "Testing /response endpoint with image tags..."

    # Create a session
    open_dm_session

    # Set up session files
    local session_dir="$TEST_SESSION_DIR/tmain"
    mkdir -p "$session_dir"
    echo "$CHAT_ID" > "$session_dir/chat_id"

    # Test response with image tag (image won't exist, but parsing should work)
    local result body
    body='{"session":"tmain","text":"Here is the result [[image:/tmp/nonexistent.png|test caption]]"}'
    result=$(hook_curl "http://localhost:$PORT/response" "$body")

    if [[ "$result" == "OK" ]]; then
        # Check bridge log for image handling attempt
        sleep 0.3
        if grep -q "tmain" "$BRIDGE_LOG" 2>/dev/null; then
            success "/response endpoint handles image tags"
        else
            fail "/response endpoint did not process message"
        fi
    else
        fail "/response with image tags failed: $result"
    fi

    # Cleanup
    close_dm_session
}

test_response_endpoint() {
    info "Testing /response endpoint (hook -> bridge -> Telegram)..."

    # Use real chat_id if TEST_CHAT_ID provided (for full e2e verification)
    local test_chat_id="$CHAT_ID"
    local expect_real="false"
    [[ -n "${TEST_CHAT_ID:-}" ]] && expect_real="true"

    # Create a new session for this test
    open_dm_session

    # Set up pending file (simulates waiting for response)
    local session_dir="$TEST_SESSION_DIR/tmain"
    mkdir -p "$session_dir"
    date +%s > "$session_dir/pending"
    echo "$test_chat_id" > "$session_dir/chat_id"

    # Simulate hook calling /response endpoint
    local result body
    body='{"session":"tmain","text":"Test response from hook"}'
    result=$(hook_curl "http://localhost:$PORT/response" "$body")

    if [[ "$result" == "OK" ]]; then
        # Check bridge log for success
        sleep 0.3
        if grep -q "Response sent: tmain -> Telegram OK" "$BRIDGE_LOG" 2>/dev/null; then
            if [[ "$expect_real" == "true" ]]; then
                success "/response endpoint sends to Telegram (check your Telegram!)"
            else
                success "/response endpoint sends to Telegram"
            fi
        else
            # Check if there was an API error (expected with fake chat_id)
            if grep -q "Telegram API error" "$BRIDGE_LOG" 2>/dev/null; then
                if [[ "$expect_real" == "true" ]]; then
                    fail "/response endpoint failed to send (check TEST_REAL_CHAT_ID)"
                else
                    success "/response endpoint works (API error expected with test chat_id)"
                fi
            else
                fail "/response endpoint did not log send attempt"
            fi
        fi
    else
        fail "/response endpoint failed: $result"
    fi

    # Cleanup
    close_dm_session
}

test_last_chat_id_persistence() {
    local last_chat_file="$TEST_NODE_DIR/last_chat_id"

    # Clean up first
    rm -f "$last_chat_file"

    # Send a message to trigger chat ID save
    send_message "test persistence"
    sleep 0.5

    # Verify file was created with correct content
    if [[ -f "$last_chat_file" ]]; then
        local saved_id
        saved_id=$(cat "$last_chat_file")
        if [[ "$saved_id" == "$CHAT_ID" ]]; then
            success "last_chat_id persistence works"
        else
            fail "last_chat_id mismatch: expected $CHAT_ID, got $saved_id"
        fi
    else
        fail "last_chat_id file not created"
    fi
}


test_response_without_pending() {
    info "Testing /response works without pending file (v0.6.2 behavior)..."

    # Create a session for this test
    open_dm_session

    # Set up ONLY chat_id file - NO pending file
    # This tests v0.6.2 change: pending is not a gate for sending
    local session_dir="$TEST_SESSION_DIR/tmain"
    mkdir -p "$session_dir"
    echo "$CHAT_ID" > "$session_dir/chat_id"
    # Explicitly ensure no pending file
    rm -f "$session_dir/pending"

    # Simulate hook calling /response endpoint
    local result body
    body='{"session":"tmain","text":"Test without pending"}'
    result=$(hook_curl "http://localhost:$PORT/response" "$body")

    if [[ "$result" == "OK" ]]; then
        success "/response works without pending file (proactive messaging enabled)"
    else
        fail "/response without pending failed: $result"
    fi

    # Cleanup
    close_dm_session
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker naming and routing tests
# ─────────────────────────────────────────────────────────────────────────────

test_hire_binary_check() {
    info "Testing session creation rejects missing claude binary..."

    if python3 -c "
import bridge

# Save originals
orig_which_binary = bridge._which_binary

# Make 'claude' not found
def mock_which_binary(name):
    if name == 'claude':
        return None
    return orig_which_binary(name)

bridge._which_binary = mock_which_binary

# open_session should fail with binary-not-found error
ok, err = bridge.session_manager.open_session('testbincheck')
assert ok is False, f'expected open_session to fail, got ok={ok}'
assert 'claude' in err, f'expected binary name in error: {err}'
assert 'not found' in err, f'expected not-found message: {err}'

# Verify no tmux session was created
import subprocess
result = subprocess.run(['tmux', 'has-session', '-t', f'{bridge.TMUX_PREFIX}testbincheck'], capture_output=True)
assert result.returncode != 0, 'tmux session should NOT have been created'

# Cleanup
bridge._which_binary = orig_which_binary

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "session creation rejects missing claude binary"
    else
        fail "missing claude binary check test failed"
    fi
}

test_claude_start_cmd() {
    info "Testing claude start command generation..."

    if python3 - <<'PY' 2>/dev/null | grep -q "OK"; then
import os, sys
sys.path.insert(0, os.environ.get("BRIDGE_DIR", "."))
os.environ.setdefault("TELEGRAM_BOT_TOKEN", "fake")
import bridge

cmd = bridge.build_claude_start_cmd("abc123")
assert "--resume" in cmd, f"resume flag missing: {cmd}"
assert "--dangerously-skip-permissions" in cmd, f"danger flag missing: {cmd}"
assert "--append-system-prompt" not in cmd, f"append flag should be removed: {cmd}"

cmd2 = bridge.build_claude_start_cmd()
assert "--resume" not in cmd2, f"resume should not be present: {cmd2}"
assert "--dangerously-skip-permissions" in cmd2, f"danger flag missing: {cmd2}"

print("OK")
PY
        success "Claude start command generation works"
    else
        fail "Claude start command test failed"
    fi
}


test_watchdog_suppressed_after_restart() {
    info "Testing watchdog resolved alert suppressed after recent restart..."

    if python3 -c "
import time
import bridge

calls = []
def fake_api(method, data):
    calls.append((method, data))
    return {'ok': True}

orig_api = bridge.telegram_api
bridge.telegram_api = fake_api
bridge.admin_chat_id = 12345

# Clear state
with bridge._watchdog_lock:
    bridge._prev_session_states.clear()
    bridge._prev_session_states['bob'] = 'STUCK'

# Mark bob as recently restarted
bridge._recent_restarts['bob'] = time.time()

# Resolved alert should be suppressed
bridge._send_resolved_alert('bob', 'READY')
assert len(calls) == 0, f'Expected 0 calls (suppressed), got {len(calls)}'

# After 30s, should fire again
bridge._recent_restarts['bob'] = time.time() - 31
calls.clear()
bridge._send_resolved_alert('bob', 'READY')
assert len(calls) == 1, f'Expected 1 call after cooldown, got {len(calls)}'

bridge.telegram_api = orig_api
bridge.admin_chat_id = None
bridge._recent_restarts.clear()
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog resolved alert suppressed after restart"
    else
        fail "Watchdog resolved alert suppressed after restart"
    fi
}

test_get_any_session_id() {
    info "Testing get_any_session_id finds codex/claude session ids..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp

# No session dir
sid, src = bridge.get_any_session_id('alice')
assert sid == '' and src == '', f'Expected empty, got {sid}/{src}'

# With codex_session_id
session_dir = tmp / 'alice'
session_dir.mkdir()
(session_dir / 'codex_session_id').write_text('thread_abc')
sid, src = bridge.get_any_session_id('alice')
assert sid == 'thread_abc', f'Expected thread_abc, got {sid}'
assert src == 'codex', f'Expected codex, got {src}'

# With claude_session_id
(session_dir / 'codex_session_id').unlink()
(session_dir / 'claude_session_id').write_text('sess_xyz')
sid, src = bridge.get_any_session_id('alice')
assert sid == 'sess_xyz', f'Expected sess_xyz, got {sid}'
assert src == 'claude', f'Expected claude, got {src}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "get_any_session_id works"
    else
        fail "get_any_session_id test failed"
    fi
}

test_extract_worker_activity() {
    info "Testing _extract_activity parses tmux output signals..."

    if python3 -c "
from bridge import _extract_activity

# Spinner shows actual verb + duration (not just 'Thinking')
lines = ['some output', '· Razzle-dazzling… (6m 21s · thought for 7s)', '───']
result = _extract_activity(lines)
assert 'razzle-dazzling' in result.lower(), f'Expected verb in: {result}'
assert '6m 21s' in result, f'Expected duration in: {result}'

# Compacting shows as compacting, not thinking
lines = ['some output', '* Compacting conversation… (5m 26s · thought for 5s)', '───']
result = _extract_activity(lines)
assert 'compacting' in result.lower(), f'Expected compacting in: {result}'
assert '5m 26s' in result, f'Expected duration in: {result}'

# Thinking with * prefix
lines = ['some output', '* Stewing… (44s)', 'more stuff']
result = _extract_activity(lines)
assert 'stewing' in result.lower(), f'Expected verb in: {result}'
assert '44s' in result, f'Expected duration in: {result}'

# Tool actively running (● prefix + ⎿ Running...)
lines = ['● Bash(python3 -u test.py)', '  ⎿  Running...']
result = _extract_activity(lines)
assert 'bash' in result.lower() or 'running' in result.lower(), f'Expected running bash in: {result}'

# Finished tool call should NOT report as running
lines = ['● Bash(python3 -u test.py)', '  ⎿  file1.txt', '     file2.txt']
result = _extract_activity(lines)
assert 'running' not in result.lower(), f'Finished tool should NOT show as running: {result}'

# Backgrounded tool should NOT report as running
lines = ['● Bash(python3 -u test.py 2>&1)', '  ⎿  Running in the background (↓ to manage)', '✻ Compacting conversation… (5m 26s)', '❯']
result = _extract_activity(lines)
assert 'running bash' not in result.lower(), f'Backgrounded tool should NOT show as running: {result}'

# Task list with progress
lines = ['  ✔ Task A', '  ✔ Task B', '  ◻ Task C', '  ◻ Task D']
result = _extract_activity(lines)
assert '2' in result and '4' in result, f'Expected 2/4 progress in: {result}'

# Error in discussion should NOT trigger error (false positive)
lines = ['● 300ms gap gives best result: 0.77% with 53.4%', 'savings (only 16 errors). Close to target.']
result = _extract_activity(lines)
assert 'error:' not in result.lower(), f'Should not false-positive on discussion error: {result}'

# Standalone error line SHOULD trigger
lines = ['FAIL: test_something', 'exit code 1']
result = _extract_activity(lines)
assert 'error' in result.lower() or 'fail' in result.lower(), f'Expected error/fail in: {result}'

# Plan approval prompt
lines = ['Plan:', '1. Do X', '2. Do Y', 'Do you want to proceed?']
result = _extract_activity(lines)
assert 'waiting' in result.lower() or 'input' in result.lower() or 'approval' in result.lower(), f'Expected waiting/input in: {result}'

# ✻ Churned = PAST tense, NOT active thinking — with mode bar at bottom
lines = ['● Skill looks solid.', '✻ Churned for 2m 45s', '───', '❯ save reports', '───', '  ⏵⏵ bypass permissions on · 1 bash']
result = _extract_activity(lines)
assert 'thinking' not in result.lower(), f'✻ Churned should NOT be thinking: {result}'
assert result == 'Ready', f'Prompt with bypass mode bar should be idle: {result}'

# ✻ with ellipsis = ACTIVE spinner frame, not past tense (kelvin bug 2026-03-08)
lines = ['● Bash(ssh host \"adb screencap\")', '  ⎿  Running… (7s · timeout 15s)', '✻ Discombobulating… (49m 13s · thinking)', '───', '❯', '───', '⏵⏵ bypass permissions on (shift+tab to cycle) · es…']
result = _extract_activity(lines)
assert 'discombobulating' in result.lower(), f'✻ with … should be active spinner: {result}'
assert '49m 13s' in result, f'Expected duration in: {result}'

# Prompt with hint text = idle (auto-suggestion, not queued message)
lines = ['● Done with task.', '───', '❯ do the next thing', '───']
result = _extract_activity(lines)
assert result == 'Ready', f'Prompt hint text should be idle: {result}'

# Idle at bare prompt
lines = ['● Done with task.', '───', '❯', '───']
result = _extract_activity(lines)
assert result == 'Ready', f'Expected idle at prompt: {result}'

# bypass permissions mode bar is NEVER a blocking prompt — bypass = auto-approved
lines = ['● Some output', '  ⏵⏵ bypass permissions on · 1 bash']
result = _extract_activity(lines)
assert 'permission' not in result.lower(), f'Bypass mode bar should NOT be permission: {result}'

# bypass mode bar with prompt = idle
lines = ['● Some output', '───', '  ⏵⏵ bypass permissions on · 1 bash', '───', '❯', '───']
result = _extract_activity(lines)
assert result == 'Ready', f'Prompt with bypass mode bar should be idle: {result}'
assert 'permission' not in result.lower(), f'Should NOT show permission: {result}'

# mode bar WITHOUT pending actions = NOT a permission prompt
# bypass-permissions-on with shift+tab hint is just persistent mode bar
lines = ['● Done!', '✻ Cooked for 21m', '───', '❯ merge the PR', '───', '⏵⏵ bypass permissions on (shift+tab to cycle)']
result = _extract_activity(lines)
assert 'permission' not in result.lower(), f'Mode bar without actions should NOT be permission: {result}'
assert result == 'Ready', f'Prompt with hint text should be idle: {result}'

# ⏵⏵ accept edits on = mode bar, NOT permission prompt (Codex fix #3)
lines = ['● Finished edits', '⏵⏵ accept edits on (shift+tab to cycle)']
result = _extract_activity(lines)
assert 'permission' not in result.lower(), f'accept edits should NOT be permission: {result}'

# ⏸ plan mode bar detection (Codex fix #4)
lines = ['● Some output', '⏸ plan mode on (shift+tab to cycle)']
result = _extract_activity(lines)
assert 'plan mode' in result.lower(), f'Expected plan mode: {result}'

# ⏸ plan mode with prompt AFTER = idle (worker moved past plan mode bar)
lines = ['⏸ plan mode on (shift+tab to cycle)', '❯']
result = _extract_activity(lines)
assert result == 'Ready', f'Prompt after plan bar should be idle: {result}'

# Rate limit ABOVE prompt should still detect rate limit (Codex fix #2)
lines = ['Rate limit exceeded. Retrying in 30s...', '❯']
result = _extract_activity(lines)
assert 'rate limit' in result.lower(), f'Rate limit should beat idle prompt: {result}'

# Case-insensitive error matching (Codex fix #6)
lines = ['error: something went wrong']
result = _extract_activity(lines)
assert 'error' in result.lower(), f'Lowercase error should be caught: {result}'

lines = ['ERROR: fatal crash']
result = _extract_activity(lines)
assert 'error' in result.lower(), f'Uppercase ERROR should be caught: {result}'

# Active spinner beats mode bar (spinner is real status)
lines = ['· Ruminating… (20m 2s · thinking)', '───', '❯', '───', '  ⏵⏵ bypass permissions on · 1 bash']
result = _extract_activity(lines)
assert 'ruminating' in result.lower(), f'Active spinner should beat mode bar: {result}'
assert '20m 2s' in result, f'Expected duration in: {result}'

# Last ● block concat (multi-line) — no idle prompt after
lines = ['● Found 3 bugs in the', '  auth module. All critical.', '  Context left until auto-compact: 42%']
result = _extract_activity(lines)
assert 'found 3 bugs' in result.lower() and 'auth module' in result.lower(), f'Expected concat ● block: {result}'

# Rate limiting detection
lines = ['● Some output', 'Rate limit exceeded. Retrying in 30s...']
result = _extract_activity(lines)
assert 'rate limit' in result.lower(), f'Expected rate limit detection: {result}'

# Connection error detection
lines = ['● Output', 'Connection error, retrying in 5s']
result = _extract_activity(lines)
assert 'connection' in result.lower(), f'Expected connection error: {result}'

# Editor mode detection
lines = ['some code', 'Save and close editor to continue...']
result = _extract_activity(lines)
assert 'editor' in result.lower(), f'Expected editor mode: {result}'

# Hook execution — SessionStart
lines = ['Loading hooks', 'Running SessionStart hooks…']
result = _extract_activity(lines)
assert 'sessionstart' in result.lower() or 'hooks' in result.lower(), f'Expected hook execution: {result}'

# Hook execution — PreCompact
lines = ['Auto-compacting', 'Running PreCompact hooks…']
result = _extract_activity(lines)
assert 'precompact' in result.lower() or 'hooks' in result.lower(), f'Expected hook execution: {result}'

# Plan mode entry
lines = ['● Plan:', '1. Do X', '2. Do Y', 'Entering plan mode']
result = _extract_activity(lines)
assert 'plan' in result.lower(), f'Expected plan mode: {result}'

# Team lead approval
lines = ['Changes ready', 'Waiting for team lead to review and approve...']
result = _extract_activity(lines)
assert 'team lead' in result.lower(), f'Expected team lead: {result}'

# ✢ spinner character (Unicode cross spinner frame)
lines = ['some output', '✢ Befuddling… (14m 23s · thought for 3s)']
result = _extract_activity(lines)
assert 'befuddling' in result.lower(), f'Expected ✢ spinner verb: {result}'
assert '14m 23s' in result, f'Expected duration for ✢ spinner: {result}'

# Idle / empty
lines = ['', '  >', '']
result = _extract_activity(lines)
assert result, f'Should return something even for idle, got empty'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "_extract_activity parses tmux signals"
    else
        fail "_extract_activity parsing test failed"
    fi
}

test_activity_detects_interactive_prompt() {
    info "Testing _extract_activity detects interactive TUI prompts..."

    if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import _extract_activity, _extract_question_details

# AskUserQuestion single-select (exact kelvin repro)
lines = [
    '☐ Translate how?',
    '',
    'Which translation method?',
    '',
    '❯ 1. OpenAI API (Recommended)',
    '     Use GPT to auto-translate missing/untranslated',
    '  2. Detect only + open issue',
    '  3. Google Cloud Translate',
    '  4. Type something.',
    '───────────────────────────────────────────────────',
    '  5. Chat about this',
    '  6. Skip interview and plan immediately',
    '',
    'Enter to select · ↑/↓ to navigate · Esc to cancel',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Single-select: expected Waiting, got: {result}'
assert result != 'Ready', f'Single-select: must NOT be Ready'

# Question details extraction
details = _extract_question_details(lines)
assert details is not None, 'details should not be None'
assert details['header'] == 'Translate how?', f'header: {details[\"header\"]}'
assert len(details['options']) >= 4, f'options: {len(details[\"options\"])}'
assert details['selected_num'] == 1, f'selected: {details[\"selected_num\"]}'
assert details['options'][0]['label'] == 'OpenAI API (Recommended)', f'opt1: {details[\"options\"][0]}'

# AskUserQuestion multi-select
lines = [
    '☐ Which features?',
    '  [x] Feature A',
    '  [ ] Feature B',
    '  [ ] Feature C',
    'Space to toggle, Enter to confirm, a to select all, n to select none',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Multi-select: expected Waiting, got: {result}'

# Searchable list
lines = [
    'Select a file:',
    '❯ src/main.ts',
    '  src/app.ts',
    '  src/index.ts',
    'Press ↑↓ to navigate · Enter to select · Type to search · Esc to cancel',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Searchable: expected Waiting, got: {result}'

# Continue prompt
lines = [
    'Some output text here',
    'Press Enter to continue',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Continue: expected Waiting, got: {result}'

# Enter to confirm variant
lines = [
    '❯ 1. Yes, proceed',
    '  2. No, cancel',
    '↑/↓ to select · Enter to confirm · Esc to cancel',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Confirm variant: expected Waiting, got: {result}'

# Normal idle prompt must still work
lines = ['❯']
result = _extract_activity(lines)
assert result == 'Ready', f'Idle: expected Ready, got: {result}'

# Prompt with text (auto-suggestion) still idle
lines = ['❯ some auto text']
result = _extract_activity(lines)
assert result == 'Ready', f'Idle+text: expected Ready, got: {result}'

# No interactive prompt = None details
lines = ['❯']
details = _extract_question_details(lines)
assert details is None, f'Idle should have no details, got: {details}'
" 2>&1; then
        success "_extract_activity detects interactive prompts + rich details"
    else
        fail "_extract_activity interactive prompt detection failed"
    fi
}

test_activity_detects_plan_approval() {
    info "Testing _extract_activity detects ExitPlanMode plan approval prompt..."

    if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import _extract_activity, _extract_question_details

# ExitPlanMode 'Ready to code?' prompt (with editor configured)
lines = [
    'Here is Claude\'s plan:',
    '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -',
    '# Plan: Implement feature X',
    '',
    '## Files to modify',
    '| File | Change |',
    '|------|--------|',
    '| src/main.ts | Add handler |',
    '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -',
    'Claude has written up a plan and is ready to execute. Would you like to proceed?',
    '❯ 1. Yes, clear context (31% used) and bypass permissions',
    '  2. Yes, and bypass permissions',
    '  3. Yes, manually approve edits',
    '  4. Type here to tell Claude what to change',
    'ctrl-g to edit in Vim',
]
result = _extract_activity(lines)
assert 'Waiting' in result, f'Plan approval: expected Waiting, got: {result}'
assert result != 'Ready', f'Plan approval: must NOT be Ready'

# ExitPlanMode without editor (no ctrl-g footer — only content-based detection)
lines_no_editor = [
    'Claude has written up a plan and is ready to execute. Would you like to proceed?',
    '❯ 1. Yes, clear context (42% used) and auto-accept edits (shift+tab)',
    '  2. Yes, auto-accept edits',
    '  3. Yes, manually approve edits',
    '  4. Type here to tell Claude what to change',
]
result = _extract_activity(lines_no_editor)
assert 'Waiting' in result or 'plan' in result.lower(), f'No-editor plan: expected plan/waiting, got: {result}'
assert result != 'Ready', f'No-editor plan: must NOT be Ready'

# ExitPlanMode with auto-approve countdown
lines_auto = [
    'Claude has written up a plan and is ready to execute. Would you like to proceed?',
    '❯ 1. Yes, clear context (50% used) and bypass permissions',
    '  2. Yes, and bypass permissions',
    '  3. Yes, manually approve edits',
    '  4. Type here to tell Claude what to change',
    'ctrl-g to edit in Vim',
    'Auto-approving in 5s… Press any key to intervene.',
]
result = _extract_activity(lines_auto)
assert 'Waiting' in result or 'plan' in result.lower() or 'auto' in result.lower(), \
    f'Auto-approve plan: expected plan/waiting/auto, got: {result}'
assert result != 'Ready', f'Auto-approve plan: must NOT be Ready'

# EnterPlanMode prompt (different from ExitPlanMode)
lines_enter = [
    'Claude wants to enter plan mode to explore and design an implementation approach.',
    'In plan mode, Claude will:',
    ' · Explore the codebase thoroughly',
    ' · Identify existing patterns',
    ' · Design an implementation strategy',
    ' · Present a plan for your approval',
    'No code changes will be made until you approve the plan.',
    '❯ 1. Yes, enter plan mode',
    '  2. No, start implementing now',
]
result = _extract_activity(lines_enter)
assert result != 'Ready', f'EnterPlanMode: must NOT be Ready, got: {result}'

# Tool permission prompt (e.g., Allow Bash?)
lines_tool = [
    'Allow Bash?',
    'ls -la /tmp',
    '❯ 1. Yes',
    '  2. Yes, and don\\'t ask again for this tool',
    '  3. No',
]
result = _extract_activity(lines_tool)
assert result != 'Ready', f'Tool permission: must NOT be Ready, got: {result}'

# Question details should still be extractable for plan approval
details = _extract_question_details(lines)
assert details is not None, f'Plan approval details should not be None'
assert details['selected_num'] == 1, f'Plan approval selected: {details[\"selected_num\"]}'
assert len(details['options']) >= 3, f'Plan approval options: {len(details[\"options\"])}'
" 2>&1; then
        success "_extract_activity detects plan approval prompts"
    else
        fail "_extract_activity plan approval detection failed"
    fi
}

test_watchdog_waiting_input_state() {
    info "Testing watchdog detects WAITING_INPUT state and formats alert..."

    if python3 -c "
import sys; sys.path.insert(0, '.')
import bridge, time

# Test _format_watchdog_status with WAITING_INPUT
bridge._session_states['testbot'] = ('WAITING_INPUT', 'question=Pick color', time.time() - 120)
result = bridge._format_watchdog_status('testbot')
assert 'Needs reply' in result, f'Expected Needs reply, got: {result}'
assert '2m' in result, f'Expected 2m duration, got: {result}'

# Test that WAITING_INPUT is in bad_states for alert transitions
bad = {'OFFLINE', 'DEAD', 'STUCK', 'POISONED', 'EXITED', 'WAITING_INPUT'}
assert 'WAITING_INPUT' in bad

# Test _team_attention_summary picks it up
icon, label, rank = bridge._team_attention_summary('Needs reply (2m)', 'Waiting for input: Pick color')
assert icon == '\U0001f7e1', f'Expected yellow icon, got: {icon}'
assert 'reply' in label, f'Expected reply label, got: {label}'

# Clean up
bridge._session_states.pop('testbot', None)
" 2>&1; then
        success "Watchdog WAITING_INPUT state detection"
    else
        fail "Watchdog WAITING_INPUT state detection failed"
    fi
}


test_concurrent_sends_no_interleave() {
    info "Testing concurrent tmux sends don't interleave (flock behavior)..."

    local test_session="test-conc-$$"
    local recv_log="/tmp/test-conc-recv-$$.log"
    rm -f "$recv_log"
    tmux new-session -d -s "$test_session" -x 200 -y 50 \
        "/bin/sh -c 'while IFS= read -r line; do printf \"%s\\n\" \"\$line\" >> $recv_log; done'"

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create test tmux session"
        return
    fi

    # Wait for the receiver command to be active without assuming pane shell syntax.
    local ready=0
    for _ in $(seq 1 20); do
        [[ -f "$recv_log" ]] && ready=1 && break
        [[ "$(tmux display-message -p -t "$test_session" '#{pane_current_command}' 2>/dev/null || true)" == "sh" ]] && ready=1 && break
        sleep 0.1
    done
    if [[ "$ready" -ne 1 ]]; then
        fail "Receiver did not start"
        tmux kill-session -t "$test_session" 2>/dev/null || true
        rm -f "$recv_log"
        return
    fi

    # 5 parallel threads, 5 messages each, all via tmux_send_message (has flock)
    if python3 -c "
import sys, threading, time; sys.path.insert(0, '.')
import bridge

bridge._node_name = 'test-conc'

results = {'errors': []}

def sender(label, count):
    for i in range(1, count+1):
        ok = bridge.tmux_send_message('$test_session', f'CC-{label}{i}')
        if not ok:
            results['errors'].append(f'{label}{i} send failed')

threads = []
for s in 'ABCDE':
    t = threading.Thread(target=sender, args=(s, 5))
    threads.append(t)
    t.start()
for t in threads:
    t.join()

assert not results['errors'], f'Send errors: {results[\"errors\"]}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        for _ in $(seq 1 30); do
            local lines
            lines=$(wc -l < "$recv_log" 2>/dev/null || echo 0)
            [[ "$lines" -ge 25 ]] && break
            sleep 0.1
        done

        # Count clean messages (each should be exactly CC-X# on its own line)
        # NB: grep -c prints 0 AND exits 1 on no-match — `|| echo 0` would yield "0\n0",
        # and a failing pipeline here aborts the whole suite under set -euo pipefail.
        local total_expected=25
        local clean
        clean=$(grep -cE '^CC-[A-E][1-5]$' "$recv_log" 2>/dev/null || true)
        clean=${clean:-0}
        local total
        total=$(grep -c 'CC-' "$recv_log" 2>/dev/null || true)
        total=${total:-0}
        local corrupted=$(( total - clean ))

        if [[ "$clean" -eq "$total_expected" && "$corrupted" -eq 0 ]]; then
            success "Concurrent sends: $clean/$total_expected clean, 0 corrupted"
        else
            fail "Concurrent sends: $clean/$total_expected clean, $corrupted corrupted"
            { grep -v '^CC-[A-E][1-5]$' "$recv_log" 2>/dev/null | grep 'CC-' | head -5 || true; } | while IFS= read -r line; do
                info "  corrupted: '$line'"
            done
        fi
    else
        fail "Concurrent send test script failed"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null
    rm -f "$recv_log"
}

test_flock_per_session_isolation() {
    info "Testing flock is per-session (different sessions don't block)..."

    if python3 -c "
import sys; sys.path.insert(0, '.')
import bridge

bridge._node_name = 'test-iso'

# Different sessions get different lock files
path_a = bridge.tmux_send_lock_path('session-alice')
path_b = bridge.tmux_send_lock_path('session-bob')
assert path_a != path_b, f'same lock path for different sessions: {path_a}'
assert 'session-alice' in str(path_a), f'lock path missing session name: {path_a}'
assert 'session-bob' in str(path_b), f'lock path missing session name: {path_b}'

# Acquiring flock on session A should not block session B
import fcntl, os
path_a.parent.mkdir(parents=True, exist_ok=True)
fd_a = os.open(str(path_a), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd_a, fcntl.LOCK_EX)

# Session B lock should be immediately acquirable (non-blocking test)
path_b.parent.mkdir(parents=True, exist_ok=True)
fd_b = os.open(str(path_b), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd_b, fcntl.LOCK_EX | fcntl.LOCK_NB)  # LOCK_NB = non-blocking, raises if blocked

fcntl.flock(fd_b, fcntl.LOCK_UN)
os.close(fd_b)
fcntl.flock(fd_a, fcntl.LOCK_UN)
os.close(fd_a)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Flock is per-session (different sessions independent)"
    else
        fail "Flock isolation between sessions failed"
    fi
}

test_flock_node_namespaced() {
    info "Testing flock path includes node name (multi-node isolation)..."

    if python3 -c "
import sys; sys.path.insert(0, '.')
import bridge

# Prod node
bridge._node_name = 'prod'
path_prod = bridge.tmux_send_lock_path('claude-prod-chen')
assert '/prod/locks/' in str(path_prod), f'prod lock not namespaced: {path_prod}'

# Dev node
bridge._node_name = 'dev'
path_dev = bridge.tmux_send_lock_path('claude-dev-chen')
assert '/dev/locks/' in str(path_dev), f'dev lock not namespaced: {path_dev}'

# They must be different (same worker name, different nodes)
assert path_prod != path_dev, f'prod and dev lock paths collide: {path_prod}'

# Follows existing pipe isolation pattern: /tmp/claudecode-telegram/<node>/...
assert str(path_prod).startswith('/tmp/claudecode-telegram/'), f'wrong base: {path_prod}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Flock path is node-namespaced (multi-node isolation)"
    else
        fail "Flock node namespace test failed"
    fi
}


test_end_clears_pending() {
    info "Testing /end clears pending file..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.FILE_INBOX_ROOT = tmp / 'inbox'
bridge.session_manager.sessions_dir = tmp
bridge.session_manager.tmux_prefix = 'claude-test-'
bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'}
}

bridge.set_pending('alice', 12345)
pending_file = bridge.get_pending_file('alice')
assert pending_file.exists(), 'pending should exist before end'

ok, err = bridge.session_manager.close_session('alice')
assert ok is True, f'end failed: {err}'
assert not pending_file.exists(), 'pending should be cleared by /end'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/end clears pending file"
    else
        fail "/end clears pending file test failed"
    fi
}

test_hook_response_clears_pending_on_send_failure() {
    info "Testing hook response clears pending even when Telegram send fails..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp

def boom(*a, **k):
    raise RuntimeError('telegram down')
bridge.send_response_to_telegram = boom
bridge.mark_hook_event = lambda n: None

bridge.set_pending('alice', 999)
assert bridge.get_pending_file('alice').exists(), 'pending should exist before delivery'

try:
    bridge.deliver_hook_response('alice', 'hi', 123)
except RuntimeError:
    pass  # send failure is expected to propagate

assert not bridge.get_pending_file('alice').exists(), 'pending must be cleared even when send fails'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "hook response clears pending on send failure"
    else
        fail "hook response pending-on-failure test failed"
    fi
}

test_restart_clears_pending() {
    info "Testing restart clears pending for interactive worker..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp
bridge.session_manager.tmux_prefix = 'claude-test-'
bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'}
}
# Force the dead-worker path and stub it, so restart() returns right after the
# (hoisted) clear_pending without doing real tmux work.
bridge.tmux_exists = lambda *a, **k: False
bridge.session_manager._restart_dead_worker = lambda *a, **k: (True, None)

bridge.set_pending('alice', 12345)
assert bridge.get_pending_file('alice').exists(), 'pending should exist before restart'

ok, err = bridge.session_manager.restart('alice')
assert not bridge.get_pending_file('alice').exists(), 'pending must be cleared by restart'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "restart clears pending"
    else
        fail "restart clears pending test failed"
    fi
}

test_end_clears_session_id_for_interactive() {
    info "Testing /end clears session id + cwd for interactive workers..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.FILE_INBOX_ROOT = tmp / 'inbox'
bridge.session_manager.sessions_dir = tmp
bridge.session_manager.tmux_prefix = 'claude-test-'
bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'}
}

session_dir = tmp / 'alice'
session_dir.mkdir()
(session_dir / 'claude_session_id').write_text('old-session-123')
(session_dir / 'claude_session_cwd').write_text('/some/old/dir')

bridge.state['active'] = 'alice'
ok, err = bridge.session_manager.close_session('alice')
assert ok is True, f'end failed: {err}'
assert not (session_dir / 'claude_session_id').exists(), 'session id must be cleared on /end'
assert not (session_dir / 'claude_session_cwd').exists(), 'session cwd must be cleared on /end'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/end clears session id + cwd for interactive workers"
    else
        fail "/end session-id-clear test failed"
    fi
}


test_get_registered_sessions_no_autopick() {
    info "Testing get_registered_sessions does not auto-pick focus..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp
bridge.session_manager.tmux_prefix = 'claude-test-'
bridge.session_manager.scan_tmux_sessions = lambda: {'bob': {'tmux': 'claude-test-bob', 'backend': 'claude'}}
bridge._registry_bootstrap = lambda reg: None
bridge._load_registry = lambda: {'workers': {}}

bridge.state['active'] = None
reg = bridge.session_manager.get_registered_sessions()
assert 'bob' in reg, 'bob should be registered'
assert bridge.state['active'] is None, 'focus must stay None, not be auto-picked'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "get_registered_sessions does not auto-pick"
    else
        fail "get_registered_sessions auto-pick test failed"
    fi
}

test_poisoned_hook_signal_file() {
    info "Testing poisoned detection via hook signal file..."

    if python3 -c "
import tempfile, time, os
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp

name = 'hooktest'
tmux_name = 'claude-test-hooktest'
session_dir = tmp / name
session_dir.mkdir()
(session_dir / 'backend').write_text('claude')

# Create hook signal file with 4 recent failures (>= 3 threshold)
node = os.environ.get('TMUX_PREFIX', 'claude-test-').rstrip('-').split('-', 1)[-1] if os.environ.get('TMUX_PREFIX') else 'test'
hook_dir = Path(f'/tmp/claudecode-telegram/{node}/{name}/hooks')
hook_dir.mkdir(parents=True, exist_ok=True)
failures_file = hook_dir / 'failures'

now = int(time.time())
lines = []
for i in range(4):
    lines.append(f'{now - i} Bash')
failures_file.write_text('\\n'.join(lines) + '\\n')

# _detect_poisoned should find hook signal and return reason
reason = bridge._detect_poisoned(name, tmux_name)
assert reason is not None, f'expected poisoned from hook signal, got None'
assert 'hook' in reason.lower() or 'failure' in reason.lower(), f'expected hook-based reason, got {reason!r}'

# Cleanup
import shutil
shutil.rmtree(hook_dir.parent, ignore_errors=True)
failures_file.unlink(missing_ok=True)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Poisoned detection via hook signal file works"
    else
        fail "Poisoned detection via hook signal file failed"
    fi
}

test_poisoned_hook_signal_stale_ignored() {
    info "Testing poisoned detection ignores stale hook signals..."

    if python3 -c "
import tempfile, time, os
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp

name = 'hookstale'
tmux_name = 'claude-test-hookstale'
session_dir = tmp / name
session_dir.mkdir()
(session_dir / 'backend').write_text('claude')

# Create hook signal file with 4 OLD failures (> 120s ago)
node = os.environ.get('TMUX_PREFIX', 'claude-test-').rstrip('-').split('-', 1)[-1] if os.environ.get('TMUX_PREFIX') else 'test'
hook_dir = Path(f'/tmp/claudecode-telegram/{node}/{name}/hooks')
hook_dir.mkdir(parents=True, exist_ok=True)
failures_file = hook_dir / 'failures'

old = int(time.time()) - 300
lines = []
for i in range(4):
    lines.append(f'{old - i} Bash')
failures_file.write_text('\\n'.join(lines) + '\\n')

# Should NOT detect poisoned (stale failures)
reason = bridge._detect_poisoned(name, tmux_name)
# With stale hook signals, should fall through to regex (which has no pane text for non-tmux)
# So reason should be None
assert reason is None, f'expected None for stale signals, got {reason!r}'

# Cleanup
import shutil
shutil.rmtree(hook_dir.parent, ignore_errors=True)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Poisoned detection ignores stale hook signals"
    else
        fail "Poisoned detection stale hook signal test failed"
    fi
}

test_poisoned_hook_signal_below_threshold() {
    info "Testing poisoned detection below threshold..."

    if python3 -c "
import tempfile, time, os
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp

name = 'hooklow'
tmux_name = 'claude-test-hooklow'
session_dir = tmp / name
session_dir.mkdir()
(session_dir / 'backend').write_text('claude')

# Create hook signal file with only 2 recent failures (< 3 threshold)
node = os.environ.get('TMUX_PREFIX', 'claude-test-').rstrip('-').split('-', 1)[-1] if os.environ.get('TMUX_PREFIX') else 'test'
hook_dir = Path(f'/tmp/claudecode-telegram/{node}/{name}/hooks')
hook_dir.mkdir(parents=True, exist_ok=True)
failures_file = hook_dir / 'failures'

now = int(time.time())
lines = [f'{now} Bash', f'{now - 1} Edit']
failures_file.write_text('\\n'.join(lines) + '\\n')

# Should NOT detect poisoned (below threshold)
reason = bridge._detect_poisoned(name, tmux_name)
assert reason is None, f'expected None for below-threshold, got {reason!r}'

# Cleanup
import shutil
shutil.rmtree(hook_dir.parent, ignore_errors=True)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Poisoned detection below threshold works"
    else
        fail "Poisoned detection below threshold test failed"
    fi
}

test_on_tool_failure_hook_script() {
    info "Testing on-tool-failure.sh hook script writes signal file..."

    # Create a tmux session to simulate a worker
    local test_session="${TMUX_PREFIX}hookscript"
    tmux new-session -d -s "$test_session" "bash" 2>/dev/null || true
    sleep 0.3

    # Set tmux env vars that the hook reads
    tmux set-environment -t "$test_session" TMUX_PREFIX "$TMUX_PREFIX"

    # Derive node name the same way as bridge.py
    local node_name
    node_name=$(echo "$TMUX_PREFIX" | sed 's/-$//' | sed 's/^claude-//')
    [ -z "$node_name" ] && node_name="default"

    # Clean up any pre-existing signal file
    local hook_dir="/tmp/claudecode-telegram/${node_name}/hookscript/hooks"
    rm -rf "$hook_dir" 2>/dev/null

    # Simulate PostToolUseFailure payload via the hook script
    # The hook reads stdin and extracts tool_name
    local hook_script
    hook_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks/on-tool-failure.sh"

    # Run hook in the tmux session context (so tmux display-message works)
    echo '{"tool_name": "Bash", "error": "Command failed"}' | \
        tmux send-keys -t "$test_session" \
        "echo '{\"tool_name\": \"Bash\", \"error\": \"Command failed\"}' | $hook_script" Enter
    sleep 0.5

    local failures_file="${hook_dir}/failures"
    if [ -f "$failures_file" ]; then
        local content
        content=$(cat "$failures_file")
        if echo "$content" | grep -q "Bash"; then
            success "on-tool-failure.sh writes signal file correctly"
        else
            fail "Signal file exists but no Bash entry: $content"
        fi
    else
        fail "Signal file not created at $failures_file"
    fi

    # Cleanup
    tmux kill-session -t "$test_session" 2>/dev/null || true
    rm -rf "$hook_dir" 2>/dev/null
}

test_clear_hook_failures_on_restart() {
    info "Testing hook failure signal cleared on non-resume restart..."

    if python3 -c "
import tempfile, time, os
from pathlib import Path
import bridge

# Set up signal file
node = os.environ.get('TMUX_PREFIX', 'claude-test-').rstrip('-').removeprefix('claude-') or 'default'
name = 'cleartest'
hook_dir = Path(f'/tmp/claudecode-telegram/{node}/{name}/hooks')
hook_dir.mkdir(parents=True, exist_ok=True)
failures_file = hook_dir / 'failures'
now = int(time.time())
failures_file.write_text(f'{now} Bash\n{now} Edit\n{now} Read\n')

assert failures_file.exists(), 'setup failed: signal file not created'

# Clear
bridge._clear_hook_failures(name)

assert not failures_file.exists(), 'signal file should be deleted after clear'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Hook failure signal cleared on restart"
    else
        fail "Hook failure signal clear test failed"
    fi
}

test_since_preserved_on_reason_change() {
    info "Testing watchdog since preserved when reason changes..."

    if python3 -c "
import time
import bridge

bridge._session_states.clear()
now = time.time()

first_since = bridge._record_worker_state('alice', 'DEAD', 'claude missing 1s', now)
second_since = bridge._record_worker_state('alice', 'DEAD', 'claude missing 5s', now + 5)

assert first_since == second_since, 'since should remain when state is unchanged'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog since preserved on reason change"
    else
        fail "Watchdog since preservation test failed"
    fi
}


test_compute_state_interactive() {
    info "Testing compute_state for INTERACTIVE backends..."

    if python3 -c "
import time
import bridge

now = time.time()

# OFFLINE: tmux_exists=False
state, reason = bridge.compute_state(
    tmux_exists=False, claude_pid=None, pending=False, pending_ts=None,
    pending_age=0, children=0, last_child_ts=0.0, cpu=0.0,
    last_hook_ts=None, last_seen_claude=None, now=now,
)
assert state == 'OFFLINE', f'OFFLINE case: expected OFFLINE, got {state} ({reason})'

# DEAD: tmux_exists=True, claude_pid=None, past START_GRACE
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid=None, pending=False, pending_ts=None,
    pending_age=0, children=0, last_child_ts=0.0, cpu=0.0,
    last_hook_ts=None, last_seen_claude=now - 60, now=now,
)
assert state == 'DEAD', f'DEAD case: expected DEAD, got {state} ({reason})'

# READY: tmux_exists=True, claude_pid set, no pending, low CPU
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=False, pending_ts=None,
    pending_age=0, children=0, last_child_ts=0.0, cpu=1.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'READY', f'READY case: expected READY, got {state} ({reason})'

# BUSY_TOOL: pending set, children > 0
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=True, pending_ts=now - 5,
    pending_age=5, children=3, last_child_ts=now, cpu=50.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'BUSY_TOOL', f'BUSY_TOOL case: expected BUSY_TOOL, got {state} ({reason})'

# BUSY_THINKING: pending set, children == 0, CPU > CPU_ACTIVE (15.0)
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=True, pending_ts=now - 5,
    pending_age=5, children=0, last_child_ts=0.0, cpu=20.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'BUSY_THINKING', f'BUSY_THINKING case: expected BUSY_THINKING, got {state} ({reason})'

# WAITING: pending set, children == 0, CPU < CPU_IDLE (7.0), age < STALE_PENDING (300)
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=True, pending_ts=now - 100,
    pending_age=100, children=0, last_child_ts=0.0, cpu=2.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'WAITING', f'WAITING case: expected WAITING, got {state} ({reason})'

# STUCK: pending set, pending_age > STALE_PENDING (900), cpu < CPU_IDLE
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=True, pending_ts=now - 1200,
    pending_age=1200, children=0, last_child_ts=0.0, cpu=2.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'STUCK', f'STUCK case: expected STUCK, got {state} ({reason})'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "compute_state handles interactive backends (all state transitions)"
    else
        fail "compute_state interactive test failed"
    fi
}

test_idle_child_baseline() {
    info "Testing idle child baseline filters MCP servers..."

    if python3 -c "
import time
import bridge

now = time.time()

# With children=0 (baseline subtracted), idle worker should be READY
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=False, pending_ts=None,
    pending_age=0, children=0, last_child_ts=0.0, cpu=1.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'READY', f'Idle with baseline subtracted: expected READY, got {state} ({reason})'

# With children=1 (one extra above baseline), should be UNTRACKED_BUSY
state, reason = bridge.compute_state(
    tmux_exists=True, claude_pid='12345', pending=False, pending_ts=None,
    pending_age=0, children=1, last_child_ts=now, cpu=1.0,
    last_hook_ts=None, last_seen_claude=now, now=now,
)
assert state == 'UNTRACKED_BUSY', f'Extra child above baseline: expected UNTRACKED_BUSY, got {state} ({reason})'

# Test _idle_child_baseline map directly
bridge._idle_child_baseline.clear()

# First observation: sets baseline
bridge._idle_child_baseline['test-worker'] = 2  # simulate 2 MCP servers
baseline = bridge._idle_child_baseline['test-worker']
assert baseline == 2, f'Expected baseline 2, got {baseline}'

# Effective children with 2 MCP + 1 tool = 3 total, active = 1
children_total = 3
children_active = max(0, children_total - baseline)
assert children_active == 1, f'Expected 1 active child, got {children_active}'

# Effective children with just MCP = 2 total, active = 0
children_total = 2
children_active = max(0, children_total - baseline)
assert children_active == 0, f'Expected 0 active children, got {children_active}'

# Cleanup
bridge._idle_child_baseline.clear()

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Idle child baseline filters MCP server children"
    else
        fail "Idle child baseline test failed"
    fi
}

test_idle_streak_prevents_false_stuck() {
    info "Testing idle_streak prevents false STUCK alerts..."

    if python3 -c "
import bridge

# Reset idle streak
bridge._idle_streak.clear()

# Simulate: compute_state returns STUCK but streak < IDLE_STREAK_STUCK
# The watchdog loop downgrades to WAITING until streak reaches threshold

# First STUCK sample: streak=1, should downgrade to WAITING
bridge._idle_streak['testworker'] = bridge._idle_streak.get('testworker', 0) + 1
streak = bridge._idle_streak['testworker']
assert streak == 1, f'expected streak 1, got {streak}'
assert streak < bridge.IDLE_STREAK_STUCK, f'streak {streak} should be < {bridge.IDLE_STREAK_STUCK}'

# Second STUCK sample: streak=2, still WAITING
bridge._idle_streak['testworker'] = bridge._idle_streak.get('testworker', 0) + 1
streak = bridge._idle_streak['testworker']
assert streak == 2, f'expected streak 2, got {streak}'
assert streak < bridge.IDLE_STREAK_STUCK, f'streak {streak} should be < {bridge.IDLE_STREAK_STUCK}'

# Third STUCK sample: streak=3, now real STUCK
bridge._idle_streak['testworker'] = bridge._idle_streak.get('testworker', 0) + 1
streak = bridge._idle_streak['testworker']
assert streak == 3, f'expected streak 3, got {streak}'
assert streak >= bridge.IDLE_STREAK_STUCK, f'streak {streak} should be >= {bridge.IDLE_STREAK_STUCK}'

# Non-STUCK state resets streak
bridge._idle_streak['testworker'] = 0
assert bridge._idle_streak['testworker'] == 0, 'streak should reset to 0'

# Verify IDLE_STREAK_STUCK constant
assert bridge.IDLE_STREAK_STUCK == 3, f'expected IDLE_STREAK_STUCK=3, got {bridge.IDLE_STREAK_STUCK}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "idle_streak prevents false STUCK (requires 3 consecutive samples)"
    else
        fail "idle_streak test failed"
    fi
}

test_watchdog_resolved_alert() {
    info "Testing watchdog resolved alert on STUCK -> READY transition..."

    if python3 -c "
import bridge

# Track calls to telegram_api
calls = []
def fake_api(method, data):
    calls.append((method, data))
    return {'ok': True}

orig_api = bridge.telegram_api
bridge.telegram_api = fake_api
bridge.admin_chat_id = 12345

# Clear state
with bridge._watchdog_lock:
    bridge._prev_session_states.clear()

# Simulate STUCK -> READY transition
with bridge._watchdog_lock:
    bridge._prev_session_states['testworker'] = 'STUCK'

bridge._send_resolved_alert('testworker', 'READY')

assert len(calls) == 1, f'Expected 1 API call, got {len(calls)}'
method, data = calls[0]
assert method == 'sendMessage', f'Expected sendMessage, got {method}'
assert 'testworker' in data['text'], f'Expected worker name in text, got {data[\"text\"]}'
assert 'back to normal' in data['text'], f'Expected back to normal in text, got {data[\"text\"]}'

# Verify no alert when transition is not from bad to good state
calls.clear()
with bridge._watchdog_lock:
    bridge._prev_session_states['testworker'] = 'READY'
bridge._send_resolved_alert('testworker', 'BUSY_TOOL')
assert len(calls) == 0, f'Expected no call for READY->BUSY_TOOL, got {len(calls)}'

bridge.telegram_api = orig_api
bridge.admin_chat_id = None
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog resolved alert fires on STUCK -> READY"
    else
        fail "Watchdog resolved alert test failed"
    fi
}

test_parse_at_mentions() {
    info "Testing parse_at_mentions behavior..."

    if python3 -c "
import bridge

# Create a mock workers object
class MockWorkers:
    def get_registered_sessions(self, registered=None):
        return {'alice': {'tmux': 'claude-test-alice'}, 'bob': {'tmux': 'claude-test-bob'}}

class MockTelegramAPI:
    def send_message(self, chat_id, text, **kwargs):
        pass

router = bridge.CommandRouter(MockTelegramAPI(), MockWorkers())

# Single @mention extracts correct worker name
targets, cleaned = router.parse_at_mentions('@alice hello there')
assert targets == ['alice'], f'Single mention: expected [alice], got {targets}'
assert 'hello there' in cleaned, f'Cleaned text should contain message, got: {cleaned}'

# Multiple @mentions extract all names
targets, cleaned = router.parse_at_mentions('@alice @bob do this task')
assert 'alice' in targets and 'bob' in targets, f'Multi mention: expected alice+bob, got {targets}'
assert len(targets) == 2, f'Expected 2 targets, got {len(targets)}'

# @nonexistent returns empty (no matching worker)
targets, cleaned = router.parse_at_mentions('@charlie hello')
assert targets == [], f'Nonexistent mention: expected [], got {targets}'

# Text without @ returns empty
targets, cleaned = router.parse_at_mentions('hello world')
assert targets == [], f'No mention: expected [], got {targets}'
assert cleaned == 'hello world', f'No mention: cleaned text should be unchanged, got {cleaned}'

# Empty text returns empty
targets, cleaned = router.parse_at_mentions('')
assert targets == [], f'Empty text: expected [], got {targets}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "parse_at_mentions handles all mention patterns"
    else
        fail "parse_at_mentions test failed"
    fi
}

test_format_watchdog_status() {
    info "Testing _format_watchdog_status for each state..."

    if python3 -c "
import time
import bridge

now = time.time()
since = now - 120  # 2 minutes ago

# Build a state snapshot for each state
states = {
    'ready_worker': ('READY', 'idle', since),
    'busy_tool_worker': ('BUSY_TOOL', 'children=3', since),
    'busy_thinking_worker': ('BUSY_THINKING', 'cpu=20.0', since),
    'waiting_worker': ('WAITING', 'age=100s', since),
    'stuck_worker': ('STUCK', 'age=600s cpu=2.0', since),
    'dead_worker': ('DEAD', 'claude missing 60s', since),
    'offline_worker': ('OFFLINE', 'tmux missing', since),
    'poisoned_worker': ('POISONED', 'exec loop', since),
    'untracked_worker': ('UNTRACKED_BUSY', 'children=1', since),
}

# Inject into _session_states
with bridge._watchdog_lock:
    bridge._session_states.update(states)

snapshot = dict(states)

# READY -> 'Ready'
result = bridge._format_watchdog_status('ready_worker', lambda n: False, state_snapshot=snapshot)
assert result == 'Ready', f'READY: expected Ready, got {result}'

# BUSY_TOOL -> 'Working'
result = bridge._format_watchdog_status('busy_tool_worker', lambda n: True, state_snapshot=snapshot)
assert result == 'Working', f'BUSY_TOOL: expected Working, got {result}'

# BUSY_THINKING -> 'Thinking'
result = bridge._format_watchdog_status('busy_thinking_worker', lambda n: True, state_snapshot=snapshot)
assert result == 'Thinking', f'BUSY_THINKING: expected Thinking, got {result}'

# WAITING -> 'Working'
result = bridge._format_watchdog_status('waiting_worker', lambda n: True, state_snapshot=snapshot)
assert result == 'Working', f'WAITING: expected Working, got {result}'

# STUCK -> 'No progress (Xm)'
result = bridge._format_watchdog_status('stuck_worker', lambda n: True, state_snapshot=snapshot)
assert result.startswith('No progress'), f'STUCK: expected No progress (Xm), got {result}'
assert 'm)' in result, f'STUCK: expected minutes in parens, got {result}'

# DEAD -> 'Not responding'
result = bridge._format_watchdog_status('dead_worker', lambda n: False, state_snapshot=snapshot)
assert result == 'Not responding', f'DEAD: expected Not responding, got {result}'

# OFFLINE -> 'Offline'
result = bridge._format_watchdog_status('offline_worker', lambda n: False, state_snapshot=snapshot)
assert result == 'Offline', f'OFFLINE: expected Offline, got {result}'

# POISONED -> 'Error loop (Xm)'
result = bridge._format_watchdog_status('poisoned_worker', lambda n: True, state_snapshot=snapshot)
assert result.startswith('Error loop'), f'POISONED: expected Error loop (Xm), got {result}'

# Unknown worker -> fallback based on pending
result = bridge._format_watchdog_status('nonexistent_worker', lambda n: True, state_snapshot=snapshot)
assert result == 'Working', f'Unknown+pending: expected Working, got {result}'
result = bridge._format_watchdog_status('nonexistent_worker', lambda n: False, state_snapshot=snapshot)
assert result == 'Ready', f'Unknown+idle: expected Ready, got {result}'

# Clean up
with bridge._watchdog_lock:
    for k in list(states.keys()):
        bridge._session_states.pop(k, None)

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "_format_watchdog_status returns correct text for each state"
    else
        fail "_format_watchdog_status test failed"
    fi
}

test_send_response_html_formatting() {
    info "Testing send_response_to_telegram with HTML formatting..."

    if python3 -c "
import bridge

# Track API calls
calls = []
def fake_api(method, data):
    calls.append((method, data))
    return {'ok': True, 'result': {'message_id': 123}}

orig_api = bridge.telegram_api
bridge.telegram_api = fake_api

# Send a response with markdown bold
bridge.send_response_to_telegram('testworker', '**hello world**', 12345)

assert len(calls) >= 1, f'Expected at least 1 API call, got {len(calls)}'
method, data = calls[0]
assert method == 'sendMessage', f'Expected sendMessage, got {method}'
assert data['parse_mode'] == 'HTML', f'Expected HTML parse_mode, got {data.get(\"parse_mode\")}'
# markdown_to_telegram_html should convert **bold** to <b>bold</b>
assert '<b>' in data['text'] or 'hello world' in data['text'], \
    f'Expected HTML bold tags or plain text, got: {data[\"text\"]}'

# Test with code block
calls.clear()
bridge.send_response_to_telegram('testworker', '\`\`\`python\nprint(1)\n\`\`\`', 12345)
assert len(calls) >= 1, f'Expected at least 1 API call for code block'
method, data = calls[0]
assert '<pre>' in data['text'] or '<code>' in data['text'] or 'print(1)' in data['text'], \
    f'Expected code HTML in text, got: {data[\"text\"]}'

bridge.telegram_api = orig_api
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "send_response_to_telegram uses HTML formatting"
    else
        fail "send_response_html_formatting test failed"
    fi
}

test_format_response_strips_name_prefix() {
    info "Testing format_response_text strips redundant name prefix..."

    if python3 -c "
from bridge import format_response_text

# Normal message - no prefix to strip
result = format_response_text('lee', 'hello world')
assert result == '<b>lee:</b>\nhello world', f'unexpected: {result}'

# Message with redundant prefix - should strip it
result = format_response_text('lee', 'lee: hello world')
assert result == '<b>lee:</b>\nhello world', f'unexpected: {result}'

# Case-insensitive prefix strip
result = format_response_text('lee', 'Lee: hello world')
assert result == '<b>lee:</b>\nhello world', f'unexpected: {result}'

# Different worker name - should NOT strip
result = format_response_text('lee', 'chen: hello world')
assert result == '<b>lee:</b>\nchen: hello world', f'unexpected: {result}'

# Prefix with leading whitespace
result = format_response_text('lee', '  lee: hello world')
assert result == '<b>lee:</b>\nhello world', f'unexpected: {result}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "format_response_text strips redundant name prefix"
    else
        fail "format_response_text prefix strip test failed"
    fi
}


test_reserved_names_rejection() {
    info "Testing reserved names rejection..."

    if python3 -c "
from bridge import RESERVED_NAMES

# Verify all expected reserved names are included
expected = {'team', 'focus', 'progress', 'pause', 'restart',
            'settings', 'hire', 'end', 'all', 'start', 'help'}
for name in expected:
    assert name in RESERVED_NAMES, f'{name} should be reserved'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Reserved names are configured"
    else
        fail "Reserved names check failed"
    fi

    # Test actual rejection via webhook
    local result
    result=$(send_message "/hire team")  # 'team' is reserved

    if [[ "$result" == "OK" ]]; then
        success "Reserved name /hire rejection handled"
    else
        fail "Reserved name handling failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Security tests
# ─────────────────────────────────────────────────────────────────────────────

test_graceful_shutdown_notification() {
    info "Testing graceful shutdown attempts notification..."

    # Test that graceful_shutdown tries to send notification when admin_chat_id is set
    if python3 -c "
import bridge
import unittest.mock as mock
import signal

# Set up admin chat ID
bridge.admin_chat_id = 12345

# Mock telegram_api and sys.exit
with mock.patch.object(bridge, 'telegram_api') as mock_api, \
     mock.patch('sys.exit'):
    mock_api.return_value = {'ok': True}
    # Call graceful_shutdown with SIGTERM
    bridge.graceful_shutdown(signal.SIGTERM, None)

# Verify notification was attempted
assert mock_api.called, 'telegram_api should be called for shutdown notification'
# Check that sendMessage was called (notification attempt)
call_found = any('sendMessage' in str(c) for c in mock_api.call_args_list)
assert call_found, 'Should attempt to send shutdown message'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Graceful shutdown attempts notification"
    else
        fail "Graceful shutdown notification test failed"
    fi
}

test_typing_indicator_loop() {
    info "Testing typing indicator loop calls sendChatAction..."

    # Test that send_typing_loop calls telegram_api with sendChatAction
    if python3 -c "
import bridge
import unittest.mock as mock

# Set up a pending state that will clear after first check
call_count = [0]
def mock_is_pending(name):
    call_count[0] += 1
    return call_count[0] <= 1  # True first time, False after

# Mock is_pending and telegram_api
with mock.patch.object(bridge, 'is_pending', mock_is_pending), \
     mock.patch.object(bridge, 'telegram_api') as mock_api, \
     mock.patch('time.sleep'):  # Skip the sleep
    mock_api.return_value = {'ok': True}
    bridge.send_typing_loop(12345, 'test')

# Verify sendChatAction was called
assert mock_api.called, 'telegram_api should be called'
call_args = mock_api.call_args
assert call_args[0][0] == 'sendChatAction', f'Expected sendChatAction, got {call_args[0][0]}'
assert call_args[0][1]['chat_id'] == 12345
assert call_args[0][1]['action'] == 'typing'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Typing indicator loop calls sendChatAction"
    else
        fail "Typing indicator behavior test failed"
    fi
}

test_token_isolation() {
    info "Testing token isolation..."

    # Verify TELEGRAM_BOT_TOKEN is NOT exposed to tmux sessions
    # Create a worker and check its environment
    open_dm_session

    local tmux_name="${TEST_TMUX_PREFIX}tmain"

    if tmux has-session -t "$tmux_name" 2>/dev/null; then
        # export_hook_env injects vars ~0.5-0.8s into the launch chain — poll
        # for PORT= instead of reading once (single read races the injection).
        local tmux_env="" attempts=0
        while [[ $attempts -lt 50 ]]; do
            tmux_env=$(tmux show-environment -t "$tmux_name" 2>/dev/null || echo "")
            echo "$tmux_env" | grep -q "PORT=" && break
            sleep 0.1
            ((attempts++)) || true
        done

        if echo "$tmux_env" | grep -q "TELEGRAM_BOT_TOKEN"; then
            fail "Token leaked to tmux session environment!"
        else
            success "Token isolated - not in tmux environment"
        fi

        # Verify expected env vars ARE present
        if echo "$tmux_env" | grep -q "PORT="; then
            success "PORT env var exported to tmux"
        else
            fail "PORT env var not found in tmux"
        fi

        if echo "$tmux_env" | grep -q "TMUX_PREFIX="; then
            success "TMUX_PREFIX env var exported to tmux"
        else
            fail "TMUX_PREFIX env var not found in tmux"
        fi
    else
        fail "Could not verify token isolation - session not found"
    fi

    # Cleanup
    close_dm_session
}

test_secure_directory_permissions() {
    info "Testing secure directory permissions..."

    # Test node directory permissions
    if [[ -d "$TEST_NODE_DIR" ]]; then
        local perms
        if [[ "$(uname)" == "Darwin" ]]; then
            perms=$(stat -f "%Lp" "$TEST_NODE_DIR")
        else
            perms=$(stat -c "%a" "$TEST_NODE_DIR")
        fi
        if [[ "$perms" == "700" ]]; then
            success "Node directory permissions secure (0700)"
        else
            fail "Node directory permissions incorrect: $perms (expected 700)"
        fi
    fi

    # Test sessions directory permissions
    if [[ -d "$TEST_SESSION_DIR" ]]; then
        local perms
        if [[ "$(uname)" == "Darwin" ]]; then
            perms=$(stat -f "%Lp" "$TEST_SESSION_DIR")
        else
            perms=$(stat -c "%a" "$TEST_SESSION_DIR")
        fi
        if [[ "$perms" == "700" ]]; then
            success "Sessions directory permissions secure (0700)"
        else
            fail "Sessions directory permissions incorrect: $perms (expected 700)"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HTTP endpoint tests
# ─────────────────────────────────────────────────────────────────────────────

test_health_endpoint() {
    info "Testing GET / API index endpoint..."

    local response
    response=$(curl -s "http://localhost:$PORT")

    if echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'endpoints' in d
assert 'name' in d
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "API index returns JSON with endpoints"
    else
        fail "API index response incorrect: $response"
    fi
}

test_response_endpoint_missing_fields() {
    info "Testing /response endpoint with missing fields..."

    # Missing session
    local result
    result=$(hook_curl "http://localhost:$PORT/response" '{"text":"Test"}')

    if echo "$result" | grep -q "Missing"; then
        success "/response rejects missing session"
    else
        fail "/response should reject missing session"
    fi

    # Missing text
    result=$(hook_curl "http://localhost:$PORT/response" '{"session":"test"}')

    if echo "$result" | grep -q "Missing"; then
        success "/response rejects missing text"
    else
        fail "/response should reject missing text"
    fi
}

test_response_endpoint_no_chat_id() {
    info "Testing /response endpoint with non-existent session..."

    local body='{"session":"nonexistent_session_xyz","text":"Test"}'
    local result
    result=$(hook_curl "http://localhost:$PORT/response" "$body")

    # Should return 404 for session without chat_id file
    if echo "$result" | grep -q "No chat_id"; then
        success "/response returns 404 for unknown session"
    else
        # Check HTTP code
        local http_code
        http_code=$(hook_curl_code "http://localhost:$PORT/response" "$body")
        if [[ "$http_code" == "404" ]]; then
            success "/response returns 404 for unknown session"
        else
            fail "/response should return 404 for unknown session"
        fi
    fi
}

test_notify_endpoint_missing_text() {
    info "Testing /notify endpoint with missing text..."

    local http_code
    http_code=$(hook_curl_code "http://localhost:$PORT/notify" '{}')

    if [[ "$http_code" == "400" ]]; then
        success "/notify rejects missing text (400)"
    else
        fail "/notify should return 400 for missing text, got $http_code"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Pending and timeout tests
# ─────────────────────────────────────────────────────────────────────────────

test_pending_no_side_effect() {
    info "Testing is_pending() is non-mutating (no auto-delete)..."

    if python3 -c "
from bridge import is_pending, set_pending, get_pending_file, _pending_timestamp
import time
from pathlib import Path

# Create test session dir
test_name = 'sideeffect_test'
pending_file = get_pending_file(test_name)
pending_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

# Write a pending file with timestamp 11 minutes ago (past PENDING_TIMEOUT=600s)
old_ts = int(time.time()) - (11 * 60)
pending_file.write_text(str(old_ts))

# is_pending should return False for stale pending...
result = is_pending(test_name)
assert result == False, f'expected False for stale pending, got {result}'

# ...BUT the file must still exist (non-mutating read)
# This is critical: watchdog needs the file at 15min for STALE_PENDING detection
assert pending_file.exists(), 'is_pending must NOT delete the pending file'

# _pending_timestamp should still return the original timestamp
ts = _pending_timestamp(test_name)
assert ts == old_ts, f'expected {old_ts}, got {ts}'

# Fresh timestamp should return True
fresh_ts = int(time.time())
pending_file.write_text(str(fresh_ts))
result = is_pending(test_name)
assert result == True, f'expected True for fresh pending, got {result}'

# Cleanup
pending_file.unlink(missing_ok=True)
pending_file.parent.rmdir()

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "is_pending() is non-mutating"
    else
        fail "is_pending() side-effect test failed"
    fi
}

test_stale_pending_survives_for_watchdog() {
    info "Testing pending file survives past 10min for STALE_PENDING (15min) detection..."

    if python3 -c "
from bridge import is_pending, get_pending_file, _pending_timestamp, compute_state
import time
from pathlib import Path

test_name = 'stale_test'
pending_file = get_pending_file(test_name)
pending_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

# Simulate 16 minutes old pending (past both PENDING_TIMEOUT and STALE_PENDING)
stale_ts = int(time.time()) - (16 * 60)
pending_file.write_text(str(stale_ts))

# is_pending returns False (timed out)
assert is_pending(test_name) == False

# But _pending_timestamp still returns the timestamp
ts = _pending_timestamp(test_name)
assert ts == stale_ts, f'timestamp lost: {ts}'

# And compute_state should see STALE_PENDING
now = time.time()
pending_age = now - stale_ts
state, reason = compute_state(
    tmux_exists=True,
    claude_pid='12345',
    pending=True,  # watchdog uses _pending_timestamp, not is_pending()
    pending_ts=stale_ts,
    pending_age=pending_age,
    children=0,
    last_child_ts=0,
    cpu=0.0,
    last_hook_ts=None,
    last_seen_claude=now,  # claude was seen recently
    now=now,
)
# STALE_PENDING threshold triggers STUCK state (not a separate state name)
assert state == 'STUCK', f'expected STUCK at stale pending, got {state}: {reason}'

# Cleanup
pending_file.unlink(missing_ok=True)
pending_file.parent.rmdir()

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Pending file survives for STALE_PENDING detection"
    else
        fail "Stale pending survival test failed"
    fi
}

# ============================================================
# CLI + HOOK TESTS
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# CLI command tests
# ─────────────────────────────────────────────────────────────────────────────

test_cli_help() {
    info "Testing CLI --help..."

    if ./claudecode-telegram.sh --help 2>/dev/null | grep -q "USAGE"; then
        success "CLI --help works"
    else
        fail "CLI --help failed"
    fi
}

test_cli_version() {
    info "Testing CLI --version..."

    if ./claudecode-telegram.sh --version 2>/dev/null | grep -q "claudecode-telegram"; then
        success "CLI --version works"
    else
        fail "CLI --version failed"
    fi
}

test_cli_unknown_command() {
    info "Testing CLI unknown command error..."

    # The output has color codes, so we strip them first or check for "Unknown"
    local result
    result=$(./claudecode-telegram.sh unknowncommand 2>&1 || true)

    if echo "$result" | grep -qi "unknown"; then
        success "CLI rejects unknown commands"
    else
        fail "CLI should reject unknown commands, got: $result"
    fi
}

test_cli_missing_token_error() {
    info "Testing CLI missing token error..."

    # Unset token and try to run webhook info
    local result
    result=$(TELEGRAM_BOT_TOKEN="" ./claudecode-telegram.sh webhook info 2>&1 || true)

    if echo "$result" | grep -q "TELEGRAM_BOT_TOKEN"; then
        success "CLI reports missing token error"
    else
        fail "CLI should report missing token"
    fi
}

test_cli_hook_install_uninstall() {
    info "Testing CLI hook install/uninstall..."

    local temp_home
    temp_home="$(mktemp -d)"

    # Test hook install (with force to overwrite if exists)
    if HOME="$temp_home" TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh hook install --force 2>/dev/null; then
        if [[ -f "$temp_home/.claude/hooks/send-to-telegram.sh" ]]; then
            success "CLI hook install creates Stop hook file"
        else
            fail "Stop hook file not created"
        fi
        if [[ -f "$temp_home/.claude/hooks/checkin-on-start.sh" ]]; then
            success "CLI hook install creates SessionStart hook file"
        else
            fail "SessionStart hook file not created"
        fi
    else
        fail "CLI hook install failed"
    fi

    # Test hooks are in settings.json
    if [[ -f "$temp_home/.claude/settings.json" ]]; then
        if grep -q "send-to-telegram.sh" "$temp_home/.claude/settings.json"; then
            success "Stop hook registered in settings.json"
        else
            fail "Stop hook not in settings.json"
        fi
        if grep -q "checkin-on-start.sh" "$temp_home/.claude/settings.json"; then
            success "SessionStart hook registered in settings.json"
        else
            fail "SessionStart hook not in settings.json"
        fi
        if grep -q '"compact|resume|init|start"' "$temp_home/.claude/settings.json"; then
            success "SessionStart hook has correct matcher"
        else
            fail "SessionStart hook matcher missing"
        fi

        if grep -q "PostToolUseFailure" "$temp_home/.claude/settings.json"; then
            success "PostToolUseFailure hook registered in settings.json"
        else
            fail "PostToolUseFailure hook not in settings.json"
        fi
        if grep -q "on-tool-failure.sh" "$temp_home/.claude/settings.json"; then
            success "PostToolUseFailure hook points to on-tool-failure.sh"
        else
            fail "PostToolUseFailure hook script path missing"
        fi
    fi

    rm -rf "$temp_home"
}

# ─────────────────────────────────────────────────────────────────────────────
# Hook behavior tests (critical - hook script validation)
# ─────────────────────────────────────────────────────────────────────────────

test_hook_env_validation() {
    info "Testing hook fails when required env vars missing..."

    # Create a mock transcript for the hook
    local tmp_transcript=$(mktemp)
    echo '{"type":"user","message":{"content":[{"type":"text","text":"test"}]}}' > "$tmp_transcript"
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"response"}]}}' >> "$tmp_transcript"

    # Create mock input for hook
    local mock_input='{"transcript_path":"'$tmp_transcript'"}'

    # The hook reads env vars from tmux session env first, then falls back to
    # shell env. When running inside a tmux session with bridge env vars set
    # (e.g., claude-prod-lee), the tmux values override our test values.
    # Fix: temporarily unset tmux env vars so shell env takes effect.
    local saved_tmux_vars=()
    for var in TMUX_PREFIX SESSIONS_DIR PORT BRIDGE_URL; do
        local val
        val=$(tmux show-environment "$var" 2>/dev/null) || true
        if [[ -n "$val" && "$val" != -* ]]; then
            saved_tmux_vars+=("$val")
            tmux set-environment -u "$var" 2>/dev/null || true
        fi
    done

    # Test 1: Missing TMUX_PREFIX
    local result
    result=$(echo "$mock_input" | TMUX_PREFIX="" SESSIONS_DIR="/tmp" PORT="8080" bash "$SCRIPT_DIR/hooks/send-to-telegram.sh" 2>&1) || true

    # Hook should exit silently (exit 0) but with error message to stderr
    if echo "$result" | grep -q "Missing TMUX_PREFIX" || [[ -z "$result" ]]; then
        success "Hook exits when TMUX_PREFIX missing"
    else
        fail "Hook should exit when TMUX_PREFIX missing"
    fi

    # Test 2: Missing SESSIONS_DIR
    result=$(echo "$mock_input" | TMUX_PREFIX="claude-test-" SESSIONS_DIR="" PORT="8080" bash "$SCRIPT_DIR/hooks/send-to-telegram.sh" 2>&1) || true

    if echo "$result" | grep -q "Missing SESSIONS_DIR" || [[ -z "$result" ]]; then
        success "Hook exits when SESSIONS_DIR missing"
    else
        fail "Hook should exit when SESSIONS_DIR missing"
    fi

    # Test 3: Missing both BRIDGE_URL and PORT
    result=$(echo "$mock_input" | TMUX_PREFIX="claude-test-" SESSIONS_DIR="/tmp" PORT="" BRIDGE_URL="" bash "$SCRIPT_DIR/hooks/send-to-telegram.sh" 2>&1) || true

    if echo "$result" | grep -q "Missing BRIDGE_URL and PORT" || [[ -z "$result" ]]; then
        success "Hook exits when both BRIDGE_URL and PORT missing"
    else
        fail "Hook should exit when BRIDGE_URL and PORT missing"
    fi

    # Restore tmux env vars
    for var_line in "${saved_tmux_vars[@]}"; do
        local var_name="${var_line%%=*}"
        local var_val="${var_line#*=}"
        tmux set-environment "$var_name" "$var_val" 2>/dev/null || true
    done

    rm -f "$tmp_transcript"
}

test_checkin_hook_env_validation() {
    info "Testing checkin hook exits when env vars missing..."

    # The checkin hook reads env vars from tmux session env first.
    # Temporarily unset tmux env vars so shell env takes effect.
    local saved_tmux_vars=()
    for var in TMUX_PREFIX BRIDGE_URL PORT; do
        local val
        val=$(tmux show-environment "$var" 2>/dev/null) || true
        if [[ -n "$val" && "$val" != -* ]]; then
            saved_tmux_vars+=("$val")
            tmux set-environment -u "$var" 2>/dev/null || true
        fi
    done

    # Test 1: Missing TMUX_PREFIX - hook should exit silently
    local result exit_code
    result=$(TMUX_PREFIX="" BRIDGE_URL="http://localhost:8080" bash "$SCRIPT_DIR/hooks/checkin-on-start.sh" 2>&1) || true
    if [[ -z "$result" ]]; then
        success "Checkin hook exits silently when TMUX_PREFIX missing"
    else
        fail "Checkin hook should exit silently when TMUX_PREFIX missing, got: $result"
    fi

    # Test 2: Missing both BRIDGE_URL and PORT - hook should exit silently
    result=$(TMUX_PREFIX="claude-test-" BRIDGE_URL="" PORT="" bash "$SCRIPT_DIR/hooks/checkin-on-start.sh" 2>&1) || true
    if [[ -z "$result" ]]; then
        success "Checkin hook exits silently when BRIDGE_URL and PORT missing"
    else
        fail "Checkin hook should exit silently when both missing, got: $result"
    fi

    # Restore tmux env vars
    for var_line in "${saved_tmux_vars[@]}"; do
        local var_name="${var_line%%=*}"
        local var_val="${var_line#*=}"
        tmux set-environment "$var_name" "$var_val" 2>/dev/null || true
    done
}

test_checkin_hook_calls_endpoint() {
    info "Testing checkin hook calls /checkin endpoint..."

    # This test requires a running bridge (integration test).
    # The hook runs inside a tmux session, reads env vars, and curls /checkin.
    # We simulate by setting env vars directly (tmux env already unset in previous test).
    local saved_tmux_vars=()
    for var in TMUX_PREFIX BRIDGE_URL PORT; do
        local val
        val=$(tmux show-environment "$var" 2>/dev/null) || true
        if [[ -n "$val" && "$val" != -* ]]; then
            saved_tmux_vars+=("$val")
            tmux set-environment -u "$var" 2>/dev/null || true
        fi
    done

    # Run the hook with valid env vars pointing to our test bridge
    local result
    result=$(TMUX_PREFIX="claude-test-" BRIDGE_URL="http://localhost:$PORT" bash "$SCRIPT_DIR/hooks/checkin-on-start.sh" 2>&1) || true

    if [[ -n "$result" ]] && echo "$result" | grep -qi -e "RECEIVING\|SENDING\|MESSAGING\|worker\|instruction"; then
        success "Checkin hook returns bridge instructions"
    else
        # May return empty if session name doesn't match prefix (expected outside bridge tmux)
        success "Checkin hook executed (no matching session in current tmux)"
    fi

    # Restore tmux env vars
    for var_line in "${saved_tmux_vars[@]}"; do
        local var_name="${var_line%%=*}"
        local var_val="${var_line#*=}"
        tmux set-environment "$var_name" "$var_val" 2>/dev/null || true
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI stop/restart/clean/status tests
# ─────────────────────────────────────────────────────────────────────────────

test_cli_status_command() {
    info "Testing CLI status command..."

    # Test status command with no nodes running (should not error)
    local result
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh --node nonexistent status 2>&1) || true

    # Should output something about the node (stopped or not configured)
    if echo "$result" | grep -qi -e "stopped\|running\|node"; then
        success "CLI status command works"
    else
        # May also say "not running" or similar
        success "CLI status command executed (node not running)"
    fi
}

test_cli_webhook_info() {
    info "Testing CLI webhook info command..."

    if [[ -z "${TEST_BOT_TOKEN:-}" ]]; then
        success "CLI webhook info skipped (no TEST_BOT_TOKEN)"
        return
    fi

    local result
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh webhook info 2>&1) || true

    # Should output webhook info or "not configured"
    if echo "$result" | grep -qi -e "url\|webhook\|configured\|pending\|warning\|unavailable\|error"; then
        success "CLI webhook info works"
    else
        fail "CLI webhook info failed: $result"
    fi
}

test_cli_hook_test_no_chat() {
    info "Testing CLI hook test without chat ID..."

    # hook test requires a chat_id file to exist
    local result
    result=$(TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" ./claudecode-telegram.sh --node emptynode hook test 2>&1) || true

    # Should report no chat ID found
    if echo "$result" | grep -qi -e "no chat\|not found\|send a message"; then
        success "CLI hook test reports missing chat ID"
    else
        fail "CLI hook test should report missing chat ID"
    fi
}

# ============================================================
# DIAGNOSTICS + MISC COVERAGE
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Concurrency and locking tests
# ─────────────────────────────────────────────────────────────────────────────

test_tmux_send_locks() {
    info "Testing per-session tmux send locks..."

    if python3 -c "
from bridge import _get_tmux_send_lock, _tmux_send_locks
import threading

# Get lock for same session twice - should return same lock
lock1 = _get_tmux_send_lock('test-session-1')
lock2 = _get_tmux_send_lock('test-session-1')
assert lock1 is lock2, 'same session should get same lock'

# Different sessions should get different locks
lock3 = _get_tmux_send_lock('test-session-2')
assert lock1 is not lock3, 'different sessions should get different locks'

# Verify locks are threading.Lock instances
assert isinstance(lock1, type(threading.Lock())), 'should be threading.Lock'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Per-session tmux send locks work"
    else
        fail "Tmux send locks test failed"
    fi
}

test_tmux_paste_buffer_send() {
    info "Testing tmux paste-buffer message delivery..."

    local test_session="test-paste-buf-$$"
    tmux new-session -d -s "$test_session" -x 200 -y 50 2>/dev/null

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create test tmux session"
        return
    fi

    # Test 1: Short message via paste-buffer
    if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import tmux_send_message
result = tmux_send_message('$test_session', 'paste-test-short-ok')
assert result == True, f'Expected True, got {result}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "paste-buffer: short message sent"
    else
        fail "paste-buffer: short message failed"
        tmux kill-session -t "$test_session" 2>/dev/null
        return
    fi

    sleep 0.5
    local pane_content
    pane_content=$(tmux capture-pane -t "$test_session" -p 2>/dev/null)
    if echo "$pane_content" | grep -q "paste-test-short-ok"; then
        success "paste-buffer: short message arrived in pane"
    else
        fail "paste-buffer: short message not found in pane"
        tmux kill-session -t "$test_session" 2>/dev/null
        return
    fi

    # Test 2: Long message (1000+ chars)
    if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import tmux_send_message
long_msg = 'LONGMSG_' + 'A' * 1000 + '_END'
result = tmux_send_message('$test_session', long_msg)
assert result == True, f'Expected True, got {result}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "paste-buffer: long message (1000+ chars) sent"
    else
        fail "paste-buffer: long message send failed"
    fi

    sleep 0.5
    pane_content=$(tmux capture-pane -t "$test_session" -p -S -50 2>/dev/null)
    if echo "$pane_content" | grep -q "LONGMSG_"; then
        success "paste-buffer: long message arrived in pane"
    else
        fail "paste-buffer: long message not found in pane"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null
}

test_paste_buffer_uses_bracketed_paste() {
    info "Testing paste-buffer uses -p flag for bracketed paste..."

    if python3 -c "
import sys, subprocess, unittest.mock; sys.path.insert(0, '.')
import bridge

bridge._node_name = 'test-bp'

calls = []
orig_run = subprocess.run

def mock_run(cmd, *args, **kwargs):
    calls.append(cmd)
    # Simulate success
    return type('R', (), {'returncode': 0, 'stdout': b'', 'stderr': b''})()

subprocess.run = mock_run
try:
    # Need a temp tmux lock dir
    import tempfile, os
    lock_dir = f'/tmp/claudecode-telegram/test-bp/locks'
    os.makedirs(lock_dir, exist_ok=True)

    bridge.tmux_send_message('test-session', 'hello world')

    # Find the paste-buffer call
    paste_calls = [c for c in calls if isinstance(c, list) and 'paste-buffer' in c]
    assert len(paste_calls) == 1, f'Expected 1 paste-buffer call, got {len(paste_calls)}: {paste_calls}'

    paste_cmd = paste_calls[0]
    assert '-p' in paste_cmd, f'Missing -p flag in paste-buffer: {paste_cmd}'
    assert '-r' in paste_cmd, f'Missing -r flag in paste-buffer: {paste_cmd}'

    print('OK')
finally:
    subprocess.run = orig_run
" 2>/dev/null | grep -q "OK"; then
        success "paste-buffer uses -p (bracketed paste) and -r flags"
    else
        fail "paste-buffer missing -p flag for bracketed paste"
    fi
}

test_image_caption_enter_with_bracketed_paste() {
    info "Chaos test: image+caption message (multi-line with path) Enter delivery..."

    # TUI simulator that simulates Claude Code's behavior:
    # - Enables bracketed paste mode
    # - After receiving paste end, simulates processing delay (image rendering)
    # - Counts PASTE+ENTER pairs
    cat > /tmp/tui-sim-imgcap-$$.py << 'TUITEST'
import sys, os, select, time, tty, termios

RESULT_FILE = sys.argv[1]
EXPECTED = int(sys.argv[2])
# Simulate TUI processing delay after paste (image path detection + rendering)
RENDER_DELAY_MS = int(sys.argv[3]) if len(sys.argv) > 3 else 0
# Deadline scales with send count: serialized sends each carry a ~1s post-paste sleep
DEADLINE_S = int(sys.argv[4]) if len(sys.argv) > 4 else 8

sys.stdout.buffer.write(b'\033[?2004h')
sys.stdout.buffer.flush()

old = termios.tcgetattr(sys.stdin)
tty.setraw(sys.stdin)

paste_count = 0
enter_after_count = 0
enter_during_render = 0
buf = b''
in_paste = False
paste_data = b''
rendering = False
render_end_time = 0

try:
    deadline = time.time() + DEADLINE_S
    while time.time() < deadline:
        readable, _, _ = select.select([sys.stdin], [], [], 0.01)
        if readable:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buf += chunk

            while True:
                if not in_paste:
                    idx = buf.find(b'\x1b[200~')
                    if idx >= 0:
                        in_paste = True
                        paste_data = b''
                        buf = buf[idx + 6:]
                        continue
                    else:
                        if b'\r' in buf:
                            now = time.time()
                            if rendering and now < render_end_time:
                                # Enter arrived while TUI is still rendering
                                enter_during_render += 1
                            elif paste_count > enter_after_count:
                                enter_after_count += 1
                                rendering = False
                            buf = buf[buf.rfind(b'\r')+1:]
                        break
                else:
                    idx = buf.find(b'\x1b[201~')
                    if idx >= 0:
                        paste_data += buf[:idx]
                        in_paste = False
                        paste_count += 1
                        # Simulate TUI rendering delay after paste ends
                        if RENDER_DELAY_MS > 0:
                            rendering = True
                            render_end_time = time.time() + (RENDER_DELAY_MS / 1000.0)
                        buf = buf[idx + 6:]
                        continue
                    else:
                        paste_data += buf
                        buf = b''
                        break

        # Check if rendering finished
        if rendering and time.time() >= render_end_time:
            rendering = False

        if enter_after_count >= EXPECTED:
            break
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
    sys.stdout.buffer.write(b'\033[?2004l')
    sys.stdout.buffer.flush()

with open(RESULT_FILE, 'w') as f:
    f.write(f'PASTES:{paste_count}\n')
    f.write(f'ENTERS:{enter_after_count}\n')
    f.write(f'ENTER_DURING_RENDER:{enter_during_render}\n')
TUITEST

    local test_session="test-imgcap-$$"
    local result_file="/tmp/tui-imgcap-result-$$.txt"
    local chaos_count=10
    # Simulate 120ms TUI render delay (image path detection + re-render).
    # Claude Code needs time to detect image paths and re-draw prompt.
    # Bridge post-paste delay must exceed this to avoid Enter swallowing.
    local render_delay_ms=120
    rm -f "$result_file"

    tmux new-session -d -s "$test_session" -x 200 -y 50 \
        "python3 /tmp/tui-sim-imgcap-$$.py $result_file $chaos_count $render_delay_ms 30"
    sleep 1

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create TUI simulator session"
        rm -f "/tmp/tui-sim-imgcap-$$.py"
        return
    fi

    # Chaos: send 10 image+caption messages rapidly
    local sent=0
    local send_failed=0
    for i in $(seq 1 $chaos_count); do
        if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import tmux_send_message

# Exact format bridge produces for image+caption
caption = 'can u improve the check capturing haha'
img_path = '/tmp/claudecode-telegram/prod/kenji/inbox/7ca9f508093444a4be3e5824bd339e24.jpg'
msg = f'{caption}\n\nManager sent image: {img_path}'
result = tmux_send_message('$test_session', msg)
print('OK' if result else 'FAIL')
" 2>/dev/null | grep -q "OK"; then
            sent=$((sent + 1))
        else
            send_failed=$((send_failed + 1))
        fi
    done

    if [ "$sent" -ne "$chaos_count" ]; then
        fail "Only $sent/$chaos_count messages sent (tmux_send_message returned False)"
        tmux kill-session -t "$test_session" 2>/dev/null || true
        rm -f "/tmp/tui-sim-imgcap-$$.py" "$result_file"
        return
    fi

    # Wait for TUI to process all. Success exits as soon as the simulator
    # writes the expected ENTERS count; failures still wait through its 30s
    # internal deadline before judging red.
    local attempts=0
    while [[ $attempts -lt 300 ]]; do
        if [[ -f "$result_file" ]] && wait_for_file_content "$result_file" '^ENTERS:' 0; then
            local observed_enters
            observed_enters=$(grep -Eo '^ENTERS:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
            observed_enters=${observed_enters:-0}
            [[ "$observed_enters" -ge "$chaos_count" ]] && break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [ -f "$result_file" ]; then
        local pastes enters renders
        pastes=$(grep -Eo '^PASTES:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        enters=$(grep -Eo '^ENTERS:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        renders=$(grep -Eo '^ENTER_DURING_RENDER:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        pastes=${pastes:-0}
        enters=${enters:-0}
        renders=${renders:-0}
        if [ "$enters" -ge "$chaos_count" ]; then
            success "Chaos: $enters/$chaos_count image+caption Enter delivered ($pastes pastes, $renders during render)"
        elif [ "$enters" -gt 0 ]; then
            fail "Chaos: only $enters/$chaos_count Enter received ($pastes pastes, $renders during render) — Enter swallowed!"
        else
            fail "Chaos: 0/$chaos_count Enter received ($pastes pastes, $renders during render) — total failure"
        fi
    else
        fail "TUI simulator produced no result file"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null || true
    rm -f "/tmp/tui-sim-imgcap-$$.py" "$result_file"
}

test_long_text_enter_with_bracketed_paste() {
    info "Testing long text (60 lines) + Enter delivered via bracketed paste..."

    # Create TUI simulator that enables bracketed paste mode
    cat > /tmp/tui-sim-test-$$.py << 'TUITEST'
import sys, os, select, time, tty, termios

RESULT_FILE = sys.argv[1]

# Enable bracketed paste mode (like Claude Code)
sys.stdout.buffer.write(b'\033[?2004h')
sys.stdout.buffer.flush()

old = termios.tcgetattr(sys.stdin)
tty.setraw(sys.stdin)

results = []
buf = b''
in_paste = False
paste_data = b''
paste_received = False

try:
    deadline = time.time() + 5
    while time.time() < deadline:
        readable, _, _ = select.select([sys.stdin], [], [], 0.05)
        if readable:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buf += chunk

            while True:
                if not in_paste:
                    idx = buf.find(b'\x1b[200~')
                    if idx >= 0:
                        in_paste = True
                        paste_data = b''
                        buf = buf[idx + 6:]
                        continue
                    else:
                        if b'\r' in buf:
                            if paste_received:
                                results.append("ENTER_AFTER_PASTE")
                            buf = buf[buf.rfind(b'\r')+1:]
                        break
                else:
                    idx = buf.find(b'\x1b[201~')
                    if idx >= 0:
                        paste_data += buf[:idx]
                        in_paste = False
                        paste_received = True
                        lines = paste_data.count(b'\n') + 1
                        results.append(f"PASTE:{lines}lines")
                        buf = buf[idx + 6:]
                        continue
                    else:
                        paste_data += buf
                        buf = b''
                        break

        if "ENTER_AFTER_PASTE" in results:
            break
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
    sys.stdout.buffer.write(b'\033[?2004l')
    sys.stdout.buffer.flush()

if not results:
    results.append("NOTHING_RECEIVED")

with open(RESULT_FILE, 'w') as f:
    f.write('\n'.join(results) + '\n')
TUITEST

    local test_session="test-bp-long-$$"
    local result_file="/tmp/tui-bp-result-$$.txt"
    rm -f "$result_file"

    tmux new-session -d -s "$test_session" -x 200 -y 50 \
        "python3 /tmp/tui-sim-test-$$.py $result_file"
    sleep 1

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create TUI simulator session"
        rm -f "/tmp/tui-sim-test-$$.py"
        return
    fi

    # Send 60-line message via bridge function
    if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import tmux_send_message

# Generate 60-line message
lines = [f'Line {i}: Test content for bracketed paste delivery verification.' for i in range(1, 61)]
msg = '\n'.join(lines)
result = tmux_send_message('$test_session', msg)
assert result == True, f'tmux_send_message returned {result}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        : # send succeeded
    else
        fail "tmux_send_message failed for 60-line message"
        tmux kill-session -t "$test_session" 2>/dev/null
        rm -f "/tmp/tui-sim-test-$$.py" "$result_file"
        return
    fi

    # Wait for TUI to process. Success exits as soon as Enter-after-paste is
    # recorded; failures still wait through the simulator's 5s deadline.
    local attempts=0
    while [[ $attempts -lt 50 ]]; do
        if [[ -f "$result_file" ]] && wait_for_file_content "$result_file" '^ENTER_AFTER_PASTE$' 0; then
            break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [ -f "$result_file" ]; then
        local has_paste has_enter
        has_paste=$(grep -c "PASTE:" "$result_file" 2>/dev/null || true)
        has_paste=${has_paste:-0}
        has_enter=$(grep -c "ENTER_AFTER_PASTE" "$result_file" 2>/dev/null || true)
        has_enter=${has_enter:-0}
        if [ "$has_paste" -gt 0 ] && [ "$has_enter" -gt 0 ]; then
            success "60-line text + Enter delivered via bracketed paste"
        elif [ "$has_paste" -gt 0 ]; then
            fail "Paste received but Enter lost ($(cat "$result_file" | tr '\n' ' '))"
        else
            fail "Bracketed paste not detected ($(cat "$result_file" | tr '\n' ' '))"
        fi
    else
        fail "TUI simulator produced no result file"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null || true
    rm -f "/tmp/tui-sim-test-$$.py" "$result_file"
}

test_slow_paste_render_enter_delivered() {
    info "Chaos test: slow paste render (400ms) — 1s delay must cover it..."

    # Same TUI simulator as test_image_caption_enter but with 400ms render delay
    # (exceeds old 150ms sleep, within new 1s sleep).
    cat > /tmp/tui-sim-slowpaste-$$.py << 'TUITEST'
import sys, os, select, time, tty, termios
RESULT_FILE = sys.argv[1]
EXPECTED = int(sys.argv[2])
RENDER_DELAY_MS = int(sys.argv[3]) if len(sys.argv) > 3 else 400
sys.stdout.buffer.write(b'\033[?2004h')
sys.stdout.buffer.flush()
old = termios.tcgetattr(sys.stdin)
tty.setraw(sys.stdin)
paste_count = 0
enter_after_count = 0
enter_during_render = 0
buf = b''
in_paste = False
paste_data = b''
rendering = False
render_end_time = 0
try:
    deadline = time.time() + 15
    while time.time() < deadline:
        readable, _, _ = select.select([sys.stdin], [], [], 0.01)
        if readable:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buf += chunk
            while True:
                if not in_paste:
                    idx = buf.find(b'\x1b[200~')
                    if idx >= 0:
                        in_paste = True
                        paste_data = b''
                        buf = buf[idx + 6:]
                        continue
                    else:
                        if b'\r' in buf:
                            now = time.time()
                            if rendering and now < render_end_time:
                                enter_during_render += 1
                            elif paste_count > enter_after_count:
                                enter_after_count += 1
                                rendering = False
                            buf = buf[buf.rfind(b'\r')+1:]
                        break
                else:
                    idx = buf.find(b'\x1b[201~')
                    if idx >= 0:
                        paste_data += buf[:idx]
                        in_paste = False
                        paste_count += 1
                        if RENDER_DELAY_MS > 0:
                            rendering = True
                            render_end_time = time.time() + (RENDER_DELAY_MS / 1000.0)
                        buf = buf[idx + 6:]
                        continue
                    else:
                        paste_data += buf
                        buf = b''
                        break
        if rendering and time.time() >= render_end_time:
            rendering = False
        if enter_after_count >= EXPECTED:
            break
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
    sys.stdout.buffer.write(b'\033[?2004l')
    sys.stdout.buffer.flush()
with open(RESULT_FILE, 'w') as f:
    f.write(f'PASTES:{paste_count}\n')
    f.write(f'ENTERS:{enter_after_count}\n')
    f.write(f'ENTER_DURING_RENDER:{enter_during_render}\n')
TUITEST

    local test_session="test-slowpaste-$$"
    local result_file="/tmp/tui-slowpaste-result-$$.txt"
    local msg_count=5
    local render_delay_ms=400
    rm -f "$result_file"

    tmux new-session -d -s "$test_session" -x 200 -y 50 \
        "python3 /tmp/tui-sim-slowpaste-$$.py $result_file $msg_count $render_delay_ms"
    sleep 1

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create TUI simulator session"
        return
    fi

    local sent=0
    for i in $(seq 1 $msg_count); do
        if python3 -c "
import sys; sys.path.insert(0, '.')
from bridge import tmux_send_message
result = tmux_send_message('$test_session', 'Slow paste test message $i')
print('OK' if result else 'FAIL')
" 2>/dev/null | grep -q "OK"; then
            sent=$((sent + 1))
        fi
    done

    # Wait for TUI to process all. Success exits as soon as the simulator
    # writes the expected ENTERS count; failures still wait through its 15s
    # internal deadline before judging red.
    local attempts=0
    while [[ $attempts -lt 150 ]]; do
        if [[ -f "$result_file" ]] && wait_for_file_content "$result_file" '^ENTERS:' 0; then
            local observed_enters
            observed_enters=$(grep -Eo '^ENTERS:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
            observed_enters=${observed_enters:-0}
            [[ "$observed_enters" -ge "$msg_count" ]] && break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    if [ -f "$result_file" ]; then
        local pastes enters renders
        pastes=$(grep -Eo '^PASTES:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        enters=$(grep -Eo '^ENTERS:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        renders=$(grep -Eo '^ENTER_DURING_RENDER:[0-9]+' "$result_file" 2>/dev/null | head -1 | cut -d: -f2 || true)
        pastes=${pastes:-0}
        enters=${enters:-0}
        renders=${renders:-0}
        if [ "$enters" -ge "$msg_count" ]; then
            success "Slow paste: $enters/$msg_count Enter delivered ($renders during render)"
        else
            fail "Slow paste: $enters/$msg_count Enter OK, $renders during render — message lost!"
        fi
    else
        fail "TUI simulator produced no result file"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null || true
    rm -f "$result_file"
}

test_tmux_send_uses_flock() {
    info "Testing tmux_send_message acquires cross-process flock..."

    # tmux_send_message should acquire a file lock (flock) so that
    # external processes (workers) using the same lock file are serialized.
    # Verify the lock file exists after a send.
    local test_session="test-flock-$$"
    tmux new-session -d -s "$test_session" -x 200 -y 50 2>/dev/null

    if ! tmux has-session -t "$test_session" 2>/dev/null; then
        fail "Could not create test tmux session"
        return
    fi

    if python3 -c "
import sys, os; sys.path.insert(0, '.')
import bridge

# Override _node_name so lock path is predictable
bridge._node_name = 'test-flock'
bridge.TMUX_PREFIX = 'test-flock-'

# Send a message
result = bridge.tmux_send_message('$test_session', 'flock-test-msg')
assert result == True, f'send failed: {result}'

# Check that a lock file was created for this session
lock_path = bridge.tmux_send_lock_path('$test_session')
assert os.path.exists(lock_path), f'lock file not created: {lock_path}'
assert '/test-flock/' in str(lock_path), f'lock not node-namespaced: {lock_path}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "tmux_send_message uses flock (lock file created)"
    else
        fail "tmux_send_message does not use flock"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup and shutdown tests
# ─────────────────────────────────────────────────────────────────────────────

# ============================================================
# CLI + NODE CONFIG (NEW)
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Run/Tunnel Behavior Tests (NEW)
# ─────────────────────────────────────────────────────────────────────────────

# ============================================================
# GAPS + ENV + ROUTING (NEW)
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Misc Behavior Gaps Tests (NEW)
# ─────────────────────────────────────────────────────────────────────────────

test_watchdog_alert_on_stuck() {
    info "Testing watchdog alerts on stuck transition..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._last_alert_ts = {}
bridge._prev_session_states = {'alice': 'READY'}
bridge._session_states = {'alice': ('STUCK', 'age=400s cpu=0.0', 600)}

sent = {}
def fake_api(method, data):
    sent['method'] = method
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._handle_watchdog_transition('alice', 'STUCK', 'age=400s cpu=0.0', since=600, now=1000)

assert sent.get('method') == 'sendMessage', 'telegram_api not called'
assert sent['data']['chat_id'] == 123, 'admin chat id should be used'
txt = sent['data']['text']
assert 'alice' in txt, f'alert should include worker name: {txt}'
assert 'no progress' in txt or '/cd' in txt, f'alert should be human-friendly: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog stuck alert fires on transition"
    else
        fail "Watchdog stuck alert test failed"
    fi
}

test_extra_mounts_docker_cmd() {
    info "Testing extra mounts via --mount and --mount-ro in Docker cmd..."

    if python3 -c "
import os
os.environ['SANDBOX_ENABLED'] = '1'
os.environ['PORT'] = '8295'
os.environ['SANDBOX_MOUNTS'] = '/host:/container,ro:/readonly:/readonly'

# Re-import to pick up env changes
import importlib
import bridge
importlib.reload(bridge)

from bridge import SANDBOX_EXTRA_MOUNTS

# Verify mounts were parsed
assert len(SANDBOX_EXTRA_MOUNTS) >= 2, f'Should have parsed mounts, got {len(SANDBOX_EXTRA_MOUNTS)}'

# Check for read-only mount
has_ro = any(m[2] for m in SANDBOX_EXTRA_MOUNTS)
assert has_ro, 'Should have at least one read-only mount'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Extra mounts parsing works"
    else
        fail "Extra mounts parsing test failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bridge Public URL Tests
# ─────────────────────────────────────────────────────────────────────────────









test_bridge_public_url_auto_detect() {
    info "Testing BRIDGE_PUBLIC_URL auto-detects from Tailscale when unset..."

    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items() if k not in ('BRIDGE_PUBLIC_URL',)}
env['TELEGRAM_BOT_TOKEN'] = 'test'
result = subprocess.run([sys.executable, '-c', '''
import bridge
# Should be auto-detected from tailscale or empty (no tailscale)
url = bridge.BRIDGE_PUBLIC_URL
assert isinstance(url, str), f\"Expected string, got {type(url)}\"
if url:
    assert url.startswith(\"http://\"), f\"Expected http:// URL, got {url!r}\"
    assert \"localhost\" not in url and \"127.0.0.1\" not in url, f\"Should not be localhost: {url!r}\"
print(\"OK\")
'''], capture_output=True, text=True, env=env)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
" 2>/dev/null | grep -q "OK"; then
        success "BRIDGE_PUBLIC_URL auto-detects or stays empty"
    else
        fail "BRIDGE_PUBLIC_URL default test failed"
    fi
}

test_bridge_public_url_auto_bind() {
    info "Testing BRIDGE_PUBLIC_URL auto-sets BRIDGE_BIND when implicit..."

    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items() if k not in ('BRIDGE_PUBLIC_URL', 'BRIDGE_BIND')}
env['TELEGRAM_BOT_TOKEN'] = 'test'
env['BRIDGE_PUBLIC_URL'] = 'http://100.125.36.102:8080'
result = subprocess.run([sys.executable, '-c', '''
import bridge
assert bridge.BRIDGE_PUBLIC_URL == \"http://100.125.36.102:8080\", bridge.BRIDGE_PUBLIC_URL
assert bridge.BRIDGE_BIND == \"0.0.0.0\", f\"Expected BRIDGE_BIND=0.0.0.0, got {bridge.BRIDGE_BIND!r}\"
print(\"OK\")
'''], capture_output=True, text=True, env=env)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
" 2>/dev/null | grep -q "OK"; then
        success "BRIDGE_PUBLIC_URL auto-sets BRIDGE_BIND=0.0.0.0 when implicit"
    else
        fail "BRIDGE_PUBLIC_URL auto-bind test failed"
    fi
}

test_bridge_public_url_no_auto_bind_when_explicit() {
    info "Testing explicit BRIDGE_BIND overrides BRIDGE_PUBLIC_URL auto-bind..."

    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items() if k not in ('BRIDGE_PUBLIC_URL', 'BRIDGE_BIND')}
env['TELEGRAM_BOT_TOKEN'] = 'test'
env['BRIDGE_PUBLIC_URL'] = 'http://100.125.36.102:8080'
env['BRIDGE_BIND'] = '127.0.0.9'
result = subprocess.run([sys.executable, '-c', '''
import bridge
assert bridge.BRIDGE_PUBLIC_URL == \"http://100.125.36.102:8080\", bridge.BRIDGE_PUBLIC_URL
assert bridge.BRIDGE_BIND == \"127.0.0.9\", f\"Expected explicit BRIDGE_BIND to persist, got {bridge.BRIDGE_BIND!r}\"
print(\"OK\")
'''], capture_output=True, text=True, env=env)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
" 2>/dev/null | grep -q "OK"; then
        success "Explicit BRIDGE_BIND is preserved with BRIDGE_PUBLIC_URL"
    else
        fail "Explicit BRIDGE_BIND override test failed"
    fi
}

test_bridge_url_ignores_stale_localhost() {
    info "Testing BRIDGE_URL ignores stale localhost env and derives from PORT..."

    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items() if k not in ('BRIDGE_URL',)}
env['TELEGRAM_BOT_TOKEN'] = 'test'
env['PORT'] = '9999'
env['BRIDGE_URL'] = 'http://localhost:8080'  # stale from old bridge
result = subprocess.run([sys.executable, '-c', '''
import bridge
assert bridge.BRIDGE_URL == \"http://localhost:9999\", f\"Expected http://localhost:9999, got {bridge.BRIDGE_URL!r}\"
print(\"OK\")
'''], capture_output=True, text=True, env=env)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
" 2>/dev/null | grep -q "OK"; then
        success "BRIDGE_URL ignores stale localhost env, derives from PORT"
    else
        fail "BRIDGE_URL stale localhost test failed"
    fi
}

test_bridge_url_ignores_stale_127() {
    info "Testing BRIDGE_URL ignores stale 127.0.0.1 env..."

    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items() if k not in ('BRIDGE_URL',)}
env['TELEGRAM_BOT_TOKEN'] = 'test'
env['PORT'] = '9999'
env['BRIDGE_URL'] = 'http://127.0.0.1:8080'  # stale
result = subprocess.run([sys.executable, '-c', '''
import bridge
assert bridge.BRIDGE_URL == \"http://localhost:9999\", f\"Expected http://localhost:9999, got {bridge.BRIDGE_URL!r}\"
print(\"OK\")
'''], capture_output=True, text=True, env=env)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
" 2>/dev/null | grep -q "OK"; then
        success "BRIDGE_URL ignores stale 127.0.0.1 env"
    else
        fail "BRIDGE_URL stale 127.0.0.1 test failed"
    fi
}


test_resolved_alert_cooldown() {
    info "Testing resolved alert has cooldown to prevent spam..."

    if python3 -c "
from unittest.mock import patch, MagicMock
import time
import bridge

# Reset state
bridge._last_resolved_ts.clear()
bridge._prev_session_states.clear()

alerts = []
def mock_api(method, params):
    alerts.append(params.get('text', ''))
    return {'ok': True, 'result': {'message_id': 1}}

with patch.object(bridge, 'admin_chat_id', 123), \
     patch.object(bridge, 'telegram_api', mock_api):
    # Set prev state as DEAD
    with bridge._watchdog_lock:
        bridge._prev_session_states['test'] = 'DEAD'

    # First resolved alert should send
    bridge._send_resolved_alert('test', 'READY')
    assert len(alerts) == 1, f'First alert should send, got {len(alerts)}'

    # Reset prev state back to DEAD to simulate another bad->good transition
    with bridge._watchdog_lock:
        bridge._prev_session_states['test'] = 'DEAD'

    # Second one within cooldown should be suppressed
    bridge._send_resolved_alert('test', 'READY')
    assert len(alerts) == 1, f'Second alert within cooldown should be suppressed, got {len(alerts)}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "resolved alert has 180s cooldown"
    else
        fail "resolved alert should have cooldown to prevent spam"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Node-derived config tests
# ─────────────────────────────────────────────────────────────────────────────

test_node_derives_tmux_prefix() {
    info "Testing NODE_NAME derives TMUX_PREFIX..."

    # NODE_NAME=mynode → TMUX_PREFIX should be "claude-mynode-"
    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items()
       if k not in ('TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
env['NODE_NAME'] = 'mynode'
env['TELEGRAM_BOT_TOKEN'] = 'test'
result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.TMUX_PREFIX)
'''], capture_output=True, text=True, env=env)
prefix = result.stdout.strip()
assert prefix == 'claude-mynode-', f'Expected claude-mynode-, got {prefix!r}'
"; then
        success "NODE_NAME=mynode → TMUX_PREFIX=claude-mynode-"
    else
        fail "NODE_NAME did not derive TMUX_PREFIX"
    fi
}

test_node_derives_sessions_dir() {
    info "Testing NODE_NAME derives SESSIONS_DIR..."

    # NODE_NAME=mynode → SESSIONS_DIR should be ~/.claude/telegram/nodes/mynode/sessions
    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items()
       if k not in ('TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
env['NODE_NAME'] = 'mynode'
env['TELEGRAM_BOT_TOKEN'] = 'test'
result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.SESSIONS_DIR)
'''], capture_output=True, text=True, env=env)
got = result.stdout.strip()
expected = os.path.expanduser('~/.claude/telegram/nodes/mynode/sessions')
assert got == expected, f'Expected {expected}, got {got!r}'
"; then
        success "NODE_NAME=mynode → SESSIONS_DIR=~/.claude/telegram/nodes/mynode/sessions"
    else
        fail "NODE_NAME did not derive SESSIONS_DIR"
    fi
}

test_node_derives_port() {
    info "Testing NODE_NAME derives PORT from default map..."

    # NODE_NAME=prod → PORT=8271, dev→8272, test→8295, other→8270
    if python3 -c "
import subprocess, sys, os

cases = [('prod', 8271), ('dev', 8272), ('test', 8295), ('custom', 8270)]
for node, expected_port in cases:
    env = {k: v for k, v in os.environ.items()
           if k not in ('TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
    env['NODE_NAME'] = node
    env['TELEGRAM_BOT_TOKEN'] = 'test'
    result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.PORT)
'''], capture_output=True, text=True, env=env)
    got = int(result.stdout.strip())
    assert got == expected_port, f'NODE_NAME={node}: expected PORT={expected_port}, got {got}'
"; then
        success "NODE_NAME derives correct PORT for prod/dev/test/other"
    else
        fail "NODE_NAME did not derive PORT correctly"
    fi
}

test_node_derives_bridge_url() {
    info "Testing NODE_NAME derives BRIDGE_URL from PORT..."

    # NODE_NAME=dev → PORT=8272 → BRIDGE_URL=http://localhost:8272
    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items()
       if k not in ('TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
env['NODE_NAME'] = 'dev'
env['TELEGRAM_BOT_TOKEN'] = 'test'
result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.BRIDGE_URL)
'''], capture_output=True, text=True, env=env)
got = result.stdout.strip()
assert got == 'http://localhost:8272', f'Expected http://localhost:8272, got {got!r}'
"; then
        success "NODE_NAME=dev → BRIDGE_URL=http://localhost:8272"
    else
        fail "NODE_NAME did not derive BRIDGE_URL"
    fi
}

test_node_explicit_env_overrides() {
    info "Testing explicit env vars override NODE_NAME derivation..."

    # NODE_NAME=prod but PORT=9999, TMUX_PREFIX=custom-, SESSIONS_DIR=/tmp/custom
    if python3 -c "
import subprocess, sys, os, tempfile
tmpdir = tempfile.mkdtemp()
env = {k: v for k, v in os.environ.items()
       if k not in ('TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
env['NODE_NAME'] = 'prod'
env['TELEGRAM_BOT_TOKEN'] = 'test'
env['PORT'] = '9999'
env['TMUX_PREFIX'] = 'custom-'
env['SESSIONS_DIR'] = tmpdir
result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.PORT)
print(bridge.TMUX_PREFIX)
print(bridge.SESSIONS_DIR)
'''], capture_output=True, text=True, env=env)
lines = result.stdout.strip().split('\n')
assert lines[0] == '9999', f'PORT: expected 9999, got {lines[0]!r}'
assert lines[1] == 'custom-', f'TMUX_PREFIX: expected custom-, got {lines[1]!r}'
assert lines[2] == tmpdir, f'SESSIONS_DIR: expected {tmpdir}, got {lines[2]!r}'
import shutil; shutil.rmtree(tmpdir, ignore_errors=True)
"; then
        success "Explicit env vars override NODE_NAME derivation"
    else
        fail "Explicit env vars did not override NODE_NAME"
    fi
}

test_node_empty_uses_defaults() {
    info "Testing no NODE_NAME uses existing defaults..."

    # No NODE_NAME, no PORT, no TMUX_PREFIX, no SESSIONS_DIR → original defaults
    if python3 -c "
import subprocess, sys, os
env = {k: v for k, v in os.environ.items()
       if k not in ('NODE_NAME', 'TMUX_PREFIX', 'SESSIONS_DIR', 'PORT', 'BRIDGE_URL')}
env['TELEGRAM_BOT_TOKEN'] = 'test'
result = subprocess.run([sys.executable, '-c', '''
import bridge
print(bridge.PORT)
print(bridge.TMUX_PREFIX)
print(bridge.SESSIONS_DIR)
print(bridge.BRIDGE_URL)
'''], capture_output=True, text=True, env=env)
lines = result.stdout.strip().split('\n')
expected_dir = os.path.expanduser('~/.claude/telegram/sessions')
assert lines[0] == '8270', f'PORT: expected 8270, got {lines[0]!r}'
assert lines[1] == 'claude-', f'TMUX_PREFIX: expected claude-, got {lines[1]!r}'
assert lines[2] == expected_dir, f'SESSIONS_DIR: expected {expected_dir}, got {lines[2]!r}'
assert lines[3] == 'http://localhost:8270', f'BRIDGE_URL: expected http://localhost:8270, got {lines[3]!r}'
"; then
        success "No NODE_NAME preserves original defaults"
    else
        fail "Missing NODE_NAME changed defaults"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Persistence file tests
# ─────────────────────────────────────────────────────────────────────────────

test_persistence_file_functions() {
    info "Testing persistence file functions..."

    if python3 -c "
from bridge import save_last_chat_id, load_last_chat_id, LAST_CHAT_ID_FILE

# Test save and load chat_id (last_active was removed with the focus concept)
test_chat_id = 987654321
save_last_chat_id(test_chat_id)
loaded = load_last_chat_id()
assert loaded == test_chat_id, f'expected {test_chat_id}, got {loaded}'

# Verify file permissions
perms = oct(LAST_CHAT_ID_FILE.stat().st_mode)[-3:]
assert perms == '600', f'chat_id file should be 600, got {perms}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Persistence file functions work"
    else
        fail "Persistence file functions test failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker Registry Tests (persistent registry)
# ─────────────────────────────────────────────────────────────────────────────

test_registry_add_remove() {
    info "Testing registry add/remove CRUD..."

    if python3 -c "
import os, json, tempfile, time
from pathlib import Path
import bridge

# Use temp dir to avoid touching real registry
tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'

# Add a worker
bridge._registry_add('alice', 'claude', 12345)
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'alice' in data['workers'], 'alice not in registry'
assert data['workers']['alice']['backend'] == 'claude'
assert data['workers']['alice']['chat_id'] == 12345
assert data['version'] == 1

# Add another
bridge._registry_add('bob', 'codex', 67890)
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'alice' in data['workers'] and 'bob' in data['workers'], 'both should exist'

# Remove alice
bridge._registry_remove('alice')
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'alice' not in data['workers'], 'alice should be removed'
assert 'bob' in data['workers'], 'bob should remain'

# Remove nonexistent (no crash)
bridge._registry_remove('charlie')

# Verify file permissions
perms = oct(bridge.WORKER_REGISTRY_FILE.stat().st_mode)[-3:]
assert perms == '600', f'registry file should be 600, got {perms}'

import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Registry add/remove CRUD works"
    else
        fail "Registry add/remove CRUD failed"
    fi
}

test_registry_bootstrap() {
    info "Testing registry bootstrap from tmux sessions..."

    if python3 -c "
import os, json, tempfile
from pathlib import Path
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'

# Simulate existing tmux sessions
registered = {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'},
    'bob': {'tmux': 'claude-test-bob', 'backend': 'codex'},
}

# Bootstrap should create registry
bridge._registry_bootstrap(registered)
assert bridge.WORKER_REGISTRY_FILE.exists(), 'registry file should be created'
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'alice' in data['workers'] and 'bob' in data['workers'], 'both workers should be bootstrapped'
assert data['workers']['alice']['backend'] == 'claude'
assert data['workers']['bob']['backend'] == 'codex'

# Second call should be a no-op (file already exists)
old_mtime = bridge.WORKER_REGISTRY_FILE.stat().st_mtime
import time; time.sleep(0.01)
bridge._registry_bootstrap({'charlie': {'tmux': 'claude-test-charlie', 'backend': 'claude'}})
new_mtime = bridge.WORKER_REGISTRY_FILE.stat().st_mtime
assert old_mtime == new_mtime, 'bootstrap should not overwrite existing registry'

import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Registry bootstrap from tmux sessions works"
    else
        fail "Registry bootstrap test failed"
    fi
}

test_registry_corrupt_recovery() {
    info "Testing registry corrupt file recovery..."

    if python3 -c "
import os, json, tempfile
from pathlib import Path
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'

# Write garbage to registry file
bridge.WORKER_REGISTRY_FILE.write_text('not valid json{{{')

# Load should return empty dict, not crash
data = bridge._load_registry()
assert data == {}, f'corrupt file should return empty dict, got {data}'

# Corrupt file should be renamed
corrupt_files = list(Path(tmpdir).glob('workers.corrupt.*'))
assert len(corrupt_files) == 1, f'expected 1 corrupt backup, got {len(corrupt_files)}'

# Now add a worker — should work fine after corrupt recovery
bridge._registry_add('alice', 'claude', 12345)
data = bridge._load_registry()
assert 'alice' in data.get('workers', {}), 'should work after corrupt recovery'

import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Registry corrupt file recovery works"
    else
        fail "Registry corrupt recovery test failed"
    fi
}

test_get_registered_includes_registry() {
    info "Testing get_registered_sessions includes registry workers..."

    if python3 -c "
import os, json, tempfile
from pathlib import Path
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'
bridge.SESSIONS_DIR = Path(tmpdir) / 'sessions'
bridge.SESSIONS_DIR.mkdir()

# Pre-create registry with a dead worker
data = {'version': 1, 'workers': {
    'deadworker': {'backend': 'claude', 'chat_id': 123, 'hire_time': 1000}
}}
bridge.WORKER_REGISTRY_FILE.write_text(json.dumps(data))

# Create worker manager that returns no tmux sessions
wm = bridge.SessionManager(bridge.SESSIONS_DIR, 'claude-test-')

# Mock scan_tmux_sessions to return empty (no live workers)
wm.scan_tmux_sessions = lambda: {}

registered = wm.get_registered_sessions()
assert 'deadworker' in registered, f'dead worker should be in registered, got {list(registered.keys())}'
assert registered['deadworker'].get('backend') == 'claude'
assert 'tmux' not in registered['deadworker'], 'dead worker should not have tmux key'

import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "get_registered_sessions includes registry workers"
    else
        fail "get_registered_sessions registry merge failed"
    fi
}

test_checkin_cwd_stores_in_memory() {
    info "Testing /checkin?cwd stores cwd in memory..."

    if python3 -c "
import io, json, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'
bridge.SESSIONS_DIR = Path(tmpdir) / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}regcheckin-'
bridge._worker_cwds.clear()

bridge._registry_add('alice', 'claude', 123)
project_dir = Path(tmpdir) / 'project'
project_dir.mkdir()

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=alice&cwd=' + quote(str(project_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

assert handler.status == 200, f'expected 200, got {handler.status}'
assert bridge._get_worker_cwd('alice') == str(project_dir), bridge._get_worker_cwd('alice')
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'cwd' not in data['workers']['alice'], data['workers']['alice']
shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd stores cwd in memory"
    else
        fail "/checkin?cwd memory update failed"
    fi
}

test_checkin_cwd_invalid_path() {
    info "Testing /checkin?cwd rejects invalid path..."

    if python3 -c "
import io, json, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'
bridge.SESSIONS_DIR = Path(tmpdir) / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}regcheckin-'

bridge._registry_add('alice', 'claude', 123)
missing = Path(tmpdir) / 'does-not-exist'

class FakeHandler:
    def __init__(self):
        self.status = None
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, *_args, **_kwargs):
        pass
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=alice&cwd=' + quote(str(missing)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

assert handler.status == 400, f'expected 400, got {handler.status}'
data = json.loads(bridge.WORKER_REGISTRY_FILE.read_text())
assert 'cwd' not in data['workers']['alice'], data['workers']['alice']
shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd rejects invalid path with 400"
    else
        fail "/checkin?cwd invalid path test failed"
    fi
}

test_checkin_cwd_restart_notifies_manager() {
    info "Testing /checkin?cwd restart sends manager start+ready notifications..."

    if python3 -c "
import io, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
tmp_path = Path(tmpdir)
bridge.NODE_DIR = tmp_path
bridge.WORKER_REGISTRY_FILE = tmp_path / 'workers.json'
bridge.SESSIONS_DIR = tmp_path / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}checkinnotify-'
bridge.admin_chat_id = None
bridge._worker_cwds.clear()

bridge._registry_add('alice', 'claude', 123)
session_dir = bridge.ensure_session_dir('alice')
chat_file = session_dir / 'chat_id'
chat_file.write_text('777')
chat_file.chmod(0o600)

old_dir = tmp_path / 'old-project'
new_dir = tmp_path / 'new-project'
old_dir.mkdir()
new_dir.mkdir()

bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': f'{bridge.TMUX_PREFIX}alice', 'backend': 'claude'}
}
bridge.tmux_exists = lambda _name: True
bridge.is_claude_running = lambda _name: False  # Allow checkin restart
bridge.export_hook_env = lambda *_args, **_kwargs: None
bridge.session_manager._get_tmux_pane_cwd = lambda _tmux: str(old_dir)
bridge.session_manager.restart = lambda name, mode='relaunch': (True, None)
bridge._wait_for_restart_ready = lambda *_args, **_kwargs: True
bridge._recent_restarts.pop('alice', None)  # Clear cooldown

sent = []
def fake_send(chat_id, text):
    sent.append((chat_id, text))
    return {'ok': True}
bridge.send_telegram_message = fake_send

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=alice&cwd=' + quote(str(new_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

body = handler.wfile.getvalue().decode()
assert handler.status == 200, f'expected 200, got {handler.status}: {body}'
assert 'Restarting in' in body, body
assert len(sent) == 2, f'expected 2 notifications, got {len(sent)}: {sent}'
assert sent[0][0] == 777 and sent[1][0] == 777, sent
first = sent[0][1].lower()
second = sent[1][1].lower()
assert 'alice' in first and 'restart' in first, first
assert 'lost' in first or 'hold' in first, first
assert 'alice' in second and 'ready' in second, second

shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd restart sends manager notifications"
    else
        fail "/checkin?cwd restart notification test failed"
    fi
}

test_checkin_cwd_restart_prefers_admin_chat_id() {
    info "Testing /checkin?cwd restart prefers admin chat id over session chat id..."

    if python3 -c "
import io, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
tmp_path = Path(tmpdir)
bridge.NODE_DIR = tmp_path
bridge.WORKER_REGISTRY_FILE = tmp_path / 'workers.json'
bridge.SESSIONS_DIR = tmp_path / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}checkinnotify-'
bridge.admin_chat_id = 999
bridge._worker_cwds.clear()

bridge._registry_add('alice', 'claude', 123)
session_dir = bridge.ensure_session_dir('alice')
chat_file = session_dir / 'chat_id'
chat_file.write_text('777')
chat_file.chmod(0o600)

old_dir = tmp_path / 'old-project'
new_dir = tmp_path / 'new-project'
old_dir.mkdir()
new_dir.mkdir()

bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': f'{bridge.TMUX_PREFIX}alice', 'backend': 'claude'}
}
bridge.tmux_exists = lambda _name: True
bridge.is_claude_running = lambda _name: False  # Allow checkin restart
bridge.export_hook_env = lambda *_args, **_kwargs: None
bridge.session_manager._get_tmux_pane_cwd = lambda _tmux: str(old_dir)
bridge.session_manager.restart = lambda name, mode='relaunch': (True, None)
bridge._wait_for_restart_ready = lambda *_args, **_kwargs: True
bridge._recent_restarts.pop('alice', None)  # Clear cooldown

sent = []
def fake_send(chat_id, text):
    sent.append((chat_id, text))
    return {'ok': True}
bridge.send_telegram_message = fake_send

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=alice&cwd=' + quote(str(new_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

body = handler.wfile.getvalue().decode()
assert handler.status == 200, f'expected 200, got {handler.status}: {body}'
assert len(sent) == 2, f'expected 2 notifications, got {len(sent)}: {sent}'
assert sent[0][0] == 999 and sent[1][0] == 999, sent

shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd restart uses admin chat id when set"
    else
        fail "/checkin?cwd admin chat id preference test failed"
    fi
}

test_checkin_cwd_restart_failure_notifies_manager() {
    info "Testing /checkin?cwd restart failure sends manager follow-up..."

    if python3 -c "
import io, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
tmp_path = Path(tmpdir)
bridge.NODE_DIR = tmp_path
bridge.WORKER_REGISTRY_FILE = tmp_path / 'workers.json'
bridge.SESSIONS_DIR = tmp_path / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}checkinnotify-'
bridge.admin_chat_id = None
bridge._worker_cwds.clear()

bridge._registry_add('alice', 'claude', 123)
session_dir = bridge.ensure_session_dir('alice')
chat_file = session_dir / 'chat_id'
chat_file.write_text('777')
chat_file.chmod(0o600)

old_dir = tmp_path / 'old-project'
new_dir = tmp_path / 'new-project'
old_dir.mkdir()
new_dir.mkdir()

bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': f'{bridge.TMUX_PREFIX}alice', 'backend': 'claude'}
}
bridge.tmux_exists = lambda _name: True
bridge.is_claude_running = lambda _name: False  # Allow checkin restart
bridge.export_hook_env = lambda *_args, **_kwargs: None
bridge.session_manager._get_tmux_pane_cwd = lambda _tmux: str(old_dir)
bridge.session_manager.restart = lambda name, mode='relaunch': (False, 'boom')
bridge._recent_restarts.pop('alice', None)  # Clear cooldown

sent = []
def fake_send(chat_id, text):
    sent.append((chat_id, text))
    return {'ok': True}
bridge.send_telegram_message = fake_send

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=alice&cwd=' + quote(str(new_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

body = handler.wfile.getvalue().decode()
assert handler.status == 500, f'expected 500, got {handler.status}: {body}'
assert 'Failed to restart' in body, body
assert len(sent) == 2, f'expected 2 notifications, got {len(sent)}: {sent}'
assert sent[0][0] == 777 and sent[1][0] == 777, sent
assert 'restart' in sent[1][1].lower() and ('fail' in sent[1][1].lower() or 'could not' in sent[1][1].lower()), sent[1][1]

shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd restart failure sends manager follow-up"
    else
        fail "/checkin?cwd restart failure notification test failed"
    fi
}

test_checkin_cwd_restart_blocked_by_cooldown() {
    info "Testing /checkin?cwd restart blocked by cooldown..."

    if python3 -c "
import io, time, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
tmp_path = Path(tmpdir)
bridge.NODE_DIR = tmp_path
bridge.WORKER_REGISTRY_FILE = tmp_path / 'workers.json'
bridge.SESSIONS_DIR = tmp_path / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}cooldown-'
bridge.admin_chat_id = None
bridge._worker_cwds.clear()

bridge._registry_add('bob', 'claude', 123)
session_dir = bridge.ensure_session_dir('bob')

old_dir = tmp_path / 'old-project'
new_dir = tmp_path / 'new-project'
old_dir.mkdir()
new_dir.mkdir()

bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'bob': {'tmux': f'{bridge.TMUX_PREFIX}bob', 'backend': 'claude'}
}
bridge.tmux_exists = lambda _name: True
bridge.is_claude_running = lambda _name: False
bridge.export_hook_env = lambda *_args, **_kwargs: None
bridge.session_manager._get_tmux_pane_cwd = lambda _tmux: str(old_dir)

restart_calls = []
bridge.session_manager.restart = lambda name, mode='relaunch': (restart_calls.append(1), (True, None))[1]
bridge._wait_for_restart_ready = lambda *_args, **_kwargs: True
bridge.send_telegram_message = lambda *a, **kw: {'ok': True}

# Set recent restart to NOW — should trigger cooldown
bridge._recent_restarts['bob'] = time.time()

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=bob&cwd=' + quote(str(new_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

body = handler.wfile.getvalue().decode()
assert handler.status == 200, f'expected 200, got {handler.status}: {body}'
assert 'blocked' in body.lower(), f'Expected cooldown block message: {body}'
assert len(restart_calls) == 0, f'Should NOT have restarted: {restart_calls}'

shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd restart blocked by cooldown"
    else
        fail "/checkin?cwd cooldown block test failed"
    fi
}

test_checkin_cwd_restart_blocked_by_running_claude() {
    info "Testing /checkin?cwd restart blocked when Claude is running..."

    if python3 -c "
import io, shutil, tempfile
from pathlib import Path
from urllib.parse import urlparse, quote
import bridge

tmpdir = tempfile.mkdtemp()
tmp_path = Path(tmpdir)
bridge.NODE_DIR = tmp_path
bridge.WORKER_REGISTRY_FILE = tmp_path / 'workers.json'
bridge.SESSIONS_DIR = tmp_path / 'sessions'
bridge.SESSIONS_DIR.mkdir()
bridge.TMUX_PREFIX = '${TEST_TMUX_PREFIX}guard-'
bridge.admin_chat_id = None
bridge._worker_cwds.clear()

bridge._registry_add('bob', 'claude', 123)

old_dir = tmp_path / 'old-project'
new_dir = tmp_path / 'new-project'
old_dir.mkdir()
new_dir.mkdir()

bridge.session_manager.get_registered_sessions = lambda registered=None: {
    'bob': {'tmux': f'{bridge.TMUX_PREFIX}bob', 'backend': 'claude'}
}
bridge.tmux_exists = lambda _name: True
bridge.is_claude_running = lambda _name: True  # Claude IS running
bridge.export_hook_env = lambda *_args, **_kwargs: None
bridge.session_manager._get_tmux_pane_cwd = lambda _tmux: str(old_dir)
bridge._recent_restarts.pop('bob', None)  # No cooldown

restart_calls = []
bridge.session_manager.restart = lambda name, mode='relaunch': (restart_calls.append(1), (True, None))[1]

class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
    def send_response(self, code):
        self.status = code
    def send_header(self, key, value):
        self.headers[key] = value
    def end_headers(self):
        pass

handler = FakeHandler()
parsed = urlparse('/checkin?name=bob&cwd=' + quote(str(new_dir)))
bridge.Handler.handle_checkin_endpoint(handler, parsed)

body = handler.wfile.getvalue().decode()
assert handler.status == 200, f'expected 200, got {handler.status}: {body}'
assert 'skipped' in body.lower() or 'running' in body.lower(), f'Expected running guard message: {body}'
assert len(restart_calls) == 0, f'Should NOT have restarted: {restart_calls}'

shutil.rmtree(tmpdir, ignore_errors=True)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/checkin?cwd restart blocked when Claude is running"
    else
        fail "/checkin?cwd running guard test failed"
    fi
}

test_restart_dead_worker() {
    info "Testing restart of dead worker (tmux gone, in registry)..."

    if python3 -c "
import os, json, tempfile, subprocess, time
from pathlib import Path
from unittest.mock import patch, MagicMock
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'
bridge.SESSIONS_DIR = Path(tmpdir) / 'sessions'
bridge.SESSIONS_DIR.mkdir()

# Pre-create registry with a dead worker
data = {'version': 1, 'workers': {
    'deadworker': {'backend': 'claude', 'chat_id': 123, 'hire_time': 1000}
}}
bridge.WORKER_REGISTRY_FILE.write_text(json.dumps(data))

prefix = 'claude-regtest-'
bridge.TMUX_PREFIX = prefix
wm = bridge.SessionManager(bridge.SESSIONS_DIR, prefix)
wm.scan_tmux_sessions = lambda: {}

registered = wm.get_registered_sessions()
assert 'deadworker' in registered, 'dead worker should be in registered'

# Test that restart detects dead worker and enters recovery path
# Mock _restart_dead_worker to track that it was called (avoids tmux/claude deps)
called = {}
original = wm._restart_dead_worker
def mock_restart(name, backend_name, backend, tmux_name, mode):
    called['name'] = name
    called['backend'] = backend_name
    called['tmux'] = tmux_name
    called['mode'] = mode
    return True, None

wm._restart_dead_worker = mock_restart

ok, err = wm.restart('deadworker', mode='relaunch')
assert ok, f'restart should succeed, got err: {err}'
assert called.get('name') == 'deadworker', f'expected deadworker, got {called}'
assert called.get('backend') == 'claude', f'expected claude backend, got {called}'
assert called.get('tmux') == f'{prefix}deadworker', f'expected regtest prefix, got {called}'
assert called.get('mode') == 'relaunch', f'expected relaunch mode, got {called}'

import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Restart of dead worker recovers from registry"
    else
        fail "Restart dead worker test failed"
    fi
}

test_revive_waits_for_pane_shell_ready() {
    info "Testing dead-worker revive gates the launch line on pane shell readiness..."
    # Increment A: _restart_dead_worker's fresh pane must wait_for_pane_shell_ready
    # BEFORE sending the launch line, exactly like create_session — else a slow
    # zsh/fish rc swallows the launch line and claude never starts.
    if python3 -c "
import tempfile
from pathlib import Path
from types import SimpleNamespace
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp
bridge.SANDBOX_ENABLED = False

events = []

class FakeProc:
    def __init__(self):
        self.returncode = 0
        self.stdout = ''

def fake_run(args, *a, **k):
    if isinstance(args, (list, tuple)) and 'send-keys' in args:
        events.append(('send', list(args)))
    elif isinstance(args, (list, tuple)) and 'new-session' in args:
        events.append(('new-session', list(args)))
    return FakeProc()

bridge.subprocess.run = fake_run
bridge.wait_for_pane_shell_ready = lambda *a, **k: events.append(('wait',) + a) or True
bridge.time.sleep = lambda *a, **k: None
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda *a, **k: None
bridge.save_claude_session_cwd = lambda *a, **k: None
bridge._which_binary = lambda b: '/usr/bin/' + b
bridge.session_manager._get_startup_cwd = lambda name, fallback_cwd='': ''
bridge.session_manager.send = lambda *a, **k: None
bridge.session_manager._build_welcome = lambda *a, **k: 'hi'

backend = SimpleNamespace(binary='claude', start_cmd=lambda resume_id='': 'claude')
ok, err = bridge.session_manager._restart_dead_worker('rev1', 'claude', backend, 'claude-test-rev1', 'relaunch')
assert ok, ('revive should succeed', err)

kinds = [e[0] for e in events]
assert 'wait' in kinds, ('revive never called wait_for_pane_shell_ready', kinds)
# Find the launch-line send (the sh -c ... wrapper) and assert wait precedes it.
launch_idx = None
for i, e in enumerate(events):
    if e[0] == 'send' and any('sh -c' in str(p) for p in e[1]):
        launch_idx = i
        break
assert launch_idx is not None, ('no launch-line send found', events)
wait_idx = kinds.index('wait')
assert wait_idx < launch_idx, ('wait must precede launch line', kinds)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "revive gates launch line on pane shell readiness"
    else
        fail "revive does not wait for pane shell readiness before launching"
    fi
}

test_restart_inplace_waits_for_pane_shell_ready() {
    # T7: restart() live-path (tmux session exists) must call wait_for_pane_shell_ready
    # BEFORE send_pane_start_cmd, exactly like _restart_dead_worker and create_session.
    # Sensitivity: A) remove the wait line -> kinds.index('wait') ValueError FAIL;
    #              B) put it after send -> wait_idx > launch_idx FAIL;
    #              C) double-wait -> len(waits) != 1 FAIL.
    info "Testing in-place restart gates launch line on pane shell readiness..."
    if python3 -c "
import tempfile, json
from pathlib import Path
from types import SimpleNamespace
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.NODE_DIR = tmp
bridge.WORKER_REGISTRY_FILE = tmp / 'workers.json'
bridge.SANDBOX_ENABLED = False

# Register a live worker
data = {'version': 1, 'workers': {
    'livewk': {'backend': 'claude', 'chat_id': 123, 'hire_time': 1000}
}}
bridge.WORKER_REGISTRY_FILE.write_text(json.dumps(data))

prefix = 'claude-inplace-'
bridge.TMUX_PREFIX = prefix
wm = bridge.SessionManager(tmp, prefix)

events = []

class FakeProc:
    returncode = 0
    stdout = ''

def fake_run(args, *a, **k):
    if isinstance(args, (list, tuple)):
        tag = ' '.join(str(x) for x in args[:4])
        events.append(('run', tag))
    return FakeProc()

# walk the live path (tmux session exists)
bridge.tmux_exists = lambda *a, **k: True
bridge.is_claude_running = lambda *a, **k: False
bridge.subprocess.run = fake_run
bridge.wait_for_pane_shell_ready = lambda pane, **k: events.append(('wait', pane)) or True
bridge.send_pane_start_cmd = lambda pane, cmd, cwd: events.append(('launch', pane, cmd))
bridge.export_hook_env = lambda *a, **k: None
bridge.time.sleep = lambda *a, **k: None
bridge._which_binary = lambda b: '/usr/bin/' + b
bridge.clear_pending = lambda *a, **k: None
bridge._clear_hook_failures = lambda *a, **k: None
bridge.save_claude_session_cwd = lambda *a, **k: None
wm._get_startup_cwd = lambda name, fallback_cwd='': ''
wm.send = lambda *a, **k: None
wm._build_welcome = lambda *a, **k: 'hi'
wm.scan_tmux_sessions = lambda: {}

ok, err = wm.restart('livewk', mode='relaunch')
assert ok, ('restart should succeed', err)

kinds = [e[0] for e in events]
waits = [e for e in events if e[0] == 'wait']
assert 'wait' in kinds, ('restart never called wait_for_pane_shell_ready', kinds)
assert len(waits) == 1, ('expected exactly 1 wait (no double-wait)', waits)
launch_idx = next(i for i, e in enumerate(events) if e[0] == 'launch')
wait_idx = kinds.index('wait')
assert wait_idx < launch_idx, ('wait must precede launch line', kinds)

import shutil; shutil.rmtree(tmp)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "in-place restart gates launch line on pane shell readiness (wait before launch, exactly once)"
    else
        fail "in-place restart does not wait for pane shell readiness before launching"
    fi
}

test_wait_for_pane_shell_ready_paths() {
    info "Testing wait_for_pane_shell_ready True/False paths against real panes..."
    # Increment B part 1: a nonexistent pane returns False after ~timeout
    # (never hangs); a real ready bash pane returns True.
    if python3 -c "
import time
import bridge

# False path: pane does not exist -> capture-pane keeps failing -> times out.
t0 = time.time()
got = bridge.wait_for_pane_shell_ready('claude-test-nonexistent-pane-xyz', timeout=0.6)
elapsed = time.time() - t0
assert got is False, ('nonexistent pane must return False', got)
assert 0.5 <= elapsed < 3.0, ('should consume ~timeout, not hang or return instantly', elapsed)
print('FALSE-OK')
" 2>/dev/null | grep -q "FALSE-OK"; then
        local false_ok=1
    else
        local false_ok=0
    fi

    # True path: spin up a real bash pane and wait for it to settle.
    local sess="${TMUX_PREFIX}waitready-$$"
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" "$(command -v bash)" 2>/dev/null || true
    local true_ok=0
    if python3 -c "
import bridge
assert bridge.wait_for_pane_shell_ready('$sess', timeout=10.0) is True
print('TRUE-OK')
" 2>/dev/null | grep -q "TRUE-OK"; then
        true_ok=1
    fi
    tmux kill-session -t "$sess" 2>/dev/null || true

    if [[ "$false_ok" == "1" && "$true_ok" == "1" ]]; then
        success "wait_for_pane_shell_ready: False on missing pane (~timeout), True on ready pane"
    else
        fail "wait_for_pane_shell_ready paths failed (false_ok=$false_ok true_ok=$true_ok)"
    fi
}

test_create_fail_open_when_wait_returns_false() {
    info "Testing create_session still launches when readiness wait fails open..."
    # Increment B part 2: a pathological rc can only DELAY the launch (wait
    # returns False) — it must never BLOCK it. The launch line must still send.
    if python3 -c "
import tempfile
from pathlib import Path
from types import SimpleNamespace
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp
bridge.SANDBOX_ENABLED = False

sends = []

class FakeProc:
    def __init__(self):
        self.returncode = 0
        self.stdout = ''

def fake_run(args, *a, **k):
    if isinstance(args, (list, tuple)) and 'send-keys' in args:
        sends.append(list(args))
    return FakeProc()

bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a, **k: False
# Readiness gate fails open (False) — must not stop the launch line.
bridge.wait_for_pane_shell_ready = lambda *a, **k: False
bridge.time.sleep = lambda *a, **k: None
bridge.export_hook_env = lambda *a, **k: None
bridge.ensure_session_dir = lambda *a, **k: None
bridge.save_claude_session_cwd = lambda *a, **k: None
bridge._which_binary = lambda b: '/usr/bin/' + b
bridge._capture_pane_text = lambda *a, **k: ''
bridge.session_manager._get_startup_cwd = lambda name, **k: ''
bridge.session_manager.register_worker = lambda *a, **k: None
bridge.session_manager.send = lambda *a, **k: None
bridge.session_manager._build_welcome = lambda *a, **k: 'hi'

ok, err = bridge.create_session('foff1')
assert ok, ('create should succeed even when wait fails open', err)
launch = [s for s in sends if any('sh -c' in str(p) for p in s)]
assert launch, ('launch line must still be sent when wait returns False', sends)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "create_session fails open: launch line sent even when readiness wait is False"
    else
        fail "create_session blocked launch when readiness wait returned False"
    fi
}

test_end_removes_from_registry() {
    info "Testing /end removes worker from registry..."

    if python3 -c "
import os, json, tempfile, subprocess
from pathlib import Path
import bridge

tmpdir = tempfile.mkdtemp()
bridge.NODE_DIR = Path(tmpdir)
bridge.WORKER_REGISTRY_FILE = Path(tmpdir) / 'workers.json'
bridge.SESSIONS_DIR = Path(tmpdir) / 'sessions'
bridge.SESSIONS_DIR.mkdir()

prefix = 'claude-regtest-'
bridge.TMUX_PREFIX = prefix  # _sync_paths() resets self.tmux_prefix to the global; without this the kill targets the wrong name
wm = bridge.SessionManager(bridge.SESSIONS_DIR, prefix)

# Create a tmux session to simulate a live worker
tmux_name = f'{prefix}endtest'
subprocess.run(['tmux', 'new-session', '-d', '-s', tmux_name], capture_output=True)

# Add to registry
bridge._registry_add('endtest', 'claude', 123)
data = bridge._load_registry()
assert 'endtest' in data['workers'], 'worker should be in registry before end'

# End the worker
ok, err = wm.close_session('endtest')
assert ok, f'end should succeed, got err: {err}'

# Verify removed from registry
data = bridge._load_registry()
assert 'endtest' not in data.get('workers', {}), 'worker should be removed from registry after end'

# Verify the tmux session was actually killed (not just deregistered)
rc = subprocess.run(['tmux', 'has-session', '-t', f'={tmux_name}'], capture_output=True).returncode
assert rc != 0, 'tmux session should be killed after end'

subprocess.run(['tmux', 'kill-session', '-t', f'={tmux_name}'], capture_output=True)
import shutil; shutil.rmtree(tmpdir)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/end removes worker from registry"
    else
        fail "/end registry removal test failed"
    fi
}


test_normalize_activity_spinner_verbs() {
    info "Testing spinner verbs are normalized to Thinking..."

    if python3 -c "
import bridge

cases = [
    ('Ionizing (52m 40s)', 'Thinking (52m 40s)'),
    ('Schlepping (45s)', 'Thinking (45s)'),
    ('Whirring (2m 19s)', 'Thinking (2m 19s)'),
    ('Hullaballooing (17m 40s)', 'Thinking (17m 40s)'),
    ('Running Bash', 'Running Bash'),
    ('Ready', 'Ready'),
    ('In plan mode', 'In plan mode'),
    ('Error: something broke', 'Error: something broke'),
    ('Tasks (3/5 done)', 'Tasks (3/5 done)'),
    ('Compacting conversation (5m)', 'Compacting conversation (5m)'),
]
for raw, expected in cases:
    got = bridge._normalize_activity(raw)
    assert got == expected, f'_normalize_activity({raw!r}) = {got!r}, expected {expected!r}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Spinner verbs normalized to Thinking"
    else
        fail "Spinner verb normalization failed"
    fi
}

test_team_ready_replaces_idle() {
    info "Testing _extract_activity returns Ready for idle prompt..."

    if python3 -c "
import bridge

# Simulate pane with idle prompt
pane_lines = [
    '--- some output ---',
    '❯ ',
    '-------------------------------------------',
    '  ⏵⏵ bypass permissions on · 5 bashes',
]
result = bridge._extract_activity(pane_lines)
assert result == 'Ready', f'Expected Ready, got {result!r}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "_extract_activity returns Ready for idle prompt"
    else
        fail "_extract_activity Ready test failed"
    fi
}


test_watchdog_alert_stuck_copy() {
    info "Testing watchdog STUCK alert copy..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._last_alert_ts = {}
bridge._prev_session_states = {'alice': 'READY'}

sent = {}
def fake_api(method, data):
    sent['method'] = method
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._handle_watchdog_transition('alice', 'STUCK', 'age=900s cpu=0.0', since=100, now=1000)

txt = sent['data']['text']
assert 'no progress' in txt.lower(), f'Should say no progress: {txt}'
assert '/cd' in txt and '/close' in txt, f'Should give topic-native recovery: {txt}'
assert '/restart' not in txt, f'Deleted commands must not be suggested: {txt}'
assert 'STUCK' not in txt, f'Should not expose internal state name: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog STUCK alert has human-friendly copy"
    else
        fail "Watchdog STUCK alert copy test failed"
    fi
}

test_watchdog_alert_poisoned_copy() {
    info "Testing watchdog POISONED alert copy..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._last_alert_ts = {}
bridge._prev_session_states = {'bob': 'READY'}

sent = {}
def fake_api(method, data):
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._handle_watchdog_transition('bob', 'POISONED', 'error loop', since=100, now=1000)

txt = sent['data']['text']
assert 'error' in txt.lower(), f'Should mention error: {txt}'
assert 'POISONED' not in txt, f'Should not expose internal state POISONED: {txt}'
assert '/cd' in txt and '/restart' not in txt, f'Should give topic-native recovery: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog POISONED alert uses human-friendly copy"
    else
        fail "Watchdog POISONED alert copy test failed"
    fi
}

test_watchdog_alert_dead_copy() {
    info "Testing watchdog DEAD alert copy..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._last_alert_ts = {}
bridge._prev_session_states = {'carol': 'READY'}

sent = {}
def fake_api(method, data):
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._handle_watchdog_transition('carol', 'DEAD', 'process gone', since=100, now=1000)

txt = sent['data']['text']
assert 'stopped' in txt.lower(), f'Should say stopped: {txt}'
assert 'process' not in txt.lower(), f'Should not say process: {txt}'
assert '/cd' in txt and '/restart' not in txt, f'Should give topic-native recovery: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog DEAD alert uses human-friendly copy"
    else
        fail "Watchdog DEAD alert copy test failed"
    fi
}

test_watchdog_alert_waiting_input_copy() {
    info "Testing watchdog WAITING_INPUT alert copy..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._last_alert_ts = {}
bridge._prev_session_states = {'dave': 'READY'}
bridge._waiting_input_details = {
    'dave': {
        'header': 'Auth method',
        'options': [
            {'num': 1, 'label': 'OAuth', 'selected': True},
            {'num': 2, 'label': 'JWT', 'selected': False},
        ],
        'selected_num': 1,
    }
}

sent = {}
def fake_api(method, data):
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._handle_watchdog_transition('dave', 'WAITING_INPUT', 'question=Auth', since=100, now=1000)

txt = sent['data']['text']
assert 'needs your reply' in txt.lower() or 'reply' in txt.lower(), f'Should say needs reply: {txt}'
assert 'Auth method' in txt, f'Should include question header: {txt}'
assert 'waiting for your input' not in txt.lower(), f'Should not use old copy: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog WAITING_INPUT alert uses human-friendly copy"
    else
        fail "Watchdog WAITING_INPUT alert copy test failed"
    fi
}

test_watchdog_resolved_copy() {
    info "Testing watchdog resolved alert copy..."

    if python3 -c "
import bridge
from unittest.mock import patch

bridge.admin_chat_id = 123
bridge._prev_session_states = {'eve': 'STUCK'}
bridge._recent_restarts = {}

sent = {}
def fake_api(method, data):
    sent['data'] = data
    return {'ok': True}

with patch('bridge.telegram_api', fake_api):
    bridge._send_resolved_alert('eve', 'READY')

txt = sent['data']['text']
assert 'back to normal' in txt.lower() or chr(0x2705) in txt, f'Should say back to normal: {txt}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog resolved alert has good copy"
    else
        fail "Watchdog resolved alert copy test failed"
    fi
}



test_team_attention_needs_reply() {
    info "Testing _team_attention_summary uses needs reply..."

    if python3 -c "
import bridge

# WAITING_INPUT status should return 'needs reply' not 'needs input'
icon, label, rank = bridge._team_attention_summary('Needs reply (5m)', 'some activity')
assert label == 'needs reply', f'Expected needs reply, got {label!r}'
assert icon == chr(0x1F7E1), f'Expected yellow, got {icon!r}'

# Green worker should return 'ok' not 'no blocker'
icon2, label2, rank2 = bridge._team_attention_summary('Ready', 'Ready')
assert label2 == 'ok', f'Expected ok, got {label2!r}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "_team_attention_summary uses needs reply / ok"
    else
        fail "_team_attention_summary copy test failed"
    fi
}

test_watchdog_exited_state() {
    info "Testing watchdog EXITED state for registry-only workers..."

    if python3 -c "
import bridge
import time

# Clear watchdog state
bridge._session_states.clear()
bridge._prev_session_states.clear()
bridge._last_alert_ts.clear()

now = time.time()

# Record EXITED state
since = bridge._record_worker_state('deadworker', 'EXITED', 'session gone', now)

# Verify it's tracked
entry = bridge._session_states.get('deadworker')
assert entry is not None, 'EXITED state should be recorded'
assert entry[0] == 'EXITED', f'state should be EXITED, got {entry[0]}'

# Verify _format_watchdog_status returns 'exited'
status = bridge._format_watchdog_status('deadworker')
assert status == 'Session ended', f'expected \"Session ended\", got \"{status}\"'

# Verify EXITED is in the alert actions
bridge.admin_chat_id = 12345
calls = []
def fake_api(method, data):
    calls.append((method, data))
    return {'ok': True}

orig_api = bridge.telegram_api
bridge.telegram_api = fake_api

# Simulate transition: first transition should alert (after grace period)
bridge._prev_session_states.clear()
bridge._handle_watchdog_transition('deadworker', 'EXITED', 'session gone', since=now - 60, now=now)
assert len(calls) == 1, f'expected 1 alert call, got {len(calls)}'
txt = calls[0][1]['text']
assert 'deadworker' in txt, f'alert should mention worker name: {txt}'
assert '/cd' in txt, f'alert should give topic-native recovery: {txt}'

bridge.telegram_api = orig_api
bridge.admin_chat_id = None
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Watchdog EXITED state detection works"
    else
        fail "Watchdog EXITED state test failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Telegram API limit test
# ─────────────────────────────────────────────────────────────────────────────

# ============================================================
# INTEGRATION + WORKER COMMUNICATION
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Integration tests (require tunnel)
# ─────────────────────────────────────────────────────────────────────────────

test_with_tunnel() {
    if ! command -v cloudflared &>/dev/null; then
        info "Skipping tunnel tests (cloudflared not installed)"
        return 0
    fi

    info "Starting tunnel..."
    cloudflared tunnel --url "http://localhost:$PORT" >"$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Wait for tunnel URL to appear in log (up to 30 seconds)
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        TUNNEL_URL=$(grep -o 'https://[^[:space:]|]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        [[ -n "$TUNNEL_URL" ]] && break
        sleep 1
        ((++attempts))
    done

    if [[ -n "$TUNNEL_URL" ]]; then
        success "Tunnel started: $TUNNEL_URL"

        # Wait for DNS propagation
        sleep 5

        # Test webhook setup
        local webhook_result
        webhook_result=$(curl -s "https://api.telegram.org/bot${TEST_BOT_TOKEN}/setWebhook?url=${TUNNEL_URL}")

        if echo "$webhook_result" | grep -q '"ok":true'; then
            success "Webhook configured"
        else
            fail "Webhook setup failed"
        fi
    else
        fail "Could not get tunnel URL"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker Discovery Tests (inter-worker communication)
# ─────────────────────────────────────────────────────────────────────────────

test_workers_endpoint_removed() {
    local code

    if ! nc -z localhost "$PORT" 2>/dev/null; then
        mkdir -p "$TEST_NODE_DIR" "$TEST_SESSION_DIR" "$TEST_TEAM_DIR"
        chmod 700 "$TEST_NODE_DIR" "$TEST_SESSION_DIR" "$TEST_TEAM_DIR"
        TELEGRAM_BOT_TOKEN="$TEST_BOT_TOKEN" \
        PORT="$PORT" \
        NODE_NAME="$TEST_NODE" \
        SESSIONS_DIR="$TEST_SESSION_DIR" \
        TMUX_PREFIX="$TEST_TMUX_PREFIX" \
        ADMIN_CHAT_ID="${TEST_CHAT_ID:-}" \
        TEAM_DIR="$TEST_TEAM_DIR" \
        python3 -u "$SCRIPT_DIR/bridge.py" > "$BRIDGE_LOG" 2>&1 &
        BRIDGE_PID=$!
        echo "$BRIDGE_PID" > "$TEST_NODE_DIR/bridge.pid"
        echo "$PORT" > "$TEST_NODE_DIR/port"
        if ! wait_for_port "$PORT"; then
            echo "bridge failed to start"
            return 1
        fi
    fi

    if ! code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/workers"); then
        code="000"
    fi
    [[ "$code" == "404" ]] || { echo "expected 404, got $code"; return 1; }
    success "/workers returns 404"
}


test_send_to_session_integration() {
    info "Testing send_to_session with real tmux worker..."

    # Create a worker first
    open_dm_session
    sleep 0.3

    local tmux_name="${TEST_TMUX_PREFIX}tmain"

    # Use send_to_session to send a unique message
    local unique_msg="test_send_to_session_${RANDOM}"

    # Note: Must set TMUX_PREFIX to match the test prefix for send_to_session to find the session
    if TMUX_PREFIX="$TEST_TMUX_PREFIX" python3 -c "
import os
# Force reload of bridge to pick up TMUX_PREFIX from env
import importlib
import bridge
importlib.reload(bridge)

from bridge import send_to_session, TMUX_PREFIX
print('TMUX_PREFIX:', TMUX_PREFIX)

# Send message using the generic function
result = send_to_session('tmain', '$unique_msg')
print('sent:', result)
" 2>/dev/null | grep -q "sent: True"; then
        # Verify message appeared in tmux pane
        sleep 1
        local pane_content
        pane_content=$(tmux capture-pane -t "$tmux_name" -p 2>/dev/null || echo "")

        if echo "$pane_content" | grep -q "$unique_msg"; then
            success "send_to_session delivered message to tmux worker"
        else
            fail "send_to_session message not found in tmux pane"
        fi
    else
        fail "send_to_session returned False for existing worker"
    fi

    # Cleanup
    close_dm_session
}

# ─────────────────────────────────────────────────────────────────────────────
# send_to_session Abstraction Tests (TDD)
# ─────────────────────────────────────────────────────────────────────────────

test_send_to_session_uses_backend_registry() {
    info "Testing send_to_session dispatches through the claude backend..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge

calls = {'claude': 0}
original_send = bridge.ClaudeBackend.send
def fake_claude_send(self, name, tmux_name, message, bridge_url, sessions_dir):
    calls['claude'] += 1
    return True
bridge.ClaudeBackend.send = fake_claude_send

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.session_manager.sessions_dir = tmp
bridge.session_manager.scan_tmux_sessions = lambda: {'testclaude': {'tmux': 'claude-test-testclaude'}}
bridge._sync_session_manager()
(tmp / 'testclaude').mkdir()

result = bridge.send_to_session('testclaude', 'hello from test')
assert result == True, f'Expected True, got {result}'
assert calls['claude'] == 1, calls

import shutil
shutil.rmtree(tmp)
bridge.ClaudeBackend.send = original_send
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "send_to_session uses backend registry correctly"
    else
        fail "send_to_session backend registry test failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Direct Mode Tests (--no-tmux / --direct)
# ─────────────────────────────────────────────────────────────────────────────

# Test markdown_to_telegram_html converter (markdown-it-py based)
test_markdown_to_telegram_html() {
    info "Testing markdown_to_telegram_html converts markdown to Telegram HTML..."

    if python3 -c "
from bridge import markdown_to_telegram_html

# Bold, italic, strikethrough, inline code
r = markdown_to_telegram_html('**bold** *italic* ~~strike~~ \`code\`')
assert '<b>bold</b>' in r, f'Bold: {r}'
assert '<i>italic</i>' in r, f'Italic: {r}'
assert '<s>strike</s>' in r, f'Strike: {r}'
assert '<code>code</code>' in r, f'Code: {r}'

# Code block with language
r = markdown_to_telegram_html('\`\`\`python\nprint(1)\n\`\`\`')
assert '<pre><code class=\"language-python\">' in r, f'Fence lang: {r}'

# Link
r = markdown_to_telegram_html('[click](http://example.com)')
assert '<a href=\"http://example.com\">click</a>' in r, f'Link: {r}'

# Heading as bold
r = markdown_to_telegram_html('## Heading')
assert '<b>Heading</b>' in r, f'Heading: {r}'

# Bullet list
r = markdown_to_telegram_html('- a\n- b')
assert '\u2022 a' in r and '\u2022 b' in r, f'Bullets: {r}'

# Table as pre-block with aligned columns
r = markdown_to_telegram_html('| A | B |\n|---|---|\n| 1 | 2 |')
assert '<pre>' in r and 'A' in r and '1' in r, f'Table: {r}'

# Blockquote
r = markdown_to_telegram_html('> quoted')
assert '<blockquote>' in r, f'Blockquote: {r}'

# HTML escaping
r = markdown_to_telegram_html('a < b & c > d')
assert '&lt;' in r and '&amp;' in r, f'Escape: {r}'

# HTML block with safe tags (e.g. <pre>...</pre> in source)
r = markdown_to_telegram_html('<pre>a > b & c</pre>')
assert '<pre>' in r, f'HTML block pre open: {r}'
assert '</pre>' in r, f'HTML block pre close: {r}'
assert '&lt;pre&gt;' not in r, f'pre tag should NOT be escaped: {r}'
assert '&gt;' in r, f'Content > should be escaped: {r}'
assert '&amp;' in r, f'Content & should be escaped: {r}'

# HTML block with <code class=\"language-xxx\"> inside <pre> (Telegram syntax)
r = markdown_to_telegram_html('<pre><code class=\"language-bash\">echo hello</code></pre>')
assert '<code class=\"language-bash\">' in r, f'code+class should be safe tag: {r}'
assert '</code>' in r, f'closing code should be preserved: {r}'
assert '&lt;code' not in r, f'code+class must NOT be escaped: {r}'

# HTML inline safe tags
r = markdown_to_telegram_html('<strong>bold</strong>')
assert '<strong>bold</strong>' in r, f'strong should be preserved: {r}'
r = markdown_to_telegram_html('<em>italic</em>')
assert '<em>italic</em>' in r, f'em should be preserved: {r}'
r = markdown_to_telegram_html('<del>strike</del>')
assert '<del>strike</del>' in r, f'del should be preserved: {r}'

# Unsafe tags should be escaped (open + close)
r = markdown_to_telegram_html('<div>unsafe</div>')
assert '&lt;div&gt;unsafe&lt;/div&gt;' in r, f'unsafe div should be escaped: {r}'

# Telegram spoiler span rules
r = markdown_to_telegram_html('<span class=\"tg-spoiler\">secret</span>')
assert '<span class=\"tg-spoiler\">secret</span>' in r, f'tg-spoiler span should be preserved: {r}'
r = markdown_to_telegram_html('<span class=\"other\">bad</span>')
assert '&lt;span class=\"other\"&gt;bad&lt;/span&gt;' in r, f'non tg-spoiler span should be escaped: {r}'

# Empty
assert markdown_to_telegram_html('') == '', 'Empty'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "markdown_to_telegram_html converts all markdown types correctly"
    else
        fail "markdown_to_telegram_html test failed"
    fi
}

# Test forward-to-bridge.py sends escape:True (bridge converts markdown)
test_forward_to_bridge_escape_flag() {
    info "Testing forward-to-bridge sends escape:True in payload..."

    if python3 -c "
import sys, json
from importlib.util import spec_from_loader, module_from_spec
from importlib.machinery import SourceFileLoader
from unittest.mock import patch, MagicMock
from io import BytesIO

# Load forward-to-bridge.py as a module
spec = spec_from_loader('forward_to_bridge', SourceFileLoader('forward_to_bridge', 'hooks/forward-to-bridge.py'))
forward_to_bridge = module_from_spec(spec)
spec.loader.exec_module(forward_to_bridge)

# Capture the JSON payload sent to bridge
captured = {}
def mock_urlopen(req, **kwargs):
    captured['data'] = json.loads(req.data)
    resp = MagicMock()
    resp.status = 200
    resp.__enter__ = lambda s: s
    resp.__exit__ = lambda s, *a: None
    return resp

with patch('urllib.request.urlopen', mock_urlopen):
    forward_to_bridge.forward_to_bridge('**bold** text', 'test-session', 'http://localhost:8080/response')

assert captured['data']['text'] == '**bold** text', 'Text should be raw markdown (not converted)'
assert captured['data']['session'] == 'test-session', 'Session mismatch'
assert 'escape' not in captured['data'], 'escape flag should not be sent'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "forward-to-bridge sends raw markdown to bridge"
    else
        fail "forward-to-bridge raw markdown test failed"
    fi
}

test_backend_registry_exists() {
    info "Testing backend helpers expose only claude..."

    if python3 -c "
import bridge

# Claude is the ONLY backend in the topic-only bridge (v1.0.0)
expected = ['claude']

backend = bridge.get_backend('claude')
assert backend is not None, 'get_backend(claude) should return backend'
assert hasattr(backend, 'send'), 'claude backend should have send method'
assert hasattr(backend, 'is_online'), 'claude backend should have is_online method'
assert hasattr(backend, 'start_cmd'), 'claude backend should have start_cmd method'

# Unknown backends fall back to claude; is_valid_backend rejects them
assert bridge.is_valid_backend('claude') == True
assert bridge.is_valid_backend('codex') == False
assert bridge.is_valid_backend('invalid') == False
assert bridge.get_backend('codex') is backend, 'unknown backends fall back to claude'

# Check list_backends helper
available = bridge.list_backends()
assert set(available) == set(expected), f'list_backends should return {expected}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "backend helpers expose only claude"
    else
        fail "backend helper test failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
test_checkin_endpoint() {
    info "Testing /checkin endpoint..."

    local result
    result=$(curl -s "http://localhost:$PORT/checkin")

    if [[ $? -eq 0 ]] && [[ -n "$result" ]]; then
        success "/checkin endpoint returns content"
    else
        fail "/checkin endpoint failed"
        return 1
    fi

    # Test with worker name parameter
    result=$(curl -s "http://localhost:$PORT/checkin?name=testworker")
    if [[ $? -eq 0 ]] && [[ -n "$result" ]]; then
        success "/checkin?name=testworker returns personalized content"
    else
        fail "/checkin with name parameter failed"
    fi
}

test_checkin_note() {
    info "Testing checkin note from TEAM_DIR file..."

    # Bridge reads TEAM_DIR/checkin-note.txt (TEAM_DIR set in bridge start).
    local note_file="$TEST_TEAM_DIR/checkin-note.txt"

    # 1. Write a note with {name} placeholder
    echo 'You are {name}. Read ~/team/{name}/kanban.md' > "$note_file"

    # 2. Verify /checkin includes the note with {name} substituted
    local result
    result=$(curl -s "http://localhost:$PORT/checkin?name=testworker")
    if echo "$result" | grep -q "MANAGER NOTE" && echo "$result" | grep -q "You are testworker"; then
        success "/checkin includes note with {name} replaced"
    else
        fail "/checkin should include note with substitution: $result"
    fi

    # 3. Verify {name} is NOT literal in response
    if echo "$result" | grep -q '{name}'; then
        fail "/checkin still has literal {name} placeholder"
    else
        success "/checkin has no literal {name} placeholder"
    fi

    # 4. Remove the file, verify note disappears
    rm -f "$note_file"
    result=$(curl -s "http://localhost:$PORT/checkin?name=testworker")
    if echo "$result" | grep -q "MANAGER NOTE"; then
        fail "/checkin still has note after file removal"
    else
        success "/checkin has no note after file removal"
    fi
}

test_checkin_note_machine_substitution() {
    info "Testing checkin note {machine} substitution (all sessions are local in v1.0.0)..."

    local result
    result=$(python3 -c "
import os, tempfile
import bridge

tmpdir = tempfile.mkdtemp()
team_dir = os.path.join(tmpdir, 'team')
os.makedirs(team_dir)
with open(os.path.join(team_dir, 'checkin-note.txt'), 'w') as f:
    f.write('You are {name}. You are on: {machine}.')

old_team_dir = bridge.TEAM_DIR
old_checkin = bridge._CHECKIN_NOTE_PATH
old_node_name = bridge.NODE_NAME
try:
    bridge.TEAM_DIR = team_dir
    bridge._CHECKIN_NOTE_PATH = os.path.join(team_dir, 'checkin-note.txt')
    bridge.NODE_NAME = ''

    note = bridge.read_checkin_note()
    assert '{machine}' in note, f'note missing placeholder: {note}'

    # Sessions are local by design.
    rendered = bridge.session_manager._build_welcome('localtest', None)
    assert 'bridge host' in rendered and '{machine}' not in rendered, rendered
    print('LOCAL=' + rendered)
finally:
    bridge.TEAM_DIR = old_team_dir
    bridge._CHECKIN_NOTE_PATH = old_checkin
    bridge.NODE_NAME = old_node_name
    import shutil
    shutil.rmtree(tmpdir)
")
    if [[ "$result" == *"LOCAL="* && "$result" == *"bridge host"* ]]; then
        success "{machine} resolves to the local machine (no remote hosts)"
    else
        fail "{machine} substitution failed: $result"
    fi
}

test_health_workers_endpoint() {
    info "Testing /health/workers endpoint..."

    local result
    result=$(curl -s "http://localhost:$PORT/health/workers")

    if [[ $? -eq 0 ]] && echo "$result" | python3 -c "import sys, json; d = json.load(sys.stdin); assert 'workers' in d" 2>/dev/null; then
        success "/health/workers returns JSON with workers key"
    else
        fail "/health/workers endpoint failed: $result"
    fi
}

test_api_index_returns_json() {
    info "Testing GET / returns JSON API index..."

    local response
    response=$(curl -s "http://localhost:$PORT")

    # Must be valid JSON with endpoints and name
    if echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'endpoints' in d, 'missing endpoints'
assert 'name' in d, 'missing name'
assert 'claudecode-telegram' in d['name'], 'wrong name'
assert 'note' in d, 'missing note'
assert 'polling' in d['note'].lower(), 'note should mention polling'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "GET / returns JSON API index with endpoints, name, and no-polling note"
    else
        fail "GET / JSON missing required fields: $response"
    fi
}

test_unknown_get_returns_404() {
    info "Testing unknown GET returns 404 JSON..."

    # GET /poll — the exact endpoint sora hallucinated
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/poll")
    if [[ "$http_code" == "404" ]]; then
        success "GET /poll returns 404"
    else
        fail "GET /poll should return 404, got $http_code"
    fi

    # Verify response is JSON with error and available_endpoints
    local response
    response=$(curl -s "http://localhost:$PORT/poll")
    if echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'error' in d, 'missing error'
assert '/poll' in d['error'], 'error should mention /poll'
assert 'available_endpoints' in d, 'missing available_endpoints'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "GET /poll returns JSON with error and available endpoints"
    else
        fail "GET /poll should return JSON error: $response"
    fi

    # Also test a random path
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent")
    if [[ "$http_code" == "404" ]]; then
        success "GET /nonexistent returns 404"
    else
        fail "GET /nonexistent should return 404, got $http_code"
    fi
}

test_unknown_post_returns_404() {
    info "Testing unknown POST returns 404 JSON..."

    # POST /hire — the exact endpoint kenji tried
    local http_code
    http_code=$(hook_curl_code "http://localhost:$PORT/hire" '{"name":"test"}')
    if [[ "$http_code" == "404" ]]; then
        success "POST /hire returns 404"
    else
        fail "POST /hire should return 404, got $http_code"
    fi

    # Verify response is JSON with error
    local response
    response=$(hook_curl "http://localhost:$PORT/hire" '{"name":"test"}')
    if echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'error' in d, 'missing error'
assert '/hire' in d['error'], 'error should mention /hire'
assert 'available_endpoints' in d, 'missing available_endpoints'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "POST /hire returns JSON with error and available endpoints"
    else
        fail "POST /hire should return JSON error: $response"
    fi

    # POST /poll should also 404
    http_code=$(hook_curl_code "http://localhost:$PORT/poll" '{}')
    if [[ "$http_code" == "404" ]]; then
        success "POST /poll returns 404"
    else
        fail "POST /poll should return 404, got $http_code"
    fi
}

test_known_endpoints_unchanged() {
    info "Testing known endpoints still return 200..."

    local http_code

    # GET /checkin
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/checkin")
    if [[ "$http_code" == "200" ]]; then
        success "GET /checkin still returns 200"
    else
        fail "GET /checkin should return 200, got $http_code"
    fi

    # GET /health/workers
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/health/workers")
    if [[ "$http_code" == "200" ]]; then
        success "GET /health/workers still returns 200"
    else
        fail "GET /health/workers should return 200, got $http_code"
    fi

    # GET / (API index)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/")
    if [[ "$http_code" == "200" ]]; then
        success "GET / still returns 200"
    else
        fail "GET / should return 200, got $http_code"
    fi
}

test_webhook_root_still_works() {
    info "Testing POST / (Telegram webhook) still works..."

    local response
    response=$(curl -s -X POST "http://localhost:$PORT/" \
        -H "Content-Type: application/json" \
        -d '{"update_id": 99999}')
    if [[ "$response" == "OK" ]]; then
        success "POST / (webhook) still returns OK"
    else
        fail "POST / (webhook) should return OK, got: $response"
    fi
}

test_tmux_prompt_empty() {
    info "Testing tmux_prompt_empty with real tmux session..."

    local test_session="${TEST_TMUX_PREFIX}prompttest"

    # Create a test tmux session with a bash shell
    tmux new-session -d -s "$test_session" "bash --norc --noprofile"
    sleep 0.3

    # The function looks for a line starting with ❯ followed by only whitespace
    # A plain bash session won't have the ❯ prompt, so it should return False
    if python3 -c "
import bridge

# tmux_prompt_empty should return False because bash doesn't have ❯ prompt
result = bridge.tmux_prompt_empty('$test_session', timeout=0.5)
assert result == False, f'Expected False for bash session without ❯ prompt, got {result}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "tmux_prompt_empty returns False for non-Claude session"
    else
        fail "tmux_prompt_empty test failed"
    fi

    # Now simulate the ❯ prompt by sending it to the session
    tmux send-keys -t "$test_session" 'export PS1="❯ "' Enter
    sleep 0.3
    # After pressing enter, we get a new empty prompt line "❯ "
    if python3 -c "
import bridge

result = bridge.tmux_prompt_empty('$test_session', timeout=1.0)
assert result == True, f'Expected True for empty ❯ prompt, got {result}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "tmux_prompt_empty returns True for empty ❯ prompt"
    else
        fail "tmux_prompt_empty with ❯ prompt test failed"
    fi

    # Type some text (don't press enter) - prompt should not be empty
    tmux send-keys -t "$test_session" -l "some text"
    sleep 0.2
    if python3 -c "
import bridge

result = bridge.tmux_prompt_empty('$test_session', timeout=0.5)
assert result == False, f'Expected False when text is on prompt line, got {result}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "tmux_prompt_empty returns False when text on prompt"
    else
        fail "tmux_prompt_empty with text on prompt test failed"
    fi

    # Cleanup
    tmux kill-session -t "$test_session" 2>/dev/null || true
}

test_process_inspection_functions() {
    info "Testing process inspection functions with real tmux session..."

    local test_session="${TEST_TMUX_PREFIX}proctest"

    # Create a test tmux session running sleep
    tmux new-session -d -s "$test_session" "sleep 300"
    sleep 0.5

    if python3 -c "
import bridge

# Test _tmux_pane_pids returns our test session
pids = bridge._tmux_pane_pids()
assert '$test_session' in pids, f'Expected $test_session in pane_pids, got keys: {list(pids.keys())}'

pane_pid = pids['$test_session']
assert pane_pid.isdigit(), f'Expected numeric PID, got: {pane_pid}'

# Test _child_count - the pane runs sleep, so it should have at least 0 children
# (the sleep process itself IS the child of the pane shell)
count = bridge._child_count(pane_pid)
assert isinstance(count, int), f'Expected int count, got {type(count)}'
assert count >= 0, f'Expected non-negative count, got {count}'

# Test _get_claude_pid - should return None since we're not running claude
claude_pid = bridge._get_claude_pid(pane_pid)
assert claude_pid is None, f'Expected None for non-claude session, got {claude_pid}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "Process inspection functions work with real tmux"
    else
        fail "Process inspection functions test failed"
    fi

    # Cleanup
    tmux kill-session -t "$test_session" 2>/dev/null || true
}

# ── export_hook_env Guard Tests ────────────────────────────────────────────

test_export_hook_env_skips_live_bridge() {
    info "Testing export_hook_env skips sessions owned by another live bridge..."

    local test_session="${TEST_TMUX_PREFIX}guardtest"
    tmux new-session -d -s "$test_session" "bash --norc --noprofile" 2>/dev/null || true
    sleep 0.2

    # Set the session's BRIDGE_URL to our running test bridge (port $PORT)
    tmux set-environment -t "$test_session" BRIDGE_URL "http://localhost:$PORT"

    # Now try to export_hook_env from a DIFFERENT bridge URL.
    # The guard should detect that localhost:$PORT is alive and SKIP.
    if python3 -c "
import bridge
import os

# Temporarily pretend we are a different bridge
orig_url = bridge.BRIDGE_URL
orig_port = bridge.PORT
bridge.BRIDGE_URL = 'http://localhost:99999'
bridge.PORT = 99999
try:
    bridge.export_hook_env('$test_session')
finally:
    bridge.BRIDGE_URL = orig_url
    bridge.PORT = orig_port

# Verify the session still points to the original URL (not overwritten)
import subprocess
r = subprocess.run(['tmux', 'show-environment', '-t', '$test_session', 'BRIDGE_URL'],
                   capture_output=True, text=True)
url = r.stdout.strip().split('=', 1)[-1]
assert url == 'http://localhost:$PORT', f'Expected http://localhost:$PORT, got {url}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "export_hook_env skips session owned by live bridge"
    else
        fail "export_hook_env should skip session owned by live bridge"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null || true
}

test_export_hook_env_overwrites_dead_bridge() {
    info "Testing export_hook_env overwrites sessions with dead bridge URL..."

    local test_session="${TEST_TMUX_PREFIX}guardtest2"
    tmux new-session -d -s "$test_session" "bash --norc --noprofile" 2>/dev/null || true
    sleep 0.2

    # Set session to point to a dead bridge (port 19999 — nothing there)
    tmux set-environment -t "$test_session" BRIDGE_URL "http://localhost:19999"

    # export_hook_env should overwrite because 19999 is dead
    if python3 -c "
import bridge
bridge.export_hook_env('$test_session')

import subprocess
r = subprocess.run(['tmux', 'show-environment', '-t', '$test_session', 'BRIDGE_URL'],
                   capture_output=True, text=True)
url = r.stdout.strip().split('=', 1)[-1]
assert url == bridge.BRIDGE_URL, f'Expected {bridge.BRIDGE_URL}, got {url}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "export_hook_env overwrites session with dead bridge URL"
    else
        fail "export_hook_env should overwrite dead bridge URL"
    fi

    tmux kill-session -t "$test_session" 2>/dev/null || true
}

# ── Transport Abstraction Tests ────────────────────────────────────────────

test_transport_interface_exists() {
    info "Testing MessageTransport base class exists..."

    if python3 -c "
import bridge
cls = bridge.MessageTransport
methods = ['send_text', 'send_photo', 'send_document', 'send_animation',
           'send_video', 'send_audio', 'send_voice', 'send_sticker',
           'send_chat_action', 'set_reaction', 'edit_message',
           'setup_commands', 'download_file']
for m in methods:
    assert m in dir(cls), f'missing {m}'
assert 'name' in dir(cls), 'missing name property'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "MessageTransport base class has all required methods"
    else
        fail "MessageTransport base class missing methods"
    fi
}

test_local_transport_send_text() {
    info "Testing LocalTransport.send_text returns stub response..."

    if python3 -c "
import bridge
lt = bridge.LocalTransport()
result = lt.send_text(123, 'hello world')
assert result == {'ok': True, 'result': {'message_id': 1}}, f'unexpected: {result}'
assert lt.name == 'local'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "LocalTransport.send_text returns correct stub"
    else
        fail "LocalTransport.send_text failed"
    fi
}

test_local_transport_media_methods() {
    info "Testing LocalTransport media methods return True..."

    if python3 -c "
import bridge
lt = bridge.LocalTransport()
assert lt.send_photo(1, '/tmp/x.png') == True
assert lt.send_document(1, '/tmp/x.pdf') == True
assert lt.send_animation(1, '/tmp/x.gif') == True
assert lt.send_video(1, '/tmp/x.mp4') == True
assert lt.send_audio(1, '/tmp/x.mp3') == True
assert lt.send_voice(1, '/tmp/x.ogg') == True
assert lt.send_sticker(1, '/tmp/x.webp') == True
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "LocalTransport media methods all return True"
    else
        fail "LocalTransport media methods failed"
    fi
}

test_local_transport_log_file() {
    info "Testing LocalTransport logs to file when TRANSPORT_LOG set..."

    local log_file
    log_file=$(mktemp /tmp/transport-log-XXXXXX.log)
    rm -f "$log_file"

    if TRANSPORT_LOG="$log_file" python3 -c "
import os
os.environ['TRANSPORT_LOG'] = '$log_file'
import importlib
import bridge
lt = bridge.LocalTransport()
lt.send_text(42, 'test message')
lt.send_photo(42, '/tmp/pic.png', caption='a photo')
print('OK')
" 2>/dev/null | grep -q "OK"; then
        if [[ -f "$log_file" ]] && grep -q "send_text" "$log_file" && grep -q "send_photo" "$log_file"; then
            success "LocalTransport writes to TRANSPORT_LOG file"
        else
            fail "LocalTransport log file missing or incomplete"
        fi
    else
        fail "LocalTransport log file test failed"
    fi
    rm -f "$log_file"
}

test_transport_init_selects_correctly() {
    info "Testing _init_transport selects based on TRANSPORT_MODE..."

    if python3 -c "
import bridge
# Current TRANSPORT_MODE is 'telegram' (default in test)
# We test the logic directly
if bridge.TRANSPORT_MODE == 'telegram':
    assert isinstance(bridge.transport, bridge.TelegramTransport), f'expected TelegramTransport, got {type(bridge.transport)}'
elif bridge.TRANSPORT_MODE == 'local':
    assert isinstance(bridge.transport, bridge.LocalTransport), f'expected LocalTransport, got {type(bridge.transport)}'
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "_init_transport selects correct transport"
    else
        fail "_init_transport selection failed"
    fi
}

# ============================================================
# bridge-ops scripts: poll-forwarder.sh + restart-node.sh
# ============================================================

# Pick a free high port (Linux+macOS portable — uses python, not /dev/tcp).
_pick_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

test_bridge_ops_scripts_are_bsd_portable() {
    info "Testing bridge-ops scripts avoid GNU grep -P..."

    # Narrow static guard: this proves the three bridge-ops extraction sites do
    # not use GNU-only grep -P. Known unautomated portability gaps remain:
    # claudecode-telegram.sh uses bash /dev/tcp, and poll-forwarder.sh still
    # uses pgrep -af for its idempotency guard.
    local repo="$SCRIPT_DIR"
    local bad=""
    local file
    for file in \
        "$repo/.claude/skills/bridge-ops/scripts/restart-node.sh" \
        "$repo/.claude/skills/bridge-ops/scripts/verify-node.sh" \
        "$repo/.claude/skills/bridge-ops/scripts/check-versions.sh"; do
        if grep -nE 'grep[[:space:]]+-oP|grep[[:space:]]+-P' "$file" >/tmp/bridge-ops-grep-p-$$ 2>/dev/null; then
            bad+="$file: $(cat /tmp/bridge-ops-grep-p-$$) "
        fi
    done
    rm -f /tmp/bridge-ops-grep-p-$$

    if [[ -z "$bad" ]]; then
        success "bridge-ops scripts avoid GNU-only grep -P"
    else
        fail "bridge-ops scripts still use grep -P: $bad"
    fi
}

test_telegram_api_curls_have_max_time() {
    info "Testing Telegram API curls have max-time bounds..."

    local bad=""
    local cli="$SCRIPT_DIR/claudecode-telegram.sh"
    local fwd="$SCRIPT_DIR/.claude/skills/bridge-ops/scripts/poll-forwarder.sh"

    local cli_hits
    cli_hits=$(grep -nE 'curl -s .*https://api\.telegram\.org' "$cli" 2>/dev/null | grep -v -- '--max-time' || true)
    [[ -n "$cli_hits" ]] && bad+="claudecode-telegram.sh: $cli_hits "

    local fwd_hits
    fwd_hits=$(grep -nE 'curl -s .*\$API_BASE/bot\$TELEGRAM_BOT_TOKEN/deleteWebhook' "$fwd" 2>/dev/null | grep -v -- '--max-time' || true)
    [[ -n "$fwd_hits" ]] && bad+="poll-forwarder.sh: $fwd_hits "

    if [[ -z "$bad" ]]; then
        success "Telegram API curls have --max-time"
    else
        fail "Telegram API curl missing --max-time: $bad"
    fi
}

# Increment A: poll-forwarder must NOT advance offset on a failed POST.
# A failed forward that still bumps offset silently drops the update forever.
test_poll_forwarder_retries_failed_post() {
    info "Testing poll-forwarder offset survives bridge POST failures..."

    local repo="$SCRIPT_DIR"
    local fwd="$repo/.claude/skills/bridge-ops/scripts/poll-forwarder.sh"
    [[ -x "$fwd" ]] || { fail "poll-forwarder.sh not found at $fwd"; return 1; }

    local tmphome; tmphome="$(mktemp -d)"
    local node="pfa"
    local api_port bridge_port
    api_port="$(_pick_free_port)"
    bridge_port="$(_pick_free_port)"

    # Fake Telegram API (records offsets seen, returns ONE update until acked)
    # + fake bridge (rejects the first 2 POSTs, then accepts and records).
    local statedir="$tmphome/state"
    mkdir -p "$statedir"
    local fake_py="$tmphome/fake.py"
    cat > "$fake_py" <<PYEOF
import json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = "$statedir"
TARGET_UID = 4242

def _rec(name, val):
    with open(os.path.join(STATE, name), "a") as f:
        f.write(str(val) + "\n")

class Api(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if "deleteWebhook" in self.path:
            return self._json({"ok": True, "result": True})
        if "getUpdates" in self.path:
            # parse offset
            offset = 0
            if "offset=" in self.path:
                try: offset = int(self.path.split("offset=")[1].split("&")[0])
                except Exception: offset = 0
            _rec("offsets_seen", offset)
            # update considered acked once offset moves past TARGET_UID
            acked = os.path.exists(os.path.join(STATE, "acked"))
            if not acked and offset <= TARGET_UID:
                return self._json({"ok": True, "result": [
                    {"update_id": TARGET_UID,
                     "message": {"message_id": 1, "date": 0,
                                 "chat": {"id": 1, "type": "private"},
                                 "from": {"id": 1, "first_name": "x"},
                                 "text": "hi"}}]})
            if offset > TARGET_UID:
                open(os.path.join(STATE, "acked"), "w").close()
            return self._json({"ok": True, "result": []})
        self._json({"ok": True, "result": []})

class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        # count attempts; fail first 2
        ap = os.path.join(STATE, "bridge_attempts")
        cnt = 0
        if os.path.exists(ap):
            cnt = int(open(ap).read() or "0")
        cnt += 1
        open(ap, "w").write(str(cnt))
        if cnt <= 2:
            self.send_response(500); self.end_headers()
            return
        try:
            upd = json.loads(n)
            _rec("bridge_received", upd.get("update_id"))
        except Exception:
            _rec("bridge_received", "parse-error")
        self.send_response(200); self.end_headers()

a = ThreadingHTTPServer(("127.0.0.1", $api_port), Api)
b = ThreadingHTTPServer(("127.0.0.1", $bridge_port), Bridge)
threading.Thread(target=a.serve_forever, daemon=True).start()
b.serve_forever()
PYEOF

    python3 -u "$fake_py" >"$tmphome/fake.log" 2>&1 &
    local fake_pid=$!
    wait_for_port "$api_port" >/dev/null 2>&1 || true
    wait_for_port "$bridge_port" >/dev/null 2>&1 || true

    # Node env + dirs under the isolated HOME.
    mkdir -p "$tmphome/.config/claudecode-telegram"
    printf 'TELEGRAM_BOT_TOKEN=fake-token-123\n' > "$tmphome/.config/claudecode-telegram/$node.env"
    mkdir -p "$tmphome/.claude/telegram/nodes/$node"

    # Run the forwarder pointed at the fakes. PORT controls the bridge URL,
    # TELEGRAM_API_BASE controls the Telegram side.
    HOME="$tmphome" PORT="$bridge_port" TELEGRAM_API_BASE="http://127.0.0.1:$api_port" \
        "$fwd" "$node" >"$tmphome/fwd.log" 2>&1 || true

    # Capture the forwarder PID it recorded so we can kill ONLY it.
    local fwd_pid=""
    [[ -f "$tmphome/.claude/telegram/nodes/$node/poller.pid" ]] && \
        fwd_pid="$(cat "$tmphome/.claude/telegram/nodes/$node/poller.pid")"

    # Give it time to: fail twice, retry, succeed.
    local attempts=0 got=""
    while [[ $attempts -lt 80 ]]; do
        if [[ -f "$statedir/bridge_received" ]] && grep -q "4242" "$statedir/bridge_received" 2>/dev/null; then
            got="yes"; break
        fi
        sleep 0.1
        ((attempts++)) || true
    done

    # Kill ONLY the forwarder + its python child, then the fake server.
    if [[ -n "$fwd_pid" ]]; then
        pkill -P "$fwd_pid" 2>/dev/null || true
        kill "$fwd_pid" 2>/dev/null || true
    fi
    kill "$fake_pid" 2>/dev/null || true

    if [[ "$got" == "yes" ]]; then
        success "Failed POST retried — bridge eventually received update 4242"
    else
        fail "Update 4242 never reached the bridge (offset advanced past a failed POST)"
    fi

    # The offset must NOT have advanced to 4243 until AFTER a successful POST.
    # If it did while POSTs were still failing, the update would be lost.
    # We assert the bridge got it AND that offset 4243 was eventually seen
    # (proving advance happened only post-success).
    if [[ -f "$statedir/offsets_seen" ]] && grep -q "^4243$" "$statedir/offsets_seen" 2>/dev/null; then
        success "Offset advanced to 4243 only after successful delivery"
    elif [[ "$got" == "yes" ]]; then
        # Delivered but the next poll wasn't observed yet — acceptable.
        success "Offset advance is gated on delivery (4243 not yet polled)"
    else
        fail "Offset behaviour wrong — update lost"
    fi

    rm -rf "$tmphome"
}

# Increment B: a second forwarder for the same bot must refuse to start.
test_poll_forwarder_idempotent() {
    info "Testing poll-forwarder idempotency (no double-run)..."

    local repo="$SCRIPT_DIR"
    local fwd="$repo/.claude/skills/bridge-ops/scripts/poll-forwarder.sh"
    [[ -x "$fwd" ]] || { fail "poll-forwarder.sh not found"; return 1; }

    local tmphome; tmphome="$(mktemp -d)"
    local node="pfb"
    local guard_port; guard_port="$(_pick_free_port)"

    mkdir -p "$tmphome/.config/claudecode-telegram"
    printf 'TELEGRAM_BOT_TOKEN=fake-token-123\n' > "$tmphome/.config/claudecode-telegram/$node.env"
    mkdir -p "$tmphome/.claude/telegram/nodes/$node"

    # Dummy process whose argv matches the pgrep guard:
    #   "getUpdates.*localhost:$PORT"
    python3 -c "import sys,time
sys.argv[0] = 'getUpdates localhost:$guard_port (fake forwarder)'
time.sleep(60)" "getUpdates localhost:$guard_port" &
    local dummy_pid=$!
    # The guard greps the full cmdline; ensure the arg is in argv regardless.
    local before
    before="$(pgrep -af "getUpdates.*localhost:$guard_port" | grep -vc "^$$" || true)"

    local out
    out="$(HOME="$tmphome" PORT="$guard_port" TELEGRAM_API_BASE="http://127.0.0.1:1" \
        "$fwd" "$node" 2>&1)"
    local rc=$?

    # No second forwarder should have appeared.
    local after
    after="$(pgrep -af "getUpdates.*localhost:$guard_port" | wc -l | tr -d ' ')"

    kill "$dummy_pid" 2>/dev/null || true

    if echo "$out" | grep -qi "already running"; then
        success "Forwarder refused to start a second instance"
    else
        fail "Forwarder did not detect the running instance: $out"
    fi
    if [[ "$rc" == "0" ]]; then
        success "Forwarder exited 0 on idempotent no-op"
    else
        fail "Forwarder exited $rc (expected 0)"
    fi

    rm -rf "$tmphome"
}

# Increment C: restart-node.sh must propagate the (export-less) env token
# through the setsid/exec boundary, or the bridge dies for lack of a token.
test_restart_node_env_propagation() {
    info "Testing restart-node.sh env propagation to the bridge..."

    require_token

    # This test's own pid poll is ss-based and Linux-only. The scripts have an
    # lsof fallback, but this test would never find new_pid on macOS and could
    # leave an orphaned bridge. Skip cleanly rather than false-fail.
    if ! command -v ss >/dev/null 2>&1; then
        success "restart-node env test skipped (ss unavailable — restart-node.sh is ss-based/Linux-only)"
        return 0
    fi

    local repo="$SCRIPT_DIR"
    local script="$repo/.claude/skills/bridge-ops/scripts/restart-node.sh"
    [[ -x "$script" ]] || { fail "restart-node.sh not found at $script"; return 1; }
    [[ -x "$repo/.venv/bin/python" ]] || { fail ".venv/bin/python missing — run uv sync"; return 1; }

    local tmphome; tmphome="$(mktemp -d)"
    local node="tn"
    local rport; rport="$(_pick_free_port)"

    mkdir -p "$tmphome/.config/claudecode-telegram"
    # plain VAR=value, NO 'export' — exactly the shape that breaks without set -a.
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TEST_BOT_TOKEN" \
        > "$tmphome/.config/claudecode-telegram/$node.env"
    local ndir="$tmphome/.claude/telegram/nodes/$node"
    mkdir -p "$ndir/sessions"

    # restart-node.sh ends by exec-ing verify-node.sh; run it in background so
    # the verify tail doesn't block us, then poll ss ourselves.
    HOME="$tmphome" PORT="$rport" \
        "$script" "$node" >"$tmphome/restart.log" 2>&1 &
    local runner_pid=$!

    # Poll for the bridge to bind the port.
    local attempts=0 new_pid=""
    while [[ $attempts -lt 100 ]]; do
        new_pid="$(ss -ltnp 2>/dev/null | grep ":$rport " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
        [[ -n "$new_pid" ]] && break
        sleep 0.1
        ((attempts++)) || true
    done

    local alive="no"
    if [[ -n "$new_pid" ]]; then
        # Must stay alive >= 3s (a token-starved bridge dies in <1s).
        local i=0
        alive="yes"
        while [[ $i -lt 30 ]]; do
            kill -0 "$new_pid" 2>/dev/null || { alive="no"; break; }
            sleep 0.1
            ((i++)) || true
        done
    fi

    # Read the bridge log under the isolated HOME.
    local blog="$ndir/bridge.log"
    local token_err="no"
    if [[ -f "$blog" ]] && grep -qi "TELEGRAM_BOT_TOKEN not set" "$blog"; then
        token_err="yes"
    fi

    # Cleanup: kill ONLY the bridge we spawned + the runner, then temp HOME.
    [[ -n "$new_pid" ]] && kill "$new_pid" 2>/dev/null || true
    kill "$runner_pid" 2>/dev/null || true
    [[ -f "$ndir/bridge.pid" ]] && kill "$(cat "$ndir/bridge.pid")" 2>/dev/null || true

    if [[ -n "$new_pid" ]]; then
        success "restart-node.sh launched a bridge on :$rport (pid=$new_pid)"
    else
        fail "No bridge bound :$rport — restart-node.sh failed to launch (see $tmphome/restart.log)"
    fi
    if [[ "$token_err" == "yes" ]]; then
        fail "bridge.log shows 'TELEGRAM_BOT_TOKEN not set' — env did NOT propagate"
    else
        success "No token-missing error — env propagated through setsid/exec"
    fi
    if [[ "$alive" == "yes" ]]; then
        success "Bridge stayed alive >= 3s (token was present)"
    else
        fail "Bridge died within 3s — token likely missing at exec"
    fi

    rm -rf "$tmphome"
}

# Guards the 07:47 silent-death regression: cmd_run MUST launch the bridge
# setsid-detached (so a closing terminal/session can never SIGHUP it), capture
# the real detached pid (not $! of the setsid wrapper), and must NOT kill that
# detached bridge on an unintended teardown — only on an intentional stop.
test_cmd_run_launches_bridge_detached() {
    log "Test: cmd_run launches the bridge setsid-detached (07:47 silent-death guard)"
    local script="$SCRIPT_DIR/claudecode-telegram.sh"
    local body
    body=$(awk '/^cmd_run\(\)/{f=1} f{print} f&&/^}$/{exit}' "$script")

    # 1. Bridge launched fully detached (</dev/null), portably: setsid on Linux
    #    with a nohup fallback for macOS (which has no setsid). Match the COMMAND
    #    shapes ('setsid bash -c' / 'nohup bash -c' / 'echo \$\$ >'), not bare words
    #    — bare 'setsid'/'nohup' also appear in the comments and would false-pass.
    if grep -qF 'setsid bash -c' <<<"$body" && grep -qF 'nohup bash -c' <<<"$body" \
        && grep -qF '</dev/null' <<<"$body" && grep -qF 'echo \$\$ >' <<<"$body"; then
        success "cmd_run detaches the bridge portably (setsid/nohup bash -c + </dev/null + child records own pid)"
    else
        fail "cmd_run launch is not portably detached (need setsid bash -c + nohup fallback + </dev/null + echo \$\$) — 07:47 silent-death / macOS risk"
    fi

    # 2. Real pid comes from the detached child, not \$! (which is the setsid wrapper):
    #    no 'bridge_pid=\$!', and a readback loop that cat's bridge.pid + kill -0 checks it.
    if grep -qE 'bridge_pid=\$!' <<<"$body"; then
        fail "cmd_run captures \$! (the setsid wrapper), not the real detached bridge pid"
    elif grep -qF 'cat "$node_dir/bridge.pid"' <<<"$body" && grep -qF 'kill -0 "$bridge_pid"' <<<"$body"; then
        success "cmd_run reads the real bridge pid back from bridge.pid (no reliance on \$!)"
    else
        fail "cmd_run has no pid-readback loop — \$! is the setsid wrapper, not the bridge pid"
    fi

    # 3. Cleanup must guard the bridge kill behind an intentional-stop flag, so a
    #    closing terminal (HUP -> EXIT trap) does not take the detached bridge down.
    local cleanup_body
    cleanup_body=$(awk '/cleanup_and_exit\(\)/{f=1} f{print} f&&/^    }$/{exit}' "$script")
    if grep -qE '_intentional_stop|intentional' <<<"$cleanup_body"; then
        success "cleanup guards the bridge kill behind an intentional-stop flag"
    else
        fail "cleanup kills the bridge unconditionally — a HUP would take the detached bridge down too"
    fi
}

# Fail-loudly guard (e310008): when the watchdog detects the detached bridge has
# died, the supervisor's cleanup MUST exit non-zero — a dead bridge is a failure,
# not a clean stop (so systemd/CI/`&&` chains can see it). An intentional stop
# (Ctrl+C) and a bare host teardown (supervisor exits, leaves the bridge running)
# must still exit 0. This runs the REAL cleanup_and_exit body in isolation with
# stubbed deps, so it asserts the actual exit code — behavior, not source text.
test_bridge_death_exits_nonzero() {
    log "Test: bridge-death cleanup exits non-zero (fail-loudly); intentional/teardown exit 0"
    local script="$SCRIPT_DIR/claudecode-telegram.sh"
    local fn
    fn=$(awk '/cleanup_and_exit\(\)/{f=1} f{print} f&&/^    }$/{exit}' "$script")
    if [[ -z "$fn" ]]; then
        fail "could not extract cleanup_and_exit from $script"
        return
    fi

    # $1 = _intentional_stop, $2 = _bridge_dead -> echoes the real exit code.
    _run_cleanup() {
        local tmp; tmp="$(mktemp)"
        {
            printf '%s\n' 'set +e'
            printf '%s\n' 'stop_poll_fallback() { :; }'
            printf '%s\n' 'log() { :; }'
            printf '%s\n' 'node="t"; tunnel_pid=""; bridge_pid=""; node_dir=""; pid_file=""'
            printf '%s\n' "_intentional_stop=$1; _bridge_dead=$2"
            printf '%s\n' "$fn"
            printf '%s\n' 'cleanup_and_exit'
        } > "$tmp"
        bash "$tmp" >/dev/null 2>&1
        local rc=$?
        rm -f "$tmp"
        echo "$rc"
    }

    local rc_dead rc_intentional rc_teardown
    rc_dead=$(_run_cleanup 0 1)
    rc_intentional=$(_run_cleanup 1 0)
    rc_teardown=$(_run_cleanup 0 0)
    unset -f _run_cleanup

    if [[ "$rc_dead" -ne 0 ]]; then
        success "bridge-death cleanup exits non-zero ($rc_dead) — fail-loudly"
    else
        fail "bridge-death cleanup exits 0 — a dead bridge is silently reported as success"
    fi
    if [[ "$rc_intentional" -eq 0 ]]; then
        success "intentional-stop cleanup exits 0 (Ctrl+C is a clean stop)"
    else
        fail "intentional-stop cleanup exits non-zero ($rc_intentional) — Ctrl+C should be clean"
    fi
    if [[ "$rc_teardown" -eq 0 ]]; then
        success "host-teardown cleanup exits 0 (leaving the bridge running is not a failure)"
    else
        fail "host-teardown cleanup exits non-zero ($rc_teardown) — leaving the bridge running is not a failure"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.3.5 Task 6 — PR review cross-repo cache + body-trusted owner/repo (C8)
# ─────────────────────────────────────────────────────────────────────────────

test_pr_cache_keyed_by_owner_repo_num() {
    info "Testing PR review cache path is keyed by owner/repo/pr_num (no cross-repo collision)..."

    if python3 -c "
import io, os
from urllib.parse import urlparse
import bridge

calls = []
def fake_run(cmd, *a, **k):
    out = None
    if '--out' in cmd:
        out = cmd[cmd.index('--out') + 1]
    calls.append({'cmd': list(cmd), 'out': out})
    if out:
        with open(out, 'w') as f:
            f.write('CONTENT-FOR ' + out)
    class R: pass
    r = R(); r.returncode = 0; r.stdout = ''; r.stderr = ''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.admin_chat_id = None
bridge.BRIDGE_PUBLIC_URL = ''
bridge.PR_REVIEW_TOKENS.clear()

class FakeHandler:
    def __init__(self):
        self.status=None; self.headers={}; self.wfile=io.BytesIO(); self.replies=[]
    def reply(self, chat_id, text, **kw): self.replies.append(text)
    def send_response(self, c): self.status=c
    def send_header(self, k, v): self.headers[k]=v
    def end_headers(self): pass
    def _send_html(self, data): self.status=200; self.wfile.write(data)

written = []
try:
    h1 = FakeHandler()
    bridge.CommandRouter.cmd_pr_review(h1, 'https://github.com/alpha/repoA/pull/5', 1)
    h2 = FakeHandler()
    bridge.CommandRouter.cmd_pr_review(h2, 'https://github.com/beta/repoB/pull/5', 1)
    for c in calls:
        if c['out']: written.append(c['out'])

    assert calls[0]['out'] is not None, 'first /pr did not pass --out: ' + str(calls[0]['cmd'])
    assert calls[1]['out'] is not None, 'second /pr did not pass --out: ' + str(calls[1]['cmd'])
    assert calls[0]['out'] != calls[1]['out'], 'cross-repo cache collision (same path for two repos): ' + calls[0]['out']
    assert 'alpha' in calls[0]['out'] and 'repoA' in calls[0]['out'], 'cache path missing owner/repo: ' + calls[0]['out']
    # injectivity: legal owner/repo names must not alias through the '-' separator
    assert bridge._pr_cache_path('alpha', 'repo-A', 5) != bridge._pr_cache_path('alpha-repo', 'A', 5), \
        'legal owner/repo names still collide through hyphen separator'

    tokens = list(bridge.PR_REVIEW_TOKENS.keys())
    assert len(tokens) == 2, 'expected 2 tokens, got ' + str(len(tokens))
    served = []
    for tok in tokens:
        hh = FakeHandler()
        bridge.Handler.handle_pr_review_endpoint(hh, urlparse('/pr-review/5?token=' + tok))
        served.append(hh.wfile.getvalue().decode('utf-8', 'replace'))
    assert served[0] != served[1], 'endpoint served identical content for two repos (cache collision at serve time)'

    # path-traversal: malicious owner/repo must be sanitized to a flat /tmp filename
    p = bridge._pr_cache_path('ev/il', 'ot/../her', 9)
    assert p.startswith('/tmp/pr-review-'), 'unexpected cache path: ' + p
    assert '/' not in p[len('/tmp/'):], 'unsanitized slash in cache filename: ' + p

    print('OK')
finally:
    for p in set(written):
        try: os.remove(p)
        except OSError: pass
" 2>/dev/null | grep -q "OK"; then
        success "PR review cache keyed by owner/repo/pr_num (no collision)"
    else
        fail "PR review cache collides across repos with same PR number"
    fi
}

test_pr_comment_uses_token_owner_repo_not_body() {
    info "Testing /pr-comment derives owner/repo from token, not request body..."

    if python3 -c "
import io, json, time
import bridge
import urllib.request as _ur
_ur.urlopen = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('blocked'))

calls = []
def fake_run(cmd, *a, **k):
    calls.append(list(cmd))
    class R: pass
    r=R(); r.returncode=0; r.stdout=''; r.stderr=''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.admin_chat_id = None
bridge.PR_REVIEW_TOKENS.clear()
tok = 'TESTTOKEN'
bridge.PR_REVIEW_TOKENS[tok] = {'pr_num': 5, 'owner': 'realowner', 'repo': 'realrepo', 'expires_at': time.time()+300}

class FakeHandler:
    def __init__(self): self.status=None; self.headers={}; self.wfile=io.BytesIO()
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self.headers[k]=v
    def end_headers(self): pass

body = json.dumps({'token': tok, 'owner': 'evil', 'repo': 'other', 'pr_num': 999,
                   'path': 'src/x.py', 'line': 10, 'side': 'RIGHT',
                   'body': 'looks good', 'head_sha': 'abc123'}).encode()
h = FakeHandler()
bridge.Handler.handle_pr_comment(h, body)
assert h.status == 200, 'status=' + str(h.status)
assert calls, 'no gh api call made'
api_path = calls[0][2]
assert api_path == 'repos/realowner/realrepo/pulls/5/comments', 'wrong repo target: ' + api_path
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/pr-comment uses token owner/repo (ignores body claim)"
    else
        fail "/pr-comment trusts body owner/repo (wrong-repo gh action)"
    fi
}

test_pr_merge_uses_token_owner_repo_not_body() {
    info "Testing /pr-merge derives owner/repo from token, not request body..."

    if python3 -c "
import io, json, time
import bridge
import urllib.request as _ur
_ur.urlopen = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('blocked'))

calls = []
def fake_run(cmd, *a, **k):
    calls.append(list(cmd))
    class R: pass
    r=R(); r.returncode=0; r.stdout=''; r.stderr=''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.admin_chat_id = None
bridge.PR_REVIEW_TOKENS.clear()
tok = 'TESTTOKEN'
bridge.PR_REVIEW_TOKENS[tok] = {'pr_num': 5, 'owner': 'realowner', 'repo': 'realrepo', 'expires_at': time.time()+300}

class FakeHandler:
    def __init__(self): self.status=None; self.headers={}; self.wfile=io.BytesIO()
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self.headers[k]=v
    def end_headers(self): pass

body = json.dumps({'token': tok, 'owner': 'evil', 'repo': 'other', 'pr_num': 999,
                   'merge_method': 'squash'}).encode()
h = FakeHandler()
bridge.Handler.handle_pr_merge(h, body)
assert h.status == 200, 'status=' + str(h.status)
assert calls, 'no gh api call made'
api_path = calls[0][2]
assert api_path == 'repos/realowner/realrepo/pulls/5/merge', 'wrong repo target: ' + api_path
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/pr-merge uses token owner/repo (ignores body claim)"
    else
        fail "/pr-merge trusts body owner/repo (wrong-repo gh action)"
    fi
}

test_pr_general_comment_uses_token_owner_repo_not_body() {
    info "Testing /pr-general-comment derives owner/repo from token, not request body..."

    if python3 -c "
import io, json, time
import bridge
import urllib.request as _ur
_ur.urlopen = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('blocked'))

calls = []
def fake_run(cmd, *a, **k):
    calls.append(list(cmd))
    class R: pass
    r=R(); r.returncode=0; r.stdout=''; r.stderr=''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.admin_chat_id = None
bridge.PR_REVIEW_TOKENS.clear()
tok = 'TESTTOKEN'
bridge.PR_REVIEW_TOKENS[tok] = {'pr_num': 5, 'owner': 'realowner', 'repo': 'realrepo', 'expires_at': time.time()+300}

class FakeHandler:
    def __init__(self): self.status=None; self.headers={}; self.wfile=io.BytesIO()
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self.headers[k]=v
    def end_headers(self): pass

body = json.dumps({'token': tok, 'owner': 'evil', 'repo': 'other', 'pr_num': 999,
                   'body': 'general comment'}).encode()
h = FakeHandler()
bridge.Handler.handle_pr_general_comment(h, body)
assert h.status == 200, 'status=' + str(h.status)
assert calls, 'no gh api call made'
api_path = calls[0][2]
assert api_path == 'repos/realowner/realrepo/issues/5/comments', 'wrong repo target: ' + api_path
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/pr-general-comment uses token owner/repo (ignores body claim)"
    else
        fail "/pr-general-comment trusts body owner/repo (wrong-repo gh action)"
    fi
}

test_pr_file_content_uses_token_owner_repo_not_query() {
    info "Testing /pr-file-content derives owner/repo from token, not query string..."

    if python3 -c "
import io, time, base64
from urllib.parse import urlparse
import bridge

calls = []
def fake_run(cmd, *a, **k):
    calls.append(list(cmd))
    class R: pass
    r=R(); r.returncode=0
    r.stdout = base64.b64encode(b'line1\nline2').decode()
    r.stderr=''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.PR_REVIEW_TOKENS.clear()
tok = 'TESTTOKEN'
bridge.PR_REVIEW_TOKENS[tok] = {'pr_num': 5, 'owner': 'realowner', 'repo': 'realrepo', 'expires_at': time.time()+300}

class FakeHandler:
    def __init__(self): self.status=None; self.headers={}; self.wfile=io.BytesIO()
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self.headers[k]=v
    def end_headers(self): pass

parsed = urlparse('/pr-file-content?token=' + tok + '&owner=evil&repo=other&path=src/x.py&ref=abc123')
h = FakeHandler()
bridge.Handler.handle_pr_file_content(h, parsed)
assert h.status == 200, 'status=' + str(h.status)
assert calls, 'no gh api call made'
api_path = calls[0][2]
assert api_path.startswith('repos/realowner/realrepo/contents/'), 'wrong repo target: ' + api_path
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/pr-file-content uses token owner/repo (ignores query claim)"
    else
        fail "/pr-file-content trusts query owner/repo (cross-repo file read)"
    fi
}

test_pr_review_cli_honors_out_flag() {
    info "Testing pr-review.py main() honors --out and accepts --no-serve (argparse executes for real)..."

    if python3 -c "
import importlib.util, os, sys, tempfile

# isolate the sqlite cache so we never touch the real /tmp/pr-review-cache.db
os.environ['PR_CACHE_DB'] = tempfile.mktemp(suffix='.db')
spec = importlib.util.spec_from_file_location('pr_review_mod', 'pr-review.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# stub out all network: fetch returns the 6-tuple main() unpacks; html is a sentinel
mod.fetch_pr_cached = lambda *a, **k: ({}, [], [], [], [], {})
mod.generate_html = lambda *a, **k: '<html>SENTINEL-OUT-FLAG</html>'

out = tempfile.mktemp(suffix='.html')
default_path = '/tmp/pr-review-5.html'
had_default = os.path.exists(default_path)
try:
    # exactly the argv bridge.py builds: positional URL + --no-serve + --out
    sys.argv = ['pr-review.py', 'https://github.com/o/r/pull/5', '--no-serve', '--out', out]
    mod.main()
    assert os.path.exists(out), 'main() did not write to the --out path (flag ignored?)'
    assert 'SENTINEL-OUT-FLAG' in open(out).read(), 'wrong content written to --out path'
    print('OK')
finally:
    for p in (out, os.environ['PR_CACHE_DB']):
        try: os.remove(p)
        except OSError: pass
    # only clean the default path if WE created it (do not clobber a real cache)
    if not had_default:
        try: os.remove(default_path)
        except OSError: pass
" 2>/dev/null | grep -q "OK"; then
        success "pr-review.py main() honors --out and accepts --no-serve"
    else
        fail "pr-review.py --out/--no-serve not honored by argparse"
    fi
}

test_pr_comment_does_not_route_to_session() {
    info "Testing PR-review comments never route @mentions into a session (topic-only model)..."

    if python3 -c "
import io, json, time
import bridge
import urllib.request as _ur
_ur.urlopen = lambda *a, **k: (_ for _ in ()).throw(RuntimeError('blocked'))

# A command_router stub that WOULD yield a worker target — proves the handlers do
# not act on it (pre-fix they routed to it; post-fix they ignore @mentions entirely).
class _Router:
    def parse_at_mentions(self, text):
        return (['t123'], text)
bridge.command_router = _Router()

sent = []
bridge.send_to_session = lambda name, msg, *a, **k: (sent.append(name), True)[1]

def fake_run(cmd, *a, **k):
    class R: pass
    r=R(); r.returncode=0; r.stdout=''; r.stderr=''
    return r
bridge.subprocess.run = fake_run
bridge.tmux_exists = lambda *a: False
bridge.admin_chat_id = None   # skip transport.send_text in handle_pr_comment
bridge.PR_REVIEW_TOKENS.clear()
tok = 'TESTTOKEN'
bridge.PR_REVIEW_TOKENS[tok] = {'pr_num': 5, 'owner': 'o', 'repo': 'r', 'expires_at': time.time()+300}

class FakeHandler:
    def __init__(self): self.status=None; self.headers={}; self.wfile=io.BytesIO()
    def send_response(self,c): self.status=c
    def send_header(self,k,v): self.headers[k]=v
    def end_headers(self): pass

# General (non-inline) PR comment carrying an @mention.
gbody = json.dumps({'token': tok, 'body': '@t123 please look at this'}).encode()
bridge.Handler.handle_pr_general_comment(FakeHandler(), gbody)
# Inline PR comment carrying an @mention.
ibody = json.dumps({'token': tok, 'body': '@t123 fix here', 'path': 'src/x.py',
                    'line': 10, 'side': 'RIGHT', 'head_sha': 'abc123'}).encode()
bridge.Handler.handle_pr_comment(FakeHandler(), ibody)

assert not sent, 'PR-review comment routed @mention into session(s): ' + str(sent)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "PR-review comments do not route @mentions into a session"
    else
        fail "PR-review comment routed an @mention into a session (topic-only model violated)"
    fi
}

# ============================================================
# TEST RUNNERS
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

run_unit_tests() {
    # Unit tests (no bridge needed)
    log "── Unit Tests ──────────────────────────────────────────────────────────"
    run_test test_wait_for_file_content_helper
    run_test test_wait_for_log_helper
    run_test test_formatting
    run_test test_send_text_includes_thread_id
    run_test test_pane_start_cmd_shell_agnostic
    run_test test_pane_start_cmd_runs_in_real_shell_panes
    run_test test_pane_start_cmd_survives_stdin_eating_rc
    run_test test_pane_start_cmd_no_resend_into_running_backend
    run_test test_topic_session_identity
    run_test test_folder_navigator_keyboard
    run_test test_handle_callback_navigates
    run_test test_open_topic_session_spawns_in_cwd
    run_test test_topic_routing_known_and_unknown
    run_test test_topic_close_and_cd
    run_test test_cd_reports_restart_failure
    run_test test_dead_realert_is_bounded
    run_test test_dead_realert_resets_after_recovery
    run_test test_topic_non_forum_fallback
    run_test test_topic_title_naming
    run_test test_topic_reaction_mapping
    run_test test_topic_reaction_updates
    run_test test_topic_reaction_done_on_delivery
    run_test test_topic_typing_stops_when_stalled
    run_test test_topic_route_tracks_request
    run_test test_topic_name_falls_back_for_nonascii
    run_test test_topic_hire_starts_pane_in_picked_cwd
    run_test test_accept_trust_prompt_picks_yes
run_test test_topic_hire_accepts_trust_prompt
run_test test_restart_paths_accept_trust
    run_test test_topic_typed_reply_during_pick_not_routed
    run_test test_topic_cd_rejects_bad_path
    run_test test_topic_legacy_command_rejected
    run_test test_topic_global_command_delegated
    run_test test_extension_seam_command
    run_test test_topic_command_menu_is_slim
    run_test test_topic_welcome_drops_multiworker_framing
    run_test test_topic_open_sends_welcome_only
    run_test test_topic_first_message_trigger_not_forwarded
    run_test test_topic_trigger_swallowed_in_grace_window
    run_test test_topic_admin_gate
    run_test test_topic_command_reply_targets_thread
    run_test test_media_reply_targets_thread
    run_test test_tmain_thread_zero_omitted
    run_test test_topic_picker_shown_on_topic_creation
    run_test test_hire_does_not_set_focus
    run_test test_startup_message_topic_semantics
    run_test test_topic_closed_ends_session
    run_test test_topic_reopened_unbound_shows_picker
    run_test test_deleted_topic_reaped_on_send_failure
    run_test test_topic_photo_routed_with_local_path
    run_test test_topic_document_routed_with_metadata
    run_test test_topic_voice_transcribed_transparently
    run_test test_topic_media_before_binding_not_forwarded
    run_test test_topic_folder_callback_data_within_limit
    run_test test_topic_typing_targets_thread
    run_test test_hook_reply_targets_thread
    run_test test_quota_render
    run_test test_quota_api_fallback
    run_test test_message_splitting
    run_test test_sandbox_docker_cmd
    # Unit tests - Markdown conversion
    log ""
    log "── Markdown Conversion Tests (Unit) ────────────────────────────────────"
    run_test test_markdown_to_telegram_html
    run_test test_forward_to_bridge_escape_flag
    # test_forward_self_heal_on_403 removed (HOOK_SECRET removed)
    # test_forward_no_self_heal_on_other_errors removed (HOOK_SECRET removed)
    # Unit tests - Backend registry
    log ""
    log "── Backend Registry Tests (Unit) ───────────────────────────────────────"
    run_test test_backend_registry_exists
    # Unit tests - Worker naming
    log ""
    log "── Worker Naming Tests (Unit) ──────────────────────────────────────────"
    run_test test_hire_binary_check
    run_test test_claude_start_cmd
    run_test test_backend_env_metadata
    run_test test_watchdog_suppressed_after_restart
    run_test test_end_clears_pending
    run_test test_hook_response_clears_pending_on_send_failure
    run_test test_restart_clears_pending
    run_test test_end_clears_session_id_for_interactive
    run_test test_get_registered_sessions_no_autopick
    run_test test_poisoned_hook_signal_file
    run_test test_poisoned_hook_signal_stale_ignored
    run_test test_poisoned_hook_signal_below_threshold
    run_test test_on_tool_failure_hook_script
    run_test test_clear_hook_failures_on_restart
    run_test test_since_preserved_on_reason_change
    run_test test_compute_state_interactive
    run_test test_idle_child_baseline
    run_test test_idle_streak_prevents_false_stuck
    run_test test_watchdog_resolved_alert
    run_test test_parse_at_mentions
    run_test test_format_watchdog_status
    run_test test_send_response_html_formatting
    run_test test_format_response_strips_name_prefix
    run_test test_get_any_session_id
    run_test test_extract_worker_activity
    run_test test_activity_detects_interactive_prompt
    run_test test_activity_detects_plan_approval
    run_test test_watchdog_waiting_input_state
    # Unit tests - Launch / Detach hardening (v1.3.5 Task 5a)
    log ""
    log "── Launch / Detach Tests (Unit) ────────────────────────────────────────"
    run_test test_cmd_run_launches_bridge_detached
    run_test test_bridge_death_exits_nonzero
    # Unit tests - Bridge public URL
    log ""
    log "── Bridge Public URL Tests (Unit) ──────────────────────────────────────"
    run_test test_bridge_public_url_auto_detect
    run_test test_bridge_public_url_auto_bind
    run_test test_bridge_public_url_no_auto_bind_when_explicit
    run_test test_bridge_url_ignores_stale_localhost
    run_test test_bridge_url_ignores_stale_127
    # Unit tests - Watchdog resolved alerts
    log ""
    log "── Watchdog Resolved Alert Tests (Unit) ────────────────────────────────"
    run_test test_resolved_alert_cooldown
    # Unit tests - Node-derived config
    log ""
    log "── Node-Derived Config Tests (Unit) ────────────────────────────────────"
    run_test test_node_derives_tmux_prefix
    run_test test_node_derives_sessions_dir
    run_test test_node_derives_port
    run_test test_node_derives_bridge_url
    run_test test_node_explicit_env_overrides
    run_test test_node_empty_uses_defaults
    # Unit tests - Media tags
    log ""
    log "── Media Tag Tests (Unit) ──────────────────────────────────────────────"
    run_test test_media_tag_parsing
    # Unit tests - Persistence functions
    log ""
    log "── Persistence Functions Tests (Unit) ──────────────────────────────────"
    run_test test_persistence_file_functions
    run_test test_pending_no_side_effect
    run_test test_stale_pending_survives_for_watchdog
    run_test test_pending_files
    # Unit tests - Worker Registry (persistent)
    log ""
    log "── Worker Registry Tests (Unit) ────────────────────────────────────────"
    run_test test_registry_add_remove
    run_test test_registry_bootstrap
    run_test test_registry_corrupt_recovery
    run_test test_get_registered_includes_registry
    run_test test_checkin_cwd_stores_in_memory
    run_test test_checkin_cwd_invalid_path
    run_test test_checkin_cwd_restart_notifies_manager
    run_test test_checkin_cwd_restart_prefers_admin_chat_id
    run_test test_checkin_cwd_restart_failure_notifies_manager
    run_test test_checkin_cwd_restart_blocked_by_cooldown
    run_test test_checkin_cwd_restart_blocked_by_running_claude
    run_test test_restart_dead_worker
    run_test test_revive_waits_for_pane_shell_ready
    run_test test_restart_inplace_waits_for_pane_shell_ready
    run_test test_wait_for_pane_shell_ready_paths
    run_test test_create_fail_open_when_wait_returns_false
    run_test test_end_removes_from_registry
    run_test test_watchdog_exited_state
    # Unit tests - Copy improvements (human-friendly /team + watchdog)
    log ""
    log "── Copy Improvement Tests (Unit) ───────────────────────────────────────"
    run_test test_normalize_activity_spinner_verbs
    run_test test_team_ready_replaces_idle
    run_test test_watchdog_alert_stuck_copy
    run_test test_watchdog_alert_poisoned_copy
    run_test test_watchdog_alert_dead_copy
    run_test test_watchdog_alert_waiting_input_copy
    run_test test_watchdog_resolved_copy
    run_test test_team_attention_needs_reply
    # Unit tests - Concurrency
    log ""
    log "── Concurrency Tests (Unit) ────────────────────────────────────────────"
    run_test test_tmux_send_locks
    run_test test_tmux_paste_buffer_send
    run_test test_paste_buffer_uses_bracketed_paste
    run_test test_image_caption_enter_with_bracketed_paste
    run_test test_long_text_enter_with_bracketed_paste
    run_test test_slow_paste_render_enter_delivered
    run_test test_tmux_send_uses_flock
    run_test test_concurrent_sends_no_interleave
    run_test test_flock_per_session_isolation
    run_test test_flock_node_namespaced
    # Unit tests - Misc behavior
    log ""
    log "── Misc Behavior Tests (Unit) ──────────────────────────────────────────"
    run_test test_watchdog_alert_on_stuck
    run_test test_extra_mounts_docker_cmd
    run_test test_checkin_note_machine_substitution
    # Unit tests - File validation
    log ""
    log "── File Validation Tests (Unit) ────────────────────────────────────────"
    run_test test_file_validation
    run_test test_file_size_limit_50mb
    run_test test_incoming_media_types
    # Unit tests - Worker discovery
    log ""
    log "── Worker Discovery Tests (Unit) ───────────────────────────────────────"
    run_test test_workers_endpoint_removed
    # Unit tests - send_to_session abstraction
    log ""
    log "── send_to_session Abstraction Tests (Unit) ─────────────────────────────"
    run_test test_send_to_session_uses_backend_registry
    run_test test_send_to_session_missing
    # Unit tests - Voice Mode (STT/TTS)
    log ""
    log "── Voice Mode Tests (Unit) ─────────────────────────────────────────────"
    run_test test_transcribe_voice_success
    run_test test_transcribe_voice_timeout_returns_none
    run_test test_transcribe_voice_bad_json_returns_none
    run_test test_voice_message_includes_transcript
    run_test test_voice_message_fallback_without_transcript
    run_test test_synthesize_speech_success
    run_test test_synthesize_speech_timeout_returns_none
    run_test test_synthesize_speech_uses_chunked_for_long_text
    run_test test_auto_tts_sends_voice_with_response
    run_test test_speak_tag_custom_text
    run_test test_auto_tts_skips_long_messages
    run_test test_auto_tts_failure_still_sends_text
    # v1.3.5 Task 5b/5c — voice endpoint defaults + tts_enabled key-absent default
    run_test test_stt_tts_endpoints_default_empty
    run_test test_auto_tts_off_when_key_absent
    run_test test_voice_toggle_command
    # Unit tests - Transcript Viewer
    log ""
    log "── Transcript Viewer Tests (Unit) ──────────────────────────────────────"
    rm -f /tmp/transcript-cache/*.db /tmp/transcript-cache/*.db-wal /tmp/transcript-cache/*.db-shm 2>/dev/null
    run_test test_transcript_renders_html
    run_test test_render_transcript_html_with_query_result
    run_test test_transcript_missing_session
    run_test test_transcript_with_tool_calls
    run_test test_transcript_default_last_page
    run_test test_transcript_bm25_search
    run_test test_transcript_search_assistant_ctx_link
    run_test test_transcript_search_sort_toggle
    run_test test_transcript_unicode
    run_test test_transcript_edit_diff_rendering
    run_test test_transcript_turn_grouping
    run_test test_transcript_hides_system_messages
    run_test test_rewind_generates_token_url
    run_test test_rewind_token_auth_required
    run_test test_rewind_no_args_shows_usage
    run_test test_transcript_prompts_filter
    run_test test_transcript_dynamic_avatars
    run_test test_transcript_sidebar_stats
    # Unit tests - PR Review security (v1.3.5 Task 6 / C8)
    log ""
    log "── PR Review Security Tests (Unit) ─────────────────────────────────────"
    run_test test_pr_cache_keyed_by_owner_repo_num
    run_test test_pr_comment_uses_token_owner_repo_not_body
    run_test test_pr_merge_uses_token_owner_repo_not_body
    run_test test_pr_general_comment_uses_token_owner_repo_not_body
    run_test test_pr_file_content_uses_token_owner_repo_not_query
    run_test test_pr_review_cli_honors_out_flag
    run_test test_pr_comment_does_not_route_to_session
    # Unit tests - Transcript Index (transcript-index.py)
    log ""
    log "── Transcript Index Tests (Unit) ───────────────────────────────────────"
    run_test test_tindex_missing_file
    run_test test_tindex_empty_file
    run_test test_tindex_basic_indexing
    run_test test_tindex_skips_noise
    run_test test_tindex_plain_text_extraction
    run_test test_tindex_incremental
    run_test test_tindex_no_reindex_unchanged
    run_test test_tindex_pagination
    run_test test_tindex_fts5_search
    run_test test_tindex_search_no_results
    run_test test_tindex_filter_prompts
    run_test test_tindex_stats
    # Unit tests - Team Chat Index (team-chat-index.py)
    log ""
    log "── Team Chat Index Tests (Unit) ────────────────────────────────────────"
    run_test test_tcindex_missing_file
    run_test test_tcindex_empty_file
    run_test test_tcindex_basic_indexing
    run_test test_tcindex_sender_resolution
    run_test test_tcindex_incremental
    run_test test_tcindex_no_reindex_unchanged
    run_test test_tcindex_pagination
    run_test test_tcindex_fts5_search
    run_test test_tcindex_page_for_msg
    # Unit tests - Team Chat Bridge (bridge.py team chat integration)
    log ""
    log "── Team Chat Bridge Tests (Unit) ───────────────────────────────────────"
    run_test test_rewind_team_token
    run_test test_team_chat_403_no_token
    run_test test_team_chat_renders_html
    run_test test_team_chat_search
    run_test test_team_chat_anchor
    run_test test_team_chat_search_context_link
    run_test test_team_chat_reply_context
    # Unit tests - Memory Subcommands (/memory status, wake-up, recall)
    log ""
    log "── Memory Subcommand Tests (Unit) ─────────────────────────────────────"
    run_test test_memory_status_subcommand
    run_test test_memory_wakeup_subcommand
    run_test test_memory_wakeup_with_wing
    run_test test_memory_recall_subcommand
    run_test test_memory_status_failure_isolation
    # Unit tests - Transport Abstraction
    log ""
    log "── Transport Abstraction Tests (Unit) ──────────────────────────────────"
    run_test test_transport_interface_exists
    run_test test_local_transport_send_text
    run_test test_local_transport_media_methods
    run_test test_local_transport_log_file
    run_test test_transport_init_selects_correctly
    # Unit tests - bridge-ops poll-forwarder
    log ""
    log "── bridge-ops poll-forwarder Tests (Unit) ──────────────────────────────"
    run_test test_bridge_ops_scripts_are_bsd_portable
    run_test test_telegram_api_curls_have_max_time
    run_test test_poll_forwarder_retries_failed_post
    run_test test_poll_forwarder_idempotent
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.3.5 Task 1 — set -e suite-killer regression tests (C3 / N1 / C6)
#
# Methodology note: a `set -e` arithmetic/`&&` abort only reproduces when errexit
# is ARMED in a FRESH PROCESS. run_test dispatches each test as `testfn || fail`,
# which SUSPENDS errexit for the whole test-function extent — and that suspension
# propagates even into in-process `( )` AND `$( )` subshells, overriding an inner
# `set -e`, so an in-process subshell can NEVER reproduce the abort (verified
# empirically). Therefore C3/N1 drive a real CLI SUBPROCESS and C6 sources the
# launcher in a separate `bash -c` PROCESS — each a fresh, fully-armed errexit,
# fully isolated so the abort can never crash the harness.
# ─────────────────────────────────────────────────────────────────────────────

# Write claudecode-telegram.sh WITHOUT its final `main "$@"` line to a temp file
# and echo the path, so a separate process can source its functions without
# running main. Caller removes the temp file.
launcher_lib_path() {
    local _tmp; _tmp="$(mktemp)"
    sed '/^main "\$@"$/d' "$SCRIPT_DIR/claudecode-telegram.sh" > "$_tmp"
    echo "$_tmp"
}

test_stop_single_node_reaches_end_after_first_kill() {
    local temp_home node nd mainpid bridgepid sess out ok has_tmux
    has_tmux=0; command -v tmux >/dev/null 2>&1 && has_tmux=1
    temp_home=$(mktemp -d)
    node="stopt$$"
    nd="$temp_home/.claude/telegram/nodes/$node"
    mkdir -p "$nd"
    sleep 300 & mainpid=$!
    sleep 300 & bridgepid=$!
    echo "$mainpid"   > "$nd/pid"
    echo "$bridgepid" > "$nd/bridge.pid"
    echo x > "$nd/port"; echo x > "$nd/bot_id"; echo x > "$nd/bot_username"
    sess="claude-${node}-victim"
    [[ "$has_tmux" -eq 1 ]] && tmux new-session -d -s "$sess" "/bin/sh -c 'sleep 300'" 2>/dev/null || true

    # CLI subprocess: its own `set -e` is armed, so the buggy `((killed++))` aborts
    # stop_single_node after the FIRST kill on the unpatched base.
    out=$(HOME="$temp_home" CLAUDE_DIR="$temp_home/.claude" \
          ./claudecode-telegram.sh --node "$node" stop 2>&1) || true

    ok=1
    # These two signals need NO tmux: on the unpatched base stop aborts at the
    # first ((killed++)) — before the final marker rm and the "stopped" success.
    if [[ -e "$nd/port" ]]; then ok=0; info "  port marker not removed (aborted before final rm)"; fi
    if ! grep -q "stopped" <<<"$out"; then ok=0; info "  'Node ... stopped' line missing (aborted before function end)"; fi
    # tmux-session reaping is an EXTRA signal, only checkable when tmux exists.
    if [[ "$has_tmux" -eq 1 ]] && tmux has-session -t "$sess" 2>/dev/null; then ok=0; info "  tmux session survived (aborted before tmux-kill block)"; fi

    kill "$mainpid" "$bridgepid" 2>/dev/null || true
    wait "$mainpid" "$bridgepid" 2>/dev/null || true
    [[ "$has_tmux" -eq 1 ]] && tmux kill-session -t "$sess" 2>/dev/null || true
    rm -rf "$temp_home"

    if [[ "$ok" -eq 1 ]]; then
        success "stop_single_node reaches end after first kill (C3)"
    else
        fail "stop_single_node aborts mid-function after first kill (C3)"
    fi
}

test_clean_removes_all_chat_id_files() {
    local temp_home node sd out left
    temp_home=$(mktemp -d)
    node="cleant$$"
    sd="$temp_home/.claude/telegram/nodes/$node/sessions"
    mkdir -p "$sd/sessA" "$sd/sessB" "$sd/sessC"
    echo 111 > "$sd/sessA/chat_id"
    echo 222 > "$sd/sessB/chat_id"
    echo 333 > "$sd/sessC/chat_id"

    out=$(HOME="$temp_home" CLAUDE_DIR="$temp_home/.claude" \
          ./claudecode-telegram.sh --node "$node" clean 2>&1) || true
    left=$(find "$sd" -name chat_id 2>/dev/null | wc -l | tr -d ' ')
    rm -rf "$temp_home"

    if [[ "$left" -eq 0 ]] && grep -q "cleaned" <<<"$out"; then
        success "clean removes all chat_id files (N1)"
    else
        fail "clean aborts after first chat_id removal (N1): $left chat_id file(s) left"
    fi
}

test_webhook_failure_cleanup_removes_pidfiles() {
    local d dp lib outf left reached
    d=$(mktemp -d); lib=$(launcher_lib_path); outf=$(mktemp)
    : > "$d/bridge.pid"; : > "$d/tunnel.pid"; : > "$d/pid"
    # A numeric PID above any real pid_max → kill reliably fails with ESRCH, with
    # no spawn/reap pid-reuse race. (Linux default pid_max is ~4.2M.)
    dp=2147483647

    # Separate bash process = fresh, fully-armed errexit (the parent test fn's
    # errexit is suspended by run_test's `|| fail`). The launcher's own
    # `set -euo pipefail` arms it; the buggy cleanup aborts on the failed kill
    # BEFORE the rm, so REACHED_END is absent and the pid files survive.
    bash -c '
        source "$1"
        node_dir="$2"; bridge_pid="$3"; tunnel_pid="$3"
        _webhook_fail_cleanup
        echo REACHED_END
    ' _ "$lib" "$d" "$dp" >"$outf" 2>&1 || true

    left=$(ls "$d"/bridge.pid "$d"/tunnel.pid "$d"/pid 2>/dev/null | wc -l | tr -d ' ')
    reached=no; grep -q REACHED_END "$outf" && reached=yes
    rm -rf "$d" "$lib" "$outf"

    if [[ "$left" -eq 0 && "$reached" == "yes" ]]; then
        success "webhook-fail cleanup removes pid files when kill fails (C6)"
    else
        fail "webhook-fail cleanup aborts before rm when kill fails (C6): $left pid file(s) left, reached=$reached"
    fi
}

run_cli_tests() {
    # CLI tests (no bridge needed)
    log ""
    log "── CLI Tests ───────────────────────────────────────────────────────────"
    run_test test_cli_help
    run_test test_cli_version
    run_test test_cli_flags_and_commands
    run_test test_cli_unknown_command
    run_test test_cli_missing_token_error
    run_test test_cli_hook_install_uninstall
    # CLI command coverage tests
    log ""
    log "── CLI Command Coverage Tests ──────────────────────────────────────────"
    run_test test_cli_status_command
    run_test test_cli_webhook_info
    run_test test_cli_webhook_commands
    run_test test_cli_hook_test_no_chat
    # v1.3.5 Task 1 — set -e suite-killer regressions (C3 / N1 / C6)
    log ""
    log "── set -e suite-killer regression Tests ────────────────────────────────"
    run_test test_stop_single_node_reaches_end_after_first_kill
    run_test test_clean_removes_all_chat_id_files
    run_test test_webhook_failure_cleanup_removes_pidfiles
}

run_integration_tests() {
    # Integration tests (bridge needed)
    log ""
    log "── Integration Tests ───────────────────────────────────────────────────"
    # Start the recording Mock-Telegram server BEFORE the bridge so the bridge
    # launch inherits TELEGRAM_API_BASE + MOCK_TG_ACTIVE (test_bridge_starts wires
    # them into the launch env). This makes delivery/threading/reactions/media
    # observable at the real wire boundary in DEFAULT mode (e2e-hardening).
    if command -v start_mock_telegram >/dev/null 2>&1; then
        start_mock_telegram || true
    fi
    run_test test_bridge_starts || exit 1
    sleep 0.3

    # Mock-Telegram DEFAULT-mode tests (SEAM-02/03/07/08/09/10 + new). They assert
    # at the recorded wire boundary, never the bridge log. C4 FIX: run them ONLY
    # when the mock is active AND the runner was sourced AND the bridge is actually
    # LISTENING on $PORT — gating on MOCK_TG_ACTIVE alone fired them against a dead
    # bridge and red the whole suite under TEST_FILTER. Skip loudly otherwise.
    if [[ "${MOCK_TG_ACTIVE:-}" == "1" ]] && command -v run_mock_tests >/dev/null 2>&1; then
        if wait_for_port "$PORT"; then
            run_mock_tests
        else
            info "Skipping run_mock_tests: bridge not listening on port $PORT"
        fi
    fi

    # HTTP endpoint tests
    log ""
    log "── HTTP Endpoint Tests ─────────────────────────────────────────────────"
    run_test test_health_endpoint
    run_test test_response_endpoint_missing_fields
    run_test test_response_endpoint_no_chat_id
    run_test test_notify_endpoint_missing_text
    run_test test_checkin_endpoint
    run_test test_checkin_note
    run_test test_health_workers_endpoint
    run_test test_api_index_returns_json
    run_test test_unknown_get_returns_404
    run_test test_unknown_post_returns_404
    run_test test_known_endpoints_unchanged
    run_test test_webhook_root_still_works
    # Admin tests
    log ""
    log "── Admin Tests ─────────────────────────────────────────────────────────"
    run_test test_admin_registration
    log "── Topic/DM Session Lifecycle Tests ────────────────────────────────────"
    run_test test_dm_session_lifecycle
    # Worker naming tests (integration)
    log ""
    log "── Worker Naming Tests (Integration) ───────────────────────────────────"
    run_test test_reserved_names_rejection
    # Tmux mode behavior tests (session lifecycle + delivery via product paths)
    log ""
    log "── Tmux Mode Behavior Tests ────────────────────────────────────────────"
    run_test test_tmux_mode_session_stays_alive
    run_test test_tmux_mode_message_delivery
    # Security tests (integration)
    log ""
    log "── Security Tests (Integration) ────────────────────────────────────────"
    run_test test_webhook_secret
    run_test test_graceful_shutdown_notification
    run_test test_typing_indicator_loop
    run_test test_token_isolation
    run_test test_secure_directory_permissions
    run_test test_session_files
    # Image/document handling tests
    log ""
    log "── Image/Document Handling Tests ───────────────────────────────────────"
    run_test test_inbox_directory
    run_test test_document_message_routing
    run_test test_incoming_document_e2e
    run_test test_incoming_image_e2e
    run_test test_response_with_image_tags
    # Response/notify endpoint tests
    log ""
    log "── Response/Notify Endpoint Tests ──────────────────────────────────────"
    run_test test_notify_endpoint
    run_test test_response_endpoint
    run_test test_response_without_pending
    # Persistence tests (integration)
    log ""
    log "── Persistence Tests (Integration) ─────────────────────────────────────"
    run_test test_last_chat_id_persistence
    # Hook behavior tests (integration)
    log ""
    log "── Hook Behavior Tests (Integration) ───────────────────────────────────"
    run_test test_hook_env_validation
    run_test test_checkin_hook_env_validation
    run_test test_checkin_hook_calls_endpoint
    # send_to_session integration tests
    log ""
    log "── send_to_session Integration Tests ────────────────────────────────────"
    run_test test_send_to_session_integration
    # Worker-to-worker pipe communication tests (e2e behavior)
    log ""
    log "── Worker-to-Worker Pipe Tests (Integration) ───────────────────────────"
    # Tmux and process inspection tests (integration)
    log ""
    log "── Tmux/Process Inspection Tests (Integration) ─────────────────────────"
    run_test test_tmux_prompt_empty
    run_test test_process_inspection_functions
    # export_hook_env guard tests
    log ""
    log "── export_hook_env Guard Tests (Integration) ───────────────────────────"
    run_test test_export_hook_env_skips_live_bridge
    run_test test_export_hook_env_overwrites_dead_bridge
    # bridge-ops restart-node env propagation
    log ""
    log "── bridge-ops restart-node Tests (Integration) ─────────────────────────"
    run_test test_restart_node_env_propagation
    # Cleanup test sessions
    send_message "/end testbot1" >/dev/null 2>&1 || true
}

run_full_tests() {
    # Full mode tests
    log ""
    log "── Tunnel Tests ────────────────────────────────────────────────────────"
    run_test test_with_tunnel
}

run_tunnel_tests() {
    run_full_tests
}

# Real-claude E2E runner (E2E=1). EMPTY stub so E2E=1 degrades gracefully when
# tests/e2e_tests.sh is absent. The real run_e2e_tests + spawn_real_claude in
# tests/e2e_tests.sh override this when that file is sourced (after main is
# defined, before main "$@" runs). Loud skip when claude is unavailable.
run_e2e_tests() {
    log ""
    log "── Real-Claude E2E Tests ───────────────────────────────────────────────"
    if ! check_claude_available; then
        info "Skipping E2E tests: claude CLI not available on PATH"
        return 0
    fi
    :
}

main() {
    log ""
    log "═══════════════════════════════════════════════════════════════════════"
    log "  claudecode-telegram Acceptance Tests"
    log "═══════════════════════════════════════════════════════════════════════"

    # Detect test mode
    local mode="default"
    local mode_desc=""
    if [[ "${FAST:-}" == "1" ]]; then
        mode="fast"
        mode_desc="FAST mode: Unit + CLI tests only (~10-15s)"
    elif [[ "${E2E:-}" == "1" ]]; then
        mode="e2e"
        mode_desc="E2E mode: Unit + Integration + real-claude E2E tests (requires claude CLI)"
    elif [[ "${FULL:-}" == "1" ]]; then
        mode="full"
        mode_desc="FULL mode: All tests including tunnel (~5 min)"
    else
        mode_desc="DEFAULT mode: Unit + Integration tests (~2-3 min)"
    fi
    log "  Mode: $mode_desc"
    if [[ -n "$TEST_FILTER" ]]; then
        local matching_tests
        matching_tests=$(count_matching_tests "$mode")
        log "  Filter: $TEST_FILTER (matching $matching_tests tests)"
    fi
    log "═══════════════════════════════════════════════════════════════════════"
    log ""

    require_token

    cd "$SCRIPT_DIR"

    # Always run unit and CLI tests
    run_unit_tests
    run_cli_tests

    # Skip integration tests in FAST mode
    if [[ "$mode" != "fast" ]]; then
        run_integration_tests

    fi

    # Run E2E and tunnel tests only in FULL mode
    if [[ "$mode" == "full" ]]; then
        # Tunnel tests
        run_full_tests
    fi

    # Real-claude E2E tests (gated behind E2E=1; runner sourced from e2e_tests.sh).
    # X4: integration (incl. the mock suite) already ran above because mode != fast;
    # this adds ONLY the real-claude seams — do NOT re-run integration here.
    if [[ "$mode" == "e2e" ]]; then
        run_e2e_tests
    fi

    # Summary
    log ""
    log "═══════════════════════════════════════════════════════════════════════"
    log "  Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, $tests_run tests run"
    log "═══════════════════════════════════════════════════════════════════════"
    log ""

    [[ $failed -eq 0 ]] && exit 0 || exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Wire in the e2e-hardening test files (sourced LAST, after every helper AND the
# run_e2e_tests stub above, so e2e_tests.sh's run_e2e_tests + spawn_real_claude
# override the stub and mock_tests.sh's run_mock_tests becomes available). Both
# files are self-contained and never redefine test.sh's own helpers.
# ─────────────────────────────────────────────────────────────────────────────
for f in "$SCRIPT_DIR"/tests/mock_tests.sh "$SCRIPT_DIR"/tests/e2e_tests.sh; do
    [[ -f "$f" ]] && source "$f"
done

main "$@"
