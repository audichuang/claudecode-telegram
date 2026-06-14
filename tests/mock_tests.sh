#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT-mode mock-based e2e tests (e2e-hardening, SEAM-02/03/07/08/09/10 + new)
#
# Closes the un-falsifiable / spy-only seams by asserting at the REAL wire
# boundary recorded by tests/mock_telegram.py — never the bridge's own log.
# Each test follows the binding Codex Review Fixes (spec §8):
#   * mock_reset at the TOP of every test (records+faults+files cleared; first
#     message_id after reset == 1).
#   * ATOMIC assertions: method=="sendMessage" AND message_thread_id==tid AND
#     text-contains(marker). Filter by method, never "any call happened".
#   * Substring containment (replies are HTML-wrapped "<b>{name}:</b>\n{text}").
#   * tmain (thread 0) ⇒ the message_thread_id KEY is ABSENT (not 0).
#
# This file is SELF-CONTAINED test functions + a `run_mock_tests` runner. It is
# sourced by test.sh AFTER its helpers, so the canonical Helper API
# (start_mock_telegram, mock_reset, mock_assert_sendmessage, …, run_test) is
# already defined. It does NOT redefine those helpers and does NOT edit test.sh.
#
# IMPORTANT determinism rules learned at the wire (see the per-test notes):
#   * Each test uses a UNIQUE thread_id. A thread that ever saw a folder picker
#     stays in the bridge's in-RAM `_awaiting_folder`, so reusing it later
#     produces a "pick a folder" nudge instead of routing — never reuse a tid.
#   * Tests that must route to a worker (reaction 👀, typing, incoming media)
#     need a REGISTERED tmux session created BEFORE the message so
#     find_topic_session() resolves it (otherwise the unknown-topic path shows
#     the picker and never routes/downloads).
#   * Such tests kill their own tmux session at the end so its typing loop /
#     watchdog stop leaking late records into a later test's window.
# ─────────────────────────────────────────────────────────────────────────────

# Base thread ids per seam (kept disjoint so no two tests share a tid).
# SEAM-02: 21xx  SEAM-03: 23xx  SEAM-07: 27xx  SEAM-08: 28xx  SEAM-09: 29xx
# SEAM-10: 30xx  NEW scenarios: 31xx

# Seed a delivery-only bound topic session (no tmux needed): chat_id + thread_id
# files only. POST /response resolves chat from chat_id; thread from thread_id.
# Args: <name> <chat_id> <thread_id>
_mock_seed_session() {
    local name="$1" chat_id="$2" thread_id="$3"
    mkdir -p "$TEST_SESSION_DIR/$name"
    printf '%s' "$chat_id" > "$TEST_SESSION_DIR/$name/chat_id"
    printf '%s' "$thread_id" > "$TEST_SESSION_DIR/$name/message_thread_id"
}

# POST /response {session,text} (delivery from the chat_id file). Returns body.
_mock_post_response() {
    local session="$1" text="$2"
    python3 - "$PORT" "$session" "$text" <<'PY'
import json, sys, urllib.request
port, session, text = sys.argv[1], sys.argv[2], sys.argv[3]
body = json.dumps({"session": session, "text": text}).encode()
req = urllib.request.Request(
    f"http://localhost:{port}/response",
    data=body, headers={"Content-Type": "application/json"},
)
try:
    print(urllib.request.urlopen(req, timeout=10).read().decode())
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}")
PY
}

# POST /notify {text} (delivers to all known chat_ids incl. admin). Returns body.
_mock_post_notify() {
    local text="$1"
    hook_curl "http://localhost:$PORT/notify" '{"text":"'"$text"'"}'
}

# Raw webhook POST of an arbitrary update JSON (for non-admin / callback / media
# shapes the canonical send_topic_message helper doesn't model).
_mock_webhook() {
    local json="$1"
    curl -s -X POST "http://localhost:$PORT" \
        -H "Content-Type: application/json" -d "$json"
}

# Create a fake-claude executable once (a real interpreter binary literally named
# `claude`, so tmux's #{pane_current_command} == 'claude' satisfies is_online();
# it prints an empty `❯ ` prompt line so tmux_prompt_empty() matches, then idles
# ignoring pasted keys). Echoes the absolute path to the `claude` binary.
_mock_fake_claude_bin() {
    local dir="$TEST_NODE_DIR/mock_fakebin"
    local bin="$dir/claude"
    local stub="$dir/claude_stub.py"
    if [[ ! -x "$bin" || ! -f "$stub" ]]; then
        mkdir -p "$dir"
        cp "$(readlink -f "$(command -v python3)")" "$bin" 2>/dev/null || cp "$(command -v python3)" "$bin"
        chmod +x "$bin"
        cat > "$stub" <<'PY'
import sys, time
# Empty Claude-style prompt so tmux_prompt_empty()'s /^❯\s*$/ matches.
sys.stdout.write("❯ \n"); sys.stdout.flush()
while True:
    time.sleep(5)
PY
    fi
    printf '%s\n' "$bin"
}

# Build a fake-claude that REPLIES to every manager message via the REAL Stop hook.
# On each non-empty stdin line it writes a minimal transcript jsonl and runs
# hooks/send-to-telegram.sh with {"transcript_path":...} on stdin; the reply text
# is <marker> when the incoming line contains <marker> (the user's message), else a
# plain "ack" (the bridge's auto-sent onboarding instructions). Replying to EVERY
# message is load-bearing: the onboarding sets the bridge's `pending` state, and only
# a /response clears it — without acking the onboarding the bridge would queue (never
# deliver) the user's marker message. The stub runs INSIDE the bridge-spawned pane so
# $TMUX_PANE + the tmux session env are present and the hook resolves the session.
#
# The bridge launches `claude --dangerously-skip-permissions`; a bare python copy
# would die on that unknown option, so `claude` is a thin wrapper that IGNORES "$@"
# and execs a python copy named `claudebin` (basename CONTAINS "claude", so
# is_process_running()'s `"claude" in pane_current_command` holds). Echoes the wrapper
# path. Args: <dir> <marker>
_mock_hooking_fake_claude_bin() {
    local dir="$1" marker="$2"
    local wrapper="$dir/claude"        # what the bridge execs (PATH-resolved)
    local realbin="$dir/claudebin"     # python interpreter copy; comm contains "claude"
    local stub="$dir/claude_hook_stub.py"
    mkdir -p "$dir"
    # Remove any stale copies first: a prior run leaves these mode 0555 (no write),
    # so a plain `cp`/`>` redirect would silently FAIL to overwrite and we'd reuse
    # the old binary (a bare python copy that dies on `claude --dangerously-...`).
    rm -f "$wrapper" "$realbin" "$stub" 2>/dev/null || true
    cp "$(readlink -f "$(command -v python3)")" "$realbin" 2>/dev/null || cp "$(command -v python3)" "$realbin"
    chmod +x "$realbin"
    printf '#!/bin/sh\nexec "%s" "%s"\n' "$realbin" "$stub" > "$wrapper"
    chmod +x "$wrapper"
    # Unquoted heredoc so $marker / $SCRIPT_DIR interpolate; the stub has no other $.
    cat > "$stub" <<PY
import json, os, subprocess, sys, tempfile
MARKER = "$marker"
HOOK = "$SCRIPT_DIR/hooks/send-to-telegram.sh"
def prompt():
    sys.stdout.write("❯ \n"); sys.stdout.flush()   # keep tmux_prompt_empty() satisfied
prompt()
while True:
    line = sys.stdin.readline()                     # readline (NOT 'for line in' — that buffers)
    if line == "":                                  # EOF (pane killed) -> exit cleanly
        break
    if line.strip():
        # Reply to EVERY message so the bridge's pending state clears; only the
        # line carrying MARKER (the user's message) replies with MARKER.
        reply = MARKER if MARKER in line else "ack"
        # Compact jsonl ONLY: the hook greps literal "type":"user" / "type":"assistant"
        # with no spaces around the colon (separators=(",",":") guarantees that).
        tdir = tempfile.mkdtemp(prefix="fakeclaude-")
        tpath = os.path.join(tdir, "fakesession.jsonl")
        user = {"type":"user","message":{"role":"user","content":[{"type":"text","text":"trigger"}]}}
        asst = {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":reply}]}}
        with open(tpath, "w") as f:
            f.write(json.dumps(user, separators=(",",":")) + "\n")
            f.write(json.dumps(asst, separators=(",",":")) + "\n")
        payload = json.dumps({"transcript_path": tpath})
        # Run the REAL Stop hook synchronously (capture output so it never pollutes
        # the pane and break tmux_prompt_empty); it forwards the reply to /response.
        subprocess.run(["bash", HOOK], input=payload.encode(), capture_output=True)
    prompt()
PY
    printf '%s\n' "$wrapper"
}

# Spawn a REGISTERED, ONLINE topic session for <name>/<thread_id> bound to
# <chat_id>: a tmux session under $TEST_TMUX_PREFIX running the fake claude
# (online=true, prompt empty=true) + the chat_id/message_thread_id meta files.
# Args: <name> <chat_id> <thread_id>
_mock_spawn_online_session() {
    local name="$1" chat_id="$2" thread_id="$3"
    local bin stub
    bin="$(_mock_fake_claude_bin)"
    stub="$TEST_NODE_DIR/mock_fakebin/claude_stub.py"
    tmux kill-session -t "${TEST_TMUX_PREFIX}${name}" 2>/dev/null || true
    tmux new-session -d -s "${TEST_TMUX_PREFIX}${name}" "exec '$bin' '$stub'"
    _mock_seed_session "$name" "$chat_id" "$thread_id"
    # Poll until the pane command resolves to 'claude' (binary fully exec'd).
    local i=0
    while [[ $i -lt 30 ]]; do
        [[ "$(tmux display-message -t "${TEST_TMUX_PREFIX}${name}" -p '#{pane_current_command}' 2>/dev/null)" == "claude" ]] && break
        sleep 0.1; i=$((i + 1))
    done
}

# Spawn a plain (registered) idle tmux session for reap/close lifecycle tests —
# does NOT need to be "online"; the reaper/close path only needs it discoverable
# by find_topic_session (real tmux session) + its topic meta files.
# Args: <name> <chat_id> <thread_id>
_mock_spawn_idle_session() {
    local name="$1" chat_id="$2" thread_id="$3"
    tmux kill-session -t "${TEST_TMUX_PREFIX}${name}" 2>/dev/null || true
    tmux new-session -d -s "${TEST_TMUX_PREFIX}${name}" 'sleep 600'
    _mock_seed_session "$name" "$chat_id" "$thread_id"
}

_mock_kill_session() {
    tmux kill-session -t "${TEST_TMUX_PREFIX}${1}" 2>/dev/null || true
}

# Poll until the mock has recorded a sendMessage to <tid> containing <marker>,
# or timeout (~3s). Avoids fixed sleeps for async /response delivery.
_mock_wait_sendmessage() {
    local thread_id="$1" marker="$2" i=0
    while [[ $i -lt 30 ]]; do
        mock_assert_sendmessage "$thread_id" "$marker" && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-02 — delivery is observable at the wire (retires the false-green where a
# bridge log line "sent OK" was the only evidence).
# ─────────────────────────────────────────────────────────────────────────────

test_mock_response_delivers_real_sendmessage() {
    info "SEAM-02: POST /response delivers a REAL sendMessage to the bound thread"
    mock_reset
    _mock_seed_session "t2101" "$CHAT_ID" 2101
    _mock_post_response "t2101" "DELIVER-2101-marker" >/dev/null
    if _mock_wait_sendmessage 2101 "DELIVER-2101-marker"; then
        success "SEAM-02: real sendMessage recorded to thread 2101 with marker"
    else
        fail "SEAM-02: no sendMessage with marker reached the wire"
    fi
}

test_mock_notify_delivers_to_admin() {
    info "SEAM-02: POST /notify delivers a sendMessage to the admin chat"
    mock_reset
    _mock_post_notify "NOTIFY-admin-marker" >/dev/null
    # Admin chat is the launch ADMIN_CHAT_ID (== $CHAT_ID under the mock harness).
    sleep 0.3
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" --arg m "NOTIFY-admin-marker" \
            'any(.[]; .method=="sendMessage" and .chat_id==$c and (.text|contains($m)))' >/dev/null; then
        success "SEAM-02: /notify delivered to admin chat $CHAT_ID"
    else
        fail "SEAM-02: /notify did not reach the admin chat at the wire"
    fi
}

test_mock_response_failure_is_red() {
    info "SEAM-02 (RED guard): broken delivery records NO matching sendMessage"
    mock_reset
    # Deliver to an UNBOUND session (no chat_id file) — the bridge cannot resolve
    # a chat, returns 404, and emits NOTHING to the wire. The positive assertion
    # MUST be false here; that is exactly what makes the green test falsifiable.
    _mock_post_response "t2102_unbound" "BROKEN-2102-marker" >/dev/null
    sleep 0.3
    if mock_assert_sendmessage 2102 "BROKEN-2102-marker"; then
        fail "SEAM-02 (RED guard): a sendMessage was recorded for a broken delivery"
    else
        success "SEAM-02 (RED guard): broken delivery is silent at the wire (assertion red)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-03 — thread targeting + isolation. Asserts message_thread_id in the
# recorded payload; tmain (thread 0) must have the field ABSENT, not 0.
# ─────────────────────────────────────────────────────────────────────────────

test_mock_reply_lands_in_correct_thread() {
    info "SEAM-03: a /response reply carries the session's message_thread_id"
    mock_reset
    _mock_seed_session "t2301" "$CHAT_ID" 2301
    _mock_post_response "t2301" "THREAD-2301-marker" >/dev/null
    if _mock_wait_sendmessage 2301 "THREAD-2301-marker"; then
        success "SEAM-03: reply landed in thread 2301 (atomic method+tid+text match)"
    else
        fail "SEAM-03: reply did not carry message_thread_id==2301"
    fi
}

test_mock_two_topics_no_crosstalk() {
    info "SEAM-03: two bound topics never cross-talk"
    mock_reset
    _mock_seed_session "t2302" "$CHAT_ID" 2302
    _mock_seed_session "t2303" "$CHAT_ID" 2303
    _mock_post_response "t2302" "ONLY-IN-2302" >/dev/null
    _mock_post_response "t2303" "ONLY-IN-2303" >/dev/null
    _mock_wait_sendmessage 2302 "ONLY-IN-2302" || { fail "SEAM-03: 2302 marker missing in thread 2302"; return; }
    _mock_wait_sendmessage 2303 "ONLY-IN-2303" || { fail "SEAM-03: 2303 marker missing in thread 2303"; return; }
    # Neither marker may appear in the other thread.
    if mock_assert_thread_absent "ONLY-IN-2302" 2303 && mock_assert_thread_absent "ONLY-IN-2303" 2302; then
        success "SEAM-03: no crosstalk — each marker only in its own thread"
    else
        fail "SEAM-03: crosstalk detected between threads 2302/2303"
    fi
}

test_mock_tmain_omits_thread_id() {
    info "SEAM-03: tmain (thread 0) reply OMITS the message_thread_id key"
    mock_reset
    _mock_seed_session "tmain" "$CHAT_ID" 0
    _mock_post_response "tmain" "TMAIN-2304-marker" >/dev/null
    sleep 0.3
    # marker present in >=1 sendMessage AND none of those carry message_thread_id.
    if mock_assert_thread_absent "TMAIN-2304-marker"; then
        success "SEAM-03: tmain reply present with NO message_thread_id key (field-absent)"
    else
        fail "SEAM-03: tmain reply missing or carried a message_thread_id key"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-09 — admin gate silence. A non-admin update (BOTH from.id AND chat.id ≠
# admin) yields ZERO sends AND ZERO reactions. Admin gets a reply. A non-admin
# callback tap (separate gate) creates/browses nothing.
# ─────────────────────────────────────────────────────────────────────────────

test_mock_nonadmin_message_is_silent() {
    info "SEAM-09: a non-admin message produces zero sends and zero reactions"
    mock_reset
    local intruder_chat=2901999
    _mock_webhook '{
        "update_id": 290101,
        "message": {"message_id": 2901, "message_thread_id": 2901, "is_topic_message": true,
            "from": {"id": 2901888, "first_name": "Intruder"},
            "chat": {"id": '"$intruder_chat"', "type": "supergroup", "is_forum": true},
            "date": 1, "text": "let me in"}}' >/dev/null
    sleep 0.4
    if mock_assert_silence "$intruder_chat"; then
        success "SEAM-09: non-admin chat is silent (no sendMessage, no setMessageReaction)"
    else
        fail "SEAM-09: a call leaked to the non-admin chat $intruder_chat"
    fi
}

test_mock_admin_message_gets_reply() {
    info "SEAM-09: an admin message in an unknown topic gets a reply (folder picker)"
    mock_reset
    # Admin == $CHAT_ID (launch ADMIN_CHAT_ID). Unknown topic ⇒ folder picker
    # sendMessage into the thread: the observable, falsifiable "reply".
    send_topic_message "$CHAT_ID" 2902 "trigger" >/dev/null
    sleep 0.4
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson n 2902 'any(.[]; .method=="sendMessage" and .message_thread_id==$n)' >/dev/null; then
        success "SEAM-09: admin gets a reply in thread 2902 (gate let the admin through)"
    else
        fail "SEAM-09: admin message produced no reply (gate wrongly rejected the admin)"
    fi
}

test_mock_nonadmin_callback_tap_silent() {
    info "SEAM-09: a non-admin folder-pick callback creates/browses nothing"
    mock_reset
    local intruder_chat=2903999
    _mock_webhook '{
        "update_id": 290301,
        "callback_query": {"id": "mockcbq", "data": "use:deadbeef",
            "from": {"id": 2903888},
            "message": {"message_id": 2903, "message_thread_id": 2903,
                "chat": {"id": '"$intruder_chat"', "type": "supergroup", "is_forum": true}}}}' >/dev/null
    sleep 0.4
    # No answerCallbackQuery / browse / open for the intruder chat, and no session.
    if mock_assert_silence "$intruder_chat" && [[ ! -d "$TEST_SESSION_DIR/t2903" ]]; then
        success "SEAM-09: non-admin callback tap is silent and created no session"
    else
        fail "SEAM-09: non-admin callback tap leaked a call or created a session"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-10 — per-request liveness reaction arc (record half) + topic-scoped
# typing action. Driven through the REAL route_message→deliver path on an online
# fake-claude session, asserted on recorded setMessageReaction / sendChatAction.
# ─────────────────────────────────────────────────────────────────────────────

test_mock_reaction_arc_recorded() {
    info "SEAM-10: the 👀 → 👍 reaction arc is recorded on the triggering message"
    mock_reset
    _mock_spawn_online_session "t3001" "$CHAT_ID" 3001
    # Inbound topic message (pinned message_id 3001) → route_message stamps 👀.
    send_topic_message "$CHAT_ID" 3001 "do the work" 3001 >/dev/null
    # Wait for 👀 to land (route_message runs in a daemon thread).
    local i=0
    while [[ $i -lt 30 ]]; do
        mock_assert_reaction_arc "$CHAT_ID" 3001 "👀" && break
        sleep 0.1; i=$((i + 1))
    done
    # Delivery of a /response stamps 👍 on the same message.
    _mock_post_response "t3001" "work complete" >/dev/null
    i=0
    local ok=1
    while [[ $i -lt 30 ]]; do
        if mock_assert_reaction_arc "$CHAT_ID" 3001 "👀" "👍"; then ok=0; break; fi
        sleep 0.1; i=$((i + 1))
    done
    _mock_kill_session "t3001"
    if [[ $ok -eq 0 ]]; then
        success "SEAM-10: reaction arc 👀 → 👍 recorded in order on message 3001"
    else
        fail "SEAM-10: reaction arc 👀 → 👍 not recorded in order"
    fi
}

test_mock_typing_action_recorded() {
    info "SEAM-10: the typing action carries the topic's message_thread_id"
    mock_reset
    _mock_spawn_online_session "t3002" "$CHAT_ID" 3002
    # No /response here: pending stays set so the typing loop ticks ≥1 time.
    send_topic_message "$CHAT_ID" 3002 "please work" 3002 >/dev/null
    local i=0 ok=1
    while [[ $i -lt 30 ]]; do
        if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
            | jq -e --argjson n 3002 \
                'any(.[]; .method=="sendChatAction" and .action=="typing" and .message_thread_id==$n)' >/dev/null; then
            ok=0; break
        fi
        sleep 0.1; i=$((i + 1))
    done
    _mock_kill_session "t3002"
    if [[ $ok -eq 0 ]]; then
        success "SEAM-10: typing action recorded with message_thread_id==3002"
    else
        fail "SEAM-10: no topic-scoped typing action reached the wire"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-07 — media round-trips at the wire. Incoming: real getFile + /file
# download into the session inbox (sha-verified). Outgoing: real multipart with
# the correct field name + message_thread_id.
# ─────────────────────────────────────────────────────────────────────────────

test_mock_incoming_document_downloads_to_inbox() {
    info "SEAM-07: an incoming document round-trips getFile+download into the inbox"
    mock_reset
    # Registered session so find_topic_session routes the doc (else it's an
    # unknown topic → picker, no download).
    _mock_spawn_idle_session "t2701" "$CHAT_ID" 2701
    local src="$TEST_NODE_DIR/mock_in_2701.bin"
    printf 'MOCK-INBOX-PAYLOAD-2701-%s' "$RANDOM$RANDOM" > "$src"
    local sha
    sha=$(sha256sum "$src" 2>/dev/null | awk '{print $1}')
    # Register EXACTLY ONE file so getFile's single-file shortcut resolves it.
    mock_register_file_bytes "documents/f2701.bin" "$src"
    local fsize
    fsize=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null)
    _mock_webhook '{
        "update_id": 270101,
        "message": {"message_id": 2701, "message_thread_id": 2701, "is_topic_message": true,
            "from": {"id": '"$CHAT_ID"'},
            "chat": {"id": '"$CHAT_ID"', "type": "supergroup", "is_forum": true},
            "date": 1, "document": {"file_id": "FILE2701", "file_unique_id": "u2701",
                "file_name": "doc.bin", "mime_type": "application/octet-stream",
                "file_size": '"$fsize"'}}}' >/dev/null
    local i=0 ok=1
    while [[ $i -lt 30 ]]; do
        if mock_assert_inbox_sha "t2701" "$sha"; then ok=0; break; fi
        sleep 0.1; i=$((i + 1))
    done
    _mock_kill_session "t2701"
    if [[ $ok -eq 0 ]]; then
        success "SEAM-07: incoming document downloaded to inbox; sha256 matches"
    else
        fail "SEAM-07: incoming document did not reach the inbox with matching sha"
    fi
}

# T4e gap-filler: an incoming PHOTO ARRAY round-trips getFile(largest)+download
# into the inbox. bridge.py picks max(photo, key=file_size) then downloads
# (bridge.py:5137) — a distinct branch from the document case. The mock's
# single-registered-file getFile shortcut serves the bytes regardless of which
# file_id the bridge resolves, so registering one file is enough. (Replaces the
# real-Telegram test_incoming_image_e2e that is skipped under MOCK_TG_ACTIVE.)
test_mock_incoming_photo_downloads_to_inbox() {
    info "SEAM-07: an incoming photo array round-trips getFile(largest)+download into the inbox"
    mock_reset
    _mock_spawn_idle_session "t2706" "$CHAT_ID" 2706
    local src="$TEST_NODE_DIR/mock_in_2706.png"
    printf '\211PNG\r\n\032\n-MOCK-INBOX-PHOTO-2706-%s' "$RANDOM$RANDOM" > "$src"
    local sha
    sha=$(sha256sum "$src" 2>/dev/null | awk '{print $1}')
    # Register EXACTLY ONE file so getFile's single-file shortcut resolves it.
    mock_register_file_bytes "photos/p2706.png" "$src"
    # photo array: a small thumb + the large original (larger declared file_size),
    # so the bridge's max(photo, key=file_size) selects the large one.
    _mock_webhook '{
        "update_id": 270601,
        "message": {"message_id": 2706, "message_thread_id": 2706, "is_topic_message": true,
            "from": {"id": '"$CHAT_ID"'},
            "chat": {"id": '"$CHAT_ID"', "type": "supergroup", "is_forum": true},
            "date": 1, "photo": [
                {"file_id": "THUMB2706", "file_unique_id": "ut2706", "width": 90, "height": 90, "file_size": 10},
                {"file_id": "LARGE2706", "file_unique_id": "ul2706", "width": 1280, "height": 1280, "file_size": 99999}
            ]}}' >/dev/null
    local i=0 ok=1
    while [[ $i -lt 30 ]]; do
        if mock_assert_inbox_sha "t2706" "$sha"; then ok=0; break; fi
        sleep 0.1; i=$((i + 1))
    done
    _mock_kill_session "t2706"
    if [[ $ok -eq 0 ]]; then
        success "SEAM-07: incoming photo (largest) downloaded to inbox; sha256 matches"
    else
        fail "SEAM-07: incoming photo did not reach the inbox with matching sha"
    fi
}

test_mock_outgoing_voice_multipart_recorded() {
    info "SEAM-07: an outgoing [[file:.ogg]] is a real sendVoice multipart"
    mock_reset
    _mock_seed_session "t2702" "$CHAT_ID" 2702
    local ogg="$TEST_NODE_DIR/mock_out_2702.ogg"
    printf 'OggS-MOCK-VOICE-2702' > "$ogg"
    _mock_post_response "t2702" "audio: [[file:$ogg|caption2702]]" >/dev/null
    sleep 0.4
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" \
            'any(.[]; .method=="sendVoice" and .chat_id==$c and .message_thread_id==2702 and .file_field=="voice")' >/dev/null; then
        success "SEAM-07: sendVoice multipart recorded (voice field, thread 2702)"
    else
        fail "SEAM-07: no sendVoice multipart with a voice field reached the wire"
    fi
}

test_mock_outgoing_media_carries_thread_id() {
    info "SEAM-07: an outgoing media multipart carries the topic's message_thread_id"
    mock_reset
    _mock_seed_session "t2703" "$CHAT_ID" 2703
    local doc="$TEST_NODE_DIR/mock_out_2703.md"
    printf '# mock report 2703' > "$doc"
    _mock_post_response "t2703" "see [[file:$doc|notes2703]]" >/dev/null
    sleep 0.4
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" \
            'any(.[]; (.method|test("^send(Document|Photo|Voice|Audio|Video|Animation)$")) and .chat_id==$c and .message_thread_id==2703 and (.file_field != null))' >/dev/null; then
        success "SEAM-07: outgoing media multipart carries message_thread_id==2703"
    else
        fail "SEAM-07: outgoing media multipart missing message_thread_id==2703"
    fi
}

# X6: an outgoing [[image:.png]] is a real sendPhoto multipart at the wire.
# bridge.py routes the images list (parsed from [[image:...]], parse_image_tags)
# by extension: .gif/.mp4 -> sendAnimation, else -> sendPhoto (bridge.py:4724);
# the multipart file field is named "photo" (bridge.py:887).
test_mock_outgoing_image_png_is_sendphoto() {
    info "X6: an outgoing [[image:.png]] is a real sendPhoto multipart"
    mock_reset
    _mock_seed_session "t2704" "$CHAT_ID" 2704
    local png="$TEST_NODE_DIR/mock_out_2704.png"
    # Minimal PNG signature is enough — routing is by extension, not content.
    printf '\211PNG\r\n\032\n-MOCK-PHOTO-2704' > "$png"
    _mock_post_response "t2704" "shot: [[image:$png|caption2704]]" >/dev/null
    sleep 0.4
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" \
            'any(.[]; .method=="sendPhoto" and .chat_id==$c and .message_thread_id==2704 and .file_field=="photo")' >/dev/null; then
        success "X6: sendPhoto multipart recorded (photo field, thread 2704)"
    else
        fail "X6: no sendPhoto multipart with a photo field reached the wire"
    fi
}

# X6: an outgoing [[image:.gif]] is a real sendAnimation multipart at the wire.
test_mock_outgoing_image_gif_is_sendanimation() {
    info "X6: an outgoing [[image:.gif]] is a real sendAnimation multipart"
    mock_reset
    _mock_seed_session "t2705" "$CHAT_ID" 2705
    local gif="$TEST_NODE_DIR/mock_out_2705.gif"
    printf 'GIF89a-MOCK-ANIM-2705' > "$gif"
    _mock_post_response "t2705" "loop: [[image:$gif|caption2705]]" >/dev/null
    sleep 0.4
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" \
            'any(.[]; .method=="sendAnimation" and .chat_id==$c and .message_thread_id==2705 and .file_field=="animation")' >/dev/null; then
        success "X6: sendAnimation multipart recorded (animation field, thread 2705)"
    else
        fail "X6: no sendAnimation multipart with an animation field reached the wire"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEAM-08 — close/reap glue. A programmed REAL HTTP 400 ("thread not found")
# drives the REAL _reap_dead_topic; /close ends the session; tmain is never
# reaped (thread 0 omitted ⇒ never bounces).
# ─────────────────────────────────────────────────────────────────────────────

test_mock_bounce_reaps_topic_session() {
    info "SEAM-08: a 400 thread-not-found bounce reaps the real topic session"
    mock_reset
    _mock_spawn_idle_session "t2801" "$CHAT_ID" 2801
    wait_for_session "t2801" || { fail "SEAM-08: setup — session t2801 never came up"; _mock_kill_session "t2801"; return; }
    # Program the NEXT send to thread 2801 to bounce with a real HTTP 400.
    mock_program_thread_not_found 2801
    # Drive delivery → send bounces → _reap_dead_topic → worker_manager.end(t2801).
    _mock_post_response "t2801" "REAP-2801" >/dev/null
    if wait_for_session_gone "t2801"; then
        success "SEAM-08: session t2801 reaped after the 400 bounce (real end())"
    else
        fail "SEAM-08: session t2801 survived the 400 bounce (reap did not fire)"
        _mock_kill_session "t2801"
    fi
}

test_mock_close_command_ends_session() {
    info "SEAM-08: /close ends the bound topic session"
    mock_reset
    _mock_spawn_idle_session "t2802" "$CHAT_ID" 2802
    wait_for_session "t2802" || { fail "SEAM-08: setup — session t2802 never came up"; _mock_kill_session "t2802"; return; }
    # Admin sends /close inside the 話題 (same lifecycle path as forum_topic_closed).
    send_topic_message "$CHAT_ID" 2802 "/close" >/dev/null
    if wait_for_session_gone "t2802"; then
        success "SEAM-08: /close ended session t2802"
    else
        fail "SEAM-08: /close did not end session t2802"
        _mock_kill_session "t2802"
    fi
}

test_mock_tmain_never_reaped() {
    info "SEAM-08: tmain (thread 0) is never reaped — thread omitted ⇒ no bounce"
    mock_reset
    _mock_spawn_idle_session "tmain" "$CHAT_ID" 0
    wait_for_session "tmain" || { fail "SEAM-08: setup — session tmain never came up"; _mock_kill_session "tmain"; return; }
    # Even if thread 0 is "programmed" to bounce, tmain delivery OMITS the
    # message_thread_id key, so the mock never bounces it and the reaper can't fire.
    mock_program_thread_not_found 0
    _mock_post_response "tmain" "TMAIN-SURVIVES-2803" >/dev/null
    # Give the (non-)bounce + any reaper a window, then prove the session is still up.
    sleep 0.6
    if tmux has-session -t "${TEST_TMUX_PREFIX}tmain" 2>/dev/null; then
        success "SEAM-08: tmain survived (thread-0 omitted, no bounce, no reap)"
    else
        fail "SEAM-08: tmain was wrongly reaped"
    fi
    _mock_kill_session "tmain"
}

# ─────────────────────────────────────────────────────────────────────────────
# NEW scenarios (were unseamed; spec §8) — all DEFAULT mode.
# ─────────────────────────────────────────────────────────────────────────────

test_mock_multichunk_reply_ordering() {
    info "NEW: a >4096-char /response splits into ordered chunks with reply_to chaining"
    mock_reset
    _mock_seed_session "t3101" "$CHAT_ID" 3101
    # >4096 chars of plain text (no HTML specials) → split_message yields ≥2 chunks.
    local big
    big=$(python3 -c "print('A'*3000 + ' ' + 'B'*3000 + ' ' + 'C'*3000)")
    _mock_post_response "t3101" "$big" >/dev/null
    sleep 0.5
    # First message_id after mock_reset is 1, so chunk i (0-based) returns id i+1
    # and chunk i+1 replies to it. Assert: ≥2 chunks, first has NO reply_to, and
    # each subsequent chunk's reply_to_message_id == its index (1,2,…).
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson n 3101 '
            [.[] | select(.method=="sendMessage" and .message_thread_id==$n)] as $m
            | ($m|length) >= 2
              and ($m[0]|has("reply_to_message_id")|not)
              and (all(range(1; ($m|length)) as $i | $m[$i].reply_to_message_id == $i))
        ' >/dev/null; then
        success "NEW: multi-chunk reply in order with reply_to chaining"
    else
        fail "NEW: multi-chunk reply ordering / reply_to chaining is wrong"
    fi
}

test_mock_session_cleanup_after_close() {
    info "NEW: a reopened topic after close gets a FRESH session (no zombie re-attach)"
    mock_reset
    _mock_spawn_idle_session "t3102" "$CHAT_ID" 3102
    wait_for_session "t3102" || { fail "NEW: setup — session t3102 never came up"; _mock_kill_session "t3102"; return; }
    # Close it (session removed).
    send_topic_message "$CHAT_ID" 3102 "/close" >/dev/null
    wait_for_session_gone "t3102" || { fail "NEW: /close did not end t3102"; _mock_kill_session "t3102"; return; }
    # Reopen the same topic: with the session gone the bridge must offer a FRESH
    # folder picker (not silently re-attach a zombie session).
    mock_reset
    _mock_webhook '{
        "update_id": 310201,
        "message": {"message_id": 31021, "message_thread_id": 3102, "is_topic_message": true,
            "from": {"id": '"$CHAT_ID"'},
            "chat": {"id": '"$CHAT_ID"', "type": "supergroup", "is_forum": true},
            "date": 1, "forum_topic_reopened": {}}}' >/dev/null
    sleep 0.4
    # The picker text "選擇這個話題" lands in thread 3102 ⇒ fresh start, no zombie.
    if mock_assert_sendmessage 3102 "選擇這個話題"; then
        success "NEW: reopened topic gets a fresh folder picker (no zombie re-attach)"
    else
        fail "NEW: reopened topic did not get a fresh picker (possible zombie re-attach)"
    fi
}

test_mock_no_real_telegram_egress() {
    info "NEW: every bridge egress is redirected to the mock (no real Telegram escape)"
    # Order-independent proof that TELEGRAM_API_BASE is honored: the bridge's boot
    # already emitted setMyCommands to the configured base, BUT sibling tests'
    # mock_reset wipes that one-shot record — so instead drive a FRESH egress here
    # (a /notify) and prove it lands AT THE MOCK. If the base were NOT redirected
    # (egress escaped to api.telegram.org), the mock would record NOTHING and this
    # is RED. This is the falsifiable "no real-Telegram egress" guarantee.
    mock_reset
    _mock_post_notify "EGRESS-PROBE-marker" >/dev/null
    sleep 0.3
    # The probe must surface as a recorded sendMessage at the mock to the admin
    # chat — the only place it can land if (and only if) the wire was redirected.
    if curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
        | jq -e --argjson c "$CHAT_ID" --arg m "EGRESS-PROBE-marker" \
            'any(.[]; .method=="sendMessage" and .chat_id==$c and (.text|contains($m)))' >/dev/null; then
        success "NEW: bridge egress recorded at the mock — no real Telegram egress"
    else
        fail "NEW: bridge egress did not reach the mock — base may have escaped to real Telegram"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Task 8 P1 — DEFAULT-mode full happy-path with a LIVE pane (no real Claude Code).
# Drives the REAL bridge path: forum trigger -> folder-picker callback ->
# open_topic_session -> create_session -> live tmux pane running a deterministic
# fake-claude -> inbound topic message -> fake-claude runs the REAL Stop hook ->
# POST /response -> mock records sendMessage(marker, BOUND thread). This is the
# single test that walks 建話題->選資料夾->誕生->訊息->回覆 with a live pane below
# E2E=1. Needs its OWN bridge+mock (fakebin on PATH + TOPIC_ROOT, neither of which
# the suite bridge provides). Red-proof: bind the callback to a different thread
# than the one asserted -> the reply carries the wrong thread -> RED.
# ─────────────────────────────────────────────────────────────────────────────
test_topic_happy_path_real_pane_fakeclaude() {
    info "HAPPY-PATH: real pane fake-claude emits a marker via the REAL Stop hook into the bound thread"
    if ! command -v tmux >/dev/null 2>&1; then
        success "HAPPY-PATH: skipped (no tmux available on this box)"
        return 0
    fi

    local tid=3103 sname="t3103"
    local marker="HAPPY-3103-$RANDOM$RANDOM"
    local fbdir="$TEST_NODE_DIR/hookfakebin_$tid"
    local troot="$TEST_NODE_DIR/topicroot_$tid"
    # FULLY isolate from the suite bridge: a DEDICATED sessions dir AND a tmux
    # prefix the suite prefix ("claude-test-") can't glob-match — otherwise the two
    # bridges share session state / the suite watchdog adopts our pane (the known
    # orphan-workers cross-contamination). is_online keys on the pane COMMAND
    # (claudebin), not the session name, so a distinct prefix is safe.
    local hp_prefix="hpt-${TEST_NODE}-"
    local hp_sess="$TEST_NODE_DIR/sessions_hp"
    local hp_port=$((PORT + 7)) hp_mock=$((MOCKPORT + 7))
    local hp_blog="$TEST_NODE_DIR/bridge_hp.log" hp_mlog="$TEST_NODE_DIR/mock_hp.log"
    local hp_bpid="" hp_mpid="" bin
    bin="$(_mock_hooking_fake_claude_bin "$fbdir" "$marker")"
    mkdir -p "$troot" "$hp_sess"
    # The bridge's /response handler needs markdown-it-py (a uv dep) — bare python3
    # lacks it and 500s. Use the repo venv interpreter, fall back to python3.
    local PYBIN="$SCRIPT_DIR/.venv/bin/python"
    [[ -x "$PYBIN" ]] || PYBIN=python3

    # Localize PORT/MOCKPORT so the existing helpers (send_topic_message /
    # _mock_webhook / mock_*) target our dedicated pair via bash dynamic scope;
    # auto-restored when this function returns.
    local PORT="$hp_port" MOCKPORT="$hp_mock"

    _hp_teardown() {
        [[ -n "$hp_bpid" ]] && kill "$hp_bpid" 2>/dev/null || true
        [[ -n "$hp_mpid" ]] && kill "$hp_mpid" 2>/dev/null || true
        tmux kill-session -t "${hp_prefix}${sname}" 2>/dev/null || true
        rm -rf "$hp_sess" 2>/dev/null || true
    }

    # Free our dedicated ports if a crashed prior run left an owner (PID-scoped to
    # THOSE ports only — never pkill). Makes re-runs robust against port collision.
    local _stale
    _stale=$(lsof -ti :"$hp_mock" 2>/dev/null || true); [[ -n "$_stale" ]] && kill -9 $_stale 2>/dev/null || true
    _stale=$(lsof -ti :"$hp_port" 2>/dev/null || true); [[ -n "$_stale" ]] && kill -9 $_stale 2>/dev/null || true

    # 1) Dedicated mock Telegram on its own port (argparse: --port/--record).
    python3 "$SCRIPT_DIR/tests/mock_telegram.py" \
        --port "$hp_mock" \
        --record "$TEST_NODE_DIR/telegram_calls_hp.jsonl" > "$hp_mlog" 2>&1 &
    hp_mpid=$!
    if ! wait_for_port "$hp_mock"; then fail "HAPPY-PATH: mock did not start on $hp_mock"; _hp_teardown; return; fi

    # 2) Dedicated bridge: fakebin first on PATH (so shutil.which + the pane both
    #    resolve `claude` to our fake), TOPIC_ROOT pinned, BRIDGE_URL -> itself.
    TELEGRAM_BOT_TOKEN="${MOCK_BOT_TOKEN:-mock-token}" \
    PORT="$hp_port" \
    NODE_NAME="$TEST_NODE" \
    SESSIONS_DIR="$hp_sess" \
    TMUX_PREFIX="$hp_prefix" \
    ADMIN_CHAT_ID="$CHAT_ID" \
    TEAM_DIR="$TEST_TEAM_DIR" \
    TOPIC_ROOT="$troot" \
    TELEGRAM_API_BASE="http://127.0.0.1:$hp_mock" \
    BRIDGE_URL="http://localhost:$hp_port" \
    PATH="$fbdir:$PATH" \
    "$PYBIN" -u "$SCRIPT_DIR/bridge.py" > "$hp_blog" 2>&1 &
    hp_bpid=$!
    if ! wait_for_port "$hp_port"; then fail "HAPPY-PATH: bridge did not start on $hp_port"; _hp_teardown; return; fi

    mock_reset

    # 3) Forum trigger (first message = pure trigger) -> folder picker.
    send_topic_message "$CHAT_ID" "$tid" "trigger" >/dev/null

    # 4) Tap the picker as ADMIN. An unregistered token falls back to TOPIC_ROOT,
    #    so the session deterministically opens in $troot.
    _mock_webhook '{
        "update_id": 310301,
        "callback_query": {"id": "hpcbq", "data": "use:hpdeadbeef",
            "from": {"id": '"$CHAT_ID"'},
            "message": {"message_id": 31031, "message_thread_id": '"$tid"',
                "chat": {"id": '"$CHAT_ID"', "type": "supergroup", "is_forum": true}}}}' >/dev/null

    # 5) Win the launch window: the bridge's launch line re-exports the tmux SESSION
    #    env (eval "$(tmux show-environment -s)"), whose PATH otherwise points at the
    #    real claude. Set it BEFORE the launch — the bridge first waits for the fish
    #    pane to settle (seconds), so polling for the session and setting PATH wins
    #    the window deterministically. Without this, `exec claude` finds the real
    #    binary and the session never comes online with our stub.
    local i=0 set_path=1
    while [[ $i -lt 60 ]]; do
        if tmux has-session -t "${hp_prefix}${sname}" 2>/dev/null; then
            tmux set-environment -t "${hp_prefix}${sname}" PATH "$fbdir:$PATH"
            set_path=0; break
        fi
        sleep 0.05; i=$((i + 1))
    done
    if [[ $set_path -ne 0 ]]; then fail "HAPPY-PATH: session never appeared to pin PATH"; _hp_teardown; return; fi

    # 6) Poll the pane born + the fake `claude` (claudebin) exec'd (NO fixed sleep).
    i=0; local born=1
    while [[ $i -lt 120 ]]; do
        case "$(tmux display-message -t "${hp_prefix}${sname}" -p '#{pane_current_command}' 2>/dev/null)" in
            *claude*) born=0; break ;;
        esac
        sleep 0.1; i=$((i + 1))
    done
    if [[ $born -ne 0 ]]; then fail "HAPPY-PATH: fake-claude pane never came online"; _hp_teardown; return; fi

    # 7) Poll the chat_id binding (save_topic_meta) — the hook hard-requires it.
    i=0; local bound=1
    while [[ $i -lt 50 ]]; do
        [[ -f "$hp_sess/$sname/chat_id" ]] && { bound=0; break; }
        sleep 0.1; i=$((i + 1))
    done
    if [[ $bound -ne 0 ]]; then fail "HAPPY-PATH: chat_id binding never written"; _hp_teardown; return; fi

    # 8) The bridge auto-sends its onboarding instructions to the new pane; the stub
    #    replies "ack", which clears the bridge's `pending` state. Wait for that ack
    #    round-trip BEFORE sending the user message, else the user message is queued
    #    (never delivered) while pending is set.
    i=0; local acked=1
    while [[ $i -lt 120 ]]; do
        mock_assert_sendmessage "$tid" "ack" && { acked=0; break; }
        sleep 0.1; i=$((i + 1))
    done
    if [[ $acked -ne 0 ]]; then fail "HAPPY-PATH: onboarding round-trip (ack) never completed — pane/hook not wired"; _hp_teardown; return; fi

    # 9) Real user topic message (its text IS the marker) -> route_message delivers
    #    'manager: <marker>' to the pane -> the fake-claude replies <marker> via the
    #    REAL Stop hook -> /response -> bound-thread sendMessage.
    send_topic_message "$CHAT_ID" "$tid" "$marker" >/dev/null

    # 10) Poll the mock for sendMessage(marker) in the BOUND thread (async hook chain).
    i=0; local got=1
    while [[ $i -lt 120 ]]; do
        mock_assert_sendmessage "$tid" "$marker" && { got=0; break; }
        sleep 0.1; i=$((i + 1))
    done

    if [[ $got -eq 0 ]] && mock_assert_thread_absent "$marker" 9999; then
        success "HAPPY-PATH: user message round-tripped through the real Stop hook into bound thread $tid (absent from decoy 9999)"
    else
        fail "HAPPY-PATH: marker did not land in bound thread $tid via the real hook chain"
    fi
    _hp_teardown
}

# ─────────────────────────────────────────────────────────────────────────────
# Runner — every test, in seam order. Sourced into test.sh's DEFAULT/integration
# branch; run_test is defined in test.sh and available when this file is sourced.
# ─────────────────────────────────────────────────────────────────────────────
run_mock_tests() {
    # F3 self-gate: never run the mock suite against a dead bridge. wait_for_port
    # is defined in test.sh (this file is sourced into it); returns instantly when
    # the bridge is already listening. Loud skip, never a silent pass.
    if ! wait_for_port "$PORT"; then
        info "Skipping mock tests: bridge not listening on port $PORT"
        return 0
    fi
    log ""
    log "── Mock-Telegram DEFAULT-mode Tests (SEAM-02/03/07/08/09/10 + new) ──────"
    # SEAM-02 delivery
    run_test test_mock_response_delivers_real_sendmessage
    run_test test_mock_notify_delivers_to_admin
    run_test test_mock_response_failure_is_red
    # SEAM-03 threading / isolation
    run_test test_mock_reply_lands_in_correct_thread
    run_test test_mock_two_topics_no_crosstalk
    run_test test_mock_tmain_omits_thread_id
    # SEAM-09 admin silence
    run_test test_mock_nonadmin_message_is_silent
    run_test test_mock_admin_message_gets_reply
    run_test test_mock_nonadmin_callback_tap_silent
    # SEAM-10 reaction / typing
    run_test test_mock_reaction_arc_recorded
    run_test test_mock_typing_action_recorded
    # SEAM-07 media / getFile
    run_test test_mock_incoming_document_downloads_to_inbox
    run_test test_mock_incoming_photo_downloads_to_inbox
    run_test test_mock_outgoing_voice_multipart_recorded
    run_test test_mock_outgoing_media_carries_thread_id
    run_test test_mock_outgoing_image_png_is_sendphoto
    run_test test_mock_outgoing_image_gif_is_sendanimation
    # SEAM-08 close / reap
    run_test test_mock_bounce_reaps_topic_session
    run_test test_mock_close_command_ends_session
    run_test test_mock_tmain_never_reaped
    # NEW scenarios
    run_test test_mock_multichunk_reply_ordering
    run_test test_mock_session_cleanup_after_close
    run_test test_mock_no_real_telegram_egress
    # Task 8 P1 — full happy-path with a live pane (fake-claude + real Stop hook)
    run_test test_topic_happy_path_real_pane_fakeclaude
}
