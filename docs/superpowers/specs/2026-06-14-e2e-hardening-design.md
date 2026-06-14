# E2E Hardening Architecture & Per-Seam Test Plan

> Closes SEAM-01..10. Goal: every new test has an explicit RED criterion — it provably fails when the feature is broken. No pass-when-broken, no spy-only assertions where a real boundary is feasible.

## 0. Verified Ground Truth (read before implementing)

All recon claims were re-verified against live source on branch `fix/v1.2.0-fail-loudly-polish`:

| Claim | Evidence |
|---|---|
| 7 hardcoded `https://api.telegram.org` literals, no env override | `bridge.py:863,970,1021,1072,1118,1185,1206` (grep count = 7) |
| Central JSON call | `TelegramAPI.api` `bridge.py:859-881` (reads `e.read()` error body -> reap works) |
| Multipart field order (chat_id, message_thread_id ONLY if truthy, file, caption) | `_send_media_multipart` `bridge.py:1088-1132` |
| getFile -> `/file/bot<token>/<path>` download two-step | `bridge.py:1180-1222` |
| `TRANSPORT=local` short-circuits before the wire (canned `{ok:True,message_id:1}`) | `bridge.py:1308-1310` |
| Reap on `"thread not found"` substring; thread 0 omitted to protect tmain | `_reap_dead_topic` `bridge.py:4695-4719`; omit at `4736-4737`; callsite `4792` |
| `_end_topic_session` shared by /close + forum_topic_closed + reaper | `bridge.py:5288-5304`, `5366`, `5394` |
| Stop hook: jsonl last-turn extraction + prefix-strip + chat_id gate + TMUX_FALLBACK | `hooks/send-to-telegram.sh:80-128,140-190` |
| `TMUX_FALLBACK=1` injected by default; hook honors `=0` | `bridge.py:4651`; hook `:143` |
| `test_direct_mode_*` dead | grep `run_test test_direct_mode` = 0; grep `DIRECT_MODE bridge.py` = 0 |
| `check_claude_available` salvageable | `test.sh:11258-11264` |
| `end()` primitive already real-tmux covered | `test_end_removes_from_registry` `test.sh:10009`, registered `12869` |
| cleanup() is the ONLY teardown (EXIT trap) | `test.sh:134-167,169` |
| count_matching_tests scrapes only unit/cli/integration/full | `test.sh:103-131` |

## 1. The Split (which mode closes which seam)

**Falsifiability without a real agent comes from a recording Mock-Telegram HTTP server (architecture A).** It makes delivery, threading, reactions, silence, and media observable at the real wire boundary in DEFAULT mode.

**Agent-driven confidence (LINK2..LINK6 true L3) comes from a gated real-claude harness (architecture B), E2E=1.**

| Seam | Mode | Why |
|---|---|---|
| SEAM-02 delivery un-falsifiable | DEFAULT (mock) | Assert recorded sendMessage, not the bridge's log line |
| SEAM-09 admin-gate silence | DEFAULT (mock) | Observe ZERO recorded send+reaction for non-admin |
| SEAM-03 thread targeting (record half) | DEFAULT (mock) | Assert message_thread_id in recorded payload; tmain field-absent |
| SEAM-08 close/reap glue | DEFAULT (mock) | Programmable 400 drives REAL reap; isolated claude-test- session |
| SEAM-10 reaction arc (record half) | DEFAULT (mock) | Assert recorded setMessageReaction sequence |
| SEAM-07 media/getFile (record half) | DEFAULT (mock) | Real multipart + real download round-trip to inbox |
| SEAM-01 real claude never runs | E2E | Only a real claude turn drives LINK3->4->5 |
| SEAM-06 Stop-hook contract e2e | E2E | TMUX_FALLBACK=0 forces real jsonl extraction |
| SEAM-04 spawn-in-cwd + trust dialog | E2E | Fresh untrusted tmpdir triggers real dialog |
| SEAM-05 pane-live != claude-live | E2E | Marker roundtrip proves the claude process, not the shell |
| SEAM-03/07/10 (L3 halves) | E2E | Two real topics + real worker transitions |

## 2. Production Changes (minimal, idiomatic)

### 2.1 REQUIRED — TELEGRAM_API_BASE seam
Add after `BOT_TOKEN` (`bridge.py:52`):
```python
TELEGRAM_API_BASE = os.environ.get("TELEGRAM_API_BASE", "https://api.telegram.org").rstrip("/")
```
Replace all 7 literals (keep the rest of each f-string identical):
- `:863` `f"{TELEGRAM_API_BASE}/bot{self.token}/{method}"`
- `:970` sendPhoto, `:1021` sendAnimation, `:1072` sendDocument, `:1118` `{api_method}`, `:1185` getFile — `f"{TELEGRAM_API_BASE}/bot{BOT_TOKEN}/..."`
- `:1206` `download_url = f"{TELEGRAM_API_BASE}/file/bot{BOT_TOKEN}/{file_path}"`

**Trap:** swapping only `:863` leaves media + getFile + download on real Telegram (SEAM-07 silently un-closed). All 7 must change. Default unset == prod byte-identical.

### 2.2 OPTIONAL (recommend ship) — hermetic Stop-hook pin
In `build_claude_start_cmd` (`bridge.py:206-211`), if `os.environ.get("CLAUDE_SETTINGS_FILE_SPAWN")` is set, append `--settings <path>` (shlex.quoted). Repurposes the already-dead `CLAUDE_SETTINGS_FILE` constant (`:80`). Lets the E2E harness pin the spawned claude's Stop hook to `<repo>/hooks/send-to-telegram.sh` for CI hermeticity. Default unset == byte-identical.

### 2.3 Test-side cleanup
Delete the 20 unregistered `test_direct_mode_*` funcs + their private helpers; salvage `check_claude_available`; drop the `direct_mode_bridge.pid` block in `cleanup()`.

## 3. Shared Harness

### 3.1 Mock-Telegram server (`tests/mock_telegram.py`, stdlib only)
- `python3 tests/mock_telegram.py --port <P> --record <JSONL>`; `ThreadingHTTPServer` + `SO_REUSEADDR` on `127.0.0.1`.
- Serves BOTH path families: `POST /bot<TOKEN>/<method>` (JSON or multipart) and `GET /file/bot<TOKEN>/<file_path>` (raw bytes).
- Multipart parsing is **hand-rolled** (~30 lines splitting on the boundary + parsing `Content-Disposition`) — `cgi.FieldStorage` is removed in 3.13 and the project is py3.12+.
- Records one **lock-guarded** JSON line per call: `{ts, method, chat_id, message_thread_id, text, caption, reply_to_message_id, _file:{field,filename,size,sha256}}` to JSONL + in-memory list.
- Default send response: `{ok:true, result:{message_id:<incrementing>, ...echo chat_id/message_thread_id}}` so multi-chunk reply-chaining (`prev_msg_id`, `bridge.py:4784`) keeps working.
- getFile -> `{ok:true,result:{file_path:'documents/<id>.bin',file_size:N}}`; download serves programmed bytes or default `b'MOCKBYTES:'+path`.
- Control: `GET /_recorded`, `POST /_reset`, `POST /_program` (`{thread_not_found:[...], files:{path:b64}}`), `GET /_health`.
- Fault: a programmed `thread_not_found` thread -> HTTP 400 `{ok:false,error_code:400,description:'Bad Request: message thread not found'}` (exact substring `_reap_dead_topic` matches).
- Must respond promptly (urllib timeouts 10/30/60s).

### 3.2 Lifecycle wiring in test.sh
- `start_mock_telegram()` before `test_bridge_starts`: `MOCKPORT=$((PORT+100))` (no collision with `$PORT`/`$BRIDGE_PID`), lsof-kill stale owner, launch, PID -> `$TEST_NODE_DIR/mock_tg.pid`, `wait_for_port`.
- Add a sibling kill block in `cleanup()` (after `bridge.pid`, `test.sh:144-147`) for `mock_tg.pid`, and rm `telegram_calls.jsonl` + e2e tmpdir.
- Bridge launch env (`test.sh:4935-4942`): add `TELEGRAM_API_BASE=http://127.0.0.1:$MOCKPORT` and a **concrete** `ADMIN_CHAT_ID` (so /notify has a target). Keep `TRANSPORT` unset (telegram) and a dummy non-empty `TELEGRAM_BOT_TOKEN` so `if not BOT_TOKEN` early-returns don't skip media/file code.

### 3.3 E2E spawn helper
`spawn_real_claude` pre-trusts the tmpdir, pins the Stop hook via `CLAUDE_SETTINGS_FILE_SPAWN`, drives real LINK1->LINK2 (forum-topic webhook + folder-picker callback), and polls for claude readiness (not `sleep 3`).

## 4. Helper API Contract (canonical — do not invent alternatives)

`start_mock_telegram`, `mock_reset`, `mock_assert_sendmessage <tid> <marker>`, `mock_assert_thread_absent <marker> [tid]`, `mock_assert_silence <chat>`, `mock_assert_reaction_arc <chat> <msg> <e1..>`, `mock_program_thread_not_found <tid>`, `mock_register_file_bytes <path> <local>`, `mock_assert_inbox_sha <session> <sha>`, `check_claude_available`, `spawn_real_claude <suffix> <cwd> <chat> <tid>`, `send_topic_message <chat> <tid> <text> [msgid]`. All assertions read `/_recorded` (lock-synced) — never the bridge log.

Canonical jq assertion:
```bash
curl -s "http://127.0.0.1:$MOCKPORT/_recorded" \
| jq -e --argjson n "$tid" --arg m "$marker" \
  'any(.[]; .method=="sendMessage" and .message_thread_id==$n and (.text|contains($m)))'
```

## 5. Mode Gating
- `FAST=1` unit+CLI (unchanged).
- DEFAULT: integration runner starts the mock + runs mock-based tests (SEAM-02/03/07/08/09/10 record/bounce halves). Fast, deterministic, no claude, no secrets.
- `FULL=1` default + tunnel (unchanged).
- `E2E=1` NEW 4th branch in `main()` (`13159-13167`) + `run_e2e_tests` gated after `13189`; `run_e2e_tests` calls `check_claude_available` and SKIPS loudly if absent. A turn timeout is a HARD FAILURE. Extend `count_matching_tests` (`103-131`) to scrape `run_e2e_tests` under an e2e branch.

## 6. Per-Seam Test Matrix
(See the structured per-seam plan; every row names its RED criterion — the assertion that fails when the feature is broken — and its GREEN criterion.)

## 7. Tracer-Bullet Implementation Order (cornerstones first)
1. **Production seam:** add `TELEGRAM_API_BASE` + route all 7 URLs. Verify prod unchanged (`uv run ruff check .`; existing suite still green).
2. **Mock server skeleton:** `tests/mock_telegram.py` JSON-only + `/_recorded`/`/_reset`/`/_health`; `start_mock_telegram` + cleanup wiring.
3. **First falsifiable test (SEAM-02):** `test_mock_response_delivers_real_sendmessage`. Prove RED by temporarily breaking delivery; confirm it fails; restore. This is the cornerstone that retires the SEAM-02 false-green.
4. **Threading (SEAM-03):** add message_thread_id capture + `mock_assert_thread_absent`; tmain field-absent test.
5. **Silence (SEAM-09)** then **reaction arc (SEAM-10).**
6. **Multipart + download (SEAM-07):** extend mock with the hand-rolled multipart parser + `/file` route + `/_program` files.
7. **Bounce/reap (SEAM-08):** add `/_program thread_not_found`; isolated claude-test- session; tmain-not-reaped guard.
8. **Delete dead `test_direct_mode_*`** (salvage `check_claude_available`).
9. **E2E mode skeleton:** 4th branch + `run_e2e_tests` + `check_claude_available` gate + count scrape; ship optional `--settings` pin.
10. **E2E cornerstone (SEAM-01/06):** `test_e2e_real_claude_marker_roundtrip` with `TMUX_FALLBACK=0`. Then SEAM-04/05 and the L3 isolation/reaction tests.

## 8. Codex Review Fixes (MANDATORY — verified against live source; apply to every applicable test)

> Independent GPT-5.5 (Codex) adversarial review flagged 6 false-greens + 4 flakiness risks + 5 missed scenarios. These are binding on all per-seam authors.

**As-built foundation facts (use these exact contracts):**
- Seed a bound topic session with two files only: `SESSIONS_DIR/<name>/chat_id` (plain int) and `SESSIONS_DIR/<name>/message_thread_id` (plain int). `POST /response {session,text}` resolves the chat from the `chat_id` file — the session does NOT need to be in the RAM worker map (no tmux/spawn needed for delivery-only tests).
- The bridge HTML-wraps replies as `<b>{name}:</b>\n{text}` → assert **substring containment**, never equality.
- Bridge boot emits a `setMyCommands` record; folder-picker/typing/callback also emit traffic → **filter by `method=="sendMessage"`**, never "any call happened".
- `mock_assert_inbox_sha` looks under `/tmp/claudecode-telegram/test/<session>/inbox/` (node `test` from `claude-test-`).
- bridge.py grew +6 lines; re-grep before trusting any absolute line number in §0.

**Assertion specificity (every mock test):** call `mock_reset` at the TOP; assert the ATOMIC tuple (`method==sendMessage` AND `message_thread_id==tid` AND `text contains marker`). Distinguish absent vs explicit-0 vs correct tid — tmain reply ⇒ the `message_thread_id` KEY is ABSENT (`mock_assert_thread_absent <marker>` with no tid).

**SEAM-08 reap:** the bounce must be a **real HTTP 400** (mock already returns 400, not 200+`ok:false` — urllib drives different paths). Drive the REAL `_reap_dead_topic` via `send_response_to_telegram` and assert the real session is **gone** (`wait_for_session_gone`), not that a stub ran. Add a tmain-never-reaped guard.

**SEAM-09 admin gate:** the non-admin update must have BOTH `from.id` AND `chat.id` ≠ admin (the gate rejects only when both differ). Assert `mock_assert_silence` (zero sendMessage AND zero setMessageReaction). ALSO add a non-admin **callback tap** test (separate gate in `handle_callback`): a non-admin folder-pick must not create/browse a session.

**E2E harness (`spawn_real_claude`) — all MANDATORY:**
1. Drive the REAL path: `forum_topic_created` webhook → folder-picker **`callback_query`** (`use:<path>`) → bridge `create_session` real tmux spawn. Do NOT call `open_topic_session`/`create_session` directly and do NOT spawn `claude` yourself — LINK2/LINK3/LINK4 must traverse the real bridge.
2. `TMUX_FALLBACK=0` must reach the **hook's own process env**: after spawn, `tmux set-environment -t <session> TMUX_FALLBACK 0` (bash/bridge env does NOT propagate to the hook). This forces a green to come only from real jsonl extraction, not capture-pane fallback.
3. Settings pin is **REQUIRED for E2E** (not optional): launch the bridge with `CLAUDE_SETTINGS_FILE_SPAWN=<settings.json pinning Stop → repo hooks/send-to-telegram.sh>` so the spawned claude loads the REPO hook, not the operator's global.
4. Turn-completion signal = **poll for mock-recorded delivery** (`/_recorded` shows a sendMessage with the marker), NEVER pending-file absence (the hook removes `pending` + exits 0 even when extraction finds no text).
5. Marker prompt: "Reply with exactly this token and nothing else: TESTMARKER-<nonce>"; assert text **CONTAINS** the marker (claude may add text); unique nonce per test.
6. Readiness polling keys off claude actually answering a probe (marker roundtrip), not generic pane text (avoid misreading a login/rate-limit screen as ready).

**SEAM-04 contradiction RESOLVED:** prod spawns with `--dangerously-skip-permissions`, so the trust dialog never appears on the prod path. MAIN SEAM-04 test = "real claude spawns and is genuinely alive in the picked cwd" (claude writes/reads a file in cwd or echoes a pwd marker) on the prod path. The trust-dialog auto-answer (`bridge.py ~4255`) is DEFENSIVE code; test it (if at all) as a clearly-labeled, **non-blocking** separate test that spawns WITHOUT `--dangerously-skip-permissions` in a fresh untrusted tmpdir. Do not claim the prod path exercises it.

**SEAM-05:** prove the claude PROCESS is alive (marker roundtrip), not the bash pane (`tmux has-session` passes on dead-claude/live-shell).

**New scenarios to ADD (were unseamed):**
- **Multi-chunk reply ordering** (DEFAULT): a >4096-char `/response` text splits into multiple sendMessage; assert each chunk recorded in order with `reply_to_message_id` chaining to the prior chunk's returned (incrementing) `message_id`.
- **Session cleanup after `forum_topic_closed`** (DEFAULT/E2E): after close, the session is removed so a reopened topic creates a FRESH session (no zombie re-attach).
- **Webhook-registration egress**: confirm the bridge issues no startup call to real Telegram when `TELEGRAM_API_BASE` points at the mock.