# Claude Code Project Instructions

## The Model (v1.0.0: topic-only)

**One Telegram forum 話題 (topic) = one Claude Code session.** This is the ONLY
model — the multi-worker era (`/hire /focus /team`, `@mention`, teleport,
codex/gemini/opencode backends, gRPC, forge `/register`) was deleted in v1.0.0.

```
建話題(第一則訊息=純觸發) → 資料夾選單 → tmux 裡誕生 claude session
話題內訊息/媒體 → bridge → tmux send → claude → Stop hook → POST /response → 回同一話題
關閉話題 = 結束 session;刪除話題靠回覆彈回 thread-not-found 收屍(Telegram 無刪除事件)
```

- Addressing = which 話題 you type in. There is **no** focus/active state.
- `TOPIC_MODE` is hardwired `True` in bridge.py; the env var is ignored.
- Claude is the only backend. Watchdog liveness shows as emoji reactions (👀✍😴👍).
- Spec: `docs/superpowers/specs/2026-06-1{0,1}-topic-*.md`; history: `DOC.md` changelog.

## Version Management

When making changes that result in a new version:

1. **Update version** in ALL THREE of `claudecode-telegram.sh`, `pyproject.toml`,
   AND `bridge.py` (keep them in sync — `/settings` reports bridge.py's copy):
   ```bash
   # claudecode-telegram.sh
   VERSION="x.y.z"
   # pyproject.toml
   version = "x.y.z"
   # bridge.py
   VERSION = "x.y.z"
   ```

2. **Update `DOC.md`** with:
   - New version number in header
   - Changelog entry describing:
     - Breaking changes (table format if applicable)
     - New features
     - Architecture changes
   - Update design philosophy sections if core principles changed

3. **Run the release gate** before committing a bump — exits non-zero on any
   version mismatch across the three files:
   ```bash
   .claude/skills/bridge-ops/scripts/check-versions.sh
   ```

4. **Run acceptance tests** before committing:
   ```bash
   TELEGRAM_BOT_TOKEN='...' ./test.sh
   ```
   See `TEST.md` for full testing documentation.

## When to Bump Version

- **Patch (0.0.x)**: Bug fixes, minor tweaks
- **Minor (0.x.0)**: New features, backward-compatible changes
- **Major (x.0.0)**: Breaking changes, architecture overhaul

## Toolchain (uv)

The project is **uv-managed**. `pyproject.toml` declares deps (`markdown-it-py` runtime;
`pytest` + `ruff` in the `dev` group), `uv.lock` is committed, `requires-python >= 3.12`,
`package = false` (the bridge runs as a script, not an installed package).

- **Setup / deps:** `uv sync` creates `.venv` and installs the locked deps. Re-run after
  editing `pyproject.toml`, and commit the updated `uv.lock`.
- **Run anything:** `uv run python bridge.py`, `uv run ruff check .`, `uv run pytest`.
- **Launch uses a `$PY` resolver:** `claudecode-telegram.sh` + both hooks prefer
  `.venv/bin/python`, falling back to system `python3`. `cmd_run` runs `uv sync --frozen`
  once at node startup — the lock stays read-only, so concurrent multi-node starts never
  race to rewrite it. `test.sh` syncs and prepends `.venv/bin` automatically.
- **Lint:** `uv run ruff check .` (config in `pyproject.toml`: `select = E,F`, py312).

## Key Files

| File | Purpose |
|------|---------|
| `bridge.py` | Telegram webhook handler, session management |
| `viewer.py` | Transcript / team-chat HTML viewer (extracted from bridge.py in v1.1.0; lazy `import bridge` for config so test monkeypatches keep working) |
| `claudecode-telegram.sh` | CLI wrapper, tunnel/webhook setup, `$PY`/uv-sync launch |
| `hooks/send-to-telegram.sh` | Claude Stop hook, sends responses |
| `hooks/on-tool-failure.sh` | PostToolUseFailure hook (POISONED detection) |
| `team_memory/` | `/memory` stack + search (graceful, empty until an index is built) |
| `pyproject.toml` / `uv.lock` | uv dependency + interpreter management, ruff config |
| `test.sh` | Automated acceptance tests |
| `.claude/skills/bridge-ops/` | Node operations skill: `restart-node.sh` (PID-kill + setsid relaunch), `poll-forwarder.sh` (getUpdates delivery), `verify-node.sh` (health check), `check-versions.sh` (release gate). **Use these instead of hand-typed ops commands.** |
| `.claude/skills/test-triage/` | test.sh failure triage skill: filtered repro → known-environmental list → worktree control experiment → instrumentation. **Use it before blaming any change for a red test.** |
| `CLAUDE.md` | Project instructions + operational learnings (AGENTS.md symlink) |
| `DOC.md` | Design philosophy, changelog |
| `TEST.md` | Testing documentation |

## Testing Requirements

Workflow rules:
- Use FAST mode during development (TDD inner loop); run default mode before committing; run FULL mode before pushing.
- Write tests alongside features; focus on e2e behavior (not scaffolding).
- Treat tests as usage examples; prefer real Telegram flows (開話題 → 選資料夾 → send → reply) and keep them deterministic.
- When adding tests, follow `TEST.md`.
- See `TEST.md` for mode definitions, env vars, isolation details, inventories, and manual/CI instructions.

### TDD Workflow: Red-Green-Refactor

Development follows increment-based TDD. Each feature is broken into small testable increments, and each increment follows Red-Green-Refactor:

**Decompose first:**
Before coding, break the feature into an increment ladder:
1. Degenerate/empty case (zero, nil, no-op)
2. Simplest happy path (one item, minimal valid input)  
3. Variations (multiple items, different valid inputs)
4. Edge cases (boundaries, limits, special characters)
5. Error cases (invalid input, missing data, failure modes)
6. Integration (combine with other components)

**Per increment:**
1. **RED** — Write one failing test in test.sh. Run it with TEST_FILTER to confirm it fails:
   ```bash
   TEST_FILTER=test_name FAST=1 TEST_BOT_TOKEN='...' ./test.sh
   ```
2. **GREEN** — Write minimal code to make the test pass. Run filtered test again.
3. **REFACTOR** — Clean up if needed. Run filtered test to confirm still green.
4. Move to next increment.

**Mode gates** (`test.sh` defaults `TMUX_PREFIX=claude-test-` so unit tests are
namespaced away from real nodes; only override it to target a different test node):
```bash
# While developing — run single test frequently
TEST_FILTER=test_name FAST=1 TEST_BOT_TOKEN='...' ./test.sh

# Per increment green — run FAST suite
FAST=1 TEST_BOT_TOKEN='...' ./test.sh

# Before commit — full local validation
TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh

# Before push — including tunnel tests
FULL=1 TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh
```

**Rules:**
- Write the test BEFORE the implementation code
- One behavior per test — tests stay focused and readable
- Run full FAST suite after each increment to catch regressions
- Show first failing test evidence before implementation in plan reviews

**Why e2e tests matter:**
- They catch integration bugs that unit tests miss
- They document how features actually work
- They give confidence when refactoring
- They're the safety net for this project

## Design Philosophy

**Source of truth: `DOC.md`** - All principles are documented there with full context.

When making changes, ensure they align with the philosophy in `DOC.md`. If adding new principles, update `DOC.md` first (both the summary table at the top AND the detailed section), then reference here.

### Quick Reference (see DOC.md for details)

| Principle | Rule |
|-----------|------|
| **Tests required** | Every new feature MUST have an e2e test |
| tmux IS persistence | No database, no state.json |
| `claude-<name>` naming | Enables auto-discovery |
| RAM state only | Rebuilt on startup from tmux |
| Per-session files | Minimal hook↔gateway coordination |
| Fail loudly | No silent errors, no hidden retries |
| Token isolation | `TELEGRAM_BOT_TOKEN` NEVER leaves bridge |
| Admin config | `ADMIN_CHAT_ID` env var or auto-learn first user |
| Secure by default | 0o700 dirs, 0o600 files |

## Learnings

### Never hardcode paths

**Problem:** Hardcoded paths break test isolation and make the system inflexible.

**Rule:** All paths must be configurable via environment variables with sensible defaults.

```bash
# Good: configurable with default
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.claude/telegram/sessions}"

# Bad: hardcoded
SESSIONS_DIR="$HOME/.claude/telegram/sessions"
```

### Env vars must propagate through the full chain

**Problem:** When process A spawns process B which runs process C, env vars set in A don't automatically reach C.

**Rule:** If a subprocess needs config, explicitly export it at each boundary:
- Parent process sets env var
- Parent exports to child's environment (e.g., `tmux send-keys "export VAR=value"`)
- Child process reads env var

**Check all entry points:** If a session can be created via `create_session()`, `register_session()`, or `restart_claude()`, ALL of them must export the required env vars.

### When adding configurable behavior, audit all code paths

**Problem:** Adding a new config option in one place but missing other places that need it.

**Rule:** When making something configurable:
1. Search for ALL usages of the old hardcoded value
2. Update every location that references it
3. Ensure all entry points (create, register, restart, discover) handle it consistently

### Keep project memory current

**Problem:** Fixes and gotchas get rediscovered when the memory is stale or scattered.

**Rule:** Capture new operational learnings here, architecture changes in `DOC.md`, and test additions in `TEST.md`. Remove or update notes if behavior changes.

**Why:** The agent (and future contributors) rely on these files as the source of truth.

### Per-node inbox isolation

**Problem:** Inboxes under `/tmp` were shared across nodes, causing collisions between prod/dev/test.

**Rule:** Namespace all `/tmp` paths by node (derived from `TMUX_PREFIX`):
```
/tmp/claudecode-telegram/<node>/<session>/inbox/   # incoming media files
```
(The `in.pipe` worker-to-worker channel was removed with the multi-worker era in v1.0.0.)

### Watchdog for bridge requires careful testing

**Problem:** Adding bridge auto-restart to the watchdog (like tunnel has) seems simple but has hidden complexity:
- Shell output buffering when redirected to files
- Port conflicts between test stages
- Race conditions between process cleanup and restart
- Test timeouts vs DNS propagation delays

**Current state:** Only tunnel watchdog exists (v0.5.0). Bridge watchdog was attempted (v0.5.4) but reverted due to test failures.

**If re-implementing:**
1. Test the script manually first, not just via test harness
2. Use `stdbuf -oL` for unbuffered output in tests
3. Add longer delays between killing processes and checking ports
4. Consider skipping watchdog tests in CI (mark as slow/optional)
5. Ensure `start_bridge()` passes ALL required env vars, not just token/port
6. Add explicit stop conditions (max retries or timeouts) and log when the watchdog gives up

### Bridge processes MUST be setsid-detached (the 07:47 silent-death lesson)

**Problem:** The dev bridge died silently twice (2026-06-10/11): last log line a
successful `POST /response`, then nothing — no banner, no traceback. Root cause:
it was launched under an interactive host (foreground `./claudecode-telegram.sh
run`); when that terminal/session went away, the process group got SIGHUP/SIGKILL,
which Python dies from silently. A foreground `run` whose webhook setup fails can
also exit after killing the old bridge, leaving the whole node dead (2026-06-12).

**Rule:** Restart nodes ONLY via the bridge-ops skill — it codifies all of this
(PID-file kill, setsid + `</dev/null` detach so PPID=1, ss-based verification):
```bash
.claude/skills/bridge-ops/scripts/restart-node.sh dev
.claude/skills/bridge-ops/scripts/verify-node.sh dev   # read-only health check
```
Verifying by hand: don't trust `curl` — the OLD bridge holds the port for tens of
seconds during graceful shutdown (curl `000` is a false alarm). Poll
`ss -ltnp | grep :<port>` for the NEW pid, then `tail bridge.log` for the banner.

### NEVER use pkill on multi-node setups

**Problem:** `pkill -f cloudflared` or `pkill -f bridge.py` kills ALL matching processes across ALL nodes, not just the target node.

**Rule:** ALWAYS use PID-based killing, NEVER pattern-based.

```bash
# WRONG - kills ALL nodes
pkill -f bridge.py
# WRONG - kills without knowing which node owns the port
lsof -ti :8271 | xargs kill

# RIGHT - PID from file, the stop command, or the bridge-ops scripts
kill $(cat ~/.claude/telegram/nodes/prod/pid)
./claudecode-telegram.sh --node prod stop
.claude/skills/bridge-ops/scripts/restart-node.sh dev
```

**Why this matters:** Multiple nodes (prod, dev, test) run simultaneously. Pattern-based killing causes collateral damage. The dev poll forwarder is an independent PPID-1 process — never kill it as a side effect; it auto-resumes delivery after bridge restarts.

### Verify port ownership before killing

**Problem:** Ran `lsof -ti :8271 | xargs kill` thinking it was dev node, but port 8271 = prod. Killed production bridge while team was working.

**Script defaults (overridable via `--port` or `PORT` env var):**
| Default Port | Node | Sandbox |
|--------------|------|---------|
| 8270 | sandbox (or custom) | `--sandbox` |
| 8271 | **prod** | `--no-sandbox` |
| 8272 | dev | `--no-sandbox` |
| 8295 | test (test.sh) | `--no-sandbox` |

Ports are dynamic — **the defaults lie in practice** (this Linux box runs the dev
node on **8270**, test on 8295). Always check the live owner before anything
destructive:
```bash
ss -ltnp | grep ':82'                             # who actually listens, with PID
cat ~/.claude/telegram/nodes/*/port 2>/dev/null   # recorded assignments
```

**Why `--no-sandbox` for prod/dev/test?** Docker overhead is too slow. Sandbox node is for untrusted/experimental code.

### Node credentials live in ~/.config/claudecode-telegram/

**Problem:** During a prod restart, wasted time extracting the bot token from `/proc/<pid>/environ` when it was already stored in a config file.

**Rule:** Token env files are at `~/.config/claudecode-telegram/<node>.env` —
one file per node on that machine (this Linux box has `dev.env` and `test.env`;
a machine hosting prod has `prod.env`). The bridge-ops scripts load them
automatically; `test.sh` credentials come from `test.env`
(`TELEGRAM_BOT_TOKEN` + `TEST_CHAT_ID`).

**The `set -a` trap:** these files are plain `VAR=value` with **no `export`** —
a bare `source` sets shell-local vars that die at the next `exec` boundary (the
bridge exits instantly with "TELEGRAM_BOT_TOKEN not set"). Anything sourcing
them across an exec must wrap: `set -a; source "$ENV_FILE"; set +a`.
Regression-tested by `test_restart_node_env_propagation`.

**Why:** Faster, more reliable than extracting from running process memory. Works even if the bridge is already dead.

### Always test on dev node before prod deployment

**Problem:** Deployed v0.9.2 fix directly to prod without testing on dev node first. Ran local stress test but skipped real integration testing on dev.

**Fix:** Always test on dev node before prod deployment:
1. Start dev bridge with dev bot token on port 8272
2. Run full integration tests against dev
3. Test manually via Telegram on dev bot
4. Only then deploy to prod

**Why:** Local/unit tests prove concepts work in isolation, but real integration bugs only surface with actual Telegram traffic on a separate dev instance. Prod is not for testing.

### tmux send race condition

**Problem:** Concurrent sends to same tmux session interleave (text1, text2, Enter1, Enter2) causing ~50% message loss.

**Fix:** Per-session locks in `tmux_send_message()` serialize sends to same session.

**Why:** Two subprocess calls (`send-keys -l text`, `send-keys Enter`) are not atomic. Without locking, concurrent sends to the same session corrupt each other.

### A pane shell's rc can eat or bury the launch line — never blind-sleep before send-keys

**Problem:** Three sibling incidents (2026-06-12, v1.1.1–v1.1.2): fish couldn't
parse the bash-syntax launch line (`unset: command not found` — claude dead at
birth); a slow zsh rc was still consuming stdin when the keystrokes arrived and
ate the whole line; an rc that prints, goes quiet, *then* `read`s stdin fools
any "is the prompt up yet" heuristic.

**Rule — the launch path has three layers, keep all of them:**
1. `make_pane_start_cmd()` wraps every sh-ism in `sh -c '...'` so ANY pane shell
   (bash/zsh/fish) can run the line.
2. `wait_for_pane_shell_ready()` gates the first keystroke on pane-content
   stability (10s cap, fail-open) — used by create AND revive. Never replace it
   with a blind `time.sleep()`.
3. `send_pane_start_cmd()` confirms via a sentinel touched right before `exec`,
   resending (max 2) only if the line was genuinely eaten. The confirmation
   window (`PANE_LAUNCH_CONFIRM_SECS`, default 20s) must outlast slow rc tails:
   while an rc runs, an *eaten* send and a *buffered* send are indistinguishable
   from outside, so TIME is the only safe discriminator — resending too early
   injects a junk copy into the freshly-started backend.

Regression tests: `test_pane_start_cmd_runs_in_real_shell_panes` (real bash/zsh/
fish panes), `..._survives_stdin_eating_rc`, `..._no_resend_into_running_backend`
(rerun with `PANE_LAUNCH_CONFIRM_SECS=8` to reproduce the old red).

### test.sh landmines (all stepped on for real)

**`set -e` kills the suite silently.** A bare `((x++))` returns 1 when x was 0;
a function whose last line is `cond && action` returns 1 when cond is false —
either aborts the whole run mid-suite. Write `((x++)) || true` and end branches
explicitly. `run_test` wraps each test, but helpers called OUTSIDE it are exposed.

**Never shadow the global counters.** `success()`/`fail()` increment globals
named `passed`/`failed`/`tests_run`. A `local failed=0` in a test silently
swallows the suite-level failure count (bash dynamic scoping). Pick other names.

**Fake `subprocess.run` makes `tmux_exists` lie.** A python mock that returns
rc=0 for everything makes `create_session` bail early with "Worker already
exists" — monkeypatch `bridge.tmux_exists = lambda *a: False` alongside. And per
the monkeypatch iron rule: patch bridge module attributes (`bridge.X = ...`),
never rebind imported copies.

**Opaque failures: instrument, don't guess.** Tests suppress stderr
(`2>/dev/null`) and `cleanup()` deletes `$BRIDGE_LOG` on exit, so a failing
integration test leaves no evidence. Temporarily patch the test's redirect to
`2>/tmp/dbg.err | tee /tmp/dbg.out`, and side-copy the bridge log while the run
is live (`for i in $(seq 1 120); do cp $BRIDGE_LOG /tmp/snap.log; sleep 0.5; done`
in parallel). Revert the patch after (`git checkout -- test.sh`).

**Time-window tests must prove they reach the branch under test.** A no-resend
test whose rc slept 6s against an 8s confirmation window never reached the
resend decision — green and worthless. Make the timings force the branch, and
keep a knob (`PANE_LAUNCH_CONFIRM_SECS=8`) that reproduces the old red.

### Known environmental flaky tests on this Linux box

**Problem:** Two tests fail on this box regardless of code version — re-triaging
them on every suite run wastes hours.

**Known list (verified against baseline/HEAD~1 worktree controls, 2026-06-12):**
- `Concurrent sends` (flock interleaving test): 0/25 delivered, fails even on
  known-good commits.
- `test_send_to_session_integration`: `/cd` fails to create tmain in the test
  bridge; fails identically on v1.1.1 and v1.1.2.

**Rule:** Before blaming a change for a suite failure, run the SAME filtered test
on the previous commit via a scratch worktree (`git worktree add /tmp/wt HEAD~1`,
symlink `.venv`, run, remove). Identical failure ⇒ environmental, proceed;
update this list when entries are fixed or new ones are proven.

### macOS vs Linux shell compatibility

**Problem:** GNU coreutils (Linux) and BSD coreutils (macOS) have different flags for the same operations.

**Common pitfalls:**
| Operation | Linux (GNU) | macOS (BSD) |
|-----------|-------------|-------------|
| File size | `stat -c %s file` | `stat -f%z file` |
| Milliseconds | `date +%s%3N` | Not supported (`%N` is GNU extension) |
| sed in-place | `sed -i 's/a/b/'` | `sed -i '' 's/a/b/'` |
| grep -P | Supported | Not supported (use `grep -E`) |

**Fix:** Always use portable alternatives or try-fallback pattern:
```bash
# Portable file size
size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

# Portable timing: use iteration counts instead of milliseconds
for i in $(seq 1 40); do sleep 0.05; done  # 2 seconds total
```

### Sed placeholders in conditionals

**Problem:** Template had conditional logic that referenced the placeholder being substituted:
```bash
NODE_NAME="__NODE_NAME__"
if [[ "$NODE_NAME" != "__NODE_NAME__" ]]; then  # Always false after sed!
```
After `sed -e "s|__NODE_NAME__|prod|g"`, condition becomes `"prod" != "prod"` → false.

**Fix:** Don't use conditionals in templates. Just bake values directly:
```bash
TMUX_PREFIX="__NODE_PREFIX__"   # Becomes "claude-prod-" after sed
SESSIONS_DIR="__NODE_SESSIONS_DIR__"
BRIDGE_PORT="__NODE_PORT__"
```

**Why:** Sed substitution is global. It replaces ALL occurrences of the pattern, including in comparison strings. Keep templates simple - no fallback logic needed since templates are never run directly.

**Prevention:**
1. Run `shellcheck` on all shell scripts
2. Test on macOS before merging (primary target platform)
3. Avoid GNU-specific extensions: `%N`, `stat -c`, `sed -i`, `grep -P`

### Test behavior, not scaffolding

*(Examples below are from the deleted multi-worker era — the principle is unchanged.)*

**Problem:** Tests verified structure (functions exist, HTTP returns OK) while a
worker subprocess was dying immediately — every check passed, the feature was
broken. Repeated in v1.1.1: a string-shape assertion on the launch line passed
while zsh panes killed claude at birth; only a real-pane behavior test caught it.

**Rule:** Tests must verify the behavior users care about, not that code exists.

```bash
# BAD - scaffolding: returns OK but the worker may already be dead
test_hire_command() { [[ $(curl -s /hire) == "OK" ]]; }

# GOOD - behavior: the session is STILL alive after creation
test_session_stays_alive() {
    curl -s /hire; sleep 3
    tmux has-session -t claude-test-worker
}
```

**Why this matters:** When tests pass but features are broken, you lose trust in the suite. Behavior tests catch real bugs; scaffolding tests give false confidence. Also give new tests a sensitivity proof: show the exact command that makes them red (a config knob, a reverted fix) — a test that can't go red proves nothing.
