# Testing Guide

## Test Modes

The project test runner is `test.sh`. It is uv-aware: on startup it runs
`uv sync --frozen`, prepends `.venv/bin` to `PATH`, and then runs the inline
Python assertions against the locked dependency set.

| Mode | Command | What Runs |
|------|---------|-----------|
| **FAST** | `FAST=1 TEST_BOT_TOKEN='...' ./test.sh` | Unit + CLI tests only |
| **Default** | `TEST_BOT_TOKEN='...' ./test.sh` | FAST coverage plus local bridge integration |
| **FULL** | `FULL=1 TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh` | Default coverage plus tunnel/webhook test |

Use FAST during development, default before committing, and FULL before pushing
or changing tunnel/webhook behavior.

### Filtering

Run one focused test with `TEST_FILTER`:

```bash
TEST_FILTER=test_topic_first_message_trigger_not_forwarded \
FAST=1 TEST_BOT_TOKEN='1234567890:TEST-dummy-token-for-unit-suite' ./test.sh
```

`TEST_FILTER` matches test names by substring.

## What Each Mode Tests

**FAST mode** (no bridge, no network):
- Topic identity, folder picker, first-message trigger behavior, `/cd`, `/close`,
  topic close/reopen, deleted-topic reap, and topic-thread reply targeting.
- Topic command surface: legacy orchestration commands are rejected, global
  topic-safe commands are delegated, and the menu stays slim.
- `EXTRA_COMMANDS` extension seam dispatch.
- Message formatting, Telegram HTML conversion, media tag parsing, file
  validation, quota rendering, STT/TTS helpers, and voice-mode behavior.
- Claude-only backend registry, tmux send locking, watchdog state calculation,
  process inspection helpers, node-derived config, checkin CWD behavior, and
  hook failure signal handling.
- `viewer.py` renderers for transcript/team-chat HTML, plus
  `transcript-index.py` and `team-chat-index.py`.
- Transport seam tests for `TelegramTransport`/`LocalTransport`.
- CLI parsing, status, webhook, and hook install/test commands.

**Default mode** (bridge running locally):
- Everything in FAST mode, plus bridge startup and local HTTP endpoints.
- Admin auto-learn/preset behavior and non-admin rejection.
- Topic/session lifecycle through the webhook path.
- tmux-backed Claude session creation, message delivery, and session file
  permissions.
- `/response`, `/notify`, `/checkin`, `/health/workers`, and API index behavior.
- Media inbox handling, response media tags, hook scripts, and security checks.

**FULL mode**:
- Everything in default mode, plus Cloudflare tunnel startup and Telegram webhook
  configuration.

## Current Test Count

As of v1.1.0:

| Scope | Count |
|-------|-------|
| Test functions defined in `test.sh` | 263 |
| FAST invocations (`run_unit_tests` + `run_cli_tests`) | 216 |
| Default invocations | 263 |
| FULL invocations | 264, including `test_with_tunnel` |

`test_workers_endpoint_removed` intentionally runs in both FAST and integration
mode because it checks both pure routing behavior and the live bridge endpoint.

## Topic-Only Coverage Matrix

There is no tmux/exec backend matrix anymore. Claude Code in tmux is the only
backend. Compatibility helpers may still use historical names such as
`backend`, `worker`, or `hire` internally, but the product model is one Telegram
forum topic = one Claude session.

| Area | Representative Tests | Notes |
|------|----------------------|-------|
| Topic creation | `test_topic_picker_shown_on_topic_creation`, `test_topic_first_message_trigger_not_forwarded`, `test_topic_open_sends_welcome_only` | First message is trigger-only |
| Topic routing | `test_topic_routing_known_and_unknown`, `test_topic_route_tracks_request`, `test_hook_reply_targets_thread` | Topic decides the target session |
| Folder/CWD | `test_folder_navigator_keyboard`, `test_topic_cd_rejects_bad_path`, `test_checkin_cwd_stores_in_memory` | Folder picker and `/cd` stay under `TOPIC_ROOT` |
| Lifecycle | `test_topic_closed_ends_session`, `test_topic_reopened_unbound_shows_picker`, `test_deleted_topic_reaped_on_send_failure` | Close/reopen/delete behavior |
| Legacy command deletion | `test_topic_legacy_command_rejected`, `test_topic_command_menu_is_slim`, `test_workers_endpoint_removed` | `/hire`, `/focus`, `/team`, `/workers` are not live product surface |
| Claude/tmux | `test_tmux_mode_session_stays_alive`, `test_tmux_mode_message_delivery` | Claude-only tmux execution path |
| Backend registry | `test_backend_registry_exists`, `test_backend_env_metadata`, `test_claude_start_cmd` | Registry is Claude-only; `codex` is rejected |
| Extension seam | `test_extension_seam_command` | `EXTRA_COMMANDS` callbacks can handle topic-safe commands without leaking to Claude |
| API endpoints | `test_api_index_returns_json`, `test_known_endpoints_unchanged`, `test_unknown_get_returns_404`, `test_unknown_post_returns_404` | `API_ENDPOINTS` is the source for the index/404 help |
| Viewers | `test_transcript_*`, `test_team_chat_*`, `test_rewind_*` | HTML renderers live in `viewer.py` and are re-exported by `bridge.py` |
| Indexers | `test_tindex_*`, `test_tcindex_*` | SQLite/FTS helpers for transcript and team-chat search |
| Transport | `test_transport_interface_exists`, `test_local_transport_*`, `test_transport_init_selects_correctly` | Telegram/local transport seam |
| Watchdog | `test_compute_state_interactive`, `test_format_watchdog_status`, `test_watchdog_*` | Liveness and alert behavior |
| Hooks | `test_hook_env_validation`, `test_checkin_hook_*`, `test_on_tool_failure_hook_script` | Stop/checkin/tool-failure hook contracts |

## Command Surface Under Test

Current topic-safe Telegram commands:
- `/cd`
- `/close`
- `/memory`
- `/quota`
- `/pr`
- `/rewind`
- `/settings`
- `/voice`

Legacy orchestration commands are deliberately blocked in topic mode:
- `/hire`
- `/focus`
- `/team`
- `/end`
- `/progress`
- `/pause`
- `/restart`

The old `/hire` parsing and multi-backend tests were deleted with the
multi-worker model. Current tests only keep compatibility names where a helper
or test name predates the topic-only cleanup, for example
`test_topic_hire_starts_pane_in_picked_cwd`; those tests validate topic session
spawn, not a public `/hire` command.

## API Endpoint Coverage

The active endpoint registry is `API_ENDPOINTS` in `bridge.py`. Current tests
assert that:
- known endpoints return 2xx where appropriate;
- unknown GET/POST routes return JSON 404s with the endpoint list;
- deleted endpoints such as `/workers`, `/pilot`, `/remote-run`, `/poll`, and
  `POST /hire` stay absent.

## Complete Inventory By Runner Group

Keep this section grouped by runner rather than listing all 263 names. The
source of truth for exact names is the `run_test ...` calls inside `test.sh`.

### Unit Tests (FAST)

| Group | Coverage |
|-------|----------|
| Topic lifecycle/routing | Topic identity, folder picker, first-message trigger, topic close/reopen/delete, thread-targeted replies |
| Topic command surface | legacy command rejection, global command delegation, slim command menu |
| Extension seam | `EXTRA_COMMANDS` dispatch and no leak to Claude when handled |
| Formatting/media | response formatting, Telegram HTML, message splitting, media tags, file validation, inbound media typing |
| Voice | STT/TTS success/failure/timeout, auto-TTS, speak tags, `/voice` toggle |
| Claude/tmux helpers | Claude start command, tmux send locks, bracketed paste, flock isolation, concurrent-send baseline |
| Watchdog/hooks | state computation, alerts, poison signal files, tool-failure hook |
| Registry/checkin | session registry, checkin CWD, dead session restart, registry cleanup |
| Viewers/indexers | `viewer.py` transcript/team-chat renderers and transcript/team-chat SQLite indexers |
| Memory | `/memory status`, wake-up, recall, and failure isolation |
| Transport | transport protocol, local transport logging, mode selection |
| CLI | help/version/flags, status, webhook commands, hook install/test |

### Integration Tests (Default)

| Group | Coverage |
|-------|----------|
| Bridge startup | `GET /`, `/health/workers`, API index, unknown route errors |
| Admin/security | admin registration, webhook secret, token isolation, secure directories/files |
| Session lifecycle | open/close tmux session, dynamic command menu, reserved names |
| Routing | mentions/replies compatibility, tmux delivery, send-to-session integration |
| Media | inbox directory, documents/images, outbound response media tags |
| Hooks/endpoints | `/response`, `/notify`, `/checkin`, hook env validation |
| Removed endpoints | `/workers` removal against the live bridge |
| Process inspection | tmux prompt/process helpers and `export_hook_env` guard behavior |

### FULL Tests

| Test | Description |
|------|-------------|
| `test_with_tunnel` | Cloudflare tunnel + webhook configuration |

## Known Local Baseline Failure

On this machine, `test_concurrent_sends_no_interleave` can fail with:

```text
Concurrent sends: 0/25 clean
```

That is a local tmux/environment baseline issue. Do not fix product code for
this Task 11 gate. The gate is green when there are no failures other than that
whitelisted symptom.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TEST_BOT_TOKEN` | Yes | Test bot token. FAST mode accepts the dummy token used by unit tests. |
| `TEST_CHAT_ID` | Default/FULL only for real Telegram delivery | Chat ID for e2e messages |
| `FAST` | No | Set to `1` for unit + CLI only |
| `FULL` | No | Set to `1` to include tunnel/webhook tests |
| `TEST_FILTER` | No | Substring filter for test names |
| `TEST_PORT` | No | Bridge port, default `8295` |
| `TMUX_PREFIX` | No | Defaults to `claude-test-` under the test harness |

## Test Isolation

Tests default to the test node and avoid production resources:

| Resource | Test Default | Production Default |
|----------|--------------|--------------------|
| Node dir | `~/.claude/telegram/nodes/test/` | `~/.claude/telegram/nodes/prod/` |
| Port | `8295` | `8271` |
| tmux prefix | `claude-test-` | `claude-prod-` |
| Session files | `.../nodes/test/sessions/` | `.../nodes/prod/sessions/` |
| Logs | `.../nodes/test/*.log` | `.../nodes/prod/*.log` |

Never use `pkill` for cleanup on a multi-node machine. Use the node-specific
PID files or `./claudecode-telegram.sh --node test stop`.

## Manual Topic Webhook Smoke Test

Start the bridge locally:

```bash
TEST_BOT_TOKEN='...' PORT=8295 uv run python bridge.py
```

Then POST a forum-topic-shaped update. The first message in an unknown topic
should show the folder picker and should not be forwarded to Claude:

```bash
curl -X POST http://localhost:8295 \
  -H "Content-Type: application/json" \
  -d '{
    "update_id": 1,
    "message": {
      "message_id": 10,
      "message_thread_id": 123,
      "from": {"id": 123456789, "first_name": "Test"},
      "chat": {"id": -100123, "type": "supergroup"},
      "date": 1781200000,
      "text": "start"
    }
  }'
```

## Writing New Tests

Add focused tests to `test.sh` and register each one in the appropriate runner:

| Runner | Use For |
|--------|---------|
| `run_unit_tests()` | Pure Python/shell behavior that does not need a live bridge |
| `run_cli_tests()` | CLI parsing and shell wrapper behavior |
| `run_integration_tests()` | Local bridge, tmux, HTTP, hooks, or media paths |
| `run_full_tests()` | Tunnel and real webhook behavior |

Rules:
- Test behavior users rely on, not scaffolding.
- Prefer topic flows: create topic, choose folder, send message/media, receive
  reply in the same topic.
- Add viewer behavior tests near the existing `test_transcript_*` or
  `test_team_chat_*` groups when touching `viewer.py`.
- Add extension seam tests around `test_extension_seam_command` when adding
  topic-safe custom commands.
