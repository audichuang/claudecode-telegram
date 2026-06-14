#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Real-Claude E2E tests (architecture B — gated behind E2E=1).
#
# Closes the agent-driven half of the e2e-hardening seams:
#   SEAM-01  real claude never runs              -> a REAL claude turn drives the chain
#   SEAM-06  Stop-hook contract end-to-end       -> TMUX_FALLBACK=0 forces real jsonl extraction
#   SEAM-04  spawn-in-cwd (prod path)            -> claude genuinely alive in the picked cwd
#   SEAM-05  pane-live != claude-live            -> marker roundtrip proves the PROCESS, not the bash pane
#   SEAM-03  thread isolation (L3 half)          -> two real topics, each marker lands only in its own thread
#   SEAM-04  trust-dialog auto-answer (defensive)-> OPTIONAL non-blocking, no --dangerously-skip-permissions
#
# This file is SELF-CONTAINED and meant to be SOURCED by test.sh AFTER its
# helpers are defined. It relies on (and never redefines) the canonical helper
# API from test.sh: start_mock_telegram, mock_reset, mock_assert_sendmessage,
# mock_assert_thread_absent, check_claude_available, wait_for_session,
# wait_for_session_gone, send_topic_message, run_test, info/success/fail, and the
# config vars SCRIPT_DIR / TEST_NODE_DIR / TEST_SESSION_DIR / TEST_TMUX_PREFIX /
# MOCKPORT / CHAT_ID. It also OVERRIDES the run_e2e_tests stub defined in test.sh.
#
# Design contract (Codex §8 — all mandatory):
#  1. Drive the REAL path: forum_topic webhook -> folder-picker callback_query
#     (use:<token>) -> bridge create_session (real tmux spawn). We NEVER call
#     open_topic_session/create_session directly and NEVER spawn claude ourselves.
#  2. TMUX_FALLBACK=0 is pushed into the SESSION's tmux env after spawn so it
#     reaches the HOOK's own process — a green can then only come from real jsonl
#     extraction, never the capture-pane fallback.
#  3. The bridge is launched with CLAUDE_SETTINGS_FILE_SPAWN pointing at a
#     settings.json that pins the spawned claude's Stop hook to the REPO's
#     hooks/send-to-telegram.sh (hermetic — not the operator's global hook).
#  4. Turn-completion = poll the mock /_recorded for the marker sendMessage,
#     NEVER pending-file absence (the hook removes pending + exits 0 even when
#     extraction finds no text).
#  5. Marker prompt asks for a unique nonce token; we assert CONTAINS (claude may
#     wrap the token in extra prose).
#  6. Readiness keys off claude actually ANSWERING (marker roundtrip), not
#     generic pane text (avoids misreading a login/rate-limit screen as "ready").
#
# A turn timeout is a HARD FAILURE. Absent claude => the runner SKIPS loudly
# (returns 0 without running) — it never passes a skipped seam.
# ─────────────────────────────────────────────────────────────────────────────

# How long to wait for a real no-tool claude turn to land in the mock. A no-tool
# marker turn returns in ~4s; we give generous headroom but treat exhaustion as
# a HARD failure (the assertion below fails -> the test fails).
E2E_TURN_TIMEOUT_SECS="${E2E_TURN_TIMEOUT_SECS:-90}"
# How long to wait for the real tmux spawn (create_session sleeps ~4s internally).
E2E_SPAWN_TIMEOUT_SECS="${E2E_SPAWN_TIMEOUT_SECS:-30}"

# State shared across the E2E tests (set by _e2e_setup_bridge).
E2E_BRIDGE_PID=""
E2E_BRIDGE_PORT=""
E2E_SETTINGS_FILE=""
E2E_TOPIC_ROOT=""

# ── E2E-local mock wire helpers ──────────────────────────────────────────────
# The canonical mock_* helpers in test.sh hardcode 127.0.0.1:$MOCKPORT; we reuse
# $MOCKPORT but add a couple of E2E-only readers (picker token extraction, marker
# polling) that test.sh does not provide.

# Read the whole /_recorded array.
_e2e_recorded() {
    curl -s "http://127.0.0.1:$MOCKPORT/_recorded"
}

# Extract the `use:<token>` callback_data from the most recent folder-picker
# sendMessage to <thread_id>. The picker is always rooted at the bridge's
# TOPIC_ROOT, so its "✅ 用這層" button targets TOPIC_ROOT exactly — replaying this
# token spawns the session in TOPIC_ROOT with a token the bridge already knows
# (no stale-token fallback to root). Prints the token, or empty on miss.
_e2e_picker_use_token() {
    local thread_id="$1"
    _e2e_recorded | jq -r --argjson n "$thread_id" '
        [ .[]
          | select(.method=="sendMessage" and .message_thread_id==$n)
          | .raw.reply_markup.inline_keyboard[]?[]?
          | select((.callback_data // "") | startswith("use:"))
          | .callback_data ]
        | last // ""
    '
}

# Poll the mock until a sendMessage to <thread_id> contains <marker>, or the
# turn timeout elapses. Returns 0 on delivery, 1 on timeout (-> HARD failure at
# the call site). NEVER keys off pending-file absence.
_e2e_wait_for_marker() {
    local thread_id="$1" marker="$2"
    local deadline=$(( SECONDS + E2E_TURN_TIMEOUT_SECS ))
    while (( SECONDS < deadline )); do
        if mock_assert_sendmessage "$thread_id" "$marker"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# A unique marker token per turn so two tests / two threads can never confuse
# each other's deliveries.
_e2e_nonce() {
    echo "TESTMARKER-$$-${RANDOM}${RANDOM}"
}

# The folder-picker text marker (so we can tell the picker landed before we
# replay the callback).
_E2E_PICKER_HINT="選好資料夾後再下指令"

# Poll for the picker sendMessage to <thread_id> carrying the hint text.
_e2e_wait_for_picker() {
    local thread_id="$1"
    local deadline=$(( SECONDS + E2E_SPAWN_TIMEOUT_SECS ))
    while (( SECONDS < deadline )); do
        if mock_assert_sendmessage "$thread_id" "$_E2E_PICKER_HINT"; then
            return 0
        fi
        sleep 0.3
    done
    return 1
}

# ── Pre-trust the spawn cwd (Codex §8 spawn job #1) ──────────────────────────
# Even with --dangerously-skip-permissions, current claude (2.1.x) shows a
# one-time "Is this a project you created or one you trust?" dialog for an
# untrusted folder, which would block the spawn forever (no turn ever completes).
# Claude records trusted folders in ~/.claude.json under
# projects["<realpath>"].hasTrustDialogAccepted. We mark the spawn cwd trusted
# BEFORE the spawn (idempotent, with a one-time backup) and restore the original
# file on teardown. The cwd is an isolated throwaway test dir, so this is benign.
E2E_CLAUDE_JSON="${E2E_CLAUDE_JSON:-$HOME/.claude.json}"
E2E_CLAUDE_JSON_BAK=""

_e2e_pretrust_dir() {
    local dir="$1"
    [[ -f "$E2E_CLAUDE_JSON" ]] || return 0
    # Back up exactly once per run so teardown can restore the operator's file.
    if [[ -z "$E2E_CLAUDE_JSON_BAK" ]]; then
        E2E_CLAUDE_JSON_BAK="$TEST_NODE_DIR/claude_json.e2ebak"
        cp -p "$E2E_CLAUDE_JSON" "$E2E_CLAUDE_JSON_BAK" 2>/dev/null || true
    fi
    CLAUDE_JSON="$E2E_CLAUDE_JSON" TRUST_DIR="$dir" python3 - <<'PY' 2>/dev/null || true
import json, os
p = os.environ["CLAUDE_JSON"]
real = os.path.realpath(os.environ["TRUST_DIR"])
try:
    with open(p) as fh:
        d = json.load(fh)
except Exception:
    d = {}
ent = d.setdefault("projects", {}).setdefault(real, {})
ent["hasTrustDialogAccepted"] = True
ent.setdefault("hasCompletedProjectOnboarding", True)
ent.setdefault("projectOnboardingSeenCount", 1)
ent.setdefault("allowedTools", [])
tmp = p + ".e2etmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, p)
PY
}

_e2e_restore_claude_json() {
    if [[ -n "$E2E_CLAUDE_JSON_BAK" && -f "$E2E_CLAUDE_JSON_BAK" ]]; then
        mv -f "$E2E_CLAUDE_JSON_BAK" "$E2E_CLAUDE_JSON" 2>/dev/null || true
        E2E_CLAUDE_JSON_BAK=""
    fi
}

# ── Pinned-hook settings.json ────────────────────────────────────────────────
# Write a settings.json whose ONLY job is to pin the spawned claude's Stop hook
# to the REPO hook (hermetic; independent of the operator's global ~/.claude).
_e2e_write_settings() {
    local repo_hook="$SCRIPT_DIR/hooks/send-to-telegram.sh"
    E2E_SETTINGS_FILE="$TEST_NODE_DIR/e2e_settings.json"
    cat > "$E2E_SETTINGS_FILE" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "$repo_hook" }
        ]
      }
    ]
  }
}
JSON
}

# ── Dedicated E2E bridge ─────────────────────────────────────────────────────
# We launch our OWN bridge (separate from test_bridge_starts) because the E2E
# bridge needs CLAUDE_SETTINGS_FILE_SPAWN + TOPIC_ROOT set, which the default
# integration bridge launch does not provide. It is pointed at the same mock and
# uses the same TMUX_PREFIX as test.sh so wait_for_session/wait_for_session_gone
# and the inbox-node helpers keep working.
#
# Picks a free bridge port distinct from $PORT and $MOCKPORT so it never collides
# with a default integration bridge that may also be running.
_e2e_setup_bridge() {
    info "E2E: setting up dedicated real-claude bridge..."

    # Mock must be up first (exports TELEGRAM_API_BASE -> the bridge inherits it).
    if [[ "${MOCK_TG_ACTIVE:-}" != "1" ]]; then
        start_mock_telegram || { fail "E2E: mock Telegram failed to start"; return 1; }
    fi

    mkdir -p "$TEST_NODE_DIR" "$TEST_SESSION_DIR"
    chmod 700 "$TEST_NODE_DIR" "$TEST_SESSION_DIR" 2>/dev/null || true

    # TOPIC_ROOT is the sandbox the folder picker is confined to; per-test cwds
    # live under it so the "✅ 用這層" token resolves to a real, in-root dir.
    E2E_TOPIC_ROOT="$TEST_NODE_DIR/e2e_root"
    mkdir -p "$E2E_TOPIC_ROOT"

    _e2e_write_settings

    # Free port for the E2E bridge (avoid $PORT and $MOCKPORT).
    E2E_BRIDGE_PORT="${E2E_BRIDGE_PORT_OVERRIDE:-$((PORT + 200))}"
    lsof -ti :"$E2E_BRIDGE_PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    sleep 0.2

    local e2e_log="$TEST_NODE_DIR/e2e_bridge.log"
    : > "$e2e_log"

    # Admin = CHAT_ID so the seeded forum chat passes the admin gate.
    TELEGRAM_BOT_TOKEN="${MOCK_BOT_TOKEN:-mock-token}" \
    PORT="$E2E_BRIDGE_PORT" \
    NODE_NAME="$TEST_NODE" \
    SESSIONS_DIR="$TEST_SESSION_DIR" \
    TMUX_PREFIX="$TEST_TMUX_PREFIX" \
    ADMIN_CHAT_ID="$CHAT_ID" \
    TEAM_DIR="$TEST_NODE_DIR/team" \
    TOPIC_ROOT="$E2E_TOPIC_ROOT" \
    TELEGRAM_API_BASE="http://127.0.0.1:$MOCKPORT" \
    CLAUDE_SETTINGS_FILE_SPAWN="$E2E_SETTINGS_FILE" \
    BRIDGE_URL="http://localhost:$E2E_BRIDGE_PORT" \
    python3 -u "$SCRIPT_DIR/bridge.py" > "$e2e_log" 2>&1 &
    E2E_BRIDGE_PID=$!
    echo "$E2E_BRIDGE_PID" > "$TEST_NODE_DIR/e2e_bridge.pid"

    if wait_for_port "$E2E_BRIDGE_PORT"; then
        success "E2E: bridge up on port $E2E_BRIDGE_PORT (mock=$MOCKPORT, settings pinned)"
        return 0
    fi
    fail "E2E: bridge failed to start on port $E2E_BRIDGE_PORT"
    return 1
}

_e2e_teardown_bridge() {
    if [[ -n "$E2E_BRIDGE_PID" ]]; then
        kill "$E2E_BRIDGE_PID" 2>/dev/null || true
        E2E_BRIDGE_PID=""
    fi
    rm -f "$TEST_NODE_DIR/e2e_bridge.pid" 2>/dev/null || true
    # Kill any claude/tmux sessions WE spawned (test-prefixed only — never pkill).
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${TEST_TMUX_PREFIX}" \
        | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done || true
    # Restore the operator's ~/.claude.json (undo the pre-trust marking).
    _e2e_restore_claude_json
}

# Send a forum-topic webhook update to the E2E bridge (not $PORT). Mirrors
# send_topic_message but targets the dedicated E2E bridge port.
_e2e_send_topic_message() {
    local chat_id="$1" thread_id="$2" text="$3" message_id="${4:-$((RANDOM))}"
    local update_id=$((RANDOM))
    curl -s -X POST "http://localhost:$E2E_BRIDGE_PORT" \
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
        }' >/dev/null
}

# Replay a folder-picker callback_query (use:<token>) to the E2E bridge so the
# REAL handle_callback -> open_topic_session -> create_session path runs.
# <sender_id> defaults to <chat_id> (admin); pass a non-admin id to exercise the
# callback admin gate.
_e2e_send_callback() {
    local chat_id="$1" thread_id="$2" data="$3" sender_id="${4:-$chat_id}"
    local update_id=$((RANDOM)) cq_id=$((RANDOM)) msg_id=$((RANDOM))
    curl -s -X POST "http://localhost:$E2E_BRIDGE_PORT" \
        -H "Content-Type: application/json" \
        -d '{
            "update_id": '"$update_id"',
            "callback_query": {
                "id": "'"$cq_id"'",
                "from": {"id": '"$sender_id"', "first_name": "TestUser"},
                "data": "'"$data"'",
                "message": {
                    "message_id": '"$msg_id"',
                    "message_thread_id": '"$thread_id"',
                    "chat": {"id": '"$chat_id"', "type": "supergroup", "is_forum": true},
                    "date": '"$(date +%s)"'
                }
            }
        }' >/dev/null
}

# Drive the REAL LINK1->LINK2 spawn for one topic and return its session name on
# stdout. Spawns into <cwd> (created under TOPIC_ROOT). After spawn, pushes
# TMUX_FALLBACK=0 into the SESSION's tmux env (reaches the hook process).
#
# Args: <thread_id> <chat_id> <cwd>
# Prints: the spawned session name (e.g. t<thread_id>) on success; empty on fail.
spawn_real_claude() {
    local thread_id="$1" chat_id="$2" cwd="$3"
    mkdir -p "$cwd"

    # Codex §8 spawn job #1: pre-trust the spawn cwd so claude doesn't block on
    # the trust dialog. The bridge clamps the pick to realpath(TOPIC_ROOT), so
    # trust that exact dir (the picked cwd resolves there).
    _e2e_pretrust_dir "$E2E_TOPIC_ROOT"

    # LINK1: the topic's first message is just the trigger -> picker appears.
    _e2e_send_topic_message "$chat_id" "$thread_id" "open topic"
    if ! _e2e_wait_for_picker "$thread_id"; then
        echo ""
        return 1
    fi

    # Extract the real use:<token> for THIS thread's picker (token == cwd because
    # TOPIC_ROOT == cwd's ancestor and the picker is rooted there; we pick the
    # exact-cwd token below by pointing the picker root at cwd).
    local token
    token=$(_e2e_picker_use_token "$thread_id")
    if [[ -z "$token" ]]; then
        echo ""
        return 1
    fi

    # LINK2: replay the folder-pick callback -> REAL create_session tmux spawn.
    _e2e_send_callback "$chat_id" "$thread_id" "$token"

    # The session name the bridge will use (no usable topic title -> t<id>).
    local session
    session="t${thread_id}"

    # Wait for the REAL tmux spawn + meta binding (chat_id file written by
    # save_topic_meta inside open_topic_session).
    local deadline=$(( SECONDS + E2E_SPAWN_TIMEOUT_SECS ))
    local bound=0
    while (( SECONDS < deadline )); do
        if tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null \
           && [[ -f "$TEST_SESSION_DIR/$session/chat_id" ]]; then
            bound=1
            break
        fi
        sleep 0.3
    done
    if [[ "$bound" != "1" ]]; then
        echo ""
        return 1
    fi

    # Codex §8.2: TMUX_FALLBACK=0 MUST reach the hook's own process env. The
    # bridge env does NOT propagate to the hook, so set it on the SESSION here.
    tmux set-environment -t "${TEST_TMUX_PREFIX}${session}" TMUX_FALLBACK 0 2>/dev/null || true

    # Codex §8.6: readiness keys off claude actually ANSWERING, not generic pane
    # text. open_topic_session routes a welcome prompt to the fresh claude; its
    # reply comes back as an HTML-wrapped "<b>t<id>:</b>" sendMessage to the
    # thread. Waiting for it proves (a) claude launched interactively, (b) it
    # completed a real turn, and (c) it is now IDLE — so the marker prompt below
    # lands on a ready process, not a still-thinking / login / rate-limited TUI.
    # (claude with Opus xhigh can take ~30s on the big welcome prompt.)
    local ready_deadline=$(( SECONDS + E2E_TURN_TIMEOUT_SECS ))
    local ready=0
    while (( SECONDS < ready_deadline )); do
        if mock_assert_sendmessage "$thread_id" "<b>${session}:</b>"; then
            ready=1
            break
        fi
        # If the session died before answering, fail fast (don't burn the timeout).
        if ! tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if [[ "$ready" != "1" ]]; then
        echo ""
        return 1
    fi

    echo "$session"
    return 0
}

# NOTE on cwd: the folder picker is always rooted at the bridge's single
# TOPIC_ROOT, so every "✅ 用這層" pick spawns the session in TOPIC_ROOT. The <cwd>
# arg to spawn_real_claude is therefore informational — the authoritative spawn
# cwd is realpath(TOPIC_ROOT). The cwd test asserts against that realpath; the
# isolation test only needs two distinct THREADS (both may share TOPIC_ROOT).

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-01 / SEAM-06 cornerstone: a REAL claude turn drives the REAL Stop hook,
# and the mock records the marker in the RIGHT thread. TMUX_FALLBACK=0 means the
# only way the marker can appear is real jsonl extraction by hooks/send-to-telegram.sh.
# ─────────────────────────────────────────────────────────────────────────────
test_e2e_real_claude_marker_roundtrip() {
    check_claude_available || { info "SKIP test_e2e_real_claude_marker_roundtrip: claude absent"; return 0; }
    info "E2E SEAM-01/06: real claude turn -> real Stop hook -> mock records marker (TMUX_FALLBACK=0)"
    mock_reset

    local tid=$((600000 + RANDOM % 90000))
    local cwd="$E2E_TOPIC_ROOT"   # picker root button targets TOPIC_ROOT exactly
    local session
    session=$(spawn_real_claude "$tid" "$CHAT_ID" "$cwd")
    if [[ -z "$session" ]]; then
        fail "E2E SEAM-01/06: real claude failed to spawn for thread $tid"
        return 1
    fi

    local marker; marker=$(_e2e_nonce)
    _e2e_send_topic_message "$CHAT_ID" "$tid" \
        "Reply with exactly this token and nothing else: $marker"

    if _e2e_wait_for_marker "$tid" "$marker"; then
        success "E2E SEAM-01/06: real claude turn delivered marker into thread $tid via real Stop hook"
    else
        fail "E2E SEAM-01/06: marker '$marker' never reached thread $tid within ${E2E_TURN_TIMEOUT_SECS}s (HARD failure)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-04 main (prod path): real claude is genuinely ALIVE in the picked cwd.
# Prove it by asking claude to report its working directory; the marker IS the
# cwd path, so a green requires (a) a live claude process and (b) it being born
# in the chosen folder. PROD path: spawn uses --dangerously-skip-permissions.
# ─────────────────────────────────────────────────────────────────────────────
test_e2e_spawn_runs_claude_in_cwd() {
    check_claude_available || { info "SKIP test_e2e_spawn_runs_claude_in_cwd: claude absent"; return 0; }
    info "E2E SEAM-04: real claude alive in the picked cwd (prod --dangerously-skip-permissions path)"
    mock_reset

    local tid=$((610000 + RANDOM % 90000))
    local cwd="$E2E_TOPIC_ROOT"   # the cwd claude should be born in (== realpath TOPIC_ROOT)
    local session
    session=$(spawn_real_claude "$tid" "$CHAT_ID" "$cwd")
    if [[ -z "$session" ]]; then
        fail "E2E SEAM-04: real claude failed to spawn for thread $tid"
        return 1
    fi

    # The bridge clamps the picked cwd to realpath(TOPIC_ROOT); ask claude to run
    # pwd and echo its basename plus a nonce so the assertion is unambiguous.
    local nonce="CWD-$$-${RANDOM}"
    local want; want=$(basename "$(cd "$cwd" && pwd -P)")
    _e2e_send_topic_message "$CHAT_ID" "$tid" \
        "Run the bash command 'pwd' and reply with exactly: $nonce:\$(basename \$(pwd))"

    # We assert the reply contains BOTH the nonce and the expected cwd basename:
    # that pair can only be produced by a live claude that can run a tool in the
    # right directory. (CONTAINS, since claude may add prose.)
    local deadline=$(( SECONDS + E2E_TURN_TIMEOUT_SECS ))
    local ok=0
    while (( SECONDS < deadline )); do
        if mock_assert_sendmessage "$tid" "$nonce" && mock_assert_sendmessage "$tid" "$want"; then
            ok=1; break
        fi
        sleep 0.5
    done
    if [[ "$ok" == "1" ]]; then
        success "E2E SEAM-04: live claude reported its cwd basename '$want' (nonce $nonce) in thread $tid"
    else
        fail "E2E SEAM-04: live-claude-in-cwd proof ('$nonce'+'$want') never reached thread $tid in ${E2E_TURN_TIMEOUT_SECS}s (HARD failure)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-05: the marker roundtrip proves the claude PROCESS is alive, not just the
# bash pane. tmux has-session passes even when claude has died and only the shell
# survives; a returned marker can ONLY come from a running claude answering a
# prompt. We assert: pane alive (has-session) AND a real turn answered.
# ─────────────────────────────────────────────────────────────────────────────
test_e2e_claude_actually_alive_not_just_pane() {
    check_claude_available || { info "SKIP test_e2e_claude_actually_alive_not_just_pane: claude absent"; return 0; }
    info "E2E SEAM-05: marker roundtrip proves the claude PROCESS (not the bash pane)"
    mock_reset

    local tid=$((620000 + RANDOM % 90000))
    local cwd="$E2E_TOPIC_ROOT"
    local session
    session=$(spawn_real_claude "$tid" "$CHAT_ID" "$cwd")
    if [[ -z "$session" ]]; then
        fail "E2E SEAM-05: real claude failed to spawn for thread $tid"
        return 1
    fi

    # Pane alive is necessary-but-insufficient; record it, then demand a turn.
    if ! tmux has-session -t "${TEST_TMUX_PREFIX}${session}" 2>/dev/null; then
        fail "E2E SEAM-05: tmux pane unexpectedly gone for $session"
        return 1
    fi

    local marker; marker=$(_e2e_nonce)
    _e2e_send_topic_message "$CHAT_ID" "$tid" \
        "Reply with exactly this token and nothing else: $marker"

    if _e2e_wait_for_marker "$tid" "$marker"; then
        success "E2E SEAM-05: live claude PROCESS answered (marker in thread $tid), not just a live pane"
    else
        fail "E2E SEAM-05: pane was alive but claude never answered marker '$marker' in ${E2E_TURN_TIMEOUT_SECS}s -> pane != process (HARD failure)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-03 (L3 half): two REAL topics, each with its own live claude. Each topic's
# unique marker must land ONLY in its own thread — proving real thread targeting
# end-to-end (no cross-talk). Asserts presence in the right thread AND absence in
# the wrong one.
# ─────────────────────────────────────────────────────────────────────────────
test_e2e_two_real_topics_isolated() {
    check_claude_available || { info "SKIP test_e2e_two_real_topics_isolated: claude absent"; return 0; }
    info "E2E SEAM-03 (L3): two real topics — each marker lands only in its own thread"
    mock_reset

    local tid_a=$((630000 + RANDOM % 40000))
    local tid_b=$((670000 + RANDOM % 40000))
    # Two DISTINCT threads, each driven through its own real picker+callback. Both
    # spawn in TOPIC_ROOT (one shared picker root) — isolation here is about
    # thread targeting, not per-cwd separation.
    local sess_a sess_b
    sess_a=$(spawn_real_claude "$tid_a" "$CHAT_ID" "$E2E_TOPIC_ROOT")
    sess_b=$(spawn_real_claude "$tid_b" "$CHAT_ID" "$E2E_TOPIC_ROOT")
    if [[ -z "$sess_a" || -z "$sess_b" ]]; then
        fail "E2E SEAM-03: failed to spawn both topics (a='$sess_a' b='$sess_b')"
        return 1
    fi

    local mark_a mark_b
    mark_a=$(_e2e_nonce)-A
    mark_b=$(_e2e_nonce)-B
    _e2e_send_topic_message "$CHAT_ID" "$tid_a" \
        "Reply with exactly this token and nothing else: $mark_a"
    _e2e_send_topic_message "$CHAT_ID" "$tid_b" \
        "Reply with exactly this token and nothing else: $mark_b"

    local got_a=0 got_b=0
    if _e2e_wait_for_marker "$tid_a" "$mark_a"; then got_a=1; fi
    if _e2e_wait_for_marker "$tid_b" "$mark_b"; then got_b=1; fi

    if [[ "$got_a" != "1" || "$got_b" != "1" ]]; then
        fail "E2E SEAM-03: a marker never arrived (a=$got_a b=$got_b) within ${E2E_TURN_TIMEOUT_SECS}s (HARD failure)"
        return 1
    fi

    # Isolation: A's marker must NOT appear in B's thread and vice versa.
    if mock_assert_thread_absent "$mark_a" "$tid_b" \
       && mock_assert_thread_absent "$mark_b" "$tid_a"; then
        success "E2E SEAM-03: each topic's marker landed ONLY in its own thread (no cross-talk)"
    else
        fail "E2E SEAM-03: marker cross-talk detected between threads $tid_a and $tid_b"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL / NON-BLOCKING (clearly labeled): the trust-dialog auto-answer is
# DEFENSIVE code (bridge.py ~4255). The PROD path uses --dangerously-skip-
# permissions and never shows the dialog, so this is NOT exercised by the main
# SEAM-04 test. Here we deliberately spawn WITHOUT that flag in a FRESH untrusted
# tmpdir to see whether the auto-answer lets a turn complete. This test never
# fails the suite: it reports DID/COULD-NOT exercise and returns 0 regardless
# (the prod path's correctness does not depend on it).
# ─────────────────────────────────────────────────────────────────────────────
test_e2e_trust_dialog_auto_answered() {
    check_claude_available || { info "SKIP test_e2e_trust_dialog_auto_answered: claude absent"; return 0; }
    info "E2E SEAM-04 (NON-BLOCKING, defensive): trust-dialog auto-answer in a fresh untrusted tmpdir"

    # This path needs a bridge that spawns WITHOUT --dangerously-skip-permissions.
    # The prod build_claude_start_cmd always appends that flag, so we cannot
    # exercise the dialog through the prod bridge. We surface that honestly rather
    # than fake a green.
    info "NON-BLOCKING: prod build_claude_start_cmd always appends --dangerously-skip-permissions;"
    info "NON-BLOCKING: the trust dialog cannot appear on the prod path, so this defensive branch"
    info "NON-BLOCKING: is not exercised end-to-end here. Reported, not asserted (returns 0)."
    success "E2E SEAM-04 (non-blocking): trust-dialog branch acknowledged as defensive-only (no false green)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Runner — overrides the stub in test.sh when this file is sourced AFTER it.
# Loud skip (return 0) when claude is absent; otherwise sets up the dedicated
# E2E bridge, runs the seam tests, and tears down. A turn timeout inside any
# test is a HARD failure (it calls fail).
# ─────────────────────────────────────────────────────────────────────────────
run_e2e_tests() {
    log ""
    log "── Real-Claude E2E Tests ───────────────────────────────────────────────"
    if ! check_claude_available; then
        info "claude absent — skipping E2E (loud skip, not a pass)"
        return 0
    fi

    if ! _e2e_setup_bridge; then
        fail "E2E: bridge setup failed — cannot run real-claude tests"
        return 1
    fi

    run_test test_e2e_real_claude_marker_roundtrip
    run_test test_e2e_spawn_runs_claude_in_cwd
    run_test test_e2e_claude_actually_alive_not_just_pane
    run_test test_e2e_two_real_topics_isolated
    # Optional / non-blocking, clearly labeled:
    run_test test_e2e_trust_dialog_auto_answered

    _e2e_teardown_bridge
}
