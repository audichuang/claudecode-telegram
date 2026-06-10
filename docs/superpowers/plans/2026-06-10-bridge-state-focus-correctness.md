# Core Bridge State / Focus Correctness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the worker's focus / session-id / pending state stay consistent with reality across hire/end/restart/crash, with no read-function side effects.

**Architecture:** Introduce a tiny explicit focus interface (`set_focus`/`clear_focus`/`reconcile_startup_focus`), make `get_registered_sessions()` stop auto-picking a focus, clean session-id on every `/end`, and clear `pending` on every restart and on every hook-response path (even on send failure).

**Tech Stack:** Python 3 (`bridge.py`, single module), bash test harness (`test.sh`) with inline `python3 -c` unit tests that import `bridge`, monkeypatch module globals, and assert behavior.

**Spec:** `docs/superpowers/specs/2026-06-10-bridge-state-focus-correctness-design.md`

**Branch:** `fix/bridge-state-focus-correctness` (already created).

**How tests run:** Each new test is registered with a `run_test test_xxx` line inside the `run_unit_tests` function in `test.sh` (these tests do NOT start a bridge, so they run in FAST mode). Run a single test with:

```bash
TEST_FILTER=test_name FAST=1 TEST_BOT_TOKEN=dummy ./test.sh
```

Run the whole FAST suite (regression guard after each task):

```bash
FAST=1 TEST_BOT_TOKEN=dummy ./test.sh
```

---

## File structure

- Modify: `bridge.py` — all production changes live here.
  - Focus helpers added after `load_last_active()` (around line 1142).
  - `get_registered_sessions()` (`4808-4843`), startup wiring (`11293-11319`), `end()` (`5126-5167`), `restart()` (`5169-5191`), `handle_hook_response()` (`10330-10389`).
- Modify: `test.sh` — new `test_*` functions (inline `python3 -c`) + `run_test` registrations in `run_unit_tests`.

No new files. The module is large but established; we follow the existing single-file pattern and the existing inline-python test style (see `test_end_clears_pending` at `test.sh:6462`).

---

## Task 1: Focus interface helpers (pure refactor)

Add `set_focus`/`clear_focus`/`reconcile_startup_focus` and route the 6 existing focus-write pairs through `set_focus`. No behavior change yet.

**Files:**
- Modify: `bridge.py` — add helpers after `load_last_active()` (after line 1142); replace focus writes at `5117-5118, 5876-5877, 6247-6248, 6360-6361, 6876-6877, 6895-6896`.
- Test: `test.sh` — add `test_focus_helpers`, register in `run_unit_tests`.

- [ ] **Step 1: Write the failing test**

Add this function to `test.sh` (next to `test_end_clears_pending`, around line 6494):

```bash
test_focus_helpers() {
    info "Testing set_focus/clear_focus/reconcile_startup_focus..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

bridge.LAST_ACTIVE_FILE = Path(tempfile.mkdtemp()) / 'last_active'
bridge.NODE_DIR = bridge.LAST_ACTIVE_FILE.parent

# set_focus sets state and persists
bridge.set_focus('alice')
assert bridge.state['active'] == 'alice', 'set_focus did not set active'
assert bridge.LAST_ACTIVE_FILE.read_text() == 'alice', 'set_focus did not persist'

# clear_focus clears, never auto-picks
bridge.clear_focus()
assert bridge.state['active'] is None, 'clear_focus did not clear active'

# reconcile_startup_focus: restore only if still registered
assert bridge.reconcile_startup_focus('bob', {'bob': {}}) == 'bob'
assert bridge.reconcile_startup_focus('gone', {'bob': {}}) is None
assert bridge.reconcile_startup_focus(None, {'bob': {}}) is None

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "focus helpers work"
    else
        fail "focus helpers test failed"
    fi
}
```

Register it: in `run_unit_tests`, add a line `run_test test_focus_helpers` next to the other focus/end unit tests.

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_FILTER=test_focus_helpers FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL (AttributeError: module 'bridge' has no attribute 'set_focus' → no "OK" → "focus helpers test failed").

- [ ] **Step 3: Add the helpers**

In `bridge.py`, immediately after `load_last_active()` (after line 1142), add:

```python
def set_focus(name):
    """Set the active (focused) worker and persist it for restart."""
    state["active"] = name
    save_last_active(name)


def clear_focus():
    """Clear focus. Never auto-picks a replacement worker."""
    state["active"] = None


def reconcile_startup_focus(last_active, registered):
    """Focus to restore on startup: last_active only if it still exists, else None."""
    if last_active and last_active in registered:
        return last_active
    return None
```

- [ ] **Step 4: Route the 6 existing focus writes through `set_focus`**

At each of these locations, replace the adjacent pair
`state["active"] = <var>` + `save_last_active(<var>)` with `set_focus(<var>)`:

- `bridge.py:5117-5118` → `set_focus(name)`
- `bridge.py:5876-5877` → `set_focus(name)`
- `bridge.py:6247-6248` → `set_focus(target)`
- `bridge.py:6360-6361` → `set_focus(worker_name)`
- `bridge.py:6876-6877` → `set_focus(name)`
- `bridge.py:6895-6896` → `set_focus(name)`

(Preserve surrounding indentation. Do not change any other lines.)

- [ ] **Step 5: Run test to verify it passes + full FAST suite green**

Run: `TEST_FILTER=test_focus_helpers FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: PASS ("focus helpers work").
Then: `FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: all FAST tests pass (the refactor is behavior-preserving).

- [ ] **Step 6: Commit**

```bash
git add bridge.py test.sh
git commit -m "refactor: add explicit focus interface (set_focus/clear_focus/reconcile_startup_focus)"
```

---

## Task 2: Stop auto-picking focus (B1)

Remove the focus auto-pick from `get_registered_sessions()`, wire startup restore through `reconcile_startup_focus`, and clear focus (not re-pick) when ending the focused worker.

**Files:**
- Modify: `bridge.py:4840-4841` (remove auto-pick), `11314-11319` (startup), `5163-5165` (end focus clear).
- Test: `test.sh` — add `test_get_registered_sessions_no_autopick` and `test_end_focused_worker_clears_focus`, register in `run_unit_tests`.

- [ ] **Step 1: Write the failing tests**

Add to `test.sh` (near `test_focus_helpers`):

```bash
test_get_registered_sessions_no_autopick() {
    info "Testing get_registered_sessions does not auto-pick focus..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.worker_manager.sessions_dir = tmp
bridge.worker_manager.tmux_prefix = 'claude-test-'
bridge.worker_manager.scan_tmux_sessions = lambda: {'bob': {'tmux': 'claude-test-bob', 'backend': 'claude'}}
bridge._registry_bootstrap = lambda reg: None
bridge._load_registry = lambda: {'workers': {}}

bridge.state['active'] = None
reg = bridge.worker_manager.get_registered_sessions()
assert 'bob' in reg, 'bob should be registered'
assert bridge.state['active'] is None, 'focus must stay None, not be auto-picked'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "get_registered_sessions does not auto-pick"
    else
        fail "get_registered_sessions auto-pick test failed"
    fi
}

test_end_focused_worker_clears_focus() {
    info "Testing /end of focused worker clears focus (no silent re-focus)..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.FILE_INBOX_ROOT = tmp / 'inbox'
bridge.WORKER_PIPE_ROOT = tmp / 'pipes'
bridge.worker_manager.sessions_dir = tmp
bridge.worker_manager.tmux_prefix = 'claude-test-'
bridge.worker_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'},
    'bob': {'tmux': 'claude-test-bob', 'backend': 'claude'},
}

bridge.state['active'] = 'alice'
ok, err = bridge.worker_manager.end('alice')
assert ok is True, f'end failed: {err}'
assert bridge.state['active'] is None, f'focus should be None, got {bridge.state[\"active\"]!r}'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "/end of focused worker clears focus"
    else
        fail "/end focus-clear test failed"
    fi
}
```

Register both with `run_test` lines in `run_unit_tests`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `TEST_FILTER=test_get_registered_sessions_no_autopick FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL — current code auto-picks `bob`, so `state['active']` becomes `'bob'`, assertion fails.
Run: `TEST_FILTER=test_end_focused_worker_clears_focus FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL — `end()` calls `get_registered_sessions()` which auto-picks `bob`, so `state['active']` is `'bob'`.

- [ ] **Step 3: Remove the auto-pick**

In `bridge.py`, delete lines `4840-4841`:

```python
        if registered and not state["active"]:
            state["active"] = list(registered.keys())[0]
```

Keep the stale-clear immediately above it (`4838-4839`) unchanged:

```python
        if state["active"] and state["active"] not in registered:
            state["active"] = None
```

- [ ] **Step 4: Wire startup restore + end() focus clear**

Replace the startup block at `bridge.py:11314-11319`:

```python
    # Load last active worker from file (if still exists)
    last_active = load_last_active()
    if last_active and last_active in registered:
        state["active"] = last_active
        print(f"Restored last active worker: {last_active}")
    elif last_active:
        print(f"Last active worker '{last_active}' no longer exists")
```

with:

```python
    # Restore focus only to a still-existing worker; otherwise leave it cleared.
    last_active = load_last_active()
    state["active"] = reconcile_startup_focus(last_active, registered)
    if state["active"]:
        print(f"Restored last active worker: {state['active']}")
    elif last_active:
        print(f"Last active worker '{last_active}' no longer exists; no focus set")
```

Replace `end()`'s focus block at `bridge.py:5163-5165`:

```python
        if state["active"] == name:
            state["active"] = None
            self.get_registered_sessions()
```

with:

```python
        if state["active"] == name:
            clear_focus()
```

- [ ] **Step 5: Run tests to verify they pass + full FAST suite**

Run the two filters from Step 2 → both PASS.
Then `FAST=1 TEST_BOT_TOKEN=dummy ./test.sh` → all pass.

- [ ] **Step 6: Commit**

```bash
git add bridge.py test.sh
git commit -m "fix: focus is never auto-picked; cleared on /end and restored only if worker still exists (B1)"
```

---

## Task 3: `/end` always clears session id + cwd (B2)

Move the `*_session_id` cleanup out of the non-interactive guard so re-hiring a name starts a fresh Claude conversation; also delete `claude_session_cwd`.

**Files:**
- Modify: `bridge.py:5138-5149` (the `if not backend.is_interactive:` block in `end()`).
- Test: `test.sh` — add `test_end_clears_session_id_for_interactive`, register in `run_unit_tests`.

- [ ] **Step 1: Write the failing test**

```bash
test_end_clears_session_id_for_interactive() {
    info "Testing /end clears session id + cwd for interactive workers..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.FILE_INBOX_ROOT = tmp / 'inbox'
bridge.WORKER_PIPE_ROOT = tmp / 'pipes'
bridge.worker_manager.sessions_dir = tmp
bridge.worker_manager.tmux_prefix = 'claude-test-'
bridge.worker_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'}
}

session_dir = tmp / 'alice'
session_dir.mkdir()
(session_dir / 'claude_session_id').write_text('old-session-123')
(session_dir / 'claude_session_cwd').write_text('/some/old/dir')

bridge.state['active'] = 'alice'
ok, err = bridge.worker_manager.end('alice')
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
```

Register with `run_test` in `run_unit_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_FILTER=test_end_clears_session_id_for_interactive FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL — for an interactive worker the cleanup is skipped, so `claude_session_id` still exists.

- [ ] **Step 3: Move the cleanup out of the guard**

In `bridge.py`, the current `end()` block (`5138-5149`):

```python
        # Clean non-interactive metadata (backend file, session IDs, pending)
        if not backend.is_interactive:
            kill_adapter(name)
            session_dir = self.sessions_dir / name
            backend_file = session_dir / "backend"
            try:
                if backend_file.exists():
                    backend_file.unlink()
                for session_id_file in session_dir.glob("*_session_id"):
                    session_id_file.unlink()
            except Exception as e:
                return False, f"Failed to clean non-interactive metadata: {e}"
```

becomes:

```python
        # Clear conversation state for ALL backends so re-hiring a name starts fresh.
        session_dir = self.sessions_dir / name
        try:
            for session_id_file in session_dir.glob("*_session_id"):
                session_id_file.unlink()
            cwd_file = session_dir / "claude_session_cwd"
            if cwd_file.exists():
                cwd_file.unlink()
        except Exception as e:
            return False, f"Failed to clean session state: {e}"

        # Clean non-interactive-only metadata (adapter + backend file).
        if not backend.is_interactive:
            kill_adapter(name)
            backend_file = session_dir / "backend"
            try:
                if backend_file.exists():
                    backend_file.unlink()
            except Exception as e:
                return False, f"Failed to clean non-interactive metadata: {e}"
```

- [ ] **Step 4: Run test to verify it passes + full FAST suite**

Run the filter from Step 2 → PASS. Then `FAST=1 TEST_BOT_TOKEN=dummy ./test.sh` → all pass (confirm `test_end_clears_pending` and `test_end_kills_adapter` still pass).

- [ ] **Step 5: Commit**

```bash
git add bridge.py test.sh
git commit -m "fix: /end clears session id + cwd for all backends so re-hire starts fresh (B2)"
```

---

## Task 4: Restart clears pending in every mode (B3)

Hoist `clear_pending(name)` so it runs for every local restart (live session, dead-worker recovery, resume, relaunch, clean), removing the false STUCK alert after an interactive restart.

**Files:**
- Modify: `bridge.py` — insert one line after `5191`; remove the redundant `clear_pending(name)` at `5223`.
- Test: `test.sh` — add `test_restart_clears_pending`, register in `run_unit_tests`.

- [ ] **Step 1: Write the failing test**

```bash
test_restart_clears_pending() {
    info "Testing restart clears pending for interactive worker..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.worker_manager.sessions_dir = tmp
bridge.worker_manager.tmux_prefix = 'claude-test-'
bridge.worker_manager.get_registered_sessions = lambda registered=None: {
    'alice': {'tmux': 'claude-test-alice', 'backend': 'claude'}
}
bridge.get_worker_host = lambda name: None
# Force the dead-worker path and stub it, so restart() returns right after the
# (hoisted) clear_pending without doing real tmux work.
bridge.tmux_exists = lambda *a, **k: False
bridge.worker_manager._restart_dead_worker = lambda *a, **k: (True, None)

bridge.set_pending('alice', 12345)
assert bridge.get_pending_file('alice').exists(), 'pending should exist before restart'

ok, err = bridge.worker_manager.restart('alice')
assert not bridge.get_pending_file('alice').exists(), 'pending must be cleared by restart'

print('OK')
" 2>/dev/null | grep -q "OK"; then
        success "restart clears pending"
    else
        fail "restart clears pending test failed"
    fi
}
```

Register with `run_test` in `run_unit_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_FILTER=test_restart_clears_pending FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL — `clear_pending` currently lives only in the non-interactive branch (and after the dead-worker return), so for this claude worker pending is never cleared.

- [ ] **Step 3: Hoist `clear_pending`**

In `bridge.py`, after line `5191` (`tmux_name = session.get("tmux", f"{self.tmux_prefix}{name}")`) and before the `if not tmux_exists(tmux_name):` check at `5193`, insert:

```python
        # A restart abandons any in-flight request, so always release pending
        # (covers live-session, dead-worker, resume, relaunch and clean modes).
        clear_pending(name)
```

Then remove the now-redundant `clear_pending(name)` inside the non-interactive branch at line `5223`:

```python
        if not backend.is_interactive:
            session_dir.mkdir(parents=True, exist_ok=True)
            ensure_worker_pipe(name)
            clear_pending(name)   # <-- delete this line
```

- [ ] **Step 4: Run test to verify it passes + full FAST suite**

Run the filter from Step 2 → PASS. Then `FAST=1 TEST_BOT_TOKEN=dummy ./test.sh` → all pass.

- [ ] **Step 5: Commit**

```bash
git add bridge.py test.sh
git commit -m "fix: restart clears pending in all modes; no false STUCK alert after interactive restart (B3)"
```

---

## Task 5: Hook response always releases pending (B4)

Extract a `deliver_hook_response()` helper that clears pending in a `finally`, so a failed Telegram send never leaves a worker stuck "pending".

**Files:**
- Modify: `bridge.py` — add `deliver_hook_response()` (near `send_response_to_telegram`, after line 5615 region or just before `handle_hook_response`); replace the send+clear at `10374-10379` with a call to it.
- Test: `test.sh` — add `test_hook_response_clears_pending_on_send_failure`, register in `run_unit_tests`.

- [ ] **Step 1: Write the failing test**

```bash
test_hook_response_clears_pending_on_send_failure() {
    info "Testing hook response clears pending even when Telegram send fails..."

    if python3 -c "
import tempfile
from pathlib import Path
import bridge

tmp = Path(tempfile.mkdtemp())
bridge.SESSIONS_DIR = tmp
bridge.worker_manager.sessions_dir = tmp

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
```

Register with `run_test` in `run_unit_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_FILTER=test_hook_response_clears_pending_on_send_failure FAST=1 TEST_BOT_TOKEN=dummy ./test.sh`
Expected: FAIL — `deliver_hook_response` does not exist yet (AttributeError → no "OK").

- [ ] **Step 3: Add the helper**

In `bridge.py`, add this module-level function just before `def handle_hook_response` (i.e., before line `10330`, outside the handler class — place it near `send_response_to_telegram`, which is module-level at line 5615; adding it directly above the class method is fine since it is module-scoped):

```python
def deliver_hook_response(session_name, text, chat_id, log_prefix="Response"):
    """Send a worker's response to Telegram and ALWAYS release the worker.

    pending + hook-event are cleared in `finally`, so a failed Telegram send
    never leaves the worker stuck 'pending' until the watchdog timeout.
    """
    try:
        send_response_to_telegram(session_name, text, int(chat_id), log_prefix=log_prefix)
    finally:
        clear_pending(session_name)
        mark_hook_event(session_name)
```

(Place it at module scope, e.g. immediately after `send_response_to_telegram`'s definition ends, around line 5660 — anywhere at module top level before it is called is correct. Do NOT indent it into a class.)

- [ ] **Step 4: Use it in `handle_hook_response`**

Replace `bridge.py:10374-10379`:

```python
            # Send response using shared helper
            send_response_to_telegram(session_name, text, int(chat_id), log_prefix="Response")

            # Clear pending
            clear_pending(session_name)
            mark_hook_event(session_name)
```

with:

```python
            # Send response and always release pending (even if the send raises).
            deliver_hook_response(session_name, text, int(chat_id), log_prefix="Response")
```

- [ ] **Step 5: Run test to verify it passes + full FAST suite**

Run the filter from Step 2 → PASS. Then `FAST=1 TEST_BOT_TOKEN=dummy ./test.sh` → all pass.

- [ ] **Step 6: Commit**

```bash
git add bridge.py test.sh
git commit -m "fix: hook response clears pending in finally so a failed send never hangs a worker (B4)"
```

---

## Final verification

- [ ] Run the default (integration) suite to confirm no regression beyond FAST:

```bash
TEST_BOT_TOKEN=dummy ./test.sh
```

Expected: all tests pass. (If `TEST_CHAT_ID` is available, the real-Telegram paths also exercise; not required for these changes.)

- [ ] Update `DOC.md` changelog with a short entry describing the four fixes (project convention in `CLAUDE.md`), and bump the patch version in `claudecode-telegram.sh` if you consider this a release. Commit.

## Spec coverage check

| Spec item | Task |
|-----------|------|
| B1 focus side-effect / startup restore / end clear | Task 2 (+ helpers in Task 1) |
| B2 stale session id on /end | Task 3 |
| B3 restart not clearing pending | Task 4 |
| B4 pending exception-safety | Task 5 |
| Focus interface (set_focus/clear_focus) | Task 1 |
| e2e test per fix | Each task, Step 1 |

## Notes / risks

- The stale-clear in `get_registered_sessions()` (`4838-4839`) is intentionally kept: it is the self-healing that makes focus go `None` when the focused worker dies, which then triggers the existing "No one assigned…" prompt in `route_to_active` (`bridge.py:8362-8369`). Only the auto-pick is removed.
- Hoisting `clear_pending` in `restart()` clears pending even if the restart later fails the binary check; acceptable because a restart abandons the current turn by definition.
- All tests are FAST-mode unit tests (inline `python3 -c`, no running bridge), matching the existing `test_end_clears_pending` style. They must be registered in `run_unit_tests` to run under FAST.
