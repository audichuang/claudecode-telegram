# Testing Guide

## Test Modes

The test suite supports three modes:

| Mode | Command | Time |
|------|---------|------|
| **FAST** | `FAST=1 ./test.sh` | ~10-15s |
| **Default** | `./test.sh` | ~2-3 min |
| **FULL** | `FULL=1 ./test.sh` | ~5 min |

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

**Default mode** (bridge running locally):
- Everything in FAST mode, plus:
- Bridge startup and health check
- All Telegram commands (/cd, /close, /memory, /quota, /voice, /settings, /rewind, /pr)
- Admin authorization
- Topic routing (new topic → folder picker → session; messages → that topic's session)
- Security (webhook secret, token isolation, file permissions)
- Image/document handling
- /response and /notify endpoints
- Persistence files

**FULL mode**:
- Everything in Default mode, plus:
- Cloudflare tunnel startup
- Webhook configuration with real Telegram API

## Test Pyramid

```
        /\
       /  \  FULL: Tunnel + Webhook
      /----\
     /      \ Default: Bridge + Commands
    /--------\
   /          \ FAST: Unit + CLI
  /-----------\
```

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

## Missing Tests (To Be Implemented)

This section tracks tests that should be added to ensure mode parity and complete coverage.

### Critical (Mode Parity)

All critical mode parity tests are now implemented. ✅

### Important (No Test)

These features have no tests in either mode and should be tested:

| Feature | Description |
|---------|-------------|
| Multipart response chaining behavior | Reply chain for multipart messages (reply_to_message_id) |

### Nice to Have

Lower priority tests for edge cases and robustness:

| Feature | Description |
|---------|-------------|
| Direct worker crash recovery | Worker process crash detection and cleanup |
| Concurrent pipe writes | Multiple workers writing to same pipe simultaneously |
| Pipe permissions | Named pipe has correct permissions (0o600) |
| Path traversal protection | Prevent `../` in worker names for inbox paths |
