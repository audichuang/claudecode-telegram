---
name: bridge-ops
description: Safe operations for claudecode-telegram bridge nodes — restart/deploy a node, verify its health, diagnose silent deaths and "已讀不回", and gate releases on version sync. Use this skill WHENEVER restarting, deploying, stopping, or health-checking a bridge node (dev/test/prod), whenever the bot seems dead or shows typing/已讀 without replying, whenever bridge.log needs reading, or before committing a version bump. Even for a "quick restart", use the bundled scripts — ad-hoc restarts are how the bridge died silently twice.
---

# bridge-ops

Operating the claudecode-telegram bridge has a history of expensive mistakes:
pkill killed prod, ad-hoc launches died silently with the closing terminal
(the 07:47 incident), curl false-alarmed during graceful shutdowns, and a
stowaway version string shipped in a release. The scripts here are those
lessons turned into code — prefer running them over re-typing the steps.

## Restart / deploy a node

```bash
.claude/skills/bridge-ops/scripts/restart-node.sh dev            # the normal case
.claude/skills/bridge-ops/scripts/restart-node.sh dev --dry-run  # show plan only
CONFIRM_PROD=1 .claude/skills/bridge-ops/scripts/restart-node.sh prod  # owner only
```

What it guarantees (and why):
- **Kills only the recorded `bridge.pid`** — pattern kills (`pkill`, `lsof|xargs kill`)
  have caused prod outages on this multi-node machine.
- **Relaunches via `setsid` + `</dev/null`** so the bridge ends up with PPID=1.
  Anything less and a closing terminal/session SIGHUPs it to a silent death.
- **Waits for the port via `ss`, not curl** — the OLD bridge holds the port for
  tens of seconds while sending shutdown notifications; curl `000` during that
  window is a false alarm.
- **Never touches the poll forwarder** — it is an independent PPID-1 process
  that auto-resumes delivery once the bridge is back. Killing or duplicating
  it breaks getUpdates delivery.
- **Refuses prod without `CONFIRM_PROD=1`** — prod restarts are the owner's
  decision, not the agent's.

Per-node config comes from `~/.config/claudecode-telegram/<node>.env`
(TELEGRAM_BOT_TOKEN required; ADMIN_CHAT_ID optional — first sender is
auto-learned otherwise). Actual ports on this machine: dev=8270, test=8295.

## Verify health (read-only, safe anytime)

```bash
.claude/skills/bridge-ops/scripts/verify-node.sh dev
```

Checks port owner = bridge.pid, `.venv` interpreter, **PPID=1**, poller alive,
and no recent traceback in `bridge.log`. A non-1 PPID is a ticking bomb —
relaunch with restart-node.sh even if everything currently "works".

## Diagnose "bot 已讀/打字但沒回應" or a dead bridge

1. `verify-node.sh <node>` — most cases end here (bridge down, poller dead).
2. Read `~/.claude/telegram/nodes/<node>/bridge.log` knowing its quirks:
   - Startup banners have **no timestamps** — bracket an instance's lifetime by
     the timestamped request lines around it.
   - A clean shutdown ALWAYS prints `Received SIGTERM ... shutting down`.
     Last line = successful POST with **no banner** ⇒ SIGKILL/SIGHUP from a
     host process group (see the 07:47 postmortem in CLAUDE.md), not a crash.
   - Claude-session transcripts use **UTC** timestamps; bridge.log is local
     (UTC+8). Convert before correlating.
3. Telegram side: `curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo"`
   — `pending_update_count` > 0 with a live poller means delivery is stuck;
   0 means Telegram has nothing (e.g. a topic was never committed — Telegram
   only creates a topic when its first message is sent).
4. A session vanishing after a reply bounce is the **dead-topic reaper**
   working as designed (`話題 gone for <name>` in the log): the topic was
   deleted, which has no Telegram event.

## Release gate

```bash
.claude/skills/bridge-ops/scripts/check-versions.sh
```

Run before committing a version bump: the version lives in
`claudecode-telegram.sh`, `pyproject.toml`, AND `bridge.py` (`/settings`
reports bridge.py's copy). Exits non-zero on mismatch. Full release steps and
test gates: see `CLAUDE.md` (Version Management + Testing Requirements).
