# Spec: Simplified "話題 = session" Telegram model

- **Date:** 2026-06-10
- **Status:** Draft (design) — pending user review
- **Target:** `bridge.py` (+ a new simplified router module) and the Telegram UX
- **Branch:** `feat/topic-sessions` (off `fix/bridge-state-focus-correctness`)

## Problem / context

The current bot is built to manage a *team* of workers across multiple projects,
backends, and machines: `hire`-by-name, `focus`, `@mention`, `team`, `pending`/
watchdog, multiple backends (claude/codex/gemini/opencode), multi-node, restart
modes, teleport, pause/resume, pilot. The **owner does not use any of that**. For
the owner the job is only: *open a Claude session, talk to it, close it* — and at
most 2–3 at once (mobile Telegram makes more impractical).

All the team/addressing machinery is therefore pure cognitive + maintenance
overhead. This spec defines a **drastically simpler model** that the owner
actually wants, and removes the unused complexity from the path they use.

This redesign is for **personal usability**, not upstream parity. It is a separate
track from the `fix/bridge-state-focus-correctness` cluster (which it builds on).

## The model: one forum group, one 話題 (Topic) per session

```
Telegram 群組 (forum / 話題 enabled), bot = admin
 ├─ 話題 "web"     ⇄  session  (tmux + a claude)
 ├─ 話題 "api"     ⇄  session
 └─ 話題 "scratch" ⇄  session
```

- **A Telegram forum group, with the bot added as admin.** Each **Topic (話題)** in
  that group is bound 1:1 to a Claude Code session.
- **Session identity = `(chat_id, message_thread_id)`.** No names, no `focus`, no
  `@`, no `team`. The 話題 *is* the addressing.
- **Talk:** type in a 話題 → routed to that session. Its reply is posted **back into
  the same 話題** (via the Stop hook).
- **Switch sessions:** tap a different 話題 (native Telegram). The bridge does
  nothing special — there is no "current/active" state to manage.
- **Open a session:** create a new 話題 and send the first message in it. The
  bridge sees an unknown `message_thread_id` and, before spawning, replies with an
  **inline-keyboard folder navigator** (see below) so you pick the workspace by
  tapping. Once a folder is chosen, the session is spawned there and the first
  message is delivered.
- **Close a session:** `/close` inside the 話題 (or closing/deleting the 話題) →
  bridge ends that session.
- **Workspace selection (folder navigator):** instead of typing paths (painful on
  mobile), the bridge shows folders as **inline-keyboard buttons**: tap a folder to
  descend, `⬆️ 上一層` to go up, `✅ 用這層` to choose the current directory. Driven
  by Telegram `callback_query`. Navigation is rooted at a configurable base
  (default `$HOME`) so the picker starts somewhere sane. `/cd` in a 話題 re-opens
  the navigator to change a running session's folder (typed `/cd <path>` also
  accepted as a shortcut).

### Kept vs removed

| Kept (the only surface) | Removed (unused complexity) |
|---|---|
| open (new 話題 → first message) | `hire`-by-name, `focus`, `@mention`, `team` |
| talk (plain text in a 話題) | `pending` marker + STUCK/POISONED watchdog |
| reply (Stop hook → same 話題) | multiple backends (codex/gemini/opencode) |
| `/close` | multi-node, teleport, `pilot` |
| `/cd <path>` (set project) | restart modes (resume/clean/relaunch), pause/resume |
| `/restart` (optional: clear & restart this session) | voice, connectors (gmail/github), sandbox |

## Architecture

Reuse the proven low-level primitives, replace only the routing/identity layer.

- **Inbound:** Telegram → (existing poll forwarder *or* webhook) → bridge HTTP `POST /`.
  A new **topic router** keys on `message.message_thread_id`:
  - known thread → deliver text to that session's tmux (existing `tmux send-keys`).
  - unknown thread → show the folder navigator; on selection, create a session for
    that thread (rooted at the chosen folder), then deliver the pending first message.
  - command (`/close`, `/cd`, `/restart`) → handle for that thread's session.
- **Folder navigator (new capability):** the bridge must handle Telegram
  `callback_query` updates (button taps). Each folder button carries a callback
  payload (target path + the thread it belongs to); the handler lists that path's
  subdirectories, edits the message's inline keyboard in place, and on `✅ 用這層`
  records the chosen cwd for the thread and proceeds to spawn. The poll forwarder
  already forwards full updates, so `callback_query` arrives the same way as messages.
- **Session:** a tmux session running `claude` (reuse existing creation primitives).
  Internal tmux name is derived from the thread id (e.g. `claude-<node>-t<thread_id>`);
  the user never sees or types it.
- **Outbound:** worker finishes → existing **Stop hook** (`send-to-telegram.sh`) →
  `POST /response` → bridge sends to Telegram **with `message_thread_id`** so the
  reply lands in the right 話題. (Today the session dir stores `chat_id`; we add
  `message_thread_id` so the hook/bridge can target the topic.)

### Session record (minimal)

Per session, stored under the session dir (reusing the existing per-session dir
pattern): `chat_id`, `message_thread_id`, `cwd`, the tmux name, and the Claude
`session_id` (for the hook). **No** `pending`, `focus`, `backend`, `host`.

## Approaches considered

- **A. New lean topic-router that reuses bridge.py primitives (recommended).**
  Add a small `topic mode` path: a router keyed by `message_thread_id`, session
  creation via the existing tmux helper, the existing Stop-hook plumbing extended
  with `message_thread_id`. The legacy team commands are simply not wired in this
  mode. Genuinely simpler active logic, low risk (reuses the hard, proven parts:
  tmux lifecycle + hook + Telegram I/O + poll fallback).
- **B. Brand-new minimal bot.** Cleanest mental model but re-implements tmux
  management, hook install, Telegram I/O and poll fallback from scratch — high
  effort/risk for little extra benefit.
- **C. Thin adapter mapping 話題 → internal worker name** over the existing
  complex bridge. Lowest effort but **keeps** the complexity underneath — contrary
  to the goal of *simplifying the logic*. Rejected.

**Recommendation: A.** Simplify the path the owner uses; reuse the plumbing that
already works.

## Error handling

- **Bot not admin / can't read group messages:** on startup or first failure, the
  bridge replies (in the group's General topic) with a one-line setup hint
  ("make me admin and enable 話題").
- **Message in a non-forum chat (no `message_thread_id`):** fall back to a single
  default session for that chat (so a plain DM still works as one session).
- **`/close` on an already-closed 話題:** no-op with a short ack.
- **Claude session dies:** next message in that 話題 re-spawns it (idempotent open).

## Testing (project convention: every feature has an e2e test)

FAST-mode unit tests (inline `python3 -c`, monkeypatching, no running bridge),
matching the existing `test.sh` style, plus integration where it matters:

| Behavior | Test |
|---|---|
| unknown thread → shows folder navigator (no session yet) | unit: feed an update with a new `message_thread_id`, assert a navigator keyboard is produced and no session is spawned until a folder is chosen |
| navigator lists subdirectories as buttons | unit: given a temp dir tree, assert the callback handler returns the child folders |
| navigator stays within the configured root | unit: `⬆️` at the root does not escape it; no path outside root is reachable |
| selecting a folder spawns the session there + delivers the pending message | unit/integration |
| known thread → routes to the right session | unit: two threads → two sessions; a message goes only to its thread's session |
| reply targets the originating 話題 | unit: outbound carries the stored `message_thread_id` |
| `/close` ends that thread's session and nothing else | unit |
| `/cd` re-opens the navigator (or accepts a typed path) for a running session | unit |
| non-forum chat → single default session | unit |
| end-to-end open → pick folder → talk → reply in topic | integration |

Regression guard: full `FAST=1` suite green (against the documented pre-existing
baseline) after each increment.

## Goals / non-goals

**Goals:** the owner can open/talk/close Claude sessions by 話題, switch by tapping
topics, with zero name/focus/team concepts. Replies land in the right 話題.

**Non-goals:** team management, multi-backend, multi-node, teleport, voice,
connectors, sandbox, watchdog. The legacy bot may keep existing for power use, but
is out of scope here. No security/auth hardening (trusted single-user). Not an
upstream contribution.

## Resolved decisions

- **Open-session trigger: (a)** the user creates a 話題 and sends the first message;
  the bridge then shows the folder navigator and spawns on selection. (Rejected (b)
  a `/new` bot-creates-topic command — less natural for the owner.)
- **Workspace selection: inline-keyboard folder navigator** (native buttons, no
  HTTPS), not a Mini App webview. Rooted at a configurable base (default `$HOME`).
- **Topic lifecycle = session lifecycle:** new 話題 ⇒ open; close/delete 話題 (or
  `/close`) ⇒ end the session.

## Add-on feature: usage/quota display (`/quota`)

Show the same usage the Claude Code statusline shows: the **5-hour** window, the
**7-day/weekly** window (used % + reset time), and **session context** usage.

**Data source (verified, not guessed).** This data is NOT available from any
Anthropic API — its only source is the JSON Claude Code pipes to the statusline
command (`rate_limits.five_hour/seven_day`, `context_window`). The owner already
runs **claude-hud** (0.1.0) as their statusline, which has a built-in machine-
readable export.

**Integration (zero-clobber).** Do NOT touch `~/.claude/settings.json` statusLine.
Instead merge ONE key into the existing `display` block of
`~/.claude/plugins/claude-hud/config.json`:
`"externalUsageWritePath": "/home/<user>/.claude/cc-usage.json"`. claude-hud then
atomically writes (mode 0600, ≥30s throttle) a snapshot:
```json
{ "updated_at": "<ISO8601>",
  "five_hour": { "used_percentage": <int 0-100>, "resets_at": "<ISO8601>" },
  "seven_day": { "used_percentage": <int 0-100>, "resets_at": "<ISO8601>" } }
```
The bot reads that file. `used_percentage` is percent **used** (remaining = 100−x).

**Context usage** is not in that file (it lives only in live stdin). Treat it as
**best-effort**: read claude-hud's internal
`context-cache/<sha256(realpath(transcript_path))>.json`
(`used_percentage`, `current_usage.{input,output,cache_creation,cache_read}_input_tokens`,
`context_window_size`) opportunistically, or omit it. (A self-owned statusline
forwarder that chains into claude-hud could capture context-% reliably, but that
risks the single-`statusLine`-slot clobber, so it is out of scope unless needed.)

**Account caveat.** `rate_limits` is populated only for Claude.ai **Pro/Max**
accounts (and is null until the first model response). API-key accounts get no
5h/7d data → the snapshot file is not written. The bot must fall back to a clear
message ("usage unavailable — no subscriber rate-limit data reported") rather than
showing 0%.

**`/quota` output** (compact, one line per window with a 10-char bar, remaining =
100−used, relative reset): `5h`, `7d`, and (if available) `ctx`. Null window →
`n/a`.

**Tests:** parse the snapshot (ISO timestamps + integer %), staleness via
`updated_at`, missing-file/null-window fallback message, bar rendering, and the
remaining = 100−used conversion.

**Precondition:** verify the installed claude-hud version supports
`externalUsageWritePath` (0.1.0 does). Enabling the key is the one config change
this feature makes; everything else is read-only.
