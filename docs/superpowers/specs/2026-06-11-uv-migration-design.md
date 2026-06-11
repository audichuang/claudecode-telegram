# Design — uv migration, ruff, and a green test suite (v0.32.0)

> Date: 2026-06-11 · Branch: `chore/uv-ruff-tooling` · Base: `679c842` (feat/topic-sessions)

## Goal

User directive: **fully migrate the project to uv**, configure **ruff**, wire up the
**pyright LSP**, and get the **test suite to pass (0 failures)**. Documentation must be
unified and clear.

## Context (pre-state)

- `pyproject.toml` existed but was a stub: `dependencies = []`, `version = 0.8.0`
  (stale vs the real `0.31.0`). uv was installed; ruff was not; no `.venv`.
- The bridge and hooks launched via bare system `python3`.
- FAST suite: **339 passed / 10 failed**. The failures were *not* flaky — each had a
  concrete cause (see triage). They had been mislabelled "environmental/baseline".

## Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Scope of uv takeover | **Full** — runtime + dev + tests | User asked for "整個都給 uv 接管". |
| Package vs script | `package = false` | Bridge runs as `python bridge.py`, never installed; avoids a build backend. |
| Interpreter selection | `$PY` resolver: prefer `.venv/bin/python`, fall back to `python3` | One policy across every entry point; graceful before first `uv sync` / on hosts without uv. |
| Hot hooks | Direct `.venv/bin/python`, **not** `uv run` | `uv run` adds ~7ms + lock work per call; hooks fire per-message. |
| `uv sync` placement | Once in `cmd_run` at node startup, `--frozen` | Idempotent; read-only lock ⇒ no cross-node race (CLAUDE.md multi-node rule). |
| `requires-python` | `>= 3.12` | Code already uses py3.12 f-string syntax; `>=3.10` was a lie. |
| ruff ruleset | `select = E,F`, ignore `E402/E741/E501`, target py312 | Conservative — no churn on the 10k-line bridge; only real findings. |
| Failing tests | Real fix / hermetic mock / honest behaviour — **never a fake pass** | Honors "test behavior, not scaffolding". |
| Isolation | Work in a git **worktree**; never restart prod | The live dev node + Telegram hooks run from the main checkout. |

## Test-failure triage (all driven to GREEN honestly)

- **`/memory` ×5 — real bug.** `bridge.py` lazily imports `team_memory.memory_stack` /
  `team_memory.search`, but the package existed nowhere (not on disk, not in git
  history). `/memory` was crashing in prod. **Fix:** created a real `team_memory`
  package that degrades gracefully (empty/zero until an index is built), matching the
  consumed API.
- **`cmd_webhook_info` — real product bug.** Under `set -euo pipefail`, the
  `grep -o … | cut` extraction aborted the command whenever the webhook response had no
  match. **Fix:** `|| true` on both pipelines. (Same pattern may recur in
  `cmd_webhook_check`/status — flagged as follow-up.)
- **`\s` SyntaxWarning — real bug.** JS regex `q.split(/\s+/)` inside a Python f-string;
  `\s` is an invalid escape (hard error under `-W error`). **Fix:** `\\s`. Removed an
  adjacent dead `return page_html`.
- **Voice ×2, Auto-TTS, Remote-restart, imgcap — test-setup drift.** FakeRouter missing
  `_resolve_media_target`; `tts_enabled` not toggled; `$HOME` not pinned so the remap
  guard failed off `/home/claude`; imgcap simulator's 8s pane deadline outrun by 10
  serialized ~1s sends → bumped to 30s. All verified GREEN offline with mocks intact.

## What changed

- `pyproject.toml`: deps, dev group (`pytest`, `ruff`), `version 0.32.0`,
  `requires-python >=3.12`, `package = false`, `[tool.ruff]`. `uv.lock` committed.
- `team_memory/{__init__,memory_stack,search}.py`: new graceful package.
- `bridge.py`: `\s` fix, dead-code removal, ruff autofixes.
- `claudecode-telegram.sh`: `$PY` resolver, `uv sync --frozen` in `cmd_run`, 3 launch
  points → `$PY`, `VERSION=0.32.0`.
- `hooks/send-to-telegram.sh`, `hooks/on-tool-failure.sh`: `$PY` resolver + launch.
- `test.sh`: `uv sync --frozen` + `.venv/bin` on PATH; 6 test-setup fixes.
- Docs: `DOC.md` (v0.32.0 changelog), `CLAUDE.md` (uv section, Key Files, version rule),
  `TEST.md`, `README.md`.

## Verification

- FAST suite: **350 passed / 0 failed**.
- uv-launch smoke test: bridge boots under `.venv/bin/python`, `/` → 200, clean SIGTERM,
  port released, no traceback.
- `bash -n` clean on all edited shell files. `bridge.py` byte-compiles with no
  `SyntaxWarning` under `-W error`.

## Rollout / follow-ups (owner: user)

- **Prod restart is the user's to trigger.** This branch only changes how nodes launch;
  the running prod/dev bridges keep their old interpreter until restarted. First node
  restart after deploy runs `uv sync` once.
- The sandbox `Dockerfile` ships Debian bookworm python (3.11) — bump to 3.12+ to match
  `requires-python` (latent; non-sandbox nodes run 3.14).
- ruff follow-ups: 6 `F841`/`E722`/`E731` findings left unfixed.
- `set -euo pipefail` no-match abort may recur in other CLI subcommands.
