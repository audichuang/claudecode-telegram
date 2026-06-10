# Topic-Sessions (簡化模型) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a simplified "one Telegram 話題 (forum Topic) = one Claude session" mode to `bridge.py`, with a native inline-keyboard folder picker and a `/quota` usage display — dropping focus/@/team/pending for the path the owner uses.

**Architecture:** A new **TOPIC_MODE** (env-gated, default off so legacy is untouched). When on, `handle_message` routes by `message_thread_id` instead of focus/team; each thread maps to a session named `t<thread_id>` (reusing existing `create_session`/tmux/hook primitives). A new `callback_query` handler drives an inline-keyboard folder navigator. Outbound replies carry `message_thread_id`. `/quota` reads claude-hud's `externalUsageWritePath` JSON.

**Tech Stack:** Python 3 (`bridge.py`, single module), bash test harness (`test.sh`) with inline `python3 -c` unit tests that import `bridge`, monkeypatch globals, and assert behavior.

**Spec:** `docs/superpowers/specs/2026-06-10-topic-sessions-design.md`

**Branch:** `feat/topic-sessions` (already created).

**How tests run:** Each new test is registered with `run_test test_xxx` inside `run_unit_tests` in `test.sh` (FAST mode). Run one with:
`TEST_FILTER=test_name FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Full FAST suite (regression guard — run with `TMUX_PREFIX=claude-test-` set, else the pre-existing `test_on_tool_failure_hook_script` aborts under `set -u`; ~10 pre-existing env failures are the baseline, NOT regressions):
`FAST=1 TEST_BOT_TOKEN=dummy TMUX_PREFIX=claude-test- ./test.sh`

**Key existing anchors (locate by content; line numbers drift):**
- `do_POST` (~`bridge.py:10235`) forwards only `"message"` updates → `command_router.handle_message`. No `callback_query` handling yet.
- `CommandRouter.handle_message` (~`6060`) reads `msg.get("text")`, `chat`, `message_id`.
- `MessageTransport.send_text(chat_id, text, parse_mode, reply_to)` (~`1309`) and `TelegramTransport.send_text` (~`1419`) → `telegram_api("sendMessage", payload)`.
- `create_session(name, backend=DEFAULT_BACKEND, chat_id=None)` (~`5890`) builds tmux `claude-<prefix><name>` and the per-session dir.
- `route_message(session_name, text, chat_id, msg_id, one_off=False)` (~`8423`) sends text into a worker's tmux.
- `get_chat_id_file(name)` (~`2980`); the Stop hook writes `chat_id`/`claude_session_id` into the session dir.
- `deliver_hook_response(session_name, text, chat_id, log_prefix)` (~`5789`, added by the B4 fix) — outbound to Telegram.

---

## Task 1: `message_thread_id` plumbing in the send path

Let outbound messages target a forum Topic. No behavior change when thread id is None.

**Files:**
- Modify: `bridge.py` — `MessageTransport.send_text` / `send_message` and `TelegramTransport.send_text` to accept `message_thread_id=None` and include it in the `sendMessage` payload when set; give `TelegramTransport.__init__` a `token: str = ""` default (backward-compatible) so the test can construct it argument-free.
- Test: `test.sh` — add `test_send_text_includes_thread_id`.

- [ ] **Step 1: Write the failing test**

```bash
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
```
Register `run_test test_send_text_includes_thread_id` in `run_unit_tests`.

- [ ] **Step 2: Run → FAIL** (`send_text` has no `message_thread_id` param → TypeError → no OK).

- [ ] **Step 3: Implement.** Add `message_thread_id=None` to the `send_text` signatures (base `MessageTransport.send_text`, `TelegramTransport.send_text`) and to `send_message`. In `TelegramTransport.send_text`, after building `payload = {"chat_id": chat_id, "text": text}`, add `if message_thread_id is not None: payload["message_thread_id"] = message_thread_id` before `telegram_api("sendMessage", payload)`. Keep `reply_to`/`parse_mode` handling unchanged. (Other transports may accept and ignore the kwarg.) Also give `TelegramTransport.__init__` a `token: str = ""` default so the Step 1 test can construct `bridge.TelegramTransport()` with no argument; this stays backward compatible with the positional caller `TelegramTransport(BOT_TOKEN)`.

- [ ] **Step 4: Run → PASS**, then full FAST suite (baseline only).

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): thread the message_thread_id through the send path"
```

---

## Task 2: Topic-session identity + store

A pure helper layer mapping a forum thread to a session, with no side effects on legacy state.

**Files:**
- Modify: `bridge.py` — add (near the focus helpers / module scope): `topic_session_name(thread_id)`, `save_topic_meta(name, chat_id, thread_id)`, `load_topic_meta(name)`, and a `find_topic_session(chat_id, thread_id, registered)` that returns the session name if its dir's stored `(chat_id, thread_id)` matches.
- Test: `test.sh` — add `test_topic_session_identity`.

- [ ] **Step 1: Write the failing test**

```bash
test_topic_session_identity() {
    info "Testing topic-session identity helpers..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.worker_manager.sessions_dir = tmp

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
```
Register it.

- [ ] **Step 2: Run → FAIL** (helpers absent → AttributeError).

- [ ] **Step 3: Implement** the four helpers. `topic_session_name(thread_id) -> f"t{int(thread_id)}"`. `save_topic_meta` writes `chat_id` and `message_thread_id` files (0600) into `SESSIONS_DIR/<name>/` (mirror `get_chat_id_file` pattern). `load_topic_meta` reads them back as ints (or `(None, None)`). `find_topic_session(chat_id, thread_id, registered)` iterates `registered` names, reads each `load_topic_meta`, returns the matching name else `None`.

- [ ] **Step 4: Run → PASS**, full FAST suite.

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): session identity keyed by (chat_id, message_thread_id)"
```

---

## Task 3: Folder navigator (inline keyboard, pure logic)

The button-browser data layer: list a directory's subfolders as buttons, confined to a root.

**Files:**
- Modify: `bridge.py` — add `TOPIC_ROOT = os.path.expanduser(os.environ.get("TOPIC_ROOT", "~"))` and `build_folder_keyboard(path)` returning a Telegram `inline_keyboard` (list of button rows): one button per immediate subdirectory (callback_data `cd:<path>`), an `⬆️ 上一層` button (callback_data `cd:<parent>`) shown only when `path` is strictly inside `TOPIC_ROOT`, and a `✅ 用這層` button (callback_data `use:<path>`). Also `_norm_under_root(path)` clamping a path to within `TOPIC_ROOT`.
- Test: `test.sh` — add `test_folder_navigator_keyboard`.

- [ ] **Step 1: Write the failing test**

```bash
test_folder_navigator_keyboard() {
    info "Testing folder navigator keyboard + root confinement..."
    if python3 -c "
import tempfile, os, json
from pathlib import Path
import bridge
root = Path(tempfile.mkdtemp())
(root / 'web').mkdir(); (root / 'api').mkdir(); (root / 'f.txt').write_text('x')
bridge.TOPIC_ROOT = str(root)

kb = bridge.build_folder_keyboard(str(root))
flat = [b for row in kb for b in row]
labels = [b['text'] for b in flat]
cbs = [b['callback_data'] for b in flat]
# folders listed (not the file), and a 'use here' button
assert any('web' in l for l in labels), labels
assert any('api' in l for l in labels), labels
assert not any('f.txt' in l for l in labels), labels
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
```
Register it.

- [ ] **Step 2: Run → FAIL** (functions absent).

- [ ] **Step 3: Implement** `TOPIC_ROOT`, `_norm_under_root` (realpath; if not under root, return `TOPIC_ROOT`), and `build_folder_keyboard` (list dirs via `os.scandir`, skip non-dirs, sort; cap to e.g. 30 buttons; add up-button only when `os.path.realpath(path) != TOPIC_ROOT`; always add `✅ 用這層`).

- [ ] **Step 4: Run → PASS**, full FAST suite.

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): inline-keyboard folder navigator (root-confined)"
```

---

## Task 4: callback_query dispatch + navigator handler

Wire button taps into the navigator: descend/up edits the keyboard; `use:` records the chosen cwd for the pending thread and opens the session.

**Files:**
- Modify: `bridge.py` — `do_POST` (~`10297`): also forward `if "callback_query" in update:` to a new `command_router.handle_callback(update)` (in a daemon thread, same as messages). Add `CommandRouter.handle_callback(update)` that parses `callback_query` (`data`, `message.chat.id`, `message.message_thread_id`, `message.message_id`), and: `cd:<path>` → edit the message's reply markup to `build_folder_keyboard(path)` (via `editMessageReplyMarkup`); `use:<path>` → call `self.open_topic_session(chat_id, thread_id, cwd=path, pending_text=<stored>)` (Task 5).
- Test: `test.sh` — add `test_handle_callback_navigates`.

- [ ] **Step 1: Write the failing test**

```bash
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
cr.handle_callback(upd('cd:' + str(root / 'web')))
assert calls['edit'] >= 1, 'cd should edit the keyboard'
cr.handle_callback(upd('use:' + str(root / 'web')))
assert calls['opened'] == (555, 4321, str(root / 'web')), calls['opened']
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "callback navigation works"
    else
        fail "callback navigation test failed"
    fi
}
```
Register it.

- [ ] **Step 2: Run → FAIL** (`handle_callback` absent).

- [ ] **Step 3: Implement** `handle_callback` + the `do_POST` forwarding. Use `editMessageReplyMarkup` with `{"chat_id","message_id","reply_markup":{"inline_keyboard": build_folder_keyboard(path)}}`. Always answer the callback (`answerCallbackQuery` with the `id`) to clear the spinner. Guard paths with `_norm_under_root`.

- [ ] **Step 4: Run → PASS**, full FAST suite.

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): callback_query dispatch + folder navigator handler"
```

---

## Task 5: Open-session flow (new 話題 → picker → spawn)

First message in an unknown thread shows the picker; selecting a folder spawns the session there and delivers the pending message.

**Files:**
- Modify: `bridge.py` — add `CommandRouter.open_topic_session(chat_id, thread_id, cwd, pending_text=None)`: `name = topic_session_name(thread_id)`; `create_session(name, chat_id=chat_id)` started in `cwd` (pass cwd via the existing startup-cwd mechanism / `_set_worker_cwd(name, cwd)` before start); `save_topic_meta(name, chat_id, thread_id)`; if `pending_text`, `route_message(name, pending_text, chat_id, None)`. Keep a module dict `_pending_topic_text: {(chat_id, thread_id): text}` set when the picker is first shown and consumed here.
- Test: `test.sh` — add `test_open_topic_session_spawns_in_cwd`.

- [ ] **Step 1: Write the failing test**

```bash
test_open_topic_session_spawns_in_cwd() {
    info "Testing open_topic_session spawns + binds + delivers..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp()); cwd = tmp / 'proj'; cwd.mkdir()
bridge.SESSIONS_DIR = tmp; bridge.worker_manager.sessions_dir = tmp
created = {}
bridge.create_session = lambda name, **k: created.update({'name': name, 'kw': k}) or (True, None)
routed = {}
cr = bridge.command_router
cr.route_message = lambda name, text, chat_id, msg_id, one_off=False: routed.update({'name': name, 'text': text})
bridge._set_worker_cwd = lambda name, c: created.update({'cwd': c})
(tmp / 't4321').mkdir(parents=True, exist_ok=True)
cr.open_topic_session(555, 4321, str(cwd), pending_text='hello')
assert created.get('name') == 't4321', created
assert created.get('cwd') == str(cwd), created
assert routed.get('text') == 'hello', routed
cid, tid = bridge.load_topic_meta('t4321')
assert cid == 555 and tid == 4321, (cid, tid)
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "open_topic_session works"
    else
        fail "open_topic_session test failed"
    fi
}
```
Register it.

- [ ] **Step 2: Run → FAIL** (`open_topic_session` absent).

- [ ] **Step 3: Implement** `open_topic_session` per the Files note. Set cwd before `create_session` so the worker starts there (reuse `_set_worker_cwd`/the startup-cwd path used by `/checkin`).

- [ ] **Step 4: Run → PASS**, full FAST suite.

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): open a session in the picked folder and deliver first message"
```

---

## Task 6: Inbound topic routing (TOPIC_MODE)

Route messages by thread when TOPIC_MODE is on; unknown thread → show picker (store pending text); known thread → deliver to its session. Legacy path untouched when TOPIC_MODE off.

**Files:**
- Modify: `bridge.py` — add `TOPIC_MODE = os.environ.get("TOPIC_MODE", "0") == "1"`. At the TOP of `handle_message` (after parsing `text`/`chat_id`/`msg_id`), add: `if TOPIC_MODE and chat_id: return self._handle_topic_message(msg, text, chat_id, msg_id)`. Implement `_handle_topic_message`: read `thread_id = msg.get("message_thread_id")`; if `thread_id is None` → single default session (Task 8); handle `/close`,`/cd` (Task 7); else `registered = worker_manager.get_registered_sessions(); name = find_topic_session(chat_id, thread_id, registered)`; if found → `route_message(name, text, chat_id, msg_id)`; else store `_pending_topic_text[(chat_id,thread_id)] = text` and send the folder navigator keyboard rooted at `TOPIC_ROOT`.
- Test: `test.sh` — add `test_topic_routing_known_and_unknown`.

- [ ] **Step 1: Write the failing test**

```bash
test_topic_routing_known_and_unknown() {
    info "Testing TOPIC_MODE inbound routing..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.worker_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
# known thread t4321 already registered + bound
(tmp / 't4321').mkdir(parents=True, exist_ok=True)
bridge.save_topic_meta('t4321', 555, 4321)
bridge.worker_manager.get_registered_sessions = lambda registered=None: {'t4321': {}}
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
assert bridge._pending_topic_text.get((555, 8888)) == 'new one', bridge._pending_topic_text
print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "topic routing works"
    else
        fail "topic routing test failed"
    fi
}
```
Register it. (Implement `_send_folder_picker(chat_id, thread_id)` to `send_message` with `reply_markup.inline_keyboard = build_folder_keyboard(TOPIC_ROOT)` and `message_thread_id=thread_id`; the test stubs it.)

- [ ] **Step 2: Run → FAIL** (`_handle_topic_message` absent / TOPIC_MODE unused).

- [ ] **Step 3: Implement** `TOPIC_MODE`, the early dispatch in `handle_message`, `_handle_topic_message`, and `_send_folder_picker`.

- [ ] **Step 4: Run → PASS**, full FAST suite (also confirm legacy tests still pass — TOPIC_MODE defaults off).

- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): route inbound messages by 話題 thread when TOPIC_MODE on"
```

---

## Task 7: `/close` and `/cd` in a 話題

`/close` ends the thread's session; `/cd` re-opens the picker (or accepts a typed path).

**Files:**
- Modify: `bridge.py` — in `_handle_topic_message`, before the find/route logic: if `text` starts with `/close` → look up the thread's session via `find_topic_session`, `worker_manager.end(name)`, reply "closed" in the thread; if `text` starts with `/cd` → with an arg `/cd <path>` set cwd (`_set_worker_cwd`) and `worker_manager.restart(name)` (or re-open) else `_send_folder_picker`.
- Test: `test.sh` — add `test_topic_close_and_cd`.

- [ ] **Step 1: Write the failing test**

```bash
test_topic_close_and_cd() {
    info "Testing /close and /cd in a topic..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.worker_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
(tmp / 't4321').mkdir(parents=True, exist_ok=True); bridge.save_topic_meta('t4321', 555, 4321)
bridge.worker_manager.get_registered_sessions = lambda registered=None: {'t4321': {}}
ended = {}; pickers = {'n': 0}
bridge.worker_manager.end = lambda name: ended.update({'name': name}) or (True, None)
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
```
Register it.

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the `/close` and `/cd` branches in `_handle_topic_message`.
- [ ] **Step 4: Run → PASS**, full FAST suite.
- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): /close ends a 話題 session, /cd changes its folder"
```

---

## Task 8: Outbound reply targets the originating 話題

The hook response must land in the right Topic.

**Files:**
- Modify: `bridge.py` — `handle_hook_response`/`deliver_hook_response` path: after resolving `session_name`, read `(_, thread_id) = load_topic_meta(session_name)` and pass `message_thread_id=thread_id` into the send (`send_response_to_telegram`/`send_text`). Thread `message_thread_id` through `send_response_to_telegram` to the transport.
- Test: `test.sh` — add `test_hook_reply_targets_thread`.

- [ ] **Step 1: Write the failing test**

```bash
test_hook_reply_targets_thread() {
    info "Testing hook reply carries message_thread_id..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.worker_manager.sessions_dir = tmp
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
```
Register it.

- [ ] **Step 2: Run → FAIL** (send doesn't yet pass thread_id from meta).
- [ ] **Step 3: Implement.** In `send_response_to_telegram`, read `load_topic_meta(name)`’s thread_id (None if absent) and pass `message_thread_id=` to `transport.send_text`. (When absent → behaves exactly as today.)
- [ ] **Step 4: Run → PASS**, full FAST suite.
- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): hook replies post back into the originating 話題"
```

---

## Task 9: `/quota` usage display

Read claude-hud's external usage snapshot and render 5h/7d (and best-effort context); clear fallback when absent.

**Files:**
- Modify: `bridge.py` — add `USAGE_FILE = os.path.expanduser(os.environ.get("CC_USAGE_FILE", "~/.claude/cc-usage.json"))`, `read_usage_snapshot()` (returns dict or None; treat older than ~10 min by `updated_at` as stale→None), `format_quota(snap)` (renders 10-char bars, `100-used` remaining, relative reset; null window → `n/a`; None → "usage unavailable — no subscriber rate-limit data"), and a `/quota` command (works in both legacy and TOPIC modes).
- Test: `test.sh` — add `test_quota_render`.

- [ ] **Step 1: Write the failing test**

```bash
test_quota_render() {
    info "Testing /quota rendering + fallback..."
    if python3 -c "
import bridge
snap = {'updated_at': '2026-06-10T12:00:00+00:00',
        'five_hour': {'used_percentage': 31, 'resets_at': '2026-06-10T14:00:00+00:00'},
        'seven_day': {'used_percentage': 82, 'resets_at': '2026-06-12T00:00:00+00:00'}}
out = bridge.format_quota(snap)
assert '5h' in out and '31%' in out, out
assert '7d' in out and '82%' in out, out
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
```
Register it. (Test calls `format_quota` directly with a fixed `now` tolerance — implement `format_quota` to not depend on the wall clock for the percent/label assertions; reset-time may be relative and is not asserted exactly.)

- [ ] **Step 2: Run → FAIL** (`format_quota` absent).
- [ ] **Step 3: Implement** `read_usage_snapshot`, `format_quota`, and the `/quota` command handler (in `handle_message` command dispatch and `_handle_topic_message`). Parse ISO timestamps with `datetime.fromisoformat`.
- [ ] **Step 4: Run → PASS**, full FAST suite.
- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh
git commit -m "feat(topic): /quota usage display from claude-hud external snapshot"
```

---

## Task 10: Non-forum fallback + final wiring & docs

A plain DM (no `message_thread_id`) maps to one default session; document setup.

**Files:**
- Modify: `bridge.py` — in `_handle_topic_message`, when `thread_id is None`: use a fixed default session name (e.g. `tmain`) — same open/route logic as a thread, keyed by chat only.
- Modify: `DOC.md` — short section: enabling TOPIC_MODE (env `TOPIC_MODE=1`, optional `TOPIC_ROOT`), the forum-group + bot-admin setup, enabling claude-hud `externalUsageWritePath` for `/quota`.
- Test: `test.sh` — add `test_topic_non_forum_fallback`.

- [ ] **Step 1: Write the failing test**

```bash
test_topic_non_forum_fallback() {
    info "Testing non-forum (no thread) → single default session..."
    if python3 -c "
import tempfile
from pathlib import Path
import bridge
tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp; bridge.worker_manager.sessions_dir = tmp
bridge.TOPIC_MODE = True; bridge.TOPIC_ROOT = str(tmp)
(tmp / 'tmain').mkdir(parents=True, exist_ok=True); bridge.save_topic_meta('tmain', 555, 0)
bridge.worker_manager.get_registered_sessions = lambda registered=None: {'tmain': {}}
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
```
Register it.

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the `thread_id is None` branch (default name `tmain`, thread stored as `0`). Then write the `DOC.md` setup section.
- [ ] **Step 4: Run → PASS**, full FAST suite.
- [ ] **Step 5: Commit**
```bash
git add bridge.py test.sh DOC.md
git commit -m "feat(topic): non-forum fallback session + TOPIC_MODE/quota setup docs"
```

---

## Final verification

- [ ] Full FAST suite green vs baseline: `FAST=1 TEST_BOT_TOKEN=dummy TMUX_PREFIX=claude-test- ./test.sh` (only the ~10 documented pre-existing env failures; all `topic`/`quota` tests pass).
- [ ] Default suite: `TEST_BOT_TOKEN=dummy TMUX_PREFIX=claude-test- ./test.sh` — no NEW failures vs the pre-existing `/hire` + env baseline.
- [ ] Manual smoke on the dev node with `TOPIC_MODE=1`: create a 話題, send a message, pick a folder, get a reply in the 話題; `/quota` shows usage or the unavailable fallback.

## Spec coverage check

| Spec item | Task |
|-----------|------|
| 話題=session identity ((chat_id, thread_id)) | 2 |
| inbound routing by thread | 6 |
| folder navigator (callback_query) | 3, 4 |
| open via new-topic-first-message | 5, 6 |
| outbound reply to originating 話題 | 1, 8 |
| /close, /cd | 7 |
| non-forum fallback | 10 |
| /quota usage display | 9 |
| TOPIC_MODE gate (legacy untouched) | 6, 10 |
| e2e test per behavior | each task, Step 1 |

## Notes / risks

- TOPIC_MODE is env-gated and default OFF, so all legacy behavior and tests are unaffected until explicitly enabled (`TOPIC_MODE=1`).
- Forum messages require the bot to be a group admin (privacy mode off) to receive non-command text; document this.
- `create_session`'s exact cwd argument: the implementer must confirm how `create_session`/startup-cwd consumes the chosen folder (reuse the `/checkin?cwd=` path: `_set_worker_cwd` then start). If `create_session` takes a cwd/requested_cwd argument directly, prefer that.
- Tests monkeypatch module globals (`bridge.create_session`, `worker_manager.*`, `transport.send_text`, `telegram_api`) — they do NOT start a bridge or tmux, matching the FAST unit-test style.
