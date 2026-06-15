# tmux Session Lifecycle Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the endless `🔴 t146 stopped unexpectedly` alerts by fixing the bug that kills `claude` at launch (the trust-folder prompt is auto-answered with "2 = No, exit"), and harden the lifecycle so a dead/manually-deleted session self-heals or stops nagging instead of re-alerting forever.

**Architecture:** Single Python file (`bridge.py`). One Telegram forum topic = one tmux session running `claude`; a background `watchdog_loop` thread classifies each session and alerts an admin. Fixes are local edits to three launch paths, the `/cd` handler, and the watchdog transition/reap logic. No new dependencies, no DB (tmux IS persistence).

**Tech Stack:** Python 3.12 (uv-managed), tmux, bash `test.sh` harness with Python-heredoc unit tests (monkeypatch `bridge.*`), mock-Telegram e2e harness.

---

## Background — confirmed root cause (live evidence + Codex independent verify)

| ID | Problem | Evidence |
|----|---------|----------|
| **R0** | Trust-folder prompt auto-answer sends `"2"` = **"No, exit"** → `claude` exits at launch in any untrusted folder. | `bridge.py:4153` (open_session) & `bridge.py:4344` (`_restart_dead_worker`) send `"2"`+Enter. Live `claude-dev-t146` pane shows the prompt then a bare bash shell (claude gone, pane alive). |
| **R0b** | The in-pane relaunch path in `restart()` has **no** trust handling at all — it `send_pane_start_cmd` then sends the welcome text straight into the prompt. | `bridge.py:4278-4290` (else branch, tmux alive) — no trust answer. |
| **R0c** | The matcher strings (`"do you trust"`, `"trust the files"`) were written for an older prompt; the current "Quick safety check…" wording only matches via `"trust this folder"` in option 1's label — fragile, can silently miss and leave claude hung. | `bridge.py:4152`. |
| **R1** | Watchdog is purely observational: a DEAD session (pane alive, claude gone) re-alerts on **every** 4 s probe, throttled only by `ALERT_COOLDOWN=180`, forever; never auto-restarts/removes. | `bridge.py:3145-3146`, `:3017`; bridge.log shows t146 DEAD re-alert loop. |
| **R2** | Manually deleting the tmux session (no `/close`) → state EXITED, re-alerts every 180 s forever, never removed from `workers.json`. | registry-only branch `bridge.py:3223`; `tmux` key is read-time-synthetic (`:4011`), never persisted (`_registry_add :678-684`). |
| **R3** | `/cd` ignores `restart()`'s `(ok, err)` return and always replies "已切換並重啟" even on failure. | `bridge.py:5457-5458`; failure returns at `:4208/:4226/:4301/:4310`. |
| **R4** *(optional)* | Watchdog alert goes to `admin_chat_id` with **no** `message_thread_id`, so it lands in the admin DM/General, not topic t146. | `bridge.py:3053-3054`. |

**Existing reusable parser:** `_extract_question_details(lines)` (`bridge.py:3818-3889`) extracts `{num,label,selected}` options and passes its `has_interactive` gate on the trust prompt because the footer `"Enter to confirm"` is in `_INTERACTIVE_FOOTERS` (`bridge.py:3790`). `_send_interactive_reply(tmux_name, "<digit>", details)` (`bridge.py:3892-3932`) navigates the TUI selection (Up/Down) to the target option and presses Enter — it never types the bare digit. Phase 1 reuses both.

**Entrenched wrong test:** `test_topic_hire_skips_trust_2_without_prompt` (`test.sh:1535`, registered `test.sh:12533`) asserts `'2' in sk` for a real trust dialog — it codifies the bug and MUST be rewritten in Phase 1.

---

## Design Decisions (review before implementing)

1. **Trust accept = navigate to the affirmative option, never type a digit.** Reuse `_extract_question_details` + `_send_interactive_reply`. Choose the option whose label contains a trust/yes keyword and is NOT a negative ("no"/"exit"). If the prompt is detected but options can't be parsed or no affirmative option is found, **do not guess** — log and leave it for the user. *Alternative rejected:* hardcode `"1"+Enter` — breaks if claude reorders options or changes confirm semantics (Codex flagged this).
2. **Apply the helper to all three launch paths** (open_session, in-pane restart, dead-worker restart) so `/cd` recovery of a trust-prompt death also works.
3. **DEAD (pane alive) → bounded re-alert, not auto-restart.** Cap re-alerts at `MAX_DEAD_REALERTS` then go silent until recovery/close. *Auto-restart from the watchdog thread is rejected for the core plan* (it would block the loop ~3.5 s per restart and risks loops); listed as optional Phase 6.
4. **EXITED (tmux gone, registry-only) → auto-reap.** After `REAP_EXITED_AFTER` seconds of continuous EXITED, remove the entry from `workers.json`. Principled under "tmux IS persistence": no tmux ⇒ no session; the topic still exists, so the next message recreates it. Directly fixes the manual-delete concern (R2).
5. **`/cd` honest reply (R3).** Check `(ok, err)`; on failure reply with the error and tell the user to retry, instead of a false success.
6. **R4 (alert into the topic) is optional (Phase 5).** Lower priority; the core fixes remove the nag entirely.
7. **Version:** 1.4.0 → **1.5.0** (minor: critical fix + new self-heal/reap behavior).
8. **(Codex review) `_send_watchdog_alert` must return whether it actually sent.** It has its own `ALERT_COOLDOWN=180` early-return (`:3017`). The bounded-alert counter MUST only increment on a real send (return `True`), else cooldown-suppressed non-sends silently consume the budget and the session goes quiet after ~8 s having alerted only once. So Phase 3 changes `_send_watchdog_alert` to return `bool` and increments `_bad_state_alert_count` only on `True`.
9. **(Codex review) Trust accept must poll for a late-rendering prompt**, not sample once. `send_pane_start_cmd` returns when the sentinel is touched *before* `exec` (`:4572`), not when Claude's TUI is up; a single `sleep(1.5)`+capture can miss a slow prompt and then the welcome text gets typed into it. `_accept_trust_prompt` polls up to ~4 s (8 × 0.5 s), returning as soon as the prompt is found (fast for the death case) or after the window (small penalty on already-trusted folders).
10. **(Codex review) Extract `_run_watchdog_once(now)`** from `watchdog_loop`'s body so the registry-only/reap and bounded-alert branches are unit-testable (the loop is otherwise an untestable `while True`). Mechanical move; `watchdog_loop` becomes a thin wrapper. This also closes the long-standing "watchdog is hard to test" gap (CLAUDE.md).
11. **(Codex review) Sandbox launch paths are OUT OF SCOPE** for 1.5.0. `SANDBOX_ENABLED` paths (`:4140-4145`, `:4271-4277`, `:4336-4340`) run Claude inside Docker and are used only by the sandbox node; dev/prod run `--no-sandbox` (CLAUDE.md). Trust handling there is a documented follow-up, not part of this release.

---

## File Structure

| File | Change |
|------|--------|
| `bridge.py` | Add `_accept_trust_prompt()` helper near `_send_interactive_reply` (~after :3932). Edit launch paths (:4150-4155, :4278-4290, :4341-4346). Edit `/cd` handler (:5454-5458). Add bounded-realert + reap logic in `_handle_watchdog_transition` (:3137-3164) and the registry-only branch (:3222-3226); add module dicts near :510 and constants near :166. Bump `VERSION` (:4). |
| `claudecode-telegram.sh` | Bump `VERSION` (:12). |
| `pyproject.toml` | Bump `version` (:3). |
| `test.sh` | Rewrite `test_topic_hire_skips_trust_2_without_prompt` → `test_topic_hire_accepts_trust_prompt` (:1535) + update registration (:12533). Add new unit tests. |
| `DOC.md` | Changelog entry for 1.5.0. |

**Branch:** create `fix/v1.5.0-tmux-lifecycle` before starting (do not work on `main`).

---

## Phase 1 — Robust trust-prompt accept (fixes R0/R0b/R0c) — MUST

### Task 1: Add the `_accept_trust_prompt` helper

**Files:**
- Modify: `bridge.py` (insert after `_send_interactive_reply`, ~line 3932)
- Test: `test.sh` (new `test_accept_trust_prompt_picks_yes`)

- [ ] **Step 1: Write the failing test** — add this function in `test.sh` immediately before `test_topic_hire_skips_trust_2_without_prompt` (line 1535):

```bash
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
assert 'Down' not in sk and 'Up' not in sk, ('Yes already selected, no nav:', sk)

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
```

- [ ] **Step 2: Register the test** — add this line in `test.sh` immediately before the `run_test test_topic_hire_skips_trust_2_without_prompt` line (1535's registration at 12533):

```bash
run_test test_accept_trust_prompt_picks_yes
```

- [ ] **Step 3: Run it to confirm it FAILS** (helper not defined yet):

```bash
TEST_FILTER=test_accept_trust_prompt_picks_yes FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: FAIL (`_accept_trust_prompt` has no attribute / AttributeError).

- [ ] **Step 4: Implement the helper** — insert in `bridge.py` after `_send_interactive_reply` (after line 3932):

```python
# Folder-trust prompt: substrings that identify Claude's "do you trust this
# folder?" dialog across versions (current wording is "Quick safety check…").
_TRUST_PROMPT_MARKERS = (
    "do you trust",
    "trust the files",
    "trust this folder",
    "trust the authors",
    "is this a project you created or one you trust",
)
_TRUST_NEGATIVE_KEYWORDS = ("no, exit", "no,", "do not trust", "don't trust", "exit")
_TRUST_AFFIRMATIVE_KEYWORDS = ("trust", "yes")


def _accept_trust_prompt(tmux_name: str) -> str:
    """If Claude is showing a folder-trust prompt, accept it robustly.

    Reuses the interactive-prompt parser to find the affirmative ("trust"/"yes")
    option, navigates the TUI selection to it (Up/Down) and confirms with Enter.
    Never blindly types a digit: the old code sent "2", which is "No, exit" on
    the current Claude TUI and silently killed the session at launch.

    Returns "accepted", "no-prompt", or "unparsed" (logged, left for the user).

    Polls up to ~4s (the TUI may render the prompt after send_pane_start_cmd
    returns — its sentinel fires before `exec`, not when Claude is up), returning
    as soon as the prompt is found.
    """
    pane = ""
    for _ in range(8):  # ~4s at 0.5s/poll; break as soon as the prompt shows
        pane = _capture_pane_text(tmux_name, lines=30)
        if pane and any(m in pane.lower() for m in _TRUST_PROMPT_MARKERS):
            break
        time.sleep(0.5)
    else:
        return "no-prompt"

    details = _extract_question_details(pane.splitlines())
    if not details or not details.get("options"):
        print(f"[trust] {tmux_name}: trust prompt detected but options unparsed; leaving for user")
        return "unparsed"

    target = None
    for o in details["options"]:
        label = o["label"].lower()
        if any(k in label for k in _TRUST_NEGATIVE_KEYWORDS):
            continue
        if any(k in label for k in _TRUST_AFFIRMATIVE_KEYWORDS):
            target = o
            break
    if target is None:
        labels = [o["label"] for o in details["options"]]
        print(f"[trust] {tmux_name}: no affirmative trust option in {labels}; leaving for user")
        return "unparsed"

    _send_interactive_reply(tmux_name, str(target["num"]), details)
    return "accepted"
```

- [ ] **Step 5: Run the test to confirm it PASSES:**

```bash
TEST_FILTER=test_accept_trust_prompt_picks_yes FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS — "✓ _accept_trust_prompt picks Yes/trust, never No,exit".

- [ ] **Step 6: Commit:**

```bash
git add bridge.py test.sh
git commit -m "feat(trust): add _accept_trust_prompt that navigates to Yes, never sends No,exit"
```

### Task 2: Wire the helper into all three launch paths + fix the entrenched test

**Files:**
- Modify: `bridge.py:4150-4155`, `bridge.py` in-pane restart (~4285), `bridge.py:4341-4346`
- Modify: `test.sh:1535-1585` (rewrite) + `test.sh:12533` (registration rename)

- [ ] **Step 1: Rewrite the entrenched test** — replace the whole `test_topic_hire_skips_trust_2_without_prompt()` function (test.sh:1535-1585) with:

```bash
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
```

- [ ] **Step 2: Update the registration** — at `test.sh:12533` change:

```bash
run_test test_topic_hire_skips_trust_2_without_prompt
```
to:
```bash
run_test test_topic_hire_accepts_trust_prompt
```

- [ ] **Step 3: Run it to confirm it FAILS** (open_session still sends "2"):

```bash
TEST_FILTER=test_topic_hire_accepts_trust_prompt FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: FAIL (`must never answer trust with a bare 2`).

- [ ] **Step 4: Patch open_session** — in `bridge.py`, replace lines 4150-4155:

```python
            # Answer Claude's "Do you trust the files in this folder?" dialog,
            # but only if it actually appears.
            time.sleep(1.5)
            pane = _capture_pane_text(tmux_name, lines=20).lower()
            if any(m in pane for m in ("do you trust", "trust the files", "trust this folder")):
                subprocess.run(["tmux", "send-keys", "-t", tmux_name, "2"])
                time.sleep(0.3)
                subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Enter"])
```
with:
```python
            # Accept Claude's folder-trust dialog if it appears (navigate to the
            # "Yes, I trust" option — never blind-send a digit; "2" is "No, exit").
            # The helper polls for a late-rendering prompt itself.
            _accept_trust_prompt(tmux_name)
```

- [ ] **Step 5: Patch the in-pane restart path** — in `bridge.py`, after the in-pane launch at line 4285 (`send_pane_start_cmd(tmux_name, backend.start_cmd(resume_id), startup_cwd)`), add the trust accept BEFORE the welcome block (4287):

```python
            wait_for_pane_shell_ready(tmux_name)
            send_pane_start_cmd(tmux_name, backend.start_cmd(resume_id), startup_cwd)
            # A relaunch in the existing pane re-triggers the folder-trust dialog
            # whenever the cwd is untrusted; accept it before sending welcome.
            # The helper polls for a late-rendering prompt itself.
            _accept_trust_prompt(tmux_name)
```

- [ ] **Step 6: Patch `_restart_dead_worker`** — in `bridge.py`, replace lines 4342-4346:

```python
            send_pane_start_cmd(tmux_name, backend.start_cmd(resume_id), startup_cwd)
            time.sleep(1.5)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "2"])
            time.sleep(0.3)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Enter"])
```
with:
```python
            send_pane_start_cmd(tmux_name, backend.start_cmd(resume_id), startup_cwd)
            # The helper polls for a late-rendering prompt itself.
            _accept_trust_prompt(tmux_name)
```

- [ ] **Step 7: Run the test to confirm PASS:**

```bash
TEST_FILTER=test_topic_hire_accepts_trust_prompt FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS.

- [ ] **Step 8: Run the full FAST suite to catch regressions** (other tests may have referenced the old name):

```bash
FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh 2>&1 | tail -20
```
Expected: no `command not found` for the renamed test; suite green except known-environmental `test_send_to_session_integration` (per CLAUDE.md).

- [ ] **Step 9: Commit:**

```bash
git add bridge.py test.sh
git commit -m "fix(trust): accept folder-trust in all 3 launch paths; stop sending No,exit (fixes stopped-unexpectedly)"
```

### Task 2c: Prove the restart paths also accept the trust prompt (Codex req #2)

The `_accept_trust_prompt` unit test (Task 1) proves the helper; this proves the two restart paths *call* it (open_session is covered by Task 2's rewritten test).

**Files:** Test only — `test.sh` (new `test_restart_paths_accept_trust`), registered next to the others.

- [ ] **Step 1: Write the test** (run AFTER Task 2's wiring, so it should already pass — it guards against future regression of the wiring):

```bash
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
```

- [ ] **Step 2: Register** `run_test test_restart_paths_accept_trust` beside the Phase 1 registrations.

- [ ] **Step 3: Run (expect PASS, since Task 2 wired both paths):**

```bash
TEST_FILTER=test_restart_paths_accept_trust FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS. (Sensitivity check: temporarily revert one wiring edit → this test goes red.)

- [ ] **Step 4: Commit:**

```bash
git add test.sh
git commit -m "test(trust): cover restart() + _restart_dead_worker trust-accept wiring"
```

---

## Phase 2 — `/cd` honest success/failure (fixes R3) — MUST

### Task 3: `/cd` checks restart() result

**Files:**
- Modify: `bridge.py:5454-5458`
- Test: `test.sh` (new `test_cd_reports_restart_failure`)

This is a REAL red-green test: it drives `command_router.handle_message` (the same entry the sample `test_topic_close_and_cd` at `test.sh:1175` uses), forces `restart()` to fail, and asserts the captured reply. It MUST fail against the current handler (which ignores the return and always replies success) and pass after the fix. (Per Codex review: a nonexistent path can't test this — it returns at `bridge.py:5451-5453` before `restart()`; so the test uses a VALID dir under `TOPIC_ROOT`.)

- [ ] **Step 1: Write the failing test** — add in `test.sh` immediately after `test_topic_close_and_cd` (ends ~line 1204), and register with `run_test test_cd_reports_restart_failure` next to Phase 1's registrations:

```bash
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
```

- [ ] **Step 2: Run it to confirm FAIL** (current handler replies success regardless):

```bash
TEST_FILTER=test_cd_reports_restart_failure FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: FAIL (`must surface restart failure` — reply was the success string).

- [ ] **Step 3: Patch the `/cd` handler** — in `bridge.py`, replace lines 5454-5458:

```python
                name = find_topic_session(chat_id, thread_id, registered)
                if name:
                    _set_worker_cwd(name, clamped)
                    self.workers.restart(name)
                    self.reply(chat_id, f"已切換資料夾並重啟：{clamped}")
```
with:
```python
                name = find_topic_session(chat_id, thread_id, registered)
                if name:
                    _set_worker_cwd(name, clamped)
                    ok, err = self.workers.restart(name)
                    if ok:
                        self.reply(chat_id, f"已切換資料夾並重啟：{clamped}")
                    else:
                        self.reply(chat_id, f"切換資料夾後重啟失敗：{err}\n請再試一次 /cd {clamped}，或 /close 後重開話題。")
```

- [ ] **Step 4: Run the guard test (PASS):**

```bash
TEST_FILTER=test_cd_reports_restart_failure FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS.

- [ ] **Step 5 (OPTIONAL mock e2e):** in `tests/mock_tests.sh`, drive `/cd <a-valid-dir-under-TOPIC_ROOT>` against a bridge whose backend binary is forced missing (so `restart()` returns `(False, "'claude' not found…")`), and assert the recorded `sendMessage` text contains `切換資料夾後重啟失敗`. Do NOT use a nonexistent path — it returns at `bridge.py:5451-5453` before `restart()`. Follow the existing `run_mock_tests` pattern (`TELEGRAM_API_BASE` seam, assert `/_recorded`). The Step 1 unit test is the primary guard; this is supplementary.

- [ ] **Step 6: Commit:**

```bash
git add bridge.py test.sh
git commit -m "fix(cd): surface restart() failure instead of false success reply"
```

---

## Phase 3 — Bounded DEAD re-alert (fixes R1 nagging) — core

### Task 4: Cap DEAD/OFFLINE/EXITED re-alerts then go silent

**Files:**
- Modify: `bridge.py` constants (~line 166), module dicts (~line 510), `_handle_watchdog_transition` (3137-3164)
- Test: `test.sh` (new `test_dead_realert_is_bounded`)

- [ ] **Step 1: Write the failing test** — add to `test.sh` and register:

```bash
test_dead_realert_is_bounded() {
    info "Testing a sustained DEAD session stops after exactly 1+MAX_DEAD_REALERTS REAL sends (real cooldown path)..."
    if python3 -c "
import bridge
# Fake clock so the REAL ALERT_COOLDOWN inside _send_watchdog_alert (time.time())
# is exercised deterministically — this catches the budget-vs-cooldown bug that a
# stubbed _send_watchdog_alert would hide (Codex review).
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
```

- [ ] **Step 2: Run it to confirm FAIL** (no `MAX_DEAD_REALERTS` / `_bad_state_alert_count` yet):

```bash
TEST_FILTER=test_dead_realert_is_bounded FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: FAIL (AttributeError: MAX_DEAD_REALERTS).

- [ ] **Step 3a: Add the constant** — in `bridge.py` after line 166 (`ALERT_COOLDOWN = 180`):

```python
MAX_DEAD_REALERTS = 1  # after the first alert, re-alert at most this many times for a
                       # sustained DEAD/OFFLINE/EXITED state, then go silent until it
                       # recovers or is closed (stops the every-180s nag)
```

- [ ] **Step 3b: Add the counter dict** — in `bridge.py` near the other watchdog dicts (~line 510, beside `_recent_restarts`):

```python
_bad_state_alert_count: dict[str, int] = {}  # name -> how many REAL alerts sent for the current bad-state streak
```

- [ ] **Step 3b2: Make `_send_watchdog_alert` return whether it actually sent** (Codex req #3 — so cooldown-suppressed non-sends don't consume the budget). In `bridge.py`, make these four edits inside `_send_watchdog_alert` (3010-3065):
  - Line 3011-3012: `if admin_chat_id is None:` / `        return` → `        return False`
  - Line 3017-3019 cooldown guard: change the trailing `        return` (3019) → `        return False`
  - In the success block (after `_alert_msg_ids[name] = (msg_id, text)`, ~3061) add a new line `            return True`
  - In the `else:` print branch (~3063) add `            return False`, and in the `except Exception` block (~3065) add `        return False`

  After these edits `_send_watchdog_alert` returns `True` only when a Telegram message was actually sent, `False` on no-admin / cooldown-suppressed / API-failure / exception.

- [ ] **Step 3c: Bound the re-alert branch (increment only on a REAL send)** — in `_handle_watchdog_transition` (`bridge.py:3137-3149`), replace:

```python
    if state in bad_states:
        with _watchdog_lock:
            _consecutive_good_probes[name] = 0

        if state_changed or prev_state is None:
            if eligible_for_alert():
                print(f"[watchdog] State change {name}: {prev_state} -> {state} ({reason}), sending alert")
                _send_watchdog_alert(name, state, reason)
        elif state in {"OFFLINE", "DEAD", "EXITED"} and eligible_for_alert():
            _send_watchdog_alert(name, state, reason)
        with _watchdog_lock:
            _prev_session_states[name] = state
        return
```
with:
```python
    if state in bad_states:
        with _watchdog_lock:
            _consecutive_good_probes[name] = 0

        if state_changed or prev_state is None:
            if eligible_for_alert():
                print(f"[watchdog] State change {name}: {prev_state} -> {state} ({reason}), sending alert")
                if _send_watchdog_alert(name, state, reason):
                    with _watchdog_lock:
                        _bad_state_alert_count[name] = 1
        elif state in {"OFFLINE", "DEAD", "EXITED"} and eligible_for_alert():
            with _watchdog_lock:
                count = _bad_state_alert_count.get(name, 0)
            if count <= MAX_DEAD_REALERTS:
                if _send_watchdog_alert(name, state, reason):
                    with _watchdog_lock:
                        _bad_state_alert_count[name] = count + 1
            # else: budget spent — stay silent until recovery (good state) or close
        with _watchdog_lock:
            _prev_session_states[name] = state
        return
```

- [ ] **Step 3d: Reset the counter on recovery** — in the good-state branch of `_handle_watchdog_transition` (`bridge.py:3151-3160`), inside the `if good_count >= GOOD_PROBE_THRESHOLD:` block where `_prev_session_states[name] = state` is set, also clear the counter:

```python
            with _watchdog_lock:
                _consecutive_good_probes[name] = 0
                _prev_session_states[name] = state
                _bad_state_alert_count.pop(name, None)
```

- [ ] **Step 3e: GC the counter** — in the watchdog cleanup block, the per-name `pop` loops live INSIDE a `with _watchdog_lock:` block whose LAST loop is `_last_activity_ts`; the subsequent `for name in list(_consecutive_probe_failures.keys()):` loop is OUTSIDE the lock (Codex Area 1). Insert this immediately AFTER the `_last_activity_ts` loop and BEFORE the un-indented `_consecutive_probe_failures` loop (so it stays under the lock):

```python
                for name in list(_bad_state_alert_count.keys()):
                    if name not in registered_names:
                        _bad_state_alert_count.pop(name, None)
```

- [ ] **Step 4: Run the test to confirm PASS:**

```bash
TEST_FILTER=test_dead_realert_is_bounded FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS — "DEAD re-alert is bounded".

- [ ] **Step 4b: Add + run the recovery-reset test** (Codex req #5 — recovery must clear the budget so a later death alerts again). Add to `test.sh` and register:

```bash
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
bridge._send_resolved_alert = lambda *a, **k: None  # isolate: don't count the ✅ message
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
```
Run:
```bash
TEST_FILTER=test_dead_realert_resets_after_recovery FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS.

- [ ] **Step 5: Commit:**

```bash
git add bridge.py test.sh
git commit -m "fix(watchdog): bound DEAD/OFFLINE/EXITED re-alerts (stop the every-180s nag)"
```

---

## Phase 4 — Auto-reap EXITED registry-only sessions (fixes R2 manual-delete) — core

### Task 4b: Extract `_run_watchdog_once(now)` so the loop body is testable (Codex req #6 prep)

The reap branch lives inside `watchdog_loop`'s `while True:` — untestable as-is. Extract the per-tick body into a function so the integration test (Task 5 Step 6) can drive one tick deterministically.

**Files:** Modify `bridge.py` `watchdog_loop` (3179-3377).

- [ ] **Step 1: Refactor** — replace the head of the loop (bridge.py:3179-3183):

```python
def watchdog_loop():
    while True:
        try:
            now = time.time()
            registered = get_registered_sessions()
```
with:
```python
def watchdog_loop():
    while True:
        try:
            _run_watchdog_once(time.time())
        except Exception as e:
            print(f"Watchdog error: {e}")
        time.sleep(WATCHDOG_INTERVAL)


def _run_watchdog_once(now):
    registered = get_registered_sessions()
```
Then at the END of the former body, DELETE the original trailing `        except Exception as e:` / `            print(f"Watchdog error: {e}")` / `        time.sleep(WATCHDOG_INTERVAL)` (bridge.py:3374-3377), and **dedent the entire former body** (old lines 3184-3373) by 8 spaces — from the old `try:`-block depth to module-function-body depth. The body already uses the local `now`, so nothing else changes. Use an editor block-dedent; the syntax/suite check below is the safety net for indentation errors.

- [ ] **Step 2: Verify the refactor is mechanical-only:**

```bash
uv run python -c "import bridge; assert callable(bridge._run_watchdog_once); print('import OK')"
FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh 2>&1 | tail -15
```
Expected: `import OK`; FAST suite green except the known-environmental `test_send_to_session_integration`.

- [ ] **Step 3: Commit:**

```bash
git add bridge.py
git commit -m "refactor(watchdog): extract _run_watchdog_once(now) for testability"
```

### Task 5: Remove a registry-only session from workers.json after sustained EXITED

**Files:**
- Modify: `bridge.py` constant (~166), module dict (~510), registry-only branch (3222-3226), GC block (3340-3373)
- Test: `test.sh` (new `test_exited_session_is_reaped`)

- [ ] **Step 1: Write the failing test** — add to `test.sh` and register:

```bash
test_exited_session_is_reaped() {
    info "Testing a registry-only EXITED session is auto-removed from the registry after the reap window..."
    if python3 -c "
import bridge, time
removed = []
bridge._registry_remove = lambda name: removed.append(name)
bridge._exited_since.clear()
now = time.time()
# First observation: record the time, do NOT reap yet.
bridge._maybe_reap_exited('tZ', now)
assert removed == [], ('must not reap immediately:', removed)
# Long after the window: reap.
bridge._maybe_reap_exited('tZ', now + bridge.REAP_EXITED_AFTER + 1)
assert removed == ['tZ'], ('must reap after window:', removed)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "EXITED registry-only session is reaped after the window"
    else
        fail "EXITED reap test failed"
    fi
}
```

- [ ] **Step 2: Run it to confirm FAIL** (`_maybe_reap_exited`/`REAP_EXITED_AFTER`/`_exited_since` undefined):

```bash
TEST_FILTER=test_exited_session_is_reaped FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: FAIL.

- [ ] **Step 3a: Add constant + dict** — in `bridge.py` after `MAX_DEAD_REALERTS` (~166) and near the watchdog dicts (~510):

```python
REAP_EXITED_AFTER = 600  # seconds: a registry-only session (tmux gone) EXITED this long
                         # is removed from workers.json (manual kill / crashed pane self-cleans)
```
```python
_exited_since: dict[str, float] = {}  # name -> first time observed EXITED & registry-only
```

- [ ] **Step 3b: Add the reaper helper** — in `bridge.py` near `_record_worker_state` (~line 3176):

```python
def _maybe_reap_exited(name: str, now: float) -> bool:
    """Remove a registry-only EXITED session from the persistent registry once it
    has been gone for REAP_EXITED_AFTER seconds. Returns True if reaped.

    The Telegram topic still exists, so the next message there recreates the
    session; this only stops an orphaned tmux-less entry from nagging forever.
    """
    with _watchdog_lock:
        first = _exited_since.get(name)
        if first is None:
            _exited_since[name] = now
            return False
        age = now - first
    if age < REAP_EXITED_AFTER:
        return False
    print(f"[watchdog] reaping registry-only EXITED session {name} (gone {int(age)}s)")
    _registry_remove(name)
    with _watchdog_lock:
        _exited_since.pop(name, None)
    return True
```

- [ ] **Step 3c: Call it from the registry-only branch** — in `watchdog_loop` (`bridge.py:3222-3226`), replace:

```python
                # Registry-only worker (tmux gone): mark EXITED directly
                if not tmux_exists and "tmux" not in session:
                    since = _record_worker_state(name, "EXITED", "session gone", now)
                    _handle_watchdog_transition(name, "EXITED", "session gone", since, now=now)
                    continue
```
with:
```python
                # Registry-only worker (tmux gone): mark EXITED, then reap after a window.
                if not tmux_exists and "tmux" not in session:
                    since = _record_worker_state(name, "EXITED", "session gone", now)
                    _handle_watchdog_transition(name, "EXITED", "session gone", since, now=now)
                    _maybe_reap_exited(name, now)
                    continue
```

- [ ] **Step 3d: Clear `_exited_since` when a session is alive again or deregistered** — in the same locked cleanup block as Step 3e, insert AFTER the `_bad_state_alert_count` loop and BEFORE the un-indented `_consecutive_probe_failures` loop:

```python
                for name in list(_exited_since.keys()):
                    if name not in registered_names:
                        _exited_since.pop(name, None)
```
and in the first per-session loop, right after the line `tmux_present[name] = tmux_exists` (where a live tmux is detected), clear any stale reap timer:

```python
                if tmux_exists:
                    with _watchdog_lock:
                        _exited_since.pop(name, None)
```

- [ ] **Step 4: Run the test to confirm PASS:**

```bash
TEST_FILTER=test_exited_session_is_reaped FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS.

- [ ] **Step 4b: Add the watchdog-tick integration test** (Codex req #6 — prove the registry-only branch actually calls the reaper, not just the helper in isolation). Requires Task 4b's `_run_watchdog_once`. Add to `test.sh` and register:

```bash
test_watchdog_reaps_exited_via_loop() {
    info "Testing one watchdog tick reaps a registry-only EXITED session after the window..."
    if python3 -c "
import bridge
reaped = []
bridge._registry_remove = lambda name: reaped.append(name)
bridge.admin_chat_id = None  # silence alerts
clock = [5000.0]
bridge.time.time = lambda: clock[0]
bridge.time.sleep = lambda *a, **k: None
# Registry-only session: in registry, no live tmux pane.
bridge.get_registered_sessions = lambda: {'tG': {'backend': 'claude'}}
bridge.session_manager.get_registered_sessions = lambda registered=None: {'tG': {'backend': 'claude'}}
bridge._tmux_pane_pids = lambda: {}      # tmux gone -> registry-only branch fires
for d in (bridge._exited_since, bridge._session_states, bridge._prev_session_states,
          bridge._consecutive_probe_failures):
    d.clear()
# First tick: records _exited_since, does NOT reap.
bridge._run_watchdog_once(clock[0])
assert reaped == [], ('must not reap on first sighting:', reaped)
assert 'tG' in bridge._exited_since, ('must record exited_since:', bridge._exited_since)
# Tick after the window: reaps.
clock[0] += bridge.REAP_EXITED_AFTER + 1
bridge._run_watchdog_once(clock[0])
assert reaped == ['tG'], ('must reap after the window:', reaped)
print('OK')
" 2>/dev/null | grep -q OK; then
        success "watchdog tick reaps registry-only EXITED after the window"
    else
        fail "watchdog reap-integration test failed"
    fi
}
```
Run:
```bash
TEST_FILTER=test_watchdog_reaps_exited_via_loop FAST=1 TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh
```
Expected: PASS.

- [ ] **Step 5: Commit:**

```bash
git add bridge.py test.sh
git commit -m "feat(watchdog): auto-reap registry-only EXITED sessions (manual tmux kill self-cleans)"
```

---

## Phase 5 — (OPTIONAL) deliver the alert into the topic (R4)

Only if the user wants the alert in-topic. `_send_watchdog_alert` would look up the session's `(chat_id, message_thread_id)` via `load_topic_meta(name)` and pass `message_thread_id` to `transport.send_text`, falling back to `admin_chat_id` (no thread) when meta is missing. Add `test_watchdog_alert_targets_topic` asserting the recorded `sendMessage` carries `message_thread_id`. Defer unless requested — the core fixes already remove the nag.

---

## Phase 6 — (OPTIONAL, future) one-shot auto-restart on DEAD

Watchdog attempts a single `session_manager.restart(name)` on first DEAD (guarded by a cooldown + max attempts, run off-thread to avoid blocking the loop). Risky (restart loops, concurrency); deferred. Now that Phase 1 fixes R0, `/cd` recovery already works and Phase 3 stops the nag, so this is a convenience, not a necessity.

---

## Version bump + docs + release gate

### Task 6: Bump to 1.5.0 and document

- [ ] **Step 1: Bump all three version strings:**
  - `claudecode-telegram.sh:12` → `VERSION="1.5.0"`
  - `pyproject.toml:3` → `version = "1.5.0"`
  - `bridge.py:4` → `VERSION = "1.5.0"`

- [ ] **Step 2: Run the release gate:**

```bash
.claude/skills/bridge-ops/scripts/check-versions.sh
```
Expected: exit 0 (all three in sync).

- [ ] **Step 3: Add a `DOC.md` changelog entry for 1.5.0** describing: the trust-prompt `2→Yes` fix (root cause of "stopped unexpectedly"), trust handling added to the in-pane restart path, `/cd` honest failure reply, bounded DEAD re-alerts, and EXITED auto-reap.

- [ ] **Step 4: Run the full default suite before commit:**

```bash
TEST_BOT_TOKEN="$(grep TELEGRAM_BOT_TOKEN ~/.config/claudecode-telegram/test.env | cut -d= -f2)" TEST_CHAT_ID="$(grep TEST_CHAT_ID ~/.config/claudecode-telegram/test.env | cut -d= -f2)" ./test.sh 2>&1 | tail -25
```
Expected: green except the known-environmental `test_send_to_session_integration` (CLAUDE.md). If anything else is red, use the `test-triage` skill before blaming this change.

- [ ] **Step 5: Commit:**

```bash
git add claudecode-telegram.sh pyproject.toml bridge.py DOC.md
git commit -m "release: v1.5.0 — trust-prompt fix + bounded alerts + EXITED reap"
```

### Task 7: Deploy + verify on the dev node, then live-confirm t146

- [ ] **Step 1: Restart the dev node via the skill (never hand-typed):**

```bash
.claude/skills/bridge-ops/scripts/restart-node.sh dev
.claude/skills/bridge-ops/scripts/verify-node.sh dev
```

- [ ] **Step 2: Live-confirm the t146 fix** — `/cd /home/audichuang` in topic t146; expect claude to relaunch, auto-accept the trust prompt, and reply; bridge.log should show the DEAD alerts stop (and a ✅ resolved). Confirm with:

```bash
tmux capture-pane -t claude-dev-t146 -p -S -10
pgrep -P "$(tmux list-panes -t claude-dev-t146 -F '#{pane_pid}' | head -1)" -f claude
```
Expected: a live `claude` child under the t146 pane; no new "stopped unexpectedly" in `~/.claude/telegram/nodes/dev/bridge.log`.

---

## Self-Review

- **Spec coverage:** R0 (Task 1 + Task 2 + Task 2c), R0b/R0c (Task 1 helper polling + markers), R1 (Task 4), R2 (Task 4b + Task 5), R3 (Task 3), R4 (Phase 5 optional). ✅
- **Placeholder scan:** All code/tests are concrete; the only deferred items are explicitly-marked optional Phases 5/6 and the mock-harness e2e (Task 3 Step 5, supplementary to the Step 1 unit test).
- **Type/name consistency:** `_accept_trust_prompt` (Task 1) used identically in Tasks 2/2c; `_run_watchdog_once` (Task 4b) consumed by Task 5 Step 4b; `MAX_DEAD_REALERTS`/`_bad_state_alert_count` (Task 4) and `REAP_EXITED_AFTER`/`_exited_since`/`_maybe_reap_exited` (Task 5) defined before use; test names match their `run_test` registrations.

### Codex review (round 1) — resolutions (NO-GO → addressed)

1. **Real `/cd` red-green test** → Task 3 rewritten to drive `command_router.handle_message` with a VALID path + forced `restart()` failure (a nonexistent path returns before `restart()`, so it can't test this).
2. **Trust tests for the other two launch paths** → Task 2c (in-pane `restart()` + `_restart_dead_worker`).
3. **`_send_watchdog_alert` returns sent/not-sent; budget increments only on a real send** → Task 4 Step 3b2 + 3c.
4. **Bounded test uses the real cooldown** → Task 4 Step 1 rewritten with a fake clock; asserts exactly `1 + MAX_DEAD_REALERTS` real sends.
5. **Recovery clears budget; later death re-alerts** → Task 4 Step 4b.
6. **Prove the watchdog tick calls the reaper** → Task 4b extracts `_run_watchdog_once`; Task 5 Step 4b drives one tick.
7. **Mock `/cd` scenario** → fixed to valid path + failing backend; marked supplementary.
8. **Sandbox launch paths** → declared OUT OF SCOPE (Design Decision 11); documented follow-up.
- Also: trust accept now POLLS for a late-rendering prompt (Design Decision 9 / Task 1 helper); GC inserts pinned inside the `_watchdog_lock` block (Design Decision + Tasks 4/5 GC steps); lock ordering confirmed deadlock-free by Codex (release lock before `_registry_remove`).

## Risks

- **Claude TUI variance:** `_accept_trust_prompt` relies on `_extract_question_details` parsing options. If a future claude renders the prompt without a recognized footer/options, the helper returns `"unparsed"` and logs — claude waits at the prompt (alive, not killed). Safer than the old silent "No, exit". Mitigation: the marker list covers current + legacy wording; add to `_INTERACTIVE_FOOTERS`/markers if claude changes again.
- **Reap surprise (Phase 4):** auto-removing a registry entry after 10 min is a behavior change; the topic still recreates on next message. `REAP_EXITED_AFTER=600` is conservative; tune if needed.
- **Concurrency:** all new dict access is under `_watchdog_lock`; `_registry_remove` already locks internally.
