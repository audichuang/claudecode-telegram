# Testing Guide

## Test Modes

The test suite supports four modes:

| Mode | Command | Time |
|------|---------|------|
| **FAST** | `FAST=1 ./test.sh` | ~10-15s |
| **Default** | `./test.sh` | ~2-3 min |
| **FULL** | `FULL=1 ./test.sh` | ~5 min |
| **E2E** | `E2E=1 ./test.sh` | ~1-2 min (spawns real `claude`) |

For workflow rules (when to run which mode), see `CLAUDE.md`.

> **uv:** `test.sh` is uv-aware — it runs `uv sync --frozen` and prepends `.venv/bin`
> to `PATH` at startup, so the inline `python3 -c` assertions exercise the locked
> dependency set (`markdown-it-py`) rather than system site-packages. If `uv` is not
> installed it falls back to system `python3` transparently. No manual step needed.

### What Each Mode Tests

**FAST mode** (no bridge, no network):
- Python imports and functions
- Message formatting and splitting
- CLI flags (--help, --version, --node, --port)
- Constants and configuration validation
- Concurrency helpers (locks)
- Hook install/uninstall

**Default mode** (bridge running locally + recording Mock-Telegram server):
- Everything in FAST mode, plus:
- Bridge startup and health check
- All Telegram commands (/cd, /close, /memory, /quota, /voice, /settings, /rewind, /pr)
- Admin authorization
- Topic routing (new topic → folder picker → session; messages → that topic's session)
- Security (webhook secret, token isolation, file permissions)
- Image/document handling
- /response and /notify endpoints
- Persistence files
- **Falsifiable wire-boundary tests (`tests/mock_tests.sh`, 20 tests):** the bridge is
  pointed at a localhost Mock-Telegram server (`tests/mock_telegram.py`) via
  `TELEGRAM_API_BASE`, which **records every outbound call** (sendMessage / reaction /
  typing / multipart media / getFile). Delivery, threading (`message_thread_id`),
  cross-topic isolation, admin-gate silence, the reaction arc, media download/upload,
  and dead-topic reaping (real HTTP-400 bounce) are asserted at the **recorded wire**,
  never the bridge's self-reported log line — so a broken feature turns the suite red.

**E2E mode** (real `claude` + Mock-Telegram; gated, opt-in):
- `tests/e2e_tests.sh` (5 tests) spawns a **real `claude`** session in a tmpdir through
  the real path (forum-topic webhook → folder-picker callback → tmux spawn), sends a
  deterministic marker prompt, lets the **real Stop hook** fire (`TMUX_FALLBACK=0` forces
  real transcript extraction, not the capture-pane fallback), and asserts the marker lands
  in the right thread at the mock. Covers: real type→answer roundtrip (SEAM-01/06),
  spawn-in-cwd liveness (SEAM-04), claude-process-alive ≠ pane-alive (SEAM-05), and
  two-topic isolation (SEAM-03 L3).
- Each test calls `check_claude_available` and **skips loudly** (never silent-passes) when
  `claude` is absent; a turn timeout is a **hard failure**. Real turns spend quota
  (~4s/turn) and need a logged-in `claude`, so E2E is excluded from FAST/Default/FULL and
  opt-in only (run before a push/release). Isolation: bridge points at the mock with a
  dummy token + placeholder admin chat, so **no real Telegram traffic** is produced.

**FULL mode**:
- Everything in Default mode, plus:
- Cloudflare tunnel startup
- Webhook configuration with real Telegram API

## Test Pyramid

```
         /\
        /  \   E2E: real claude → real Stop hook → mock (true L3)
       /----\
      /      \  FULL: Tunnel + Webhook
     /--------\
    /          \ Default: Bridge + Commands + Mock-Telegram wire tests
   /------------\
  /              \ FAST: Unit + CLI
 /----------------\
```

> **The two-axis e2e-hardening architecture** (design: `docs/superpowers/specs/2026-06-14-e2e-hardening-design.md`):
> (A) the Mock-Telegram server makes delivery/threading/reactions/silence/media **falsifiable in Default mode** with no real claude and no secrets; (B) the gated `E2E=1` mode adds **agent-driven true-L3 confidence** (a real claude turn drives the whole chain). Every new test has an explicit RED criterion — proven to fail when the feature breaks.

Workflow guidance lives in `CLAUDE.md`.

## Quick Start

```bash
TEST_BOT_TOKEN='your-test-bot-token' ./test.sh
```

## Test Coverage

The test suite is the source of truth — `test.sh` defines and registers every test.
Don't hand-maintain a duplicate inventory here (it drifts); read the live suite:

```bash
grep -cE '^[[:space:]]*run_test ' test.sh        # count of registered tests
grep -oE '^[[:space:]]*run_test [a-z_]+' test.sh # registered test names, in run order
grep -E '^test_[a-z_]+\(\)' test.sh              # every defined test function
```

Coverage spans the topic lifecycle (建話題 → folder picker → spawn-in-cwd → route →
reply-to-thread → reaper), the bridge HTTP endpoints (`/response`, `/notify`,
`/checkin`, `/workers`), security (webhook secret, token isolation, file perms, the
`0.0.0.0` bind), image/document/voice handling, hooks (Stop reply, POISONED), and the
launch/detach hardening (setsid/nohup detach, stale-pid handling, bridge-death
fail-loudly). The grouped run-order banners in `test.sh` show the live breakdown.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TEST_BOT_TOKEN` | Yes | Bot token from @BotFather |
| `TEST_PORT` | No | Bridge port (default: 8295) |
| `TEST_CHAT_ID` | No | Your chat ID for e2e tests (default: mock 123456789) |
| `FAST` | No | Set to `1` for unit + CLI tests only |
| `FULL` | No | Set to `1` to include tunnel tests |

## Manual Testing

### Simulate Telegram Webhook

```bash
# Start bridge
TELEGRAM_BOT_TOKEN='...' PORT=8295 python3 bridge.py &

# Send simulated message
curl -X POST http://localhost:8295 \
  -H "Content-Type: application/json" \
  -d '{
    "update_id": 1,
    "message": {
      "message_id": 1,
      "from": {"id": 123456789, "first_name": "Test"},
      "chat": {"id": 123456789, "type": "private"},
      "date": 1706400000,
      "text": "/settings"
    }
  }'
```

### Test with Real Telegram

```bash
# Quick tunnel (random URL each time)
./claudecode-telegram.sh run

# Or with persistent URL
./claudecode-telegram.sh run --tunnel-url https://your.domain.com
```

## Test Isolation

Tests run isolated using `--node test` under `~/.claude/telegram/nodes/test/`:

| Resource | Test | Production |
|----------|------|------------|
| Node dir | `~/.claude/telegram/nodes/test/` | `~/.claude/telegram/nodes/prod/` |
| Port | 8295 | 8271 |
| tmux prefix | `claude-test-` | `claude-prod-` |
| Session files | `.../nodes/test/sessions/` | `.../nodes/prod/sessions/` |
| PID file | `.../nodes/test/pid` | `.../nodes/prod/pid` |
| Logs | `.../nodes/test/*.log` | `.../nodes/prod/*.log` |
| Bot token | Separate test bot | Production bot |

This allows running tests while production is active.

## Full E2E Test

To test the complete response flow (hook -> bridge -> Telegram):

```bash
TEST_BOT_TOKEN='...' TEST_CHAT_ID='your-chat-id' ./test.sh
```

With `TEST_CHAT_ID` set:
- Bridge pre-locks to your chat ID (no auto-learn)
- Test messages use your real chat ID
- Response test sends actual message to your Telegram

## CI Integration

```yaml
# GitHub Actions example
- name: Run tests
  env:
    TEST_BOT_TOKEN: ${{ secrets.TELEGRAM_TEST_TOKEN }}
  run: ./test.sh
```

## Writing New Tests

Add test functions to `test.sh`:

```bash
test_my_feature() {
    info "Testing my feature..."

    local result
    result=$(send_message "/mycommand")

    if [[ "$result" == "OK" ]]; then
        success "My feature works"
    else
        fail "My feature failed"
    fi
}
```

Then add to the appropriate runner function:
- `run_unit_tests()` for tests that don't need the bridge
- `run_cli_tests()` for CLI-only tests
- `run_integration_tests()` for tests that need the bridge running
- `run_tunnel_tests()` for tests that need the tunnel

Also update:
- The **Complete Test Inventory** list above
- The **Test Coverage** tables if new tests expand coverage

Call from the runner function:

```bash
run_unit_tests() {
    # ... existing tests ...
    test_my_feature
}
```

## E2E Coverage (the 10 seams)

A 2026-06-14 audit found the suite had **zero true end-to-end tests**: real `claude` never
ran, the Stop hook was always curl-simulated, and Telegram delivery was un-falsifiable (a
fake-chat-id API error counted as success). The e2e-hardening work closed all ten seams —
each with an explicit RED criterion (proven to fail when the feature breaks):

| Seam | What was a false-green | Now closed by | Mode |
|------|-----------------------|---------------|------|
| SEAM-01 | real claude never runs | `test_e2e_real_claude_marker_roundtrip` | E2E |
| SEAM-02 | fake-chat-id API error graded as success | `test_mock_response_delivers_real_sendmessage` (+ embedded RED guard) | Default |
| SEAM-03 | thread targeting only via spy call-args | `test_mock_reply_lands_in_correct_thread`, `test_mock_two_topics_no_crosstalk`, `test_e2e_two_real_topics_isolated` | Default + E2E |
| SEAM-04 | spawn-in-cwd asserted as command strings | `test_e2e_spawn_runs_claude_in_cwd` | E2E |
| SEAM-05 | bash-pane liveness ≠ claude liveness | `test_e2e_claude_actually_alive_not_just_pane` | E2E |
| SEAM-06 | Stop-hook contract never run e2e | `test_e2e_real_claude_marker_roundtrip` (`TMUX_FALLBACK=0`) | E2E |
| SEAM-07 | media→claude only as stubbed args | `test_mock_incoming_document_downloads_to_inbox`, `test_mock_outgoing_voice_multipart_recorded` | Default |
| SEAM-08 | close/reap glue L1-stubbed | `test_mock_bounce_reaps_topic_session` (real HTTP-400), `test_mock_tmain_never_reaped` | Default |
| SEAM-09 | admin gate = "a stub wasn't called" | `test_mock_nonadmin_message_is_silent`, `test_mock_nonadmin_callback_tap_silent` | Default |
| SEAM-10 | reaction arc = spy call-counts | `test_mock_reaction_arc_recorded` | Default |

Plus new scenarios: multi-chunk reply ordering with `reply_to` chaining, fresh-session-after-close
(no zombie re-attach), and a no-real-Telegram-egress guard.

## Still Out of Scope (genuine gaps, low priority)

| Feature | Why deferred |
|---------|--------------|
| Trust-dialog auto-answer on the real path | Prod always spawns with `--dangerously-skip-permissions`, so the dialog never appears; the defensive branch is acknowledged non-blocking in `test_e2e_trust_dialog_auto_answered` |
| Path-traversal hardening of the folder picker | `_norm_under_root` clamps under `TOPIC_ROOT`; covered at L1 (`test_topic_cd_rejects_bad_path`) but not fuzzed |
| E2E in CI | Real turns need a logged-in `claude` + quota; E2E is local/pre-push only |
