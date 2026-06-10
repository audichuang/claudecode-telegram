# Spec: Core Bridge State / Focus Correctness

- **Date:** 2026-06-10
- **Status:** Approved (design) — pending implementation plan
- **Target file:** `bridge.py`
- **Branch suggestion:** `fix/bridge-state-focus-correctness`

## Context

Three functional-correctness reviews of `claudecode-telegram` surfaced a cluster of
state-consistency bugs in `bridge.py`. They all share one root theme: the worker's
three pieces of mutable state — **focus** (`state["active"]`), **session id**
(`*_session_id` files), and **pending** (the backpressure marker) — drift out of
sync with reality across the `hire` / `end` / `restart` / crash lifecycle, and a
"read" function silently mutates focus.

This spec covers ONLY this cluster. Other correctness clusters (connector message
loss, non-interactive backend gaps, shell `stop` bug, message splitter) are deferred
to their own specs.

### Bugs in scope (all confirmed by reading the code)

| ID | Bug | Location |
|----|-----|----------|
| B1 | `get_registered_sessions()` auto-picks `list(registered.keys())[0]` as focus — a read/scan function with a focus-mutating side effect. After `/end` of the focused worker, or on restart when `last_active` is gone, focus silently jumps to an arbitrary (possibly dead) worker and the next plain message is misrouted. | `bridge.py:4838-4841`; startup `11314-11319`; `end()` `5163-5165` |
| B2 | `end()` deletes `*_session_id` / `claude_session_cwd` only for non-interactive workers (gated by `if not backend.is_interactive:`). For a Claude worker the session id survives `/end`; a later `/hire` of the same name + `/restart` resumes the **previous occupant's** conversation. | `bridge.py:5139-5147` |
| B3 | `restart()` calls `clear_pending(name)` only in the non-interactive branch. Restarting an interactive worker that has an in-flight request leaves a stale `pending`; ~15 min later the watchdog fires a false STUCK/POISONED alert. | `bridge.py:5219-5243` |
| B4 | `handle_hook_response()` calls `clear_pending` AFTER `send_response_to_telegram`. If the send raises, `clear_pending` is skipped and the worker is stuck "pending" until the 600s timeout. | `bridge.py:10374-10388` |

## Goals & non-goals

**Goals**
- Focus, session id, and pending always reflect reality across the full worker lifecycle.
- Focus only ever points at a worker the user explicitly chose **and** that still exists; otherwise it is `None`.
- Re-hiring a name always starts a genuinely fresh Claude conversation.
- No false "stuck worker" watchdog alerts caused by abandoned/failed requests.
- Every fix has an e2e test in `test.sh` (project convention: every feature has an e2e test).

**Non-goals**
- Not contributing back to upstream (`beastoin`). Personal usability is the priority; clean-PR formatting and matching upstream conventions are NOT constraints.
- No security/auth hardening (explicitly out of scope — trusted single-user deployment).
- No full worker-state-machine refactor (YAGNI). We do the targeted improvement of removing the read-function side effect, nothing broader.
- We do NOT rewrite all ~35 `get_registered_sessions()` call sites or every direct `state["active"]` read.

## Desired behavior (focus model)

When the focused worker disappears — user runs `/end` on it, it crashes, or on
restart `last_active` no longer exists:

- Focus is **cleared to `None`** (never auto-picked).
- The next plain (non-`@`, non-command) message is **not routed**; the bridge replies
  with the existing prompt (`route_to_active` already does this at `bridge.py:8362-8369`:
  "No one assigned. Your team: …\nWho should I talk to?").
- On restart, focus is restored to `last_active` **only if** that worker still exists;
  otherwise `None`.

## Design

### Approach

Chosen: **point-fixes + a small explicit focus interface** (the lighter end of
"Approach B"). We remove the one architectural smell (a scan function mutating focus)
and consolidate focus writes, without a broader refactor.

### Focus-management seam

Introduce two small helpers that own writes to `state["active"]`:

- `set_focus(name)` — sets `state["active"] = name` and calls `save_last_active(name)`.
  Replaces the 6 scattered `state["active"] = …; save_last_active(…)` pairs
  (`bridge.py:5117-5118, 5876-5877, 6247-6248, 6360-6361, 6876-6877, 6895-6896`).
- `clear_focus()` — sets `state["active"] = None` (no auto-pick, no persisted last_active change beyond leaving it).

`get_registered_sessions()` becomes free of the auto-pick:
- **Remove** the auto-pick at `bridge.py:4840-4841`.
- **Keep** the stale-clear at `bridge.py:4838-4839` (`if state["active"] and state["active"] not in registered: state["active"] = None`). This is desirable self-healing: when the focused worker vanishes, focus goes `None`, which triggers the existing `route_to_active` prompt. (Keeping it means `get_registered_sessions` still has a benign, idempotent clear-only effect; it never *chooses* a focus. This is an accepted, documented exception, not the removed bug.)

### B1 — Focus never jumps to an arbitrary worker

- Delete `bridge.py:4840-4841` (the `if registered and not state["active"]: state["active"] = list(registered.keys())[0]` auto-pick).
- Startup (`bridge.py:11314-11319`): in the `elif last_active:` branch (last_active set but not in registered) explicitly set `state["active"] = None` in addition to the existing log line. Ensure that when `last_active` is falsy, `state["active"]` is also `None` (no residual auto-picked value). Net: `state["active"] = last_active if last_active in registered else None`.
- `end()` (`bridge.py:5163-5165`): when ending the focused worker, call `clear_focus()` and **remove** the trailing `self.get_registered_sessions()` call (it existed only to trigger the now-deleted auto-pick).

### B2 — Re-hiring a name starts fresh

- In `end()` (`bridge.py:5139-5147`): move the `for session_id_file in session_dir.glob("*_session_id"): session_id_file.unlink()` loop **out** of the `if not backend.is_interactive:` guard so it runs for all backends, and also delete the `claude_session_cwd` file. The non-interactive-only cleanup (backend file removal, `kill_adapter`) stays gated.
- Result: after `/end`, no `*_session_id` / `claude_session_cwd` remains, so a later `/hire` + default `/restart` cannot hit the resume branch (`bridge.py:6978-6981`) and resume the prior conversation.

### B3 — Restart clears pending in all modes

- In `restart()` (`bridge.py:5219-5243`): hoist `clear_pending(name)` **above** the `if not backend.is_interactive:` branch so it runs for every restart mode (relaunch, resume, clean). The in-flight request is abandoned on any restart, so pending must be cleared regardless of backend type.

### B4 — Pending always cleared on the response path

- In `handle_hook_response()` (`bridge.py:10374-10388`): wrap the `send_response_to_telegram(...)` call in `try: … finally: clear_pending(session_name); mark_hook_event(session_name)` so both run even when the send raises. (Chosen over clearing before the send, so ordering reflects "we attempted delivery, then released the worker.") Rationale: the worker produced output (we received the hook), so pending must clear whether or not the Telegram delivery succeeded.

### Unifying invariant

Every change to `state["active"]`, `*_session_id`, and `pending` goes through an
explicit entry point; read/scan functions never *choose* state; focus always points
at a user-chosen, still-alive worker or is `None`.

## Test strategy

Tests are added to `test.sh` following the project's red-green-refactor TDD
(write the failing test first, confirm RED with `TEST_FILTER`, implement, GREEN, then
run the `FAST=1` suite to catch regressions).

| Fix | e2e test | Mode |
|-----|----------|------|
| B1 focus-clear-on-end | hire `alice`+`bob`; `/focus alice`; `/end alice`; assert a following plain message gets the "No one assigned…" prompt and is NOT delivered to `bob` | integration (default) |
| B1 startup restore | set `last_active` to a non-existent worker; start bridge; assert `state["active"]` is `None` (not an arbitrary worker) | integration |
| B2 fresh re-hire | hire `bob`; produce a `*_session_id`; `/end bob`; assert no `*_session_id`/`claude_session_cwd` remains in the session dir; `/hire bob` again and assert restart does not resume | integration |
| B3 restart clears pending | set pending on an interactive worker; `/restart`; assert the pending file is gone | integration |
| B4 pending exception-safety | drive `/response` with a send that raises (stub/inject failure); assert pending is still cleared | unit or integration |

Regression guard: full `FAST=1` suite green after each increment; default-mode suite
green before considering the cluster done.

## Implementation order (low-coupling increments)

1. Add `set_focus()` / `clear_focus()`; route existing focus writes through them (pure refactor — existing tests stay green).
2. Remove auto-pick (`4840-4841`) + fix startup restore (`11314-11319`) + `end()` focus clear (B1).
3. `end()` unconditional `*_session_id` / `claude_session_cwd` cleanup (B2).
4. `restart()` hoist `clear_pending` (B3).
5. `handle_hook_response()` `try/finally` for `clear_pending` + `mark_hook_event` (B4).

## Risks & mitigations

- **~35 callers of `get_registered_sessions()` relied on the side effect.** Mitigation: only the auto-pick is removed; the stale-clear stays, so any caller that depended on "focus auto-clears when the worker dies" still works. The only behavior change is that focus is no longer *chosen* automatically — which is the intended fix. The B1 e2e tests cover the routing-after-clear path.
- **Hoisting `clear_pending` in `restart()`** could clear a legitimately-pending state if a restart races a just-arrived response; acceptable because a restart abandons the current turn by definition.

## Out of scope — deferred to their own specs

- Connector message loss (Gmail historyId / pagination / re-bootstrap; GitHub seed).
- Non-interactive backend gaps (Gemini/OpenCode no resume, adapter cwd, Codex empty-response drop).
- Shell `stop` `set -e` `((x++))` abort; `RESERVED_NAMES` staleness; message splitter cutting HTML entities.
