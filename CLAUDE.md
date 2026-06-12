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

3. **Run acceptance tests** before committing:
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

**Problem:** The dev bridge died silently twice (2026-06-10 20:21, 2026-06-11 07:47):
last log line was a successful `POST /response`, then nothing — no shutdown banner,
no traceback. Forensics ruled out OOM/kernel kills (journal readable & empty),
graceful signals (SIGTERM/SIGINT print a banner since v0.4.0), the test suite
(it only ever kills :8295/:8096), and manual kills (shell history + transcripts clean).

**Root cause:** the bridge was launched under an interactive host — a foreground
`./claudecode-telegram.sh run` whose parent was a terminal/Claude-session shell.
When that host went away (terminal closed / session shell reclaimed), the whole
process group got SIGHUP/SIGKILL, which Python dies from **silently** (no handler
can run for SIGKILL; SIGHUP's default action prints nothing).

**Rule:** ALWAYS launch the bridge fully detached so no host teardown can reach it:
```bash
setsid bash -c '... exec ./.venv/bin/python -u bridge.py >> "$NODE/bridge.log" 2>&1' \
  </dev/null >/dev/null 2>&1 &
```
Verify afterwards: the bridge's PPID must be 1. Every setsid-launched restart since
leaves a clean `Received SIGTERM` banner on shutdown — the silent-death mode is
extinct unless someone launches it attached again.

**Verifying a restart:** don't trust `curl` — the OLD bridge's graceful shutdown
sends notifications over the network and holds the port for tens of seconds, so
curl returns `000` while everything is fine. Poll `ss -ltnp | grep :<port>` for
the NEW pid, then `tail bridge.log` for the startup banner.

### NEVER use pkill on multi-node setups

**Problem:** `pkill -f cloudflared` or `pkill -f bridge.py` kills ALL matching processes across ALL nodes, not just the target node.

**Rule:** ALWAYS use PID-based killing, NEVER pattern-based.

```bash
# WRONG - kills ALL nodes
pkill -f cloudflared
pkill -f bridge.py

# WRONG - kills without knowing which node owns the port
lsof -ti :8271 | xargs kill

# RIGHT - use specific PID from file
kill $(cat ~/.claude/telegram/nodes/prod/pid)

# RIGHT - use the script's stop command
./claudecode-telegram.sh --node prod stop
```

**Why this matters:** Production runs multiple nodes (prod, dev, test) simultaneously. Pattern-based killing causes collateral damage to other running nodes.

### Verify port ownership before killing

**Problem:** Ran `lsof -ti :8271 | xargs kill` thinking it was dev node, but port 8271 = prod. Killed production bridge while team was working.

**Script defaults (overridable via `--port` or `PORT` env var):**
| Default Port | Node | Sandbox |
|--------------|------|---------|
| 8270 | sandbox (or custom) | `--sandbox` |
| 8271 | **prod** | `--no-sandbox` |
| 8272 | dev | `--no-sandbox` |
| 8295 | test (test.sh) | `--no-sandbox` |

Ports are dynamic — **the defaults lie in practice** (e.g. this Linux box runs
the dev node on **8270**). Always check the live owner first:
```bash
ss -ltnp | grep ':82'           # who actually listens, with PID
cat ~/.claude/telegram/nodes/*/port 2>/dev/null   # if port files exist
```

**Why `--no-sandbox` for prod/dev/test?** Docker overhead is too slow. Sandbox node is for untrusted/experimental code.

**Rule:** Before killing any port, verify which node owns it:
```bash
# Check what's running on a port BEFORE killing
cat ~/.claude/telegram/nodes/*/port  # See actual port assignments

# Or check specific node
cat ~/.claude/telegram/nodes/prod/port
```

**Why:** Ports can be overridden, so never assume a port belongs to a specific node. Always verify before destructive operations.

### Node credentials live in ~/.config/claudecode-telegram/

**Problem:** During a prod restart, wasted time extracting the bot token from `/proc/<pid>/environ` when it was already stored in a config file.

**Rule:** Token env files are at `~/.config/claudecode-telegram/<node>.env`. Use them for restarts:
```bash
# Load token and restart prod
source ~/.config/claudecode-telegram/prod.env
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" ./claudecode-telegram.sh --node prod --no-sandbox run
```

The pattern is `~/.config/claudecode-telegram/<node>.env` — one file per node
that runs on that machine (this Linux box currently has only `dev.env`; a
machine hosting prod has `prod.env`, etc.).

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

**Problem:** Tests verified structure (functions exist, HTTP returns OK) but not actual behavior. A non-interactive worker subprocess was dying immediately, but tests passed because they only checked:
- `test_bridge_starts` → bridge starts
- `test_hire_command` → HTTP returns "OK"
- `test_send_to_worker_function_exists` → functions exist

None of these verified that the worker actually stayed running or could receive messages.

**Rule:** Tests must verify the actual behavior users care about, not just that code structure exists.

```bash
# BAD - tests scaffolding
test_bridge_starts() {
    curl -s /health >/dev/null  # 200 OK, but doesn't prove workers run
}

test_hire_command() {
    [[ $(curl -s /hire) == "OK" ]]  # Returns OK but worker may have died!
}

test_send_to_worker_function_exists() {
    python3 -c "from bridge import send_to_worker; assert callable(send_to_worker)"
}

# GOOD - tests behavior
test_tmux_mode_session_stays_alive() {
    curl -s /hire  # Create worker
    sleep 3        # Wait a bit
    # Verify worker/session is STILL running, not just that it started
    tmux has-session -t claude-test-worker
}

test_worker_to_worker_pipe() {
    # Verify inter-worker pipe messages are delivered end-to-end
    assert_no_log "Cannot forward pipe message"
}
```

**Why this matters:** When tests pass but features are broken, you waste time debugging and lose trust in the test suite. Behavior tests catch real bugs; scaffolding tests give false confidence.
