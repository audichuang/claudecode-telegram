#!/usr/bin/env python3
"""Claude Code <-> Telegram Bridge - Multi-Session Control Panel"""

VERSION = "1.0.0"

import os
import json
import hashlib
import mimetypes
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import re
import urllib.error
import urllib.request
import shlex
from html.parser import HTMLParser
from urllib.parse import urlparse, parse_qs
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Optional

try:
    from gmail_connector import GmailConnector
    GMAIL_IMPORT_ERROR = None
except ImportError as e:
    GmailConnector = None
    GMAIL_IMPORT_ERROR = e

try:
    from github_connector import GitHubConnector
    GITHUB_IMPORT_ERROR = None
except ImportError as e:
    GitHubConnector = None
    GITHUB_IMPORT_ERROR = e


# ============================================================
# CONFIGURATION
# ============================================================

class ReuseAddrServer(ThreadingHTTPServer):
    """HTTP server with SO_REUSEADDR to avoid 'Address already in use' on restart."""
    allow_reuse_address = True

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")

# Node-derived config: NODE_NAME drives defaults for PORT, TMUX_PREFIX, SESSIONS_DIR.
# Explicit env vars always override. No NODE_NAME = original defaults.
NODE_NAME = os.environ.get("NODE_NAME", "")
_DEFAULT_PORTS = {"prod": 8271, "dev": 8272, "test": 8295}

if NODE_NAME and not os.environ.get("PORT"):
    PORT = _DEFAULT_PORTS.get(NODE_NAME, 8270)
else:
    PORT = int(os.environ.get("PORT", "8270"))

gmail_connector_instance = None  # initialized in main()
github_connector_instance = None  # initialized in main()

BRIDGE_BIND = os.environ.get("BRIDGE_BIND", "127.0.0.1")  # Bind address (localhost-only by default)
WEBHOOK_SECRET = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "")  # Optional webhook verification

if NODE_NAME and not os.environ.get("SESSIONS_DIR"):
    SESSIONS_DIR = Path.home() / ".claude" / "telegram" / "nodes" / NODE_NAME / "sessions"
else:
    SESSIONS_DIR = Path(os.environ.get("SESSIONS_DIR", Path.home() / ".claude" / "telegram" / "sessions"))

if NODE_NAME and not os.environ.get("TMUX_PREFIX"):
    TMUX_PREFIX = f"claude-{NODE_NAME}-"
else:
    TMUX_PREFIX = os.environ.get("TMUX_PREFIX", "claude-")  # tmux session prefix for isolation
CLAUDE_DIR = Path(os.environ.get("CLAUDE_DIR", Path.home() / ".claude"))
CLAUDE_SETTINGS_FILE = Path(os.environ.get("CLAUDE_SETTINGS_FILE", CLAUDE_DIR / "settings.json"))


# BRIDGE_URL: hook callback target. Localhost URLs are always derived from PORT to
# prevent stale-port inheritance when restarting. Only non-localhost URLs (for
# distributed setups, e.g. https://remote-bridge.example.com) are honored from env.
_bridge_url_env = os.environ.get("BRIDGE_URL", "").rstrip("/")
if _bridge_url_env and not _bridge_url_env.startswith(("http://localhost", "http://127.0.0.1")):
    BRIDGE_URL = _bridge_url_env
else:
    BRIDGE_URL = f"http://localhost:{PORT}"
# BRIDGE_PUBLIC_URL: public URL for viewer links (/pr-review, /rewind transcript, /team-chat)
# When set and BRIDGE_BIND is not explicitly set, auto-bind to 0.0.0.0
# Auto-detect from Tailscale IP if not explicitly set.
BRIDGE_PUBLIC_URL = os.environ.get("BRIDGE_PUBLIC_URL", "").rstrip("/")
if not BRIDGE_PUBLIC_URL:
    try:
        _ts_ip = subprocess.run(
            ["tailscale", "ip", "-4"], capture_output=True,
            text=True, timeout=3).stdout.strip()
        if _ts_ip:
            BRIDGE_PUBLIC_URL = f"http://{_ts_ip}:{PORT}"
    except Exception:
        pass
if BRIDGE_PUBLIC_URL and not os.environ.get("BRIDGE_BIND"):
    BRIDGE_BIND = "0.0.0.0"
PERSISTENCE_NOTE = "They'll stay on your team."

# Voice mode: STT (speech-to-text) and TTS (text-to-speech) endpoints
# STT: transcribe incoming voice messages so workers can read them
# TTS: generate voice from worker text responses (explicit [[speak]] tag)
STT_ENDPOINT = os.environ.get("STT_ENDPOINT", "http://100.126.187.125:10110/transcribe")
TTS_ENDPOINT = os.environ.get("TTS_ENDPOINT", "http://100.126.187.125:10111/synthesize")
TTS_VOICE = os.environ.get("TTS_VOICE", "Serena")
STT_TIMEOUT = int(os.environ.get("STT_TIMEOUT", "10"))  # seconds, fail-open
TTS_TIMEOUT = int(os.environ.get("TTS_TIMEOUT", "60"))  # seconds, TTS runs in background thread
TTS_CHUNKED_THRESHOLD = 200  # chars: above this, use /synthesize/chunked endpoint

# API endpoint registry — used by index, 404 handler, and worker instructions.
# Update this when adding new endpoints.
API_ENDPOINTS = {
    "GET /": "API index — lists all endpoints",
    "GET /workers": "List active workers with send commands",
    "GET /checkin?name=<name>": "Refresh worker instructions (optional: &cwd=/path)",
    "GET /health/workers": "Watchdog state for all workers",
    "GET /transcript/<name>": "Polished HTML transcript viewer for a worker",
    "GET /team-chat": "Team Telegram chat viewer (requires rewind token)",
    "GET /pr-review/<pr_num>": "PR review viewer with diff, search, file navigation",
    "POST /response": "Hook: send Claude response to Telegram",
    "POST /notify": "Send notification to all admin chats",
}

# Sandbox mode: run Claude Code in Docker container for isolation
# CLI flags: --sandbox, --sandbox-image, --mount, --mount-ro
# Default: mounts ~ to /workspace (rw)
SANDBOX_ENABLED = os.environ.get("SANDBOX_ENABLED", "0") == "1"
SANDBOX_IMAGE = os.environ.get("SANDBOX_IMAGE", "claudecode-telegram:latest")
# Extra mounts from CLI: list of (host_path, container_path, readonly)
# Parsed from SANDBOX_MOUNTS env var: "/host:/container,/path,ro:/secrets:/secrets"
SANDBOX_EXTRA_MOUNTS = []
_mounts_env = os.environ.get("SANDBOX_MOUNTS", "")
if _mounts_env:
    for mount_spec in _mounts_env.split(","):
        mount_spec = mount_spec.strip()
        if not mount_spec:
            continue
        readonly = mount_spec.startswith("ro:")
        if readonly:
            mount_spec = mount_spec[3:]
        if ":" in mount_spec:
            host, container = mount_spec.split(":", 1)
        else:
            host = container = mount_spec
        SANDBOX_EXTRA_MOUNTS.append((host, container, readonly))

# Derive node name from TMUX_PREFIX for per-node isolation in /tmp
# "claude-test-" -> "test", "claude-" -> "default"
_node_name = TMUX_PREFIX.strip("-").removeprefix("claude-") or "default"

# Temporary file inbox (session-isolated, auto-cleaned)
FILE_INBOX_ROOT = Path(f"/tmp/claudecode-telegram/{_node_name}")

DEFAULT_BACKEND = "claude"
DEFAULT_WORKER_BACKEND = DEFAULT_BACKEND
PENDING_TIMEOUT = 600

# Gmail connector: poll Gmail for manager emails with @worker mentions
GMAIL_ENABLED = os.environ.get("GMAIL_ENABLED", "0") == "1"
GMAIL_POLL_INTERVAL = int(os.environ.get("GMAIL_POLL_INTERVAL", "45"))
GMAIL_FROM_FILTER = os.environ.get("GMAIL_FROM_FILTER", "ngocthinhdp@gmail.com")
GMAIL_GWS_BIN = os.environ.get("GMAIL_GWS_BIN", os.path.expanduser("~/bin/gws"))
if GMAIL_ENABLED and not GMAIL_FROM_FILTER.strip():
    raise RuntimeError("GMAIL_FROM_FILTER must be set when GMAIL_ENABLED=1 (security: sender filter required)")

GITHUB_ENABLED = os.environ.get("BRIDGE_GHPOLL_ENABLED", "0") == "1"
GITHUB_POLL_INTERVAL = int(os.environ.get("BRIDGE_GHPOLL_INTERVAL", "60"))
GITHUB_REPO = os.environ.get("BRIDGE_GHPOLL_REPO", "BasedHardware/omi")
GITHUB_FROM_USER = os.environ.get("BRIDGE_GHPOLL_USER", "beastoin")
if GITHUB_ENABLED and not GITHUB_FROM_USER.strip():
    raise RuntimeError("BRIDGE_GHPOLL_USER must be set when BRIDGE_GHPOLL_ENABLED=1 (security: sender filter required)")

# Team directory: shared knowledge base (soul docs, kanban, playbook, etc.)
TEAM_DIR = os.path.expanduser(os.environ.get("TEAM_DIR", "~/team"))
# Checkin note: read from TEAM_DIR/checkin-note.txt on each checkin/hire/restart.
# Supports {name} placeholder for per-worker substitution.
_CHECKIN_NOTE_PATH = os.path.join(TEAM_DIR, "checkin-note.txt")
WATCHDOG_INTERVAL = 4
START_GRACE = 30
THINK_GRACE = 30
TOOL_GAP_GRACE = 12
STALE_PENDING = 900  # 15 minutes
CPU_ACTIVE = 15.0
CPU_IDLE = 7.0
IDLE_STREAK_STUCK = 3
ALERT_COOLDOWN = 180


# ============================================================
# CORE: Backend implementation
# ============================================================

def build_claude_start_cmd(resume_id: str = "") -> str:
    cmd = ["claude"]
    if resume_id:
        cmd.extend(["--resume", resume_id])
    cmd.append("--dangerously-skip-permissions")
    return " ".join(shlex.quote(part) for part in cmd)


# ─────────────────────────────────────────────────────────────────────────────
# Shared tmux helpers (used by multiple backends)
# ─────────────────────────────────────────────────────────────────────────────

# Per-session locks to prevent concurrent tmux sends from interleaving
_tmux_send_locks = {}
_tmux_send_locks_guard = threading.Lock()

# Per-session flock file descriptors (kept open for the process lifetime)
_tmux_send_flock_fds = {}


def _get_tmux_send_lock(tmux_name: str):
    """Get or create a lock for a specific tmux session."""
    with _tmux_send_locks_guard:
        if tmux_name not in _tmux_send_locks:
            _tmux_send_locks[tmux_name] = threading.Lock()
        return _tmux_send_locks[tmux_name]


def tmux_send_lock_path(tmux_name: str) -> Path:
    """Return the flock file path for a tmux session. Node-namespaced."""
    return Path(f"/tmp/claudecode-telegram/{_node_name}/locks/{tmux_name}.lock")


def _acquire_flock(tmux_name: str) -> int:
    """Acquire a cross-process flock for a tmux session. Returns fd."""
    lock_file = tmux_send_lock_path(tmux_name)
    lock_file.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_file), os.O_CREAT | os.O_RDWR, 0o600)
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _release_flock(fd: int):
    """Release a cross-process flock."""
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def tmux_exists(tmux_name: str) -> bool:
    """Check if tmux session exists."""
    return subprocess.run(
        ["tmux", "has-session", "-t", tmux_name],
        capture_output=True
    ).returncode == 0


def tmux_send_message(tmux_name: str, text: str) -> bool:
    """Send text + Enter to tmux session via paste-buffer (reliable for long messages).

    Uses tmux load-buffer/paste-buffer instead of send-keys -l to avoid
    character-by-character terminal injection which causes input batching
    on long messages or rapid sends.

    Two-layer locking:
    1. Python threading.Lock — serializes sends within this process
    2. flock on a per-session file — serializes sends across processes
       (workers sending via tmux directly use the same lock file)
    """
    lock = _get_tmux_send_lock(tmux_name)
    with lock:
        flock_fd = _acquire_flock(tmux_name)
        try:
            buf_name = f"msg-{uuid.uuid4().hex[:8]}"

            fd, tmpfile = tempfile.mkstemp(suffix=".msg", prefix="tmux-send-")
            try:
                os.write(fd, text.encode())
                os.close(fd)
                r = subprocess.run(
                    ["tmux", "load-buffer", "-b", buf_name, tmpfile],
                    capture_output=True,
                )
            finally:
                try:
                    os.unlink(tmpfile)
                except OSError:
                    pass

            if r.returncode != 0:
                return False
            # Paste buffer into the target pane with proper bracketed paste
            # -p: send bracketed paste control codes (\e[200~ ... \e[201~)
            #     so TUI apps (Claude Code) know exactly where paste ends.
            #     Without -p, Enter sent after paste can be swallowed into
            #     the TUI's time-based paste detection window.
            # -r: preserve LF as LF (don't convert to CR). Keeps multi-line
            #     text as multi-line input, not line-by-line Enter presses.
            # -d: delete buffer after pasting
            r = subprocess.run(
                ["tmux", "paste-buffer", "-p", "-r", "-t", tmux_name, "-b", buf_name, "-d"],
                capture_output=True,
            )
            if r.returncode != 0:
                return False
            # Delay after paste: TUI needs time to process paste-end marker
            # and re-render. At low context (1%), Claude Code TUI can take
            # 300-1000ms to render pasted text. Enter sent before render
            # completes hits an empty prompt and the message is silently lost.
            # 50ms → 150ms → 1s: increased after observing silent message
            # loss on prod sessions with heavy context load.
            time.sleep(1.0)
            # Send Enter to submit the pasted text
            r = subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Enter"])
            return r.returncode == 0
        finally:
            _release_flock(flock_fd)


def get_pane_command(tmux_name: str) -> str:
    """Get the current command running in tmux pane."""
    result = subprocess.run(
        ["tmux", "display-message", "-t", tmux_name, "-p", "#{pane_current_command}"],
        capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def is_process_running(tmux_name: str, process_name: str) -> bool:
    """Check if a process is running in tmux session."""
    cmd = get_pane_command(tmux_name)
    if process_name.lower() in cmd.lower():
        return True

    result = subprocess.run(
        ["tmux", "display-message", "-t", tmux_name, "-p", "#{pane_pid}"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return False

    pane_pid = result.stdout.strip()
    if not pane_pid:
        return False

    result = subprocess.run(
        ["pgrep", "-P", pane_pid, process_name],
        capture_output=True
    )
    return result.returncode == 0


def tmux_send_escape(tmux_name: str):
    subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Escape"])


def _tmux_pane_pids() -> dict:
    """Return a map of tmux session_name -> pane_pid for all panes."""
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{session_name} #{pane_pid}"],
            capture_output=True, text=True, timeout=5
        )
    except Exception:
        return {}

    if result.returncode != 0:
        return {}

    pane_map = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        session_name, pane_pid = parts[0], parts[1]
        if pane_pid.isdigit():
            pane_map[session_name] = pane_pid
    return pane_map


def _get_claude_pid(pane_pid: str) -> Optional[str]:
    """Return Claude PID for a pane, or None if not found."""
    try:
        result = subprocess.run(
            ["pgrep", "-P", str(pane_pid), "-f", "claude"],
            capture_output=True, text=True, timeout=5
        )
    except Exception:
        return None

    if result.returncode != 0:
        return None

    output = result.stdout.strip().splitlines()
    if not output:
        return None
    return output[0].strip()


def _child_count(pid: str) -> int:
    """Return child process count for pid."""
    if not pid:
        return 0
    try:
        result = subprocess.run(
            ["pgrep", "-P", str(pid)],
            capture_output=True, text=True, timeout=5
        )
    except Exception:
        return 0

    if result.returncode != 0:
        return 0

    return len([line for line in result.stdout.splitlines() if line.strip()])


def _ps_stats(pids) -> dict:
    """Return {pid: {'cpu': float, 'state': str}} for given pids."""
    pid_list = [str(pid) for pid in pids if pid]
    if not pid_list:
        return {}

    try:
        result = subprocess.run(
            ["ps", "-o", "pid=,%cpu=,state=", "-p", ",".join(pid_list)],
            capture_output=True, text=True, timeout=5
        )
    except Exception:
        return {}

    if result.returncode != 0:
        return {}

    stats = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 3:
            continue
        pid = parts[0]
        try:
            cpu = float(parts[1])
        except ValueError:
            cpu = 0.0
        state = parts[2]
        stats[pid] = {"cpu": cpu, "state": state}
    return stats


def mark_hook_event(session_name: str) -> None:
    """Record timestamp of last hook response for a session."""
    with _watchdog_lock:
        _last_hook_ts[session_name] = time.time()


class ClaudeBackend:
    """Claude Code CLI - interactive mode with hook for responses."""
    name = "claude"
    binary = "claude"

    def start_cmd(self, resume_id: str = "") -> str:
        return build_claude_start_cmd(resume_id)

    def send(self, worker_name: str, tmux_name: str, text: str,
             bridge_url: str, sessions_dir: Path) -> bool:
        if not tmux_exists(tmux_name):
            return False
        return tmux_send_message(tmux_name, text)

    def is_online(self, tmux_name: str) -> bool:
        if not tmux_exists(tmux_name):
            return False
        return is_process_running(tmux_name, "claude")


# Claude is the only backend (codex/gemini/opencode adapters removed in v1.0.0).
BACKENDS = {
    "claude": ClaudeBackend(),
}

def get_backend(name: str) -> ClaudeBackend:
    return BACKENDS.get(name, BACKENDS[DEFAULT_BACKEND])


def is_valid_backend(name: str) -> bool:
    return name in BACKENDS


def list_backends() -> list[str]:
    return list(BACKENDS.keys())


def _which_binary(binary: str) -> str | None:
    """Find binary in PATH, including common user install locations.

    The bridge may run with a minimal PATH (e.g. via env -i), missing
    ~/.local/bin or ~/bin where claude/codex are typically installed.
    """
    found = shutil.which(binary)
    if found:
        return found
    home = os.environ.get("HOME", "")
    if home:
        for extra_dir in [os.path.join(home, ".local", "bin"), os.path.join(home, "bin")]:
            candidate = os.path.join(extra_dir, binary)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
    return None


def is_claude_running(tmux_name: str) -> bool:
    return is_process_running(tmux_name, "claude")


# In-memory state (RAM only, no persistence - tmux IS the persistence).
# No "active/focused" entry: the 話題 a message arrives in IS the addressing.
state = {
    "startup_notified": False,  # Whether we've sent the startup message
    "tts_enabled": False,  # Auto-TTS for worker responses (toggle with /voice)
}

# Consecutive @mention tracking (auto-focus after 2 in a row to same worker)

# Watchdog state
_worker_states = {}  # name -> (state, reason, since)
_last_child_ts = {}
_last_seen_claude = {}
_last_hook_ts = {}
_last_alert_ts = {}
_alert_msg_ids = {}  # name -> message_id of last bad-state alert (for edit on recovery)
_idle_streak = {}
_prev_worker_states = {}
_consecutive_probe_failures = {}
_consecutive_good_probes = {}  # name -> int (consecutive good states after bad)
_idle_child_baseline = {}  # name -> int (MCP server child count at idle)
_prev_children = {}  # name -> int (previous active children count, for activity detection)
_last_activity_ts = {}  # name -> float (last time children count changed)
_worker_cwds = {}  # name -> cwd (RAM-only startup cwd hints)
_recent_restarts = {}  # name -> timestamp (suppress watchdog resolved alert after restart)
RESTART_COOLDOWN = 60  # seconds: reject checkin-triggered restarts within this window
_restart_in_progress = {}  # name -> timestamp: set BEFORE restart, cleared after completion
_restart_lock = threading.Lock()  # protects _restart_in_progress
_force_restart_pending_cwd = {}  # name -> True: force restart completed, allow one post-restart CWD fix
_waiting_input_details = {}  # name -> dict (question details for WAITING_INPUT alert)
_watchdog_lock = threading.Lock()

# Security: Pre-set admin or auto-learn first user (RAM only, re-learns on restart)
ADMIN_CHAT_ID_ENV = os.environ.get("ADMIN_CHAT_ID", "")
admin_chat_id = int(ADMIN_CHAT_ID_ENV) if ADMIN_CHAT_ID_ENV else None

# Persistence files (in node directory, survives restart)
NODE_DIR = SESSIONS_DIR.parent  # ~/.claude/telegram/nodes/<node>
LAST_CHAT_ID_FILE = NODE_DIR / "last_chat_id"

# Claude Code stores transcripts at ~/.claude/projects/<slug>/<uuid>.jsonl.
# Overridable in tests.
CLAUDE_PROJECTS_DIR = Path(os.path.expanduser("~/.claude/projects"))

# Rewind tokens: {token_str: {"name": worker, "expires_at": timestamp}}
REWIND_TOKENS = {}
PR_REVIEW_TOKENS = {}
REWIND_TIMEOUT = 5 * 60  # 5 minutes

# Tombstones for the removed multi-worker orchestration era: typing one of
# these in a 話題 gets a short hint instead of leaking to the worker as text.
TOPIC_LEGACY_CMDS = {
    "/hire", "/focus", "/team", "/end", "/progress", "/pause", "/restart",
}
# Global commands that behave the same inside a 話題 — delegated to handle_command.
TOPIC_GLOBAL_CMDS = {"/memory", "/voice", "/settings", "/rewind", "/pr"}
# The slimmed command menu advertised to users in TOPIC_MODE.
TOPIC_BOT_COMMANDS = [
    {"command": "cd", "description": "切換這個話題的工作資料夾: /cd <path>"},
    {"command": "close", "description": "結束這個話題的工作階段"},
    {"command": "memory", "description": "搜尋團隊記憶: /memory <query>"},
    {"command": "quota", "description": "顯示用量"},
    {"command": "voice", "description": "切換語音回覆: /voice on|off"},
    {"command": "settings", "description": "顯示設定"},
    {"command": "rewind", "description": "逐字稿檢視: /rewind"},
    {"command": "pr", "description": "PR 檢視: /pr <github_pr_url>"},
]

BLOCKED_COMMANDS = [
    "/mcp", "/help", "/config", "/model", "/compact", "/cost",
    "/doctor", "/init", "/login", "/logout", "/permissions",
    "/pr", "/review", "/terminal", "/vim", "/approved-tools", "/listen"
]


# ============================================================
# FILE PERSISTENCE
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Persistence (last chat ID and last active worker survive restart)
# ─────────────────────────────────────────────────────────────────────────────

def save_last_chat_id(chat_id):
    """Save last known chat ID to file for auto-notification on restart."""
    try:
        NODE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        LAST_CHAT_ID_FILE.write_text(str(chat_id))
        LAST_CHAT_ID_FILE.chmod(0o600)
    except Exception as e:
        print(f"Failed to save last_chat_id: {e}")


def load_last_chat_id():
    """Load last known chat ID from file."""
    try:
        if LAST_CHAT_ID_FILE.exists():
            chat_id = LAST_CHAT_ID_FILE.read_text().strip()
            if chat_id:
                return int(chat_id)
    except Exception as e:
        print(f"Failed to load last_chat_id: {e}")
    return None


# ─────────────────────────────────────────────────────────────────────────────
# Persistent Worker Registry
# ─────────────────────────────────────────────────────────────────────────────

WORKER_REGISTRY_FILE = NODE_DIR / "workers.json"


def _load_registry() -> dict:
    """Load worker registry from disk. Returns {} on missing/corrupt."""
    try:
        if not WORKER_REGISTRY_FILE.exists():
            return {}
        raw = WORKER_REGISTRY_FILE.read_text()
        data = json.loads(raw)
        if not isinstance(data, dict) or "workers" not in data:
            raise ValueError("invalid registry format")
        return data
    except Exception as e:
        if WORKER_REGISTRY_FILE.exists():
            corrupt_path = WORKER_REGISTRY_FILE.with_suffix(f".corrupt.{int(time.time())}")
            print(f"Corrupt worker registry, renaming to {corrupt_path}: {e}")
            try:
                WORKER_REGISTRY_FILE.rename(corrupt_path)
            except Exception:
                pass
        return {}


def _save_registry(data: dict):
    """Atomic write of registry to disk."""
    try:
        NODE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp_fd, tmp_path = tempfile.mkstemp(dir=str(NODE_DIR), suffix=".tmp")
        try:
            with os.fdopen(tmp_fd, "w") as f:
                json.dump(data, f)
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, str(WORKER_REGISTRY_FILE))
        except Exception:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass
            raise
    except Exception as e:
        print(f"Failed to save worker registry: {e}")


def _registry_add(name: str, backend: str, chat_id: int = None):
    """Add a worker to the persistent registry."""
    with _watchdog_lock:
        data = _load_registry()
        if "workers" not in data:
            data = {"version": 1, "workers": {}}
        entry = {
            "backend": backend,
            "chat_id": chat_id,
            "hire_time": int(time.time()),
        }
        data["workers"][name] = entry
        _save_registry(data)


def _registry_remove(name: str):
    """Remove a worker from the persistent registry."""
    with _watchdog_lock:
        data = _load_registry()
        if "workers" not in data:
            return
        data["workers"].pop(name, None)
        _save_registry(data)


def _set_worker_cwd(name: str, cwd: str):
    """Set startup cwd hint for a worker in RAM."""
    normalized = normalize_cwd(cwd)
    with _watchdog_lock:
        if normalized:
            _worker_cwds[name] = normalized
        else:
            _worker_cwds.pop(name, None)


def _get_worker_cwd(name: str) -> str:
    """Get startup cwd hint for a worker from RAM."""
    with _watchdog_lock:
        cwd = _worker_cwds.get(name)
    return cwd if isinstance(cwd, str) else ""


def _registry_bootstrap(registered: dict):
    """First-run: create registry from currently running tmux sessions."""
    if WORKER_REGISTRY_FILE.exists():
        return
    if not registered:
        return
    data = {"version": 1, "workers": {}}
    for name, session in registered.items():
        backend = normalize_backend(session.get("backend"))
        data["workers"][name] = {
            "backend": backend,
            "chat_id": None,
            "hire_time": int(time.time()),
        }
    _save_registry(data)
    print(f"Registry bootstrapped with {len(registered)} workers: {', '.join(registered.keys())}")


def read_checkin_note():
    """Read checkin note from file. Returns empty string if file missing."""
    try:
        path = _CHECKIN_NOTE_PATH
        if os.path.isfile(path):
            text = open(path).read().strip()
            if text:
                return text
    except Exception as e:
        print(f"Failed to read checkin note from {_CHECKIN_NOTE_PATH}: {e}")
    return ""


# Reserved names that cannot be used as worker names (would clash with commands)
RESERVED_NAMES = {
    # Bridge commands
    "team", "focus", "progress", "pause", "restart", "settings", "hire", "end",
    # Special
    "all", "cancel", "start", "help",
}


# ============================================================
# MESSAGE TRANSPORT ABSTRACTION
# ============================================================

TRANSPORT_MODE = os.environ.get("TRANSPORT", "telegram")


class MessageTransport:
    """Interface for all outbound messaging from bridge to manager."""

    @property
    def name(self) -> str:
        raise NotImplementedError

    def send_text(self, chat_id, text, parse_mode=None, reply_to=None, message_thread_id=None) -> dict | None:
        raise NotImplementedError

    def send_photo(self, chat_id, photo_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_document(self, chat_id, doc_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_animation(self, chat_id, animation_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_video(self, chat_id, video_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_audio(self, chat_id, audio_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_voice(self, chat_id, voice_path, caption=None, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_sticker(self, chat_id, sticker_path, message_thread_id=None) -> bool:
        raise NotImplementedError

    def send_chat_action(self, chat_id, action, message_thread_id=None) -> None:
        raise NotImplementedError

    def set_reaction(self, chat_id, message_id, reaction) -> None:
        raise NotImplementedError

    def edit_message(self, chat_id, message_id, text, parse_mode=None) -> dict | None:
        raise NotImplementedError

    def setup_commands(self, commands) -> None:
        raise NotImplementedError

    def download_file(self, file_id, session_name) -> str | None:
        raise NotImplementedError


# ============================================================
# TELEGRAM API
# ============================================================

class TelegramAPI:
    def __init__(self, token: str):
        self.token = token

    def api(self, method: str, data: dict):
        if not self.token:
            return None
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{self.token}/{method}",
            data=json.dumps(data).encode(),
            headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            print(f"Telegram API error: {e}")
            try:
                raw = e.read()
                body = json.loads(raw)
                return body  # Return error response so callers can inspect description
            except Exception:
                # Non-JSON error body (proxy, middlebox, empty) — return structured error
                return {"ok": False, "error_code": e.code, "description": f"HTTP {e.code} (non-JSON body)"}
        except Exception as e:
            print(f"Telegram API error: {e}")
            return None

    def send_message(self, chat_id: int, text: str, **kwargs):
        payload = {"chat_id": chat_id, "text": text}
        payload.update(kwargs)
        return self.api("sendMessage", payload)

    def send_photo(self, chat_id: int, photo, **kwargs):
        payload = {"chat_id": chat_id, "photo": photo}
        payload.update(kwargs)
        return self.api("sendPhoto", payload)

    def send_document(self, chat_id: int, document, **kwargs):
        payload = {"chat_id": chat_id, "document": document}
        payload.update(kwargs)
        return self.api("sendDocument", payload)

    def send_animation(self, chat_id: int, animation, **kwargs):
        payload = {"chat_id": chat_id, "animation": animation}
        payload.update(kwargs)
        return self.api("sendAnimation", payload)

    def set_reaction(self, chat_id: int, message_id: int, reaction: list[dict]):
        payload = {"chat_id": chat_id, "message_id": message_id, "reaction": reaction}
        return self.api("setMessageReaction", payload)

    def send_chat_action(self, chat_id: int, action: str, message_thread_id=None):
        payload = {"chat_id": chat_id, "action": action}
        if message_thread_id is not None:
            payload["message_thread_id"] = message_thread_id
        return self.api("sendChatAction", payload)


class TelegramTransport(MessageTransport):
    """Transport that sends messages via Telegram Bot API."""

    def __init__(self, token: str = ""):
        self._api = TelegramAPI(token)

    @property
    def name(self) -> str:
        return "telegram"

    def send_text(self, chat_id, text, parse_mode=None, reply_to=None, message_thread_id=None) -> dict | None:
        payload = {"chat_id": chat_id, "text": text}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        if reply_to:
            payload["reply_to_message_id"] = reply_to
        if message_thread_id is not None:
            payload["message_thread_id"] = message_thread_id
        # Use module-level telegram_api so tests can mock bridge.telegram_api
        return telegram_api("sendMessage", payload)

    def send_photo(self, chat_id, photo_path, caption=None, message_thread_id=None) -> bool:
        if not BOT_TOKEN:
            return False
        ok, validated = validate_photo_path(photo_path)
        if not ok:
            print(validated)
            return False
        photo_path = validated
        boundary = uuid.uuid4().hex
        content_type = mimetypes.guess_type(str(photo_path))[0] or "image/jpeg"
        body_parts = []
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(b'Content-Disposition: form-data; name="chat_id"')
        body_parts.append(b"")
        body_parts.append(str(chat_id).encode())
        if message_thread_id:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="message_thread_id"')
            body_parts.append(b"")
            body_parts.append(str(message_thread_id).encode())
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(f'Content-Disposition: form-data; name="photo"; filename="{photo_path.name}"'.encode())
        body_parts.append(f"Content-Type: {content_type}".encode())
        body_parts.append(b"")
        body_parts.append(photo_path.read_bytes())
        if caption:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="caption"')
            body_parts.append(b"")
            body_parts.append(caption.encode())
        body_parts.append(f"--{boundary}--".encode())
        body_parts.append(b"")
        body = b"\r\n".join(body_parts)
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendPhoto",
                data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                result = json.loads(r.read())
                if result.get("ok"):
                    print(f"Photo sent: {photo_path.name}")
                    return True
                else:
                    print(f"sendPhoto failed: {result}")
                    return False
        except Exception as e:
            print(f"sendPhoto error: {e}")
            return False

    def send_animation(self, chat_id, animation_path, caption=None, message_thread_id=None) -> bool:
        if not BOT_TOKEN:
            return False
        ok, validated = validate_photo_path(animation_path)
        if not ok:
            print(validated)
            return False
        animation_path = validated
        boundary = uuid.uuid4().hex
        content_type = "video/mp4" if animation_path.suffix.lower() == ".mp4" else "image/gif"
        body_parts = []
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(b'Content-Disposition: form-data; name="chat_id"')
        body_parts.append(b"")
        body_parts.append(str(chat_id).encode())
        if message_thread_id:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="message_thread_id"')
            body_parts.append(b"")
            body_parts.append(str(message_thread_id).encode())
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(f'Content-Disposition: form-data; name="animation"; filename="{animation_path.name}"'.encode())
        body_parts.append(f"Content-Type: {content_type}".encode())
        body_parts.append(b"")
        body_parts.append(animation_path.read_bytes())
        if caption:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="caption"')
            body_parts.append(b"")
            body_parts.append(caption.encode())
        body_parts.append(f"--{boundary}--".encode())
        body_parts.append(b"")
        body = b"\r\n".join(body_parts)
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendAnimation",
                data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                result = json.loads(r.read())
                if result.get("ok"):
                    print(f"Animation sent: {animation_path.name}")
                    return True
                else:
                    print(f"sendAnimation failed: {result}")
                    return False
        except Exception as e:
            print(f"sendAnimation error: {e}")
            return False

    def send_document(self, chat_id, doc_path, caption=None, message_thread_id=None) -> bool:
        if not BOT_TOKEN:
            return False
        ok, validated = validate_document_path(doc_path)
        if not ok:
            print(validated)
            return False
        doc_path = validated
        boundary = uuid.uuid4().hex
        content_type = mimetypes.guess_type(str(doc_path))[0] or "application/octet-stream"
        body_parts = []
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(b'Content-Disposition: form-data; name="chat_id"')
        body_parts.append(b"")
        body_parts.append(str(chat_id).encode())
        if message_thread_id:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="message_thread_id"')
            body_parts.append(b"")
            body_parts.append(str(message_thread_id).encode())
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(f'Content-Disposition: form-data; name="document"; filename="{doc_path.name}"'.encode())
        body_parts.append(f"Content-Type: {content_type}".encode())
        body_parts.append(b"")
        body_parts.append(doc_path.read_bytes())
        if caption:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="caption"')
            body_parts.append(b"")
            body_parts.append(caption.encode())
        body_parts.append(f"--{boundary}--".encode())
        body_parts.append(b"")
        body = b"\r\n".join(body_parts)
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument",
                data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                result = json.loads(r.read())
                if result.get("ok"):
                    print(f"Document sent: {doc_path.name}")
                    return True
                else:
                    print(f"sendDocument failed: {result}")
                    return False
        except Exception as e:
            print(f"sendDocument error: {e}")
            return False

    def _send_media_multipart(self, chat_id, file_path, field_name, api_method, caption=None, message_thread_id=None) -> bool:
        if not BOT_TOKEN:
            return False
        boundary = uuid.uuid4().hex
        content_type = mimetypes.guess_type(str(file_path))[0] or "application/octet-stream"
        body_parts = []
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(b'Content-Disposition: form-data; name="chat_id"')
        body_parts.append(b"")
        body_parts.append(str(chat_id).encode())
        if message_thread_id:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="message_thread_id"')
            body_parts.append(b"")
            body_parts.append(str(message_thread_id).encode())
        body_parts.append(f"--{boundary}".encode())
        body_parts.append(f'Content-Disposition: form-data; name="{field_name}"; filename="{file_path.name}"'.encode())
        body_parts.append(f"Content-Type: {content_type}".encode())
        body_parts.append(b"")
        body_parts.append(file_path.read_bytes())
        if caption:
            body_parts.append(f"--{boundary}".encode())
            body_parts.append(b'Content-Disposition: form-data; name="caption"')
            body_parts.append(b"")
            body_parts.append(caption.encode())
        body_parts.append(f"--{boundary}--".encode())
        body_parts.append(b"")
        body = b"\r\n".join(body_parts)
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/{api_method}",
                data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                result = json.loads(r.read())
                if result.get("ok"):
                    print(f"{api_method} sent: {file_path.name}")
                    return True
                else:
                    print(f"{api_method} failed: {result}")
                    return False
        except Exception as e:
            print(f"{api_method} error: {e}")
            return False

    def send_video(self, chat_id, video_path, caption=None, message_thread_id=None) -> bool:
        ok, validated = validate_document_path(video_path)
        if not ok:
            print(validated)
            return False
        return self._send_media_multipart(chat_id, validated, "video", "sendVideo", caption, message_thread_id)

    def send_audio(self, chat_id, audio_path, caption=None, message_thread_id=None) -> bool:
        ok, validated = validate_document_path(audio_path)
        if not ok:
            print(validated)
            return False
        return self._send_media_multipart(chat_id, validated, "audio", "sendAudio", caption, message_thread_id)

    def send_voice(self, chat_id, voice_path, caption=None, message_thread_id=None) -> bool:
        ok, validated = validate_document_path(voice_path)
        if not ok:
            print(validated)
            return False
        return self._send_media_multipart(chat_id, validated, "voice", "sendVoice", caption, message_thread_id)

    def send_sticker(self, chat_id, sticker_path, message_thread_id=None) -> bool:
        sticker_path = Path(sticker_path)
        if not sticker_path.exists() or not sticker_path.is_file():
            print(f"Sticker not found: {sticker_path}")
            return False
        return self._send_media_multipart(chat_id, sticker_path, "sticker", "sendSticker", message_thread_id=message_thread_id)

    def send_chat_action(self, chat_id, action, message_thread_id=None) -> None:
        payload = {"chat_id": chat_id, "action": action}
        if message_thread_id is not None:
            payload["message_thread_id"] = message_thread_id
        telegram_api("sendChatAction", payload)

    def set_reaction(self, chat_id, message_id, reaction) -> None:
        telegram_api("setMessageReaction", {"chat_id": chat_id, "message_id": message_id, "reaction": reaction})

    def edit_message(self, chat_id, message_id, text, parse_mode=None) -> dict | None:
        payload = {"chat_id": chat_id, "message_id": message_id, "text": text}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        return telegram_api("editMessageText", payload)

    def setup_commands(self, commands) -> None:
        telegram_api("setMyCommands", {"commands": commands})

    def download_file(self, file_id, session_name) -> str | None:
        if not BOT_TOKEN:
            return None
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/getFile",
                data=json.dumps({"file_id": file_id}).encode(),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                result = json.loads(r.read())
                if not result.get("ok"):
                    print(f"getFile failed: {result}")
                    return None
                file_info = result.get("result", {})
        except Exception as e:
            print(f"getFile error: {e}")
            return None
        file_path = file_info.get("file_path")
        file_size = file_info.get("file_size", 0)
        if not file_path:
            print("No file_path in response")
            return None
        if file_size > MAX_FILE_SIZE:
            print(f"File too large: {file_size} > {MAX_FILE_SIZE}")
            return None
        download_url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"
        inbox = ensure_inbox_dir(session_name)
        ext = Path(file_path).suffix or ""
        local_filename = f"{uuid.uuid4().hex}{ext}"
        local_path = inbox / local_filename
        try:
            req = urllib.request.Request(download_url)
            with urllib.request.urlopen(req, timeout=60) as r:
                content = r.read()
                if len(content) > MAX_FILE_SIZE:
                    print(f"Downloaded file too large: {len(content)}")
                    return None
                local_path.write_bytes(content)
                local_path.chmod(0o600)
            print(f"Downloaded file: {local_path}")
            return str(local_path)
        except Exception as e:
            print(f"Download error: {e}")
            return None


class LocalTransport(MessageTransport):
    """Transport that logs messages to stdout. For testing without Telegram."""

    def __init__(self):
        self._log_file = os.environ.get("TRANSPORT_LOG", "")

    @property
    def name(self) -> str:
        return "local"

    def _log(self, method, chat_id, **kwargs):
        msg = f"[local-transport] {method} chat_id={chat_id}"
        for k, v in kwargs.items():
            if v is not None:
                msg += f" {k}={v}"
        print(msg)
        if self._log_file:
            with open(self._log_file, "a") as f:
                f.write(msg + "\n")

    def send_text(self, chat_id, text, parse_mode=None, reply_to=None, message_thread_id=None) -> dict | None:
        self._log("send_text", chat_id, text=text[:200], parse_mode=parse_mode)
        return {"ok": True, "result": {"message_id": 1}}

    def send_photo(self, chat_id, photo_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_photo", chat_id, path=photo_path, caption=caption)
        return True

    def send_document(self, chat_id, doc_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_document", chat_id, path=doc_path, caption=caption)
        return True

    def send_animation(self, chat_id, animation_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_animation", chat_id, path=animation_path, caption=caption)
        return True

    def send_video(self, chat_id, video_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_video", chat_id, path=video_path, caption=caption)
        return True

    def send_audio(self, chat_id, audio_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_audio", chat_id, path=audio_path, caption=caption)
        return True

    def send_voice(self, chat_id, voice_path, caption=None, message_thread_id=None) -> bool:
        self._log("send_voice", chat_id, path=voice_path, caption=caption)
        return True

    def send_sticker(self, chat_id, sticker_path, message_thread_id=None) -> bool:
        self._log("send_sticker", chat_id, path=sticker_path)
        return True

    def send_chat_action(self, chat_id, action, message_thread_id=None) -> None:
        self._log("send_chat_action", chat_id, action=action, message_thread_id=message_thread_id)

    def set_reaction(self, chat_id, message_id, reaction) -> None:
        self._log("set_reaction", chat_id, message_id=message_id)

    def edit_message(self, chat_id, message_id, text, parse_mode=None) -> dict | None:
        self._log("edit_message", chat_id, message_id=message_id, text=text[:200])
        return {"ok": True, "result": {"message_id": message_id}}

    def setup_commands(self, commands) -> None:
        self._log("setup_commands", 0, count=len(commands))

    def download_file(self, file_id, session_name) -> str | None:
        self._log("download_file", 0, file_id=file_id, session=session_name)
        return None


def _init_transport() -> MessageTransport:
    if TRANSPORT_MODE == "local":
        return LocalTransport()
    return TelegramTransport(BOT_TOKEN)


transport = _init_transport()


def telegram_api(method, data):
    """Low-level Telegram API call. Tests can mock this to intercept all outbound calls."""
    if TRANSPORT_MODE == "local":
        print(f"[local-transport] telegram_api {method} {str(data)[:100]}")
        return {"ok": True, "result": {"message_id": 1}}
    if isinstance(transport, TelegramTransport):
        return transport._api.api(method, data)
    return None


def send_telegram_message(chat_id: int, text: str, parse_mode=None):
    """Send a Telegram message, optionally with parse_mode (HTML or MarkdownV2)."""
    return transport.send_text(chat_id, text, parse_mode=parse_mode)


def download_telegram_file(file_id, session_name):
    """Download a Telegram file to the session inbox.
    Tests can patch bridge.download_telegram_file to intercept file downloads.
    Delegates to transport.download_file() internally.
    """
    return transport.download_file(file_id, session_name)


# Backward-compat module-level media stubs.
# Tests patch these (e.g. patch.object(bridge, 'send_voice', ...)).
# Production code routes through transport.*; these stubs allow test mocking.
def send_voice(chat_id, voice_path, caption=None, message_thread_id=None):
    return transport.send_voice(chat_id, voice_path, caption, message_thread_id=message_thread_id)


def send_photo(chat_id, photo_path, caption=None, message_thread_id=None):
    return transport.send_photo(chat_id, photo_path, caption, message_thread_id=message_thread_id)


def send_animation(chat_id, animation_path, caption=None, message_thread_id=None):
    return transport.send_animation(chat_id, animation_path, caption, message_thread_id=message_thread_id)


def send_document(chat_id, doc_path, caption=None, message_thread_id=None):
    return transport.send_document(chat_id, doc_path, caption, message_thread_id=message_thread_id)


def send_video(chat_id, video_path, caption=None, message_thread_id=None):
    return transport.send_video(chat_id, video_path, caption, message_thread_id=message_thread_id)


def send_audio(chat_id, audio_path, caption=None, message_thread_id=None):
    return transport.send_audio(chat_id, audio_path, caption, message_thread_id=message_thread_id)


def send_sticker(chat_id, sticker_path, message_thread_id=None):
    return transport.send_sticker(chat_id, sticker_path, message_thread_id=message_thread_id)


# ============================================================
# MEDIA HANDLING
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Image Handling
# ─────────────────────────────────────────────────────────────────────────────

# Max file size: 50MB (Telegram Bot API limit for uploads)
MAX_FILE_SIZE = 50 * 1024 * 1024

# Allowed image extensions for outgoing (sendPhoto + sendAnimation + sendVideo)
ALLOWED_IMAGE_EXTENSIONS = {
    # Photos (sendPhoto)
    ".jpg", ".jpeg", ".png", ".webp", ".bmp",
    # Animations (sendAnimation) - autoplay, loop, silent
    ".gif", ".mp4",
}

# Allowed document extensions for outgoing (common code, docs, data files)
ALLOWED_DOC_EXTENSIONS = {
    # Docs
    ".md", ".txt", ".rst", ".pdf",
    # Data
    ".json", ".csv", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".xml",
    ".log", ".sql", ".patch", ".diff",
    # Code
    ".py", ".js", ".ts", ".jsx", ".tsx",
    ".go", ".rs", ".java", ".kt", ".swift",
    ".rb", ".php", ".c", ".cpp", ".h", ".hpp",
    ".sh", ".html", ".css", ".scss",
    # Archives
    ".zip", ".tar", ".gz",
    # Audio (sendAudio — shows player UI)
    ".mp3", ".m4a", ".flac", ".aac", ".wav",
    # Voice (sendVoice — shows voice bubble)
    ".ogg", ".opus", ".oga",
    # Video (sendVideo — shows video player)
    ".mp4", ".mov", ".avi", ".mkv", ".webm",
    # Stickers (sendSticker)
    ".tgs",
}

# Blocked extensions (secrets, keys, certificates)
BLOCKED_DOC_EXTENSIONS = {
    ".pem", ".key", ".p12", ".pfx", ".crt", ".cer", ".der",
    ".jks", ".keystore", ".kdb", ".pgp", ".gpg", ".asc",
}

# Blocked filenames (case-insensitive)
BLOCKED_FILENAMES = {
    ".env", ".npmrc", ".pypirc", ".netrc", ".git-credentials",
    "id_rsa", "id_ed25519", "id_dsa", "credentials", "kubeconfig",
}


def format_file_size(size_bytes):
    """Format file size in human-readable form."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / (1024 * 1024):.1f} MB"


def get_inbox_dir(session_name):
    """Get inbox directory for incoming files (images, documents, etc.).

    Uses /tmp for ephemeral storage, session-namespaced to prevent cross-session access.
    """
    return FILE_INBOX_ROOT / session_name / "inbox"


def ensure_inbox_dir(session_name):
    """Create inbox directory with secure permissions."""
    inbox = get_inbox_dir(session_name)
    inbox.mkdir(parents=True, exist_ok=True, mode=0o700)
    inbox.chmod(0o700)
    return inbox


def cleanup_inbox(session_name):
    """Clean up all files in a session's inbox."""
    inbox = get_inbox_dir(session_name)
    if inbox.exists():
        for f in inbox.iterdir():
            try:
                f.unlink()
            except Exception as e:
                print(f"Failed to delete {f}: {e}")


# download_telegram_file removed — use download_telegram_file() instead


def transcribe_voice(file_path: str, timeout: int = None) -> Optional[str]:
    """Transcribe a voice file via STT endpoint. Returns text or None on failure.

    Fail-open: any error (timeout, bad response, unreachable) returns None
    so the caller can fall back to delivering the raw audio file.
    """
    if not STT_ENDPOINT:
        return None
    if timeout is None:
        timeout = STT_TIMEOUT

    try:
        file_path_obj = Path(file_path)
        if not file_path_obj.exists():
            return None

        # Multipart form upload matching Cohere Transcribe API
        boundary = uuid.uuid4().hex
        body_parts = []
        body_parts.append(f"--{boundary}".encode())
        content_type = mimetypes.guess_type(str(file_path_obj))[0] or "audio/ogg"
        body_parts.append(f'Content-Disposition: form-data; name="file"; filename="{file_path_obj.name}"'.encode())
        body_parts.append(f"Content-Type: {content_type}".encode())
        body_parts.append(b"")
        body_parts.append(file_path_obj.read_bytes())
        body_parts.append(f"--{boundary}--".encode())
        body_parts.append(b"")
        body = b"\r\n".join(body_parts)

        req = urllib.request.Request(
            STT_ENDPOINT,
            data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            result = json.loads(r.read())
            text = result.get("text", "").strip()
            if text:
                duration = result.get("audio_duration_s", "?")
                print(f"STT transcribed: {len(text)} chars from {duration}s audio")
                return text
            return None
    except Exception as e:
        print(f"STT error (fail-open): {e}")
        return None


def synthesize_speech(text: str, voice: str = None, language: str = "en") -> Optional[str]:
    """Synthesize speech from text via TTS endpoint. Returns OGG file path or None.

    Fail-open: any error returns None so caller can skip voice and send text only.
    """
    if not TTS_ENDPOINT:
        return None
    if not text or not text.strip():
        return None
    if voice is None:
        voice = TTS_VOICE

    try:
        # Strip HTML tags for clean speech
        clean = re.sub(r'<[^>]+>', '', text)
        clean = clean.replace('&lt;', '<').replace('&gt;', '>').replace('&amp;', '&')
        clean = clean.strip()
        if not clean:
            return None

        payload = json.dumps({
            "text": clean[:5000],  # API limit
            "voice": voice,
            "language": language,
            "format": "ogg",
        }).encode()

        # Use chunked endpoint for longer text (splits into sentences server-side)
        endpoint = TTS_ENDPOINT
        if len(clean) > TTS_CHUNKED_THRESHOLD and TTS_ENDPOINT:
            chunked_url = TTS_ENDPOINT.rstrip('/') + '/chunked'
            # Only use chunked if it looks like /synthesize base
            if '/synthesize' in TTS_ENDPOINT:
                endpoint = chunked_url

        req = urllib.request.Request(
            endpoint,
            data=payload,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=TTS_TIMEOUT) as r:
            audio_data = r.read()
            if not audio_data:
                return None

            # Write to temp file
            tmp_path = Path(tempfile.gettempdir()) / f"tts_{uuid.uuid4().hex}.ogg"
            tmp_path.write_bytes(audio_data)
            tmp_path.chmod(0o600)

            duration = r.headers.get("X-Audio-Duration", "?")
            proc_time = r.headers.get("X-Processing-Time", "?")
            mode = "chunked" if endpoint != TTS_ENDPOINT else "single"
            print(f"TTS synthesized ({mode}): {len(clean)} chars -> {duration}s audio in {proc_time}s")
            return str(tmp_path)
    except Exception as e:
        print(f"TTS error (fail-open): {e}")
        return None


def validate_photo_path(photo_path):
    """Validate a photo path. Returns (ok, Path or error string)."""
    photo_path = Path(photo_path)

    if not photo_path.exists():
        return False, f"Photo not found: {photo_path}"

    if not photo_path.is_file():
        return False, f"Not a file: {photo_path}"

    # Check extension
    if photo_path.suffix.lower() not in ALLOWED_IMAGE_EXTENSIONS:
        return False, f"Invalid image extension: {photo_path.suffix}"

    # Check size
    file_size = photo_path.stat().st_size
    if file_size > MAX_FILE_SIZE:
        return False, f"Photo too large: {file_size} > {MAX_FILE_SIZE}"

    return True, photo_path


def is_blocked_filename(filename):
    """Check if filename matches blocked patterns (secrets, credentials, etc.)."""
    name_lower = filename.lower()
    # Check exact filename matches
    if name_lower in BLOCKED_FILENAMES:
        return True
    # Check .env.* pattern
    if name_lower.startswith(".env"):
        return True
    return False


def validate_document_path(doc_path):
    """Validate a document path. Returns (ok, Path or error string)."""
    doc_path = Path(doc_path)

    # Security: validate path exists and is regular file
    if not doc_path.exists():
        return False, f"Document not found: {doc_path}"

    if not doc_path.is_file():
        return False, f"Not a file: {doc_path}"

    # Security: check for blocked extensions (sensitive)
    ext_lower = doc_path.suffix.lower()
    if ext_lower in BLOCKED_DOC_EXTENSIONS:
        return False, f"Blocked extension (sensitive): {doc_path.suffix}"

    # Security: check for blocked filenames
    if is_blocked_filename(doc_path.name):
        return False, f"Blocked filename (sensitive): {doc_path.name}"

    # Check size
    file_size = doc_path.stat().st_size
    if file_size > MAX_FILE_SIZE:
        return False, f"Document too large: {file_size} > {MAX_FILE_SIZE}"

    # Note: No path restriction - workers can send from anywhere
    # Security is enforced via extension allowlist and filename blocklist

    return True, doc_path


# Media extensions routed to specialized Telegram API methods
VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".mkv", ".webm"}
AUDIO_EXTENSIONS = {".mp3", ".m4a", ".flac", ".aac", ".wav"}
VOICE_EXTENSIONS = {".ogg", ".opus", ".oga"}
STICKER_EXTENSIONS = {".tgs"}  # animated stickers; static .webp handled by sendPhoto


# ============================================================
# MESSAGE FORMATTING
# ============================================================

CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")


def _split_protected_segments(text, pattern):
    """Split text into (segment, is_protected) based on regex matches."""
    segments = []
    last = 0
    for match in pattern.finditer(text):
        if match.start() > last:
            segments.append((text[last:match.start()], False))
        segments.append((match.group(0), True))
        last = match.end()
    if last < len(text):
        segments.append((text[last:], False))
    return segments


def _collapse_excess_newlines(text):
    """Collapse 3+ newlines to 2, but avoid touching code blocks and inline code."""
    output = []
    for segment, protected in _split_protected_segments(text, CODE_FENCE_RE):
        if protected:
            output.append(segment)
            continue
        for inline_segment, inline_protected in _split_protected_segments(segment, INLINE_CODE_RE):
            if inline_protected:
                output.append(inline_segment)
            else:
                output.append(re.sub(r"\n{3,}", "\n\n", inline_segment))
    return "".join(output)


def _parse_media_tags(text, tag_name, validate_func):
    """Parse media tags, skipping escaped tags and code spans.

    Returns (clean_text, [(path, caption), ...]).
    """
    pattern = re.compile(rf"(\\)?\[\[{tag_name}:([^\]|]+)(?:\|([^\]]*))?\]\]")
    items = []
    removed = 0

    def replace_tag(match):
        nonlocal removed
        if match.group(1):
            # Escaped tag, return without the escape slash.
            return match.group(0)[1:]
        path = match.group(2).strip()
        caption = (match.group(3) or "").strip()
        ok, _ = validate_func(path)
        if ok:
            items.append((path, caption))
            removed += 1
            return ""
        return match.group(0)

    output = []
    for segment, protected in _split_protected_segments(text, CODE_FENCE_RE):
        if protected:
            output.append(segment)
            continue
        for inline_segment, inline_protected in _split_protected_segments(segment, INLINE_CODE_RE):
            if inline_protected:
                output.append(inline_segment)
            else:
                output.append(pattern.sub(replace_tag, inline_segment))

    clean_text = "".join(output)
    if removed:
        clean_text = _collapse_excess_newlines(clean_text).strip()
    return clean_text, items


def parse_image_tags(text):
    """Parse [[image:/path|caption]] tags from text.

    Returns (clean_text, [(path, caption), ...])
    """
    return _parse_media_tags(text, "image", validate_photo_path)


def parse_file_tags(text):
    """Parse [[file:/path|caption]] tags from text.

    Returns (clean_text, [(path, caption), ...])
    """
    return _parse_media_tags(text, "file", validate_document_path)


def escape_html(text: str) -> str:
    """Escape HTML special characters for Telegram's HTML parse mode.

    Must escape &, <, > to prevent Telegram from interpreting them as HTML tags.
    """
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def markdown_to_telegram_html(text: str) -> str:
    """Convert markdown to Telegram-compatible HTML using markdown-it-py.

    Handles: bold, italic, strikethrough, code, code blocks, links,
    blockquotes, headings (as bold), lists, tables (as bullet lists), hr.
    Unrecognized tokens degrade to plain text.
    """
    import re
    from markdown_it import MarkdownIt

    md = MarkdownIt("commonmark").enable("strikethrough").enable("table")
    tokens = md.parse(text)

    result = []
    list_depth = 0
    ordered_counter = []  # stack of counters for ordered lists
    in_table = False
    table_row = []  # current row cells
    table_headers = []  # header cells
    table_rows = []  # all data rows
    in_thead = False
    _rejected_open_tags = []

    class _TelegramHTMLSanitizer(HTMLParser):
        SAFE_TAGS = frozenset({
            "b", "strong", "i", "em", "u", "ins", "s", "strike", "del",
            "code", "pre", "a", "blockquote", "span", "tg-emoji", "tg-spoiler",
        })
        SAFE_ATTRS = {
            "a": frozenset({"href"}),
            "code": frozenset({"class"}),
            "blockquote": frozenset({"expandable"}),
            "span": frozenset({"class"}),
            "tg-emoji": frozenset({"emoji-id"}),
        }

        def __init__(self, rejected_open_tags):
            super().__init__(convert_charrefs=False)
            self._out = []
            self._rejected_open_tags = rejected_open_tags

        def _escape_attr(self, value):
            return escape_html(value).replace('"', "&quot;")

        def _attrs_are_safe(self, tag, attrs):
            allowed = self.SAFE_ATTRS.get(tag, frozenset())
            seen = set()
            for name, value in attrs:
                if name in seen or name not in allowed:
                    return False
                seen.add(name)
                if tag == "a" and name == "href":
                    if value is None:
                        return False
                elif tag == "code" and name == "class":
                    if value is None or not value.startswith("language-"):
                        return False
                elif tag == "blockquote" and name == "expandable":
                    if value not in (None, "", "expandable"):
                        return False
                elif tag == "span" and name == "class":
                    if value != "tg-spoiler":
                        return False
                elif tag == "tg-emoji" and name == "emoji-id":
                    if value is None:
                        return False
            return True

        def _render_start_tag(self, tag, attrs):
            if not attrs:
                return f"<{tag}>"
            rendered = []
            for name, value in attrs:
                if value is None:
                    rendered.append(name)
                else:
                    rendered.append(f'{name}="{self._escape_attr(value)}"')
            return f"<{tag} {' '.join(rendered)}>"

        def handle_starttag(self, tag, attrs):
            accepted = tag in self.SAFE_TAGS and self._attrs_are_safe(tag, attrs)
            if accepted:
                self._out.append(self._render_start_tag(tag, attrs))
            else:
                self._out.append(escape_html(self.get_starttag_text() or f"<{tag}>"))
                # Track rejected start tags so matching closing tags are escaped too.
                self._rejected_open_tags.append(tag)

        def handle_endtag(self, tag):
            rejected_match = False
            for idx in range(len(self._rejected_open_tags) - 1, -1, -1):
                if self._rejected_open_tags[idx] == tag:
                    rejected_match = True
                    del self._rejected_open_tags[idx]
                    break
            if tag in self.SAFE_TAGS and not rejected_match:
                self._out.append(f"</{tag}>")
            else:
                self._out.append(escape_html(f"</{tag}>"))

        def handle_startendtag(self, tag, attrs):
            accepted = tag in self.SAFE_TAGS and self._attrs_are_safe(tag, attrs)
            if accepted:
                start = self._render_start_tag(tag, attrs)
                self._out.append(f"{start[:-1]}/>")
            else:
                self._out.append(escape_html(self.get_starttag_text() or f"<{tag}/>"))

        def handle_data(self, data):
            self._out.append(escape_html(data))

        def handle_entityref(self, name):
            self._out.append(f"&{name};")

        def handle_charref(self, name):
            self._out.append(f"&#{name};")

        def handle_comment(self, data):
            self._out.append(escape_html(f"<!--{data}-->"))

        def html(self):
            return "".join(self._out)

    def _sanitize_html(raw):
        if not raw:
            return ""
        sanitizer = _TelegramHTMLSanitizer(_rejected_open_tags)
        sanitizer.feed(raw)
        sanitizer.close()
        return sanitizer.html()

    def _render_inline_plain(children):
        """Render inline token children to plain text (for use inside <pre>)."""
        out = []
        for tok in children:
            if tok.type in ("text", "code_inline"):
                out.append(tok.content)
            elif tok.type in ("softbreak", "hardbreak"):
                out.append(" ")
            elif tok.type == "image":
                out.append(tok.content or "image")
            elif tok.type in ("strong_open", "strong_close", "em_open", "em_close",
                              "s_open", "s_close", "link_open", "link_close",
                              "html_inline"):
                pass
            else:
                if tok.content:
                    out.append(tok.content)
        return "".join(out)

    def _render_inline(children):
        """Render inline token children to HTML string."""
        out = []
        for tok in children:
            if tok.type == "text":
                out.append(escape_html(tok.content))
            elif tok.type == "code_inline":
                out.append(f"<code>{escape_html(tok.content)}</code>")
            elif tok.type == "strong_open":
                out.append("<b>")
            elif tok.type == "strong_close":
                out.append("</b>")
            elif tok.type == "em_open":
                out.append("<i>")
            elif tok.type == "em_close":
                out.append("</i>")
            elif tok.type == "s_open":
                out.append("<s>")
            elif tok.type == "s_close":
                out.append("</s>")
            elif tok.type == "link_open":
                href = escape_html((tok.attrs or {}).get("href", ""))
                out.append(f'<a href="{href}">')
            elif tok.type == "link_close":
                out.append("</a>")
            elif tok.type == "softbreak":
                out.append("\n")
            elif tok.type == "hardbreak":
                out.append("\n")
            elif tok.type == "image":
                alt = escape_html(tok.content or "image")
                src = escape_html((tok.attrs or {}).get("src", ""))
                out.append(f'[{alt}]({src})')
            elif tok.type == "html_inline":
                out.append(_sanitize_html(tok.content))
            else:
                if tok.content:
                    out.append(escape_html(tok.content))
        return "".join(out)

    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok.type == "paragraph_open":
            pass
        elif tok.type == "paragraph_close":
            if not in_table:
                result.append("\n")
        elif tok.type == "inline":
            if in_table:
                table_row.append(_render_inline_plain(tok.children or []))
            else:
                result.append(_render_inline(tok.children or []))

        # Headings -> bold
        elif tok.type == "heading_open":
            result.append("<b>")
        elif tok.type == "heading_close":
            result.append("</b>\n")

        # Code blocks
        elif tok.type == "fence":
            lang = tok.info.strip() if tok.info else ""
            code = escape_html(tok.content.rstrip("\n"))
            if lang:
                result.append(f'<pre><code class="language-{escape_html(lang)}">{code}</code></pre>\n')
            else:
                result.append(f"<pre>{code}</pre>\n")
        elif tok.type == "code_block":
            code = escape_html(tok.content.rstrip("\n"))
            result.append(f"<pre>{code}</pre>\n")

        # Blockquotes
        elif tok.type == "blockquote_open":
            result.append("<blockquote>")
        elif tok.type == "blockquote_close":
            if result and result[-1].endswith("\n"):
                result[-1] = result[-1][:-1]
            result.append("</blockquote>\n")

        # Bullet lists
        elif tok.type == "bullet_list_open":
            list_depth += 1
        elif tok.type == "bullet_list_close":
            list_depth -= 1
            if list_depth == 0:
                result.append("\n")

        # Ordered lists
        elif tok.type == "ordered_list_open":
            list_depth += 1
            ordered_counter.append(0)
        elif tok.type == "ordered_list_close":
            list_depth -= 1
            ordered_counter.pop()
            if list_depth == 0:
                result.append("\n")

        # List items
        elif tok.type == "list_item_open":
            indent = "  " * (list_depth - 1)
            if ordered_counter:
                ordered_counter[-1] += 1
                result.append(f"{indent}{ordered_counter[-1]}. ")
            else:
                result.append(f"{indent}\u2022 ")
        elif tok.type == "list_item_close":
            if result and not result[-1].endswith("\n"):
                result.append("\n")

        # Tables -> <pre> aligned columns
        elif tok.type == "table_open":
            in_table = True
            table_headers = []
            table_rows = []
        elif tok.type == "table_close":
            in_table = False
            # Render as <pre> with aligned columns
            all_rows = [table_headers] + table_rows
            if all_rows and all_rows[0]:
                num_cols = max(len(r) for r in all_rows)
                col_widths = [0] * num_cols
                for row in all_rows:
                    for ci, cell in enumerate(row):
                        if ci < num_cols:
                            col_widths[ci] = max(col_widths[ci], len(cell))
                lines = []
                for ri, row in enumerate(all_rows):
                    cols = []
                    for ci in range(num_cols):
                        cell = row[ci] if ci < len(row) else ""
                        cols.append(escape_html(cell.ljust(col_widths[ci])))
                    lines.append("  ".join(cols).rstrip())
                    if ri == 0:
                        lines.append("\u2550" * (sum(col_widths) + 2 * (num_cols - 1)))
                result.append(f"<pre>{''.join(chr(10).join(lines))}</pre>\n")
            table_headers = []
            table_rows = []
        elif tok.type == "thead_open":
            in_thead = True
        elif tok.type == "thead_close":
            in_thead = False
        elif tok.type in ("tbody_open", "tbody_close"):
            pass
        elif tok.type == "tr_open":
            table_row = []
        elif tok.type == "tr_close":
            if in_thead:
                table_headers = table_row[:]
            else:
                table_rows.append(table_row[:])
            table_row = []
        elif tok.type in ("th_open", "th_close", "td_open", "td_close"):
            pass

        # Horizontal rule
        elif tok.type == "hr":
            result.append("\u2014\u2014\u2014\u2014\n")

        # HTML blocks
        elif tok.type == "html_block":
            result.append(_sanitize_html(tok.content))

        else:
            if tok.content:
                result.append(escape_html(tok.content))

        i += 1

    output = "".join(result).strip()
    while "\n\n\n" in output:
        output = output.replace("\n\n\n", "\n\n")

    # Post-process: wrap runs of plain-text tabular lines in <pre>.
    # Detects lines with 2+ internal multi-space gaps (column alignment)
    # that are NOT already inside <pre> tags.
    _MULTI_SPACE = re.compile(r'\S  +\S.*\S  +\S')  # 2+ columns with 2+ space gaps

    def _wrap_plain_tables(text):
        """Find consecutive tabular lines outside <pre> and wrap in <pre>."""
        parts = re.split(r'(<pre>.*?</pre>)', text, flags=re.DOTALL)
        out = []
        for part in parts:
            if part.startswith('<pre>'):
                out.append(part)
                continue
            lines = part.split('\n')
            i = 0
            while i < len(lines):
                if _MULTI_SPACE.search(lines[i]):
                    # Start of tabular run
                    run = [lines[i]]
                    j = i + 1
                    while j < len(lines) and (_MULTI_SPACE.search(lines[j]) or lines[j].strip() == ''):
                        run.append(lines[j])
                        j += 1
                    # Only wrap if 2+ tabular lines
                    tabular_count = sum(1 for l in run if _MULTI_SPACE.search(l))
                    if tabular_count >= 2:
                        # Strip trailing empty lines from run
                        while run and run[-1].strip() == '':
                            j -= 1
                            run.pop()
                        content = escape_html('\n'.join(run))
                        out.append(f'<pre>{content}</pre>')
                        i = j
                    else:
                        out.append(lines[i])
                        i += 1
                else:
                    out.append(lines[i])
                    i += 1
            # Rejoin non-pre parts with newlines (but parts list alternates)
            if out and not out[-1].startswith('<pre>') and not part.startswith('<pre>'):
                pass  # already appended line by line
        # Reconstruct: join lines that aren't pre blocks
        # Actually, simpler approach: rebuild from parts
        return '\n'.join(out) if out else text

    output = _wrap_plain_tables(output)
    return output


def format_response_text(session_name, text):
    """Format response with session prefix. No escaping - Claude Code handles safety."""
    # Strip redundant worker name prefix to avoid "lee:\nlee: message" double prefix
    stripped = text.lstrip()
    prefix = f"{session_name}:"
    if stripped.lower().startswith(prefix.lower()):
        text = stripped[len(prefix):].lstrip()
    return f"<b>{session_name}:</b>\n{text}"


# ─────────────────────────────────────────────────────────────────────────────
# Message Splitting (Telegram 4096 char limit)
# ─────────────────────────────────────────────────────────────────────────────

TELEGRAM_MAX_LENGTH = 4096


def split_message(text, max_len=TELEGRAM_MAX_LENGTH):
    """Split HTML text into chunks that fit within Telegram's message limit.

    HTML-aware: tracks open tags and closes/reopens them at split boundaries.
    Splits on safe boundaries: blank lines → newlines → spaces → hard cut.
    Returns list of valid HTML text chunks.
    """
    import re
    if len(text) <= max_len:
        return [text]

    # Regex for Telegram-supported HTML tags
    TAG_RE = re.compile(r'<(/?)(\w+)([^>]*)>')
    TRACKED_TAGS = frozenset(('b', 'i', 's', 'u', 'code', 'pre', 'a',
                              'strong', 'em', 'del', 'ins', 'strike', 'blockquote'))

    def _closing_tags(stack):
        """Generate closing tags for all open tags (reverse order)."""
        return "".join(f"</{tag}>" for tag, _ in reversed(stack))

    def _opening_tags(stack):
        """Generate opening tags for all open tags (original order)."""
        return "".join(full for _, full in stack)

    def _scan_tags(text):
        """Return the tag stack state after scanning text."""
        stack = []
        for m in TAG_RE.finditer(text):
            is_close = m.group(1) == '/'
            tag_name = m.group(2).lower()
            if tag_name not in TRACKED_TAGS:
                continue
            if is_close:
                for j in range(len(stack) - 1, -1, -1):
                    if stack[j][0] == tag_name:
                        stack.pop(j)
                        break
            else:
                stack.append((tag_name, m.group(0)))
        return stack

    def _find_split(text, budget):
        """Find best split point within budget chars.

        Priority: blank line → newline → space → hard cut.
        Avoids splitting inside HTML tags. Always returns >= 1.
        """
        if budget <= 0:
            budget = 1
        search = text[:budget]

        # Don't split inside a tag — find last '>' before budget
        last_tag_start = search.rfind('<')
        last_tag_end = search.rfind('>')
        if last_tag_start > last_tag_end:
            search = text[:last_tag_start]
            budget = last_tag_start

        for sep in ('\n\n', '\n', ' '):
            pos = search.rfind(sep)
            if pos > budget // 3:
                return pos + 1

        return max(budget, 1)  # Guarantee forward progress

    chunks = []
    remaining = text
    carry_stack = []  # Tags open from previous chunk

    while remaining:
        prefix = _opening_tags(carry_stack)
        available = max_len - len(prefix)

        # Close carry tags in final chunk too
        if len(prefix) + len(remaining) + len(_closing_tags(carry_stack)) <= max_len:
            suffix = _closing_tags(_scan_tags(prefix + remaining))
            chunks.append(prefix + remaining + suffix)
            break

        # Find split point with iterative backoff to guarantee max_len
        budget = available - 100  # Initial conservative reserve
        if budget < 100:
            budget = 100

        for _attempt in range(5):
            split_at = _find_split(remaining, budget)
            chunk_text = remaining[:split_at].rstrip()
            full_chunk = prefix + chunk_text
            open_stack = _scan_tags(full_chunk)
            suffix = _closing_tags(open_stack)

            if len(full_chunk) + len(suffix) <= max_len:
                break
            # Shrink budget and retry
            overshoot = len(full_chunk) + len(suffix) - max_len
            budget = max(budget - overshoot - 20, 100)
        else:
            # Last resort: hard cut to fit
            hard_limit = max_len - len(prefix) - len(suffix) - 10
            if hard_limit < 1:
                hard_limit = 1
            chunk_text = remaining[:hard_limit].rstrip()
            full_chunk = prefix + chunk_text
            open_stack = _scan_tags(full_chunk)
            suffix = _closing_tags(open_stack)
            split_at = hard_limit

        chunks.append(full_chunk + suffix)
        carry_stack = open_stack
        remaining = remaining[split_at:].lstrip()

        # Safety: prevent infinite loop
        if split_at == 0:
            # Force progress by consuming at least 1 char
            remaining = remaining[1:]

    return chunks


def format_multipart_messages(session_name, chunks):
    """Format chunks with session prefix (all chunks get prefix, no part numbers).

    Single chunk: "<b>name:</b>\ntext"
    Multiple chunks: "<b>name:</b>\ntext" (same format, no 1/3, 2/3 etc)
    """
    return [format_response_text(session_name, chunk) for chunk in chunks]


def setup_bot_commands():
    """Initial bot commands setup."""
    update_bot_commands()


def update_bot_commands():
    """Publish the topic-native command menu — a slim, fixed set. No per-worker
    /<name> shortcuts and no orchestration commands: each 話題 is its own session."""
    transport.setup_commands(list(TOPIC_BOT_COMMANDS))
    print(f"Bot commands updated ({len(TOPIC_BOT_COMMANDS)} topic commands)")


# ============================================================
# TMUX SESSION MANAGEMENT
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Session Management
# ─────────────────────────────────────────────────────────────────────────────

def get_session_dir(name):
    """Get per-session directory path."""
    return SESSIONS_DIR / name


def ensure_session_dir(name):
    """Create session directory if needed with secure permissions (0o700)."""
    d = get_session_dir(name)
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Ensure parent directories also have secure permissions
    SESSIONS_DIR.chmod(0o700)
    d.chmod(0o700)
    return d


def get_pending_file(name):
    return get_session_dir(name) / "pending"


def get_chat_id_file(name):
    return get_session_dir(name) / "chat_id"


# Root directory the folder navigator is confined to (topic-session feature).
TOPIC_ROOT = os.path.expanduser(os.environ.get("TOPIC_ROOT", "~"))

# Topic-session routing mode. When on, inbound messages are routed by forum
# thread (話題) instead of the legacy @mention/focus model. Default OFF so
# legacy behavior is fully preserved.
# Topic-only bridge (v1.0.0): one Telegram forum 話題 = one session. This is
# the only mode — the legacy hire/focus/team router was removed. The constant
# is kept (always True) so remaining gates read naturally until they are
# folded away; the TOPIC_MODE env var is no longer consulted.
TOPIC_MODE = True


def _norm_under_root(path):
    """Clamp a path to within TOPIC_ROOT.

    Returns the realpath of ``path`` if it is TOPIC_ROOT or a descendant;
    otherwise returns TOPIC_ROOT itself (no escaping above the root).
    """
    root = os.path.realpath(TOPIC_ROOT)
    try:
        real = os.path.realpath(path)
    except Exception:
        return root
    if real == root or real.startswith(root + os.sep):
        return real
    return root


# Telegram caps callback_data at 64 bytes, so the folder navigator can't embed
# absolute paths (deep folders overflow -> BUTTON_DATA_INVALID 400, picker "no
# reaction"). Map each path to a short stable token and resolve it on callback.
_folder_tokens = {}


def _folder_token(path):
    """Short, stable callback token for an absolute folder path (<= 15 bytes)."""
    real = os.path.realpath(path)
    tok = hashlib.sha1(real.encode()).hexdigest()[:12]
    _folder_tokens[tok] = real
    return tok


def _folder_from_token(tok):
    """Resolve a folder token to its path, or None if unknown (e.g. post-restart)."""
    return _folder_tokens.get(tok)


def build_folder_keyboard(path):
    """Build a Telegram inline_keyboard for browsing folders under TOPIC_ROOT.

    - One button per immediate subdirectory (callback_data ``cd:<path>``).
    - An ``⬆️ 上一層`` button (callback_data ``cd:<parent>``) only when ``path``
      is strictly inside TOPIC_ROOT (i.e. not the root itself).
    - A ``✅ 用這層`` button (callback_data ``use:<path>``), always present.
    """
    here = _norm_under_root(path)
    root = os.path.realpath(TOPIC_ROOT)
    rows = []

    subdirs = []
    try:
        for entry in os.scandir(here):
            try:
                # Skip hidden (dot) directories so real project folders aren't
                # crowded out of the button cap by ~/.cache, ~/.config, etc.
                if entry.is_dir(follow_symlinks=False) and not entry.name.startswith("."):
                    subdirs.append(entry)
            except OSError:
                continue
    except OSError:
        subdirs = []
    subdirs.sort(key=lambda e: e.name)

    for entry in subdirs[:30]:
        rows.append([{"text": f"📁 {entry.name}", "callback_data": f"cd:{_folder_token(entry.path)}"}])

    if here != root:
        parent = _norm_under_root(os.path.dirname(here))
        rows.append([{"text": "⬆️ 上一層", "callback_data": f"cd:{_folder_token(parent)}"}])

    rows.append([{"text": "✅ 用這層", "callback_data": f"use:{_folder_token(here)}"}])
    return rows


def topic_session_name(thread_id):
    """Session name for a forum Topic thread (e.g. 4321 -> 't4321').

    Thread ``0`` is the non-forum fallback: a plain DM (no message_thread_id)
    maps to one fixed default session named ``tmain``.
    """
    if int(thread_id) == 0:
        return "tmain"
    return f"t{int(thread_id)}"


# 話題 titles captured from `forum_topic_created` events, keyed by
# (chat_id, message_thread_id), so a session can be named after its Topic.
_topic_titles = {}


def _sanitize_topic_name(title):
    """Slugify a 話題 title into a tmux/dir-safe worker name, or '' when the slug
    would not faithfully represent the title so the caller falls back to t<id>.

    Returns '' when the title carries alphabetic letters outside [a-z] that
    slugifying drops (CJK, accented Latin, …) — otherwise a title like "測試546"
    silently becomes the misleading fragment "546". Pure-ASCII titles such as
    "PR 123" -> "pr-123" are unaffected.
    """
    t = title or ""
    slug = re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")
    if not slug:
        return ""
    if any(c.isalpha() and not ("a" <= c.lower() <= "z") for c in t):
        return ""
    return slug


def resolve_topic_session_name(chat_id, thread_id, registered):
    """Worker name for a topic: the slugified 話題 title when usable and not
    already taken, else the stable ``t<thread_id>`` (or ``tmain``) fallback."""
    fallback = topic_session_name(thread_id)
    slug = _sanitize_topic_name(_topic_titles.get((int(chat_id), int(thread_id)), ""))
    # Reject names that collide with the t<id>/tmain scheme, reserved command
    # words, the digit-selection UX (pure-numeric), or an already-taken worker.
    if (
        slug
        and slug != "tmain"
        and not slug.isdigit()
        and slug not in RESERVED_NAMES
        and slug not in (registered or {})
    ):
        return slug
    return fallback


def save_topic_meta(name, chat_id, thread_id):
    """Persist (chat_id, message_thread_id) for a topic session (0600 files)."""
    sd = get_session_dir(name)
    sd.mkdir(parents=True, exist_ok=True)
    cf = sd / "chat_id"
    cf.write_text(str(int(chat_id)))
    cf.chmod(0o600)
    tf = sd / "message_thread_id"
    tf.write_text(str(int(thread_id)))
    tf.chmod(0o600)


def load_topic_meta(name):
    """Read back (chat_id, message_thread_id) ints, or (None, None) if absent."""
    sd = get_session_dir(name)
    try:
        cid = int((sd / "chat_id").read_text().strip())
        tid = int((sd / "message_thread_id").read_text().strip())
        return cid, tid
    except Exception:
        return None, None


def find_topic_session(chat_id, thread_id, registered):
    """Return the registered session name whose stored (chat_id, thread_id) matches."""
    for name in registered:
        cid, tid = load_topic_meta(name)
        if cid == int(chat_id) and tid == int(thread_id):
            return name
    return None


# Topics whose folder picker is open (or whose session is still being created).
# While present, a typed reply must NOT be routed to a worker — it is a
# mis-attempt to "pick option N". Cleared once the session is bound.
_awaiting_folder = set()

# When the folder picker was sent, per (chat_id, thread_id). Telegram only
# commits a new topic when its first message is sent, so that message is just
# the trigger the platform requires — within this grace window after the
# picker appears it is silently swallowed (no nudge, never forwarded).
_picker_sent_at = {}
_PICKER_GRACE_SECS = 5.0

# Per-update reply routing: _handle_topic_message records the inbound 話題
# thread here so every reply() raised while handling that update (command
# replies, error hints, delegated /memory & friends) lands back in the same
# topic. threading.local is safe because each Telegram update is handled in
# its own dedicated thread.
_reply_ctx = threading.local()


# External usage snapshot written by claude-hud (subscriber rate-limit data).
USAGE_FILE = os.path.expanduser(os.environ.get("CC_USAGE_FILE", "~/.claude/cc-usage.json"))


def read_usage_snapshot():
    """Read claude-hud's external usage snapshot.

    Returns the parsed dict, or None if the file is missing/unreadable or its
    ``updated_at`` timestamp is older than ~10 minutes (stale → None).
    """
    try:
        with open(USAGE_FILE) as f:
            snap = json.load(f)
    except Exception:
        return None
    if not isinstance(snap, dict):
        return None
    updated_at = snap.get("updated_at")
    if updated_at:
        try:
            from datetime import datetime, timezone
            ts = datetime.fromisoformat(str(updated_at).replace("Z", "+00:00"))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            age = (datetime.now(timezone.utc) - ts).total_seconds()
            if age > 600:
                return None
        except Exception:
            return None
    return snap


def _quota_bar(pct):
    """Render a 10-char usage bar for an integer percent (0-100)."""
    try:
        p = max(0, min(100, int(pct)))
    except Exception:
        return "n/a"
    filled = round(p / 10)
    return "█" * filled + "░" * (10 - filled)


def _quota_reset_label(resets_at):
    """Relative reset label (e.g. ``重置 in 2h`` ), best-effort; never raises."""
    if not resets_at:
        return ""
    try:
        from datetime import datetime, timezone
        ts = datetime.fromisoformat(str(resets_at).replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        delta = (ts - datetime.now(timezone.utc)).total_seconds()
        if delta <= 0:
            return "重置 soon"
        if delta < 3600:
            return f"重置 in {int(delta // 60)}m"
        if delta < 86400:
            return f"重置 in {int(delta // 3600)}h"
        return f"重置 in {int(delta // 86400)}d"
    except Exception:
        return ""


def _quota_window_line(label, window):
    """Render one window line: ``<label> <bar> <remaining>% (used <used>%) <reset>``.

    A null/absent ``used_percentage`` renders as ``n/a``.
    """
    window = window or {}
    used = window.get("used_percentage")
    if used is None:
        return f"{label} n/a"
    bar = _quota_bar(used)
    try:
        remaining = 100 - int(used)
    except Exception:
        remaining = "n/a"
    reset = _quota_reset_label(window.get("resets_at"))
    line = f"{label} {bar} {used}% used, {remaining}% left"
    if reset:
        line += f" · {reset}"
    return line


def format_quota(snap):
    """Render the usage snapshot for /quota.

    None → clear unavailable fallback. Otherwise render 5h / 7d windows
    (null window → ``n/a``) plus best-effort context. Does not depend on the
    wall clock for the percent/label values it asserts on.
    """
    if not snap:
        return "usage unavailable — no subscriber rate-limit data"
    lines = ["📊 用量"]
    lines.append(_quota_window_line("5h", snap.get("five_hour")))
    lines.append(_quota_window_line("7d", snap.get("seven_day")))
    ctx = snap.get("context")
    if isinstance(ctx, dict):
        cused = ctx.get("used_percentage")
        if cused is not None:
            lines.append(f"context {_quota_bar(cused)} {cused}% used")
    return "\n".join(lines)


def get_manager_chat_id(name: str) -> Optional[int]:
    """Resolve manager chat ID for worker notifications.

    Priority:
      1) ADMIN_CHAT_ID (if configured)
      2) Session chat_id file
    """
    if admin_chat_id is not None:
        return admin_chat_id

    chat_id_file = get_chat_id_file(name)
    if not chat_id_file.exists():
        return None

    try:
        value = chat_id_file.read_text().strip()
        return int(value) if value else None
    except Exception as e:
        print(f"Failed to read chat_id for {name}: {e}")
        return None


def _read_session_file(name, filename):
    """Read a session file from the local session directory."""
    f = get_session_dir(name) / filename
    if f.exists():
        val = f.read_text().strip()
        if val:
            return val
    return ""


def _scan_latest_session_id(cwd: str) -> str:
    """Return the UUID of the most-recently-modified JSONL in <slug>/.

    Source of truth for the "current" session Claude Code is writing to.
    Returns "" if the slug dir is missing/empty or the scan errors out.
    """
    if not cwd:
        return ""
    slug = cwd.replace("/", "-")
    slug_dir = CLAUDE_PROJECTS_DIR / slug
    if not slug_dir.is_dir():
        return ""
    try:
        jsonls = [p for p in slug_dir.iterdir()
                  if p.is_file() and p.suffix == ".jsonl"]
    except OSError:
        return ""
    if not jsonls:
        return ""
    latest = max(jsonls, key=lambda p: p.stat().st_mtime)
    return latest.stem


def _cache_session_id(name: str, sid: str) -> None:
    """Write session_id to local VPS cache file (best effort, 0o600)."""
    if not sid:
        return
    try:
        d = ensure_session_dir(name)
        f = d / "claude_session_id"
        f.write_text(sid)
        f.chmod(0o600)
    except Exception:
        pass


def get_claude_session_id(name: str, authoritative: bool = False) -> str:
    """Return the Claude Code session UUID for a worker.

    The local `claude_session_id` file is a cache/hint populated by
    (a) the Stop hook POST to /response and (b) this function's scan fallback.
    The *authoritative* source is the latest-mtime JSONL under
    `~/.claude/projects/<slug>/`.

    authoritative=False (default): return the cached value if present.
        If the cache is empty, scan the transcript dir and cache the result.
    authoritative=True: always scan the transcript dir and refresh the cache.
        Use this for correctness-critical call sites — /rewind, /restart,
        memory source deep-links — where a stale UUID leads to "transcript
        not available" or a failed `--resume`. Falls back to cached value
        if the scan itself fails.
    """
    cache_file = get_session_dir(name) / "claude_session_id"

    def _read_cache():
        if cache_file.exists():
            val = cache_file.read_text().strip()
            if val:
                return val
        return ""

    if not authoritative:
        val = _read_cache()
        if val:
            return val
        # Self-heal: cache empty, try to populate via scan
        cwd = get_claude_session_cwd(name)
        if cwd:
            scanned = _scan_latest_session_id(cwd)
            if scanned:
                _cache_session_id(name, scanned)
                return scanned
        return ""

    # Authoritative: always scan
    cwd = get_claude_session_cwd(name)
    if cwd:
        scanned = _scan_latest_session_id(cwd)
        if scanned:
            _cache_session_id(name, scanned)
            return scanned
    # Scan failed — better to return stale cache than nothing
    return _read_cache()


def get_claude_session_cwd(name):
    cwd = _read_session_file(name, "claude_session_cwd")
    if cwd:
        cwd = os.path.expanduser(cwd)
    return cwd


def save_claude_session_cwd(name, cwd):
    if cwd:
        cwd = os.path.expanduser(cwd)
    d = ensure_session_dir(name)
    f = d / "claude_session_cwd"
    f.write_text(cwd)
    f.chmod(0o600)


def clear_claude_session_id(name):
    f = get_session_dir(name) / "claude_session_id"
    if f.exists():
        f.unlink()


def get_any_session_id(name):
    """Get any *_session_id value for a worker (backend-agnostic).

    Returns (session_id, source) tuple where source is the prefix (e.g. 'claude', 'codex').
    """
    session_dir = get_session_dir(name)
    if not session_dir.exists():
        return "", ""
    for f in sorted(session_dir.glob("*_session_id")):
        val = f.read_text().strip()
        if val:
            source = f.name.replace("_session_id", "")
            return val, source
    return "", ""


def set_pending(name, chat_id):
    """Mark session as having a pending request with secure permissions (0o600)."""
    d = ensure_session_dir(name)
    pending = d / "pending"
    chat_id_file = d / "chat_id"
    pending.write_text(str(int(time.time())))
    pending.chmod(0o600)
    chat_id_file.write_text(str(chat_id))
    chat_id_file.chmod(0o600)


def clear_pending(name):
    """Clear pending status for session."""
    d = get_session_dir(name)
    pending = d / "pending"
    if pending.exists():
        pending.unlink()


def is_pending(name):
    """Check if session has a pending request within the timeout window.

    Non-mutating: does NOT delete the pending file. The file is preserved
    so the watchdog can detect STALE_PENDING at 15 minutes. Cleanup happens
    only via clear_pending() when a response arrives.
    """
    pending = get_pending_file(name)
    if not pending.exists():
        return False
    try:
        ts = int(pending.read_text().strip())
        if (time.time() - ts) > PENDING_TIMEOUT:
            return False
        return True
    except Exception:
        return False


def _pending_timestamp(name: str) -> Optional[int]:
    pending = get_pending_file(name)
    if not pending.exists():
        return None
    try:
        return int(pending.read_text().strip())
    except Exception:
        return None


def compute_state(
    tmux_exists: bool,
    claude_pid: Optional[str],
    pending: bool,
    pending_ts: Optional[int],
    pending_age: float,
    children: int,
    last_child_ts: float,
    cpu: float,
    last_hook_ts: Optional[float],
    last_seen_claude: Optional[float],
    now: float,
    poisoned_reason: Optional[str] = None,
) -> tuple[str, str]:
    if not tmux_exists:
        return "OFFLINE", "tmux missing"

    if not claude_pid and last_seen_claude is not None:
        if (now - last_seen_claude) > START_GRACE:
            return "DEAD", f"claude missing {int(now - last_seen_claude)}s"

    if pending and children > 0:
        return "BUSY_TOOL", f"children={children}"

    if pending and children == 0:
        if (pending_age <= THINK_GRACE) or ((now - last_child_ts) <= TOOL_GAP_GRACE) or (cpu >= CPU_ACTIVE):
            return "BUSY_THINKING", f"age={int(pending_age)}s cpu={cpu:.1f}"
        if pending_age < STALE_PENDING:
            return "WAITING", f"age={int(pending_age)}s"
        hook_since_pending = last_hook_ts is not None and pending_ts is not None and last_hook_ts > pending_ts
        if pending_age >= STALE_PENDING and cpu < CPU_IDLE and not hook_since_pending:
            if poisoned_reason is not None:
                return "POISONED", f"{poisoned_reason}"
            return "STUCK", f"age={int(pending_age)}s cpu={cpu:.1f}"
        return "WAITING", f"age={int(pending_age)}s"

    if not pending and children > 0:
        return "UNTRACKED_BUSY", f"children={children}"

    if claude_pid and not pending:
        return "READY", "idle"

    return "OFFLINE", "tmux alive, claude missing"


POISON_PATTERNS = [
    re.compile(r"error.*overloaded", re.IGNORECASE),
    re.compile(r"error.*401", re.IGNORECASE),
    re.compile(r"error.*403", re.IGNORECASE),
    re.compile(r"error.*429", re.IGNORECASE),
    re.compile(r"image.*dimensions.*exceed", re.IGNORECASE),
    re.compile(r"context.*(length|window).*exceed", re.IGNORECASE),
    re.compile(r"context_length_exceeded", re.IGNORECASE),
    re.compile(r"rate.?limit", re.IGNORECASE),
    re.compile(r"invalid.*api.?key", re.IGNORECASE),
    re.compile(r"invalid_request_error", re.IGNORECASE),
    re.compile(r"insufficient_quota", re.IGNORECASE),
    re.compile(r"model.*not.*found", re.IGNORECASE),
    re.compile(r"APIError", re.IGNORECASE),
    re.compile(r"connection.*reset", re.IGNORECASE),
    re.compile(r"timeout.*error", re.IGNORECASE),
    re.compile(r"error.*529", re.IGNORECASE),
    re.compile(r"error.*503", re.IGNORECASE),
]


def _capture_pane_text(tmux_name: str, lines: int = 50) -> str:
    """Return the last N lines of a tmux pane, or empty string on error."""
    if lines <= 0:
        return ""
    try:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", tmux_name, "-p", "-S", f"-{lines}"],
            capture_output=True, text=True, timeout=5
        )
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout


HOOK_FAILURE_THRESHOLD = 3   # failures in window → POISONED
HOOK_FAILURE_WINDOW = 120    # seconds


def _check_hook_failure_signal(name: str) -> Optional[str]:
    """Check hook-written failure signal file for recent tool failures.

    PostToolUseFailure hook appends lines: "<epoch> <tool_name>"
    Returns reason string if >= HOOK_FAILURE_THRESHOLD recent failures, else None.
    """
    signal_path = f"/tmp/claudecode-telegram/{_node_name}/{name}/hooks/failures"
    signal_file = Path(signal_path)
    if not signal_file.exists():
        return None
    try:
        raw = signal_file.read_text().strip()
    except Exception:
        return None

    if not raw:
        return None
    lines = raw.splitlines()

    cutoff = int(time.time()) - HOOK_FAILURE_WINDOW
    recent = 0
    for line in lines:
        parts = line.split(None, 1)
        if not parts:
            continue
        try:
            ts = int(parts[0])
        except ValueError:
            continue
        if ts >= cutoff:
            recent += 1

    if recent >= HOOK_FAILURE_THRESHOLD:
        return f"hook failure signal: {recent} tool failures in {HOOK_FAILURE_WINDOW}s"
    return None


def _clear_hook_failures(name: str) -> None:
    """Remove hook failure signal file for a worker (on restart/clean)."""
    signal_path = f"/tmp/claudecode-telegram/{_node_name}/{name}/hooks/failures"
    try:
        Path(signal_path).unlink(missing_ok=True)
    except Exception:
        pass


def _detect_poisoned(name: str, tmux_name: str) -> Optional[str]:
    # Primary: check hook-written failure signal file
    hook_reason = _check_hook_failure_signal(name)
    if hook_reason:
        return hook_reason

    # Fallback: regex-based pane scanning
    combined = _capture_pane_text(tmux_name)
    if not combined:
        return None
    for pattern in POISON_PATTERNS:
        if len(pattern.findall(combined)) >= 3:
            return pattern.pattern
    return None


def _send_watchdog_alert(name: str, state: str, reason: str) -> None:
    if admin_chat_id is None:
        return

    now = time.time()
    with _watchdog_lock:
        last = _last_alert_ts.get(name)
    if last and (now - last) < ALERT_COOLDOWN:
        print(f"[watchdog] Alert suppressed for {name} ({state}): cooldown {now - last:.0f}s < {ALERT_COOLDOWN}s")
        return

    # Human-friendly alert messages for manager
    if state == "WAITING_INPUT":
        with _watchdog_lock:
            details = _waiting_input_details.get(name)
        header = details.get("header", "") if details else ""
        title = f"🟡 {name} needs your reply"
        if header:
            title += f": {header}"
        parts = [title]
        if details and details.get("options"):
            for o in details["options"]:
                marker = "\u2794 " if o.get("selected") else "  "
                parts.append(f"{marker}{o['num']}. {o['label']}")
            max_num = max(o["num"] for o in details["options"])
            parts.append(f"\nReply 1-{max_num} to choose, or \"skip\" to cancel.")
        text = "\n".join(parts)
    elif state == "STUCK":
        # Parse age from reason like "age=909s cpu=6.3 streak=3/3"
        age_match = re.search(r"age=(\d+)s", reason)
        age_min = int(age_match.group(1)) // 60 if age_match else 0
        age_str = f"{age_min}min" if age_min > 0 else reason.split()[0]
        text = f"🔴 {name} has made no progress for {age_str}.\n在它的話題用 /cd <路徑> 原地重啟，或 /close 後重開話題。"
    elif state == "POISONED":
        text = f"🔴 {name} is stuck in an error loop.\n在它的話題用 /cd <路徑> 原地重啟，或 /close 後重開話題。"
    elif state == "DEAD":
        text = f"🔴 {name} stopped unexpectedly.\n在它的話題用 /cd <路徑> 重啟，或 /close 後重開話題。"
    elif state == "EXITED":
        text = f"🟡 {name}'s session ended.\n在它的話題用 /cd <路徑> 重啟。"
    elif state == "OFFLINE":
        text = f"🔴 {name} is not running.\n重開它的話題（或在話題裡 /cd <路徑>）即可重啟。"
    else:
        text = f"{name}: {state} ({reason})."
    try:
        result = transport.send_text(admin_chat_id, text)
        if result and result.get("ok"):
            print(f"[watchdog] Alert sent for {name} ({state}): {text[:80]}")
            msg_id = result.get("result", {}).get("message_id")
            with _watchdog_lock:
                _last_alert_ts[name] = now
                if msg_id:
                    _alert_msg_ids[name] = (msg_id, text)
        else:
            print(f"[watchdog] Alert FAILED for {name} ({state}): {result}")
    except Exception as e:
        print(f"Watchdog alert error: {e}")


_last_resolved_ts: dict[str, float] = {}  # Per-worker resolved alert cooldown

def _send_resolved_alert(name: str, new_state: str) -> None:
    if admin_chat_id is None:
        return

    good_states = {"READY", "BUSY_TOOL", "BUSY_THINKING"}
    bad_states = {"OFFLINE", "DEAD", "STUCK", "POISONED", "EXITED", "WAITING_INPUT"}
    with _watchdog_lock:
        prev_state = _prev_worker_states.get(name)
    if prev_state not in bad_states or new_state not in good_states:
        return

    # Suppress if worker was recently restarted (cmd_restart sends its own confirmation)
    restart_ts = _recent_restarts.get(name)
    if restart_ts and time.time() - restart_ts < 30:
        return

    # Cooldown: don't spam "back to normal" for flapping workers
    now = time.time()
    last_resolved = _last_resolved_ts.get(name, 0)
    if now - last_resolved < 180:
        return

    _last_resolved_ts[name] = now

    # Edit the old alert to show resolved
    with _watchdog_lock:
        alert_info = _alert_msg_ids.pop(name, None)
    if alert_info:
        old_msg_id, old_text = alert_info
        resolved_text = f"✅ {name} resolved (was: {old_text.splitlines()[0]})"
        try:
            transport.edit_message(admin_chat_id, old_msg_id, resolved_text)
            print(f"[watchdog] Edited alert for {name} -> resolved")
            return
        except Exception:
            pass  # Fall through to send new message

    text = f"✅ {name} is back to normal."
    try:
        transport.send_text(admin_chat_id, text)
    except Exception as e:
        print(f"Watchdog resolved alert error: {e}")


def _handle_watchdog_transition(
    name: str,
    state: str,
    reason: str,
    since: float,
    now: Optional[float] = None,
) -> None:
    if now is None:
        now = time.time()

    bad_states = {"OFFLINE", "DEAD", "STUCK", "POISONED", "EXITED", "WAITING_INPUT"}
    good_states = {"READY", "BUSY_TOOL", "BUSY_THINKING"}
    with _watchdog_lock:
        prev_state = _prev_worker_states.get(name)
    state_changed = prev_state is None or prev_state != state

    def eligible_for_alert() -> bool:
        if state in {"OFFLINE", "DEAD", "EXITED"}:
            return since is not None and (now - since) >= START_GRACE
        return True

    GOOD_PROBE_THRESHOLD = 3

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
            _prev_worker_states[name] = state
        return

    if state in good_states and prev_state in bad_states:
        with _watchdog_lock:
            _consecutive_good_probes[name] = _consecutive_good_probes.get(name, 0) + 1
            good_count = _consecutive_good_probes[name]
        if good_count >= GOOD_PROBE_THRESHOLD:
            _send_resolved_alert(name, state)
            with _watchdog_lock:
                _consecutive_good_probes[name] = 0
                _prev_worker_states[name] = state
        return

    with _watchdog_lock:
        _consecutive_good_probes[name] = 0
        _prev_worker_states[name] = state


def _record_worker_state(name: str, state: str, reason: str, now: float) -> float:
    """Update worker state and preserve since for unchanged states."""
    with _watchdog_lock:
        prev = _worker_states.get(name)
        if prev and prev[0] == state:
            since = prev[2]
        else:
            since = now
        _worker_states[name] = (state, reason, since)
    return since


def watchdog_loop():
    while True:
        try:
            now = time.time()
            registered = get_registered_sessions()
            pane_pids = _tmux_pane_pids()

            registered_names = set(registered.keys())
            probe_failed = bool(registered_names) and not pane_pids
            if probe_failed:
                for name in registered_names:
                    _consecutive_probe_failures[name] = _consecutive_probe_failures.get(name, 0) + 1
            else:
                for name in registered_names:
                    _consecutive_probe_failures[name] = 0

            claude_pids = {}
            tmux_present = {}
            for name, session in registered.items():
                tmux_name = session.get("tmux", f"{TMUX_PREFIX}{name}")
                pane_pid = pane_pids.get(tmux_name)
                tmux_exists = bool(pane_pid)
                tmux_present[name] = tmux_exists

                if not tmux_exists:
                    continue

                claude_pid = _get_claude_pid(pane_pid)
                if claude_pid:
                    claude_pids[name] = claude_pid
                    with _watchdog_lock:
                        _last_seen_claude[name] = now
                else:
                    with _watchdog_lock:
                        if name not in _last_seen_claude:
                            _last_seen_claude[name] = now

            stats = _ps_stats(claude_pids.values())

            for name, session in registered.items():
                tmux_name = session.get("tmux", f"{TMUX_PREFIX}{name}")
                tmux_exists = tmux_present.get(name, False)

                # Registry-only worker (tmux gone): mark EXITED directly
                if not tmux_exists and "tmux" not in session:
                    since = _record_worker_state(name, "EXITED", "session gone", now)
                    _handle_watchdog_transition(name, "EXITED", "session gone", since, now=now)
                    continue

                if probe_failed and not tmux_exists and _consecutive_probe_failures.get(name, 0) < 3:
                    continue

                claude_pid = claude_pids.get(name)
                cpu = 0.0
                if claude_pid and claude_pid in stats:
                    cpu = stats[claude_pid].get("cpu", 0.0)

                children_total = _child_count(claude_pid) if claude_pid else 0

                # Dynamic baseline: MCP servers are persistent children.
                # Track idle child count so only EXTRA children count as work.
                pending_ts = _pending_timestamp(name)
                pending = pending_ts is not None
                if claude_pid:
                    with _watchdog_lock:
                        baseline = _idle_child_baseline.get(name)
                        if baseline is None:
                            # First observation — assume current count is baseline
                            _idle_child_baseline[name] = children_total
                            baseline = children_total
                        elif not pending:
                            # When idle, learn the true floor (MCP servers may start late)
                            baseline = min(baseline, children_total)
                            _idle_child_baseline[name] = baseline
                    children = max(0, children_total - baseline)
                else:
                    children = children_total

                if children > 0:
                    with _watchdog_lock:
                        _last_child_ts[name] = now

                # Activity detection: if children count increased or CPU is active,
                # worker is doing something. Reset the stale-pending timer so
                # long autonomous work doesn't trigger false STUCK alerts.
                # Only increases count — background sleep cycling (exit+restart)
                # causes ±1 flicker that shouldn't reset the timer.
                with _watchdog_lock:
                    prev_children = _prev_children.get(name)
                    activity_increased = (prev_children is not None and children > prev_children)
                    if activity_increased or cpu >= CPU_ACTIVE:
                        _last_activity_ts[name] = now
                    _prev_children[name] = children
                    last_activity = _last_activity_ts.get(name, 0.0)

                # pending_age counts from the LATER of: message arrival or last activity
                if pending_ts:
                    effective_start = max(pending_ts, last_activity) if last_activity > pending_ts else pending_ts
                    pending_age = now - effective_start
                else:
                    pending_age = 0.0
                with _watchdog_lock:
                    last_child_ts = _last_child_ts.get(name, 0.0)
                    last_hook_ts = _last_hook_ts.get(name)
                    last_seen_claude = _last_seen_claude.get(name)

                state_args = dict(
                    tmux_exists=tmux_exists,
                    claude_pid=claude_pid,
                    pending=pending,
                    pending_ts=pending_ts,
                    pending_age=pending_age,
                    children=children,
                    last_child_ts=last_child_ts,
                    cpu=cpu,
                    last_hook_ts=last_hook_ts,
                    last_seen_claude=last_seen_claude,
                    now=now,
                )
                state, reason = compute_state(**state_args)

                if state == "STUCK":
                    _idle_streak[name] = _idle_streak.get(name, 0) + 1
                    streak = _idle_streak[name]
                    if streak < IDLE_STREAK_STUCK:
                        state = "WAITING"
                    else:
                        poisoned_reason = _detect_poisoned(name, tmux_name)
                        state, reason = compute_state(
                            **state_args,
                            poisoned_reason=poisoned_reason
                        )
                    reason = f"{reason} streak={streak}/{IDLE_STREAK_STUCK}"
                elif state == "POISONED":
                    streak = _idle_streak.get(name, 0)
                    if streak:
                        reason = f"{reason} streak={streak}/{IDLE_STREAK_STUCK}"
                else:
                    _idle_streak[name] = 0

                # Detect interactive prompt (WAITING_INPUT): worker is READY
                # but TUI is at a selection/question prompt needing manager action
                if state == "READY":
                    pane_text = _capture_pane_text(tmux_name, lines=30)
                    if pane_text:
                        pane_lines = pane_text.splitlines()
                        details = _extract_question_details(pane_lines)
                        if details:
                            # Store details for the alert message
                            with _watchdog_lock:
                                _waiting_input_details[name] = details
                            state = "WAITING_INPUT"
                            header = details.get("header", "")
                            reason = f"question={header}" if header else "interactive prompt"

                since = _record_worker_state(name, state, reason, now)
                _handle_watchdog_transition(name, state, reason, since, now=now)
                # Surface live state to the topic user as an evolving reaction
                # (✍ working / 😴 stalled) on their in-flight message.
                _update_topic_reaction(name, state)

            with _watchdog_lock:
                for name in list(_worker_states.keys()):
                    if name not in registered_names:
                        _worker_states.pop(name, None)
                for name in list(_last_child_ts.keys()):
                    if name not in registered_names:
                        _last_child_ts.pop(name, None)
                for name in list(_last_seen_claude.keys()):
                    if name not in registered_names:
                        _last_seen_claude.pop(name, None)
                for name in list(_last_hook_ts.keys()):
                    if name not in registered_names:
                        _last_hook_ts.pop(name, None)
                for name in list(_prev_worker_states.keys()):
                    if name not in registered_names:
                        _prev_worker_states.pop(name, None)
                for name in list(_last_alert_ts.keys()):
                    if name not in registered_names:
                        _last_alert_ts.pop(name, None)
                for name in list(_idle_streak.keys()):
                    if name not in registered_names:
                        _idle_streak.pop(name, None)
                for name in list(_idle_child_baseline.keys()):
                    if name not in registered_names:
                        _idle_child_baseline.pop(name, None)
                for name in list(_prev_children.keys()):
                    if name not in registered_names:
                        _prev_children.pop(name, None)
                for name in list(_last_activity_ts.keys()):
                    if name not in registered_names:
                        _last_activity_ts.pop(name, None)
            for name in list(_consecutive_probe_failures.keys()):
                if name not in registered_names:
                    _consecutive_probe_failures.pop(name, None)
        except Exception as e:
            print(f"Watchdog error: {e}")

        time.sleep(WATCHDOG_INTERVAL)


# ─────────────────────────────────────────────────────────────────────────────
# Worker Backend Helpers
# ─────────────────────────────────────────────────────────────────────────────

def normalize_backend(backend: Optional[str]) -> str:
    """Return a normalized backend name with a safe default."""
    return backend or DEFAULT_BACKEND


def normalize_cwd(cwd: Optional[str]) -> str:
    """Expand ~ and return absolute path; empty string for unset/blank."""
    if cwd is None:
        return ""
    raw = cwd.strip()
    if not raw:
        return ""
    return os.path.abspath(os.path.expanduser(raw))


def validate_cwd(cwd: Optional[str]) -> tuple[str, str]:
    """Validate cwd path. Returns (normalized_path, error_message)."""
    normalized = normalize_cwd(cwd)
    if not normalized:
        return "", "cwd is empty"
    if not os.path.exists(normalized):
        return "", f"cwd does not exist: {normalized}"
    if not os.path.isdir(normalized):
        return "", f"cwd is not a directory: {normalized}"
    return normalized, ""


def _format_watchdog_status(name: str, pending_lookup=None, state_snapshot: Optional[dict] = None) -> str:
    if pending_lookup is None:
        pending_lookup = is_pending

    if state_snapshot is None:
        with _watchdog_lock:
            entry = _worker_states.get(name)
    else:
        entry = state_snapshot.get(name)
    if not entry:
        return "Working" if pending_lookup(name) else "Ready"

    state, _reason, since = entry
    now = time.time()

    if state == "READY":
        return "Ready"
    if state == "BUSY_TOOL":
        return "Working"
    if state == "BUSY_THINKING":
        return "Thinking"
    if state == "WAITING":
        return "Working"
    if state == "WAITING_INPUT":
        minutes = max(0, int((now - since) / 60)) if since else 0
        return f"Needs reply ({minutes}m)"
    if state == "STUCK":
        minutes = max(0, int((now - since) / 60)) if since else 0
        return f"No progress ({minutes}m)"
    if state == "POISONED":
        minutes = max(0, int((now - since) / 60)) if since else 0
        return f"Error loop ({minutes}m)"
    if state == "DEAD":
        return "Not responding"
    if state == "OFFLINE":
        return "Offline"
    if state == "EXITED":
        return "Session ended"
    if state == "UNTRACKED_BUSY":
        return "Working"
    return state.lower()


def _team_attention_summary(watchdog_status: str, activity: str) -> tuple[str, str, int]:
    """Return (icon, blocker_label, sort_rank) for /team rows."""
    status = (watchdog_status or "").lower()
    act = (activity or "").lower()

    if "rate limit" in act:
        return "🔴", "rate limit", 0
    if "error" in act or "traceback" in act or "not running" in act or "failed" in act:
        return "🔴", "error", 0
    if "needs input" in status or "needs reply" in status:
        return "🟡", "needs reply", 1
    if "stuck" in status or "no progress" in status:
        return "🔴", "stuck", 0
    if "poisoned" in status or "error loop" in status:
        return "🔴", "error loop", 0
    if "dead" in status or "not responding" in status:
        return "🔴", "stopped", 0
    if "offline" in status:
        return "🔴", "offline", 0
    if "exited" in status or "session ended" in status:
        return "🔴", "session ended", 0

    waiting_signals = (
        "waiting for",
        "awaiting",
        "approval",
        "accept edits",
        "confirm",
        "in plan mode",
    )
    if "working (waiting)" in status or any(sig in act for sig in waiting_signals):
        return "🟡", "needs reply", 1

    return "🟢", "ok", 2


def format_team_lines(
    registered: dict,
    active: Optional[str],
    pending_lookup=None,
    worker_live: Optional[dict] = None
) -> list[str]:
    """Format /team response lines with attention, activity, and context."""
    if pending_lookup is None:
        pending_lookup = is_pending
    if worker_live is None:
        worker_live = {}

    with _watchdog_lock:
        state_snapshot = dict(_worker_states)

    backend_values = set()
    for name, session in registered.items():
        live = worker_live.get(name, {})
        backend = normalize_backend(live.get("backend") or session.get("backend"))
        backend_values.add(backend)
    show_backend = len(backend_values) > 1

    rows = []
    counts = {"🔴": 0, "🟡": 0, "🟢": 0}
    for name in sorted(registered.keys()):
        session = registered[name]
        watchdog_status = _format_watchdog_status(name, pending_lookup, state_snapshot=state_snapshot)
        live = worker_live.get(name, {})
        backend = normalize_backend(live.get("backend") or session.get("backend"))

        raw_activity = (live.get("activity") or "").strip()
        if not raw_activity or raw_activity == "Unknown":
            raw_activity = watchdog_status
        activity = _normalize_activity(raw_activity)
        if len(activity) > 42:
            activity = activity[:39].rstrip() + "..."

        context_pct = (live.get("context_pct") or "").strip()
        icon, blocker, severity_rank = _team_attention_summary(watchdog_status, raw_activity)
        counts[icon] += 1

        name_cell = f"{name} 🎯" if name == active else name
        ctx_part = f" | ctx {context_pct}" if context_pct and context_pct != "--" else ""
        row = f"{icon} {name_cell} — {activity}{ctx_part}"
        if show_backend:
            row += f" | backend={backend}"

        focus_rank = 0 if name == active else 1
        rows.append((severity_rank, focus_rank, name, blocker, row))

    rows.sort(key=lambda item: (item[0], item[1], item[2]))
    attention_rows = [f"{name} ({blocker})" for rank, _focus, name, blocker, _row in rows if rank < 2]

    lines = []
    focused = active or "(none)"
    lines.append(
        f"Team: {len(registered)} agents · focused: {focused} | "
        f"🟢 {counts['🟢']} ok · 🟡 {counts['🟡']} need reply · 🔴 {counts['🔴']} blocked"
    )
    if attention_rows:
        lines.append("Needs your reply: " + ", ".join(attention_rows))
    lines.extend(row for _rank, _focus, _name, _blocker, row in rows)
    return lines


def _normalize_activity(raw: str) -> str:
    """Normalize Claude Code spinner verbs to human-friendly text.

    Claude Code TUI shows random verbs like "Ionizing", "Hullaballooing",
    "Schlepping" as thinking spinner text. These are meaningless to managers.
    Normalize single-word spinner verbs to "Thinking (duration)".

    Multi-word activities like "Running Bash", "Compacting conversation",
    "In plan mode", etc. pass through unchanged.
    """
    if not raw:
        return raw
    # Pattern: single capitalized gerund word optionally followed by (duration)
    m = re.match(r'^([A-Z][a-z]+ing)\s*(?:\((.+)\))?\s*$', raw)
    if m:
        dur = m.group(2)
        # Known multi-word prefixes that happen to start with a gerund are handled
        # by the regex requiring the FULL string to be one word + optional duration.
        # "Running Bash" won't match because "Bash" follows after a space.
        # "Compacting conversation (5m)" won't match because "conversation" follows.
        # Only single-word verbs like "Ionizing", "Whirring" match.
        if dur:
            return f"Thinking ({dur})"
        return "Thinking"
    return raw


def _extract_activity(lines: list[str]) -> str:
    """Extract a 1-line activity summary from tmux pane output.

    Based on Claude Code v2.1.59 (repo d6ab0ea, 2026-02-26).
    Scans for Claude Code UI signals. Priority:
    1.  Active thinking spinner (· Verb… / * Verb…) — NOT ✻ (past tense)
    2.  Tool actively running (● ToolName( + ⎿ Running…)
    3.  Rate limiting / connection errors (blockers — before prompt check)
    4.  Mode bars (⏵⏵ permission/accept-edits, ⏸ plan mode) vs idle (❯)
    5.  Editor mode ("Save and close editor to continue...")
    6.  Hook execution ("Running SessionStart/PreCompact hooks…")
    7.  Confirmation prompts (plan approval, accept edits, team lead, etc.)
    8.  Task progress (✔/◻)
    9.  Last ● output block (non-tool)
    10. Standalone error line
    """
    if not lines:
        return "Active"

    stripped = [l.strip() for l in lines if l.strip()]
    if not stripped:
        return "Idle"

    # 1. Active thinking spinner — "· Verb…" or "* Verb…" or "✢ Verb…" etc.
    #    Claude Code cycles through various Unicode chars as spinner frames.
    #    ✻ is ALSO a spinner frame (not just past tense) — distinguish by "…" presence.
    #    "✻ Verbing… (49m)" = active; "✻ Thought for 5s" = completed (no "…").
    _ACTIVE_SPINNER_CHARS = {"·", "*", "✢", "✦", "✧", "✹", "✵", "∙", "•", "✻"}
    for raw in reversed(stripped):
        first = raw[0] if raw else ""
        if first == "✻" and "…" not in raw and "..." not in raw:
            continue  # Past tense completed thinking (no ellipsis = done)
        if first not in _ACTIVE_SPINNER_CHARS:
            continue
        # "· Compacting conversation… (5m 26s · thought for 5s)" → verb + duration
        m = re.match(r'^.\s+(.+?)(?:…|\.{3})\s*\(([^()]+)\)\s*$', raw)
        if m:
            verb = m.group(1).strip()
            dur = m.group(2).split('·')[0].strip()
            return f"{verb} ({dur})"
        # Fallback: "· Verb…" or "· Verb" without duration ($ anchor fixes greedy)
        vm = re.match(r'^.\s+(.+?)(?:…|\.{3})?\s*$', raw)
        if vm:
            verb = vm.group(1).strip()
            dm = re.search(r'(\d+m?\s*\d*\.?\d*s)', raw)
            return f"{verb} ({dm.group(1).strip()})" if dm else verb

    # 2. Tool actively running: "● ToolName(...)" followed by "⎿ Running…"
    #    Also handles MCP tools: "● mcp__server__tool("
    last_running_tool = None
    for i, raw in enumerate(stripped):
        m_tool = re.match(r'^●\s*([A-Za-z][A-Za-z0-9_]*(?:__[A-Za-z0-9_]+)*)\(', raw)
        if not m_tool:
            continue
        tool = m_tool.group(1)
        # Look ahead up to 5 lines for "⎿ Running…" (tolerant of intermediate lines)
        for j in range(i + 1, min(i + 6, len(stripped))):
            s = stripped[j]
            if not s:
                continue
            if s.startswith("⎿"):
                if "Running" in s and "background" not in s:
                    last_running_tool = tool
                break
    if last_running_tool:
        # Shorten MCP tool names: mcp__figma__get_file → figma.get_file
        if last_running_tool.startswith("mcp__"):
            parts = last_running_tool.split("__")
            last_running_tool = ".".join(parts[1:]) if len(parts) > 1 else last_running_tool
        return f"Running {last_running_tool}"

    # 3. Rate limiting / connection errors (BEFORE prompt — blockers override idle)
    for raw in reversed(stripped):
        ll = raw.lower()
        if "rate limit" in ll:
            return "Rate limited — waiting to retry"
        if "connection error" in ll and "retrying" in ll:
            return "Connection error — retrying"
        if ll.startswith("retrying") or "retrying in" in ll:
            return "Retrying API request"

    # 3b. Interactive prompts — Claude Code TUI has taken over input.
    #      These footer lines appear at the bottom when a selection/question UI
    #      is active. The ❯ symbol in these states is a SELECTION CURSOR, not
    #      the text input prompt. Must check BEFORE the ❯ prompt check below.
    #      Uses module-level _INTERACTIVE_FOOTERS list (shared with _extract_question_details).
    for raw in reversed(stripped):
        for footer in _INTERACTIVE_FOOTERS:
            if footer in raw:
                # Try to extract question header (☐ line)
                for q_raw in stripped:
                    if "☐" in q_raw:
                        q = q_raw.replace("☐", "").strip()
                        if q:
                            return f"Waiting for input: {q}"
                return "Waiting for user input"

    # 3c. Content-based interactive detection — prompts without standard footers.
    #      ExitPlanMode, EnterPlanMode, and tool permission prompts may not render
    #      any _INTERACTIVE_FOOTERS pattern (e.g. plan approval only shows "ctrl-g to edit"
    #      when an editor is configured, and nothing at all otherwise).
    #      Must check BEFORE the ❯ prompt check to avoid misclassifying ❯ selection cursor.
    #      Uses module-level _INTERACTIVE_CONTENT list.
    for raw in stripped:
        for pattern in _INTERACTIVE_CONTENT:
            if pattern in raw:
                # Check if this is a plan approval specifically
                if "plan" in raw.lower() and ("proceed" in raw.lower() or "execute" in raw.lower()):
                    return "Waiting for plan approval"
                if "plan mode" in raw.lower():
                    return "Waiting for plan mode decision"
                if raw.startswith("Allow "):
                    return "Waiting for tool permission"
                return "Waiting for user input"

    # 4. Prompt + mode bars — all bottom-bar elements are informational, not blocking
    #    ⏵⏵ bypass permissions on · 1 bash    → mode bar (bypass ON, 1 bash auto-approved)
    #    ⏵⏵ bypass permissions on (shift+tab)  → mode bar (bypass ON, no recent actions)
    #    ⏵⏵ accept edits on (shift+tab)       → mode bar (accept edits mode)
    #    ⏸ plan mode on (shift+tab to cycle)  → plan mode indicator
    #    ❯                                     → idle prompt
    #    ❯ some text                           → idle (auto-suggestion hint, not a message)
    #
    #  "bypass permissions on" means permissions ARE being bypassed — worker is NOT blocked.
    #  The · N action count shows what was auto-approved (informational).
    last_prompt_idx = None
    last_plan_bar_idx = None  # "⏸ plan mode on"
    for i, raw in enumerate(stripped):
        if raw.startswith("❯"):
            last_prompt_idx = i
        if raw.startswith("⏸"):
            last_plan_bar_idx = i

    # ⏸ plan mode bar (persistent at bottom, only if no prompt after it)
    if last_plan_bar_idx is not None:
        if last_prompt_idx is None or last_prompt_idx < last_plan_bar_idx:
            return "In plan mode"

    # Prompt present = ready (text after ❯ is auto-suggestion hint)
    if last_prompt_idx is not None:
        return "Ready"

    # 5. Editor mode — worker waiting for external editor
    for raw in reversed(stripped):
        if "Save and close editor to continue" in raw:
            return "Waiting for external editor"

    # 6. Hook execution — system hooks running
    for raw in reversed(stripped):
        if "Running SessionStart" in raw:
            return "Running SessionStart hooks"
        if "Running PreCompact" in raw:
            return "Running PreCompact hooks"

    # 7. Confirmation prompts (plan approval, team lead, etc.)
    for raw in reversed(stripped):
        if "Do you want to proceed?" in raw or "Would you like to proceed?" in raw:
            return "Waiting for plan approval"
        if "Exit plan mode?" in raw or "Entering plan mode" in raw:
            return "In plan mode"
        if "Waiting for team lead" in raw:
            return "Waiting for team lead approval"

    # 8. Task progress
    done = 0
    total = 0
    for raw in stripped:
        s = raw.lstrip()
        if s.startswith("✔") or s.startswith("✅"):
            done += 1
            total += 1
        elif s.startswith("◻"):
            total += 1
    if total >= 2:
        return f"Tasks ({done}/{total} done)"

    # 9. Last non-tool ● output block
    def _is_block_end(text):
        t = text.lstrip()
        if t.startswith("Context left until auto-compact:"):
            return True
        return t.startswith(("●", "·", "*", "✻", "─", "❯", "⏵", "⏸"))

    for i in range(len(stripped) - 1, -1, -1):
        raw = stripped[i]
        if not raw.startswith("●"):
            continue
        # Skip tool calls (● CapitalWord( or ● mcp__server__tool()
        if re.match(r'^●\s*[A-Za-z][A-Za-z0-9_]*(?:__[A-Za-z0-9_]+)*\(', raw):
            continue
        parts = []
        head = re.sub(r'^●\s*', '', raw).strip()
        if head and not head.startswith("⎿") and not head.startswith("(ctrl+"):
            parts.append(head)
        j = i + 1
        while j < len(stripped):
            nxt = stripped[j]
            if _is_block_end(nxt):
                break
            t = nxt.strip()
            if t and not t.startswith("⎿") and not t.startswith("(ctrl+"):
                parts.append(t)
            j += 1
        if parts:
            msg = re.sub(r'\s+', ' ', ' '.join(parts)).strip()
            if len(msg) > 120:
                msg = msg[:117].rstrip() + "..."
            return msg

    # 10. Standalone error (case-insensitive for broader coverage)
    for raw in reversed(stripped):
        if re.match(r'^(FAIL|ERROR|Error|Traceback|Fail)\b', raw, re.IGNORECASE):
            ll = raw.lower()
            if ll.startswith("error"):
                tail = raw[len("Error"):].lstrip(": ").strip()
                return f"Error: {tail}" if tail else "Error"
            return f"Error: {raw[:60]}"

    return "Active"


def _extract_context_pct(lines: list[str]) -> Optional[str]:
    """Extract context % from tmux output if present."""
    for line in reversed(lines):
        m = re.search(r'Context left.*?(\d+)%', line)
        if m:
            return f"{m.group(1)}%"
    return None


def _read_tmux_activity(tmux_name: str) -> tuple:
    """Read tmux pane and extract activity summary + context% + raw lines.

    Returns (activity_str, context_pct_str_or_None, raw_lines_or_None).
    """
    try:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", tmux_name, "-p"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return "Unknown", None, None
        lines = result.stdout.split("\n")
        tail = lines[-40:]
        return _extract_activity(tail), _extract_context_pct(tail), tail
    except Exception:
        return "Unknown", None, None


def _wait_for_restart_ready(tmux_name: str, backend_name: str, timeout: float = 45.0) -> bool:
    """Wait until restarted worker is actually back at the prompt."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not tmux_exists(tmux_name):
            return False
        activity, _, _ = _read_tmux_activity(tmux_name)
        if activity == "Idle at prompt":
            return True
        time.sleep(0.5)
    return False


# Interactive footer patterns (kept in sync with _extract_activity step 3b)
_INTERACTIVE_FOOTERS = [
    "Enter to select",      # AskUserQuestion single-select
    "Space to toggle",      # AskUserQuestion multi-select
    "Tab to toggle",        # Toggle confirm
    "Type to search",       # Searchable list
    "Enter to submit",      # Text submission prompt
    "Enter to add",         # Autocomplete
    "Enter to retry",       # Retry prompt
    "Enter to continue",    # Continue/proceed prompt
    "Enter to try again",   # Retry variant
    "Enter to confirm",     # Selection confirm variant
    "ctrl-g to edit",       # ExitPlanMode plan approval (editor configured)
    "Auto-approving in",    # ExitPlanMode auto-approve countdown
    "Press any key to intervene",  # ExitPlanMode auto-approve variant
]

# Content patterns that indicate an interactive prompt even without a matching footer.
# These are checked BEFORE the ❯ idle-prompt detection (step 3c) to avoid misclassifying
# the ❯ selection cursor as the text input prompt.
_INTERACTIVE_CONTENT = [
    # ExitPlanMode "Ready to code?" prompt
    "Would you like to proceed?",
    "written up a plan and is ready to execute",
    # EnterPlanMode prompt
    "wants to enter plan mode",
    "No code changes will be made until you approve",
    # Tool permission prompts
    "Allow Bash",
    "Allow Read",
    "Allow Write",
    "Allow Edit",
    "Allow Glob",
    "Allow Grep",
    "Allow Agent",
    "Allow Notebook",
]


def _extract_question_details(lines: list[str]) -> Optional[dict]:
    """Extract interactive question details from tmux pane output.

    Returns dict with:
      header: str — question title from ☐ line (or "")
      options: list of {num: int, label: str, selected: bool}
      selected_num: int — currently selected option number (or 0)
    Returns None if no interactive prompt detected.
    """
    if not lines:
        return None

    stripped = [l.strip() for l in lines if l.strip()]
    if not stripped:
        return None

    # If the idle ❯ prompt appears in the last few lines, the dialog was
    # already dismissed — it's just still visible in scrollback above.
    tail = stripped[-5:]
    if any(line == "❯" for line in tail):
        return None

    # Check for interactive footer or content patterns
    has_interactive = False
    for raw in reversed(stripped):
        for footer in _INTERACTIVE_FOOTERS:
            if footer in raw:
                has_interactive = True
                break
        if has_interactive:
            break
    if not has_interactive:
        for raw in stripped:
            for pattern in _INTERACTIVE_CONTENT:
                if pattern in raw:
                    has_interactive = True
                    break
            if has_interactive:
                break
    if not has_interactive:
        return None

    # Extract header (☐ line)
    header = ""
    for raw in stripped:
        if "☐" in raw:
            header = raw.replace("☐", "").strip()
            break

    # Extract options: lines matching "❯? N. Label" or "  N. Label"
    # Option lines start with optional ❯, then number + dot
    options = []
    selected_num = 0
    opt_re = re.compile(r'^(❯)?\s*(\d+)\.\s+(.+)')
    for raw in stripped:
        m = opt_re.match(raw)
        if m:
            is_selected = m.group(1) == "❯"
            num = int(m.group(2))
            label = m.group(3).strip()
            options.append({"num": num, "label": label, "selected": is_selected})
            if is_selected:
                selected_num = num

    if not options:
        return None

    return {
        "header": header,
        "options": options,
        "selected_num": selected_num,
    }


def _send_interactive_reply(tmux_name: str, reply: str, details: dict) -> bool:
    """Handle manager's reply to an interactive prompt via keystroke navigation.

    reply: "1"-"9" for option selection, "skip"/"cancel" for Escape.
    details: from _extract_question_details().
    Returns True if handled, False if not applicable.
    """
    reply = reply.strip().lower()

    if reply in ("skip", "cancel", "esc"):
        subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Escape"])
        return True

    if reply.isdigit():
        target_num = int(reply)
        # Find target option index and current selected index
        option_nums = [o["num"] for o in details["options"]]
        if target_num not in option_nums:
            return False

        target_idx = option_nums.index(target_num)
        current_idx = 0
        for i, o in enumerate(details["options"]):
            if o["selected"]:
                current_idx = i
                break

        diff = target_idx - current_idx
        keys = []
        if diff > 0:
            keys = ["Down"] * diff
        elif diff < 0:
            keys = ["Up"] * abs(diff)
        keys.append("Enter")

        for key in keys:
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, key])
            time.sleep(0.05)
        return True

    return False


def format_progress_lines(
    name: str,
    pending: bool,
    backend: str,
    online: bool,
    ready: bool,
    mode: str,
    resume_line: Optional[str] = None,
    continuity_line: Optional[str] = None,
    needs_attention: Optional[str] = None,
    activity: Optional[str] = None,
    context_pct: Optional[str] = None,
    question_details: Optional[dict] = None
) -> list[str]:
    """Format /progress response lines (manager-friendly)."""
    status = []

    # Header with name + context%
    watchdog_status = _format_watchdog_status(name)
    ctx = f" · context {context_pct}" if context_pct else ""
    status.append(f"{name.capitalize()} ({backend}) — {watchdog_status}{ctx}")

    # Activity line (what they're doing right now)
    if activity:
        status.append(f"Doing: {activity}")
    elif not online:
        status.append("Doing: Offline")
    elif pending:
        status.append("Doing: Working on a request")

    # Rich question details (when at interactive prompt)
    if question_details and question_details.get("options"):
        opts = question_details["options"]
        if question_details.get("header"):
            status.append(f"\n{question_details['header']}")
        for o in opts:
            marker = "\u2794 " if o.get("selected") else "  "
            status.append(f"{marker}{o['num']}. {o['label']}")
        max_num = max(o["num"] for o in opts)
        status.append(f"\nReply 1-{max_num} to pick, \"skip\" to cancel")

    # Blockers / attention
    if needs_attention:
        status.append(f"Blocker: {needs_attention}")

    # Session info
    if continuity_line:
        status.append(continuity_line)
    elif resume_line:
        status.append(resume_line)

    return status


def get_worker_backend(name: str, session: Optional[dict] = None) -> str:
    """Get backend for a worker.

    Backend comes from the live session/registry cache; Claude is the default.
    """
    if session and session.get("backend"):
        return normalize_backend(session.get("backend"))
    return DEFAULT_BACKEND


class WorkerManager:
    def __init__(self, sessions_dir: Path, tmux_prefix: str):
        self.sessions_dir = sessions_dir
        self.tmux_prefix = tmux_prefix

    def _sync_paths(self):
        if self.sessions_dir != SESSIONS_DIR:
            self.sessions_dir = SESSIONS_DIR
        if self.tmux_prefix != TMUX_PREFIX:
            self.tmux_prefix = TMUX_PREFIX

    def _get_startup_cwd(self, name: str, requested_cwd: str = "", fallback_cwd: str = "") -> str:
        """Resolve startup cwd with priority: explicit > RAM hint > disk > fallback."""
        candidate = normalize_cwd(requested_cwd)
        if not candidate:
            candidate = normalize_cwd(_get_worker_cwd(name))
        if not candidate:
            candidate = normalize_cwd(get_claude_session_cwd(name))
        if candidate:
            if os.path.isdir(candidate):
                return candidate
            print(f"Ignoring invalid startup cwd for {name}: {candidate}")

        fallback = normalize_cwd(fallback_cwd)
        if fallback and os.path.isdir(fallback):
            return fallback
        return ""

    def _get_tmux_pane_cwd(self, tmux_name: str) -> str:
        """Read current pane cwd for a tmux session."""
        result = subprocess.run(
            ["tmux", "display-message", "-t", tmux_name, "-p", "#{pane_current_path}"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return ""

    def _cd_tmux_to_cwd(self, tmux_name: str, cwd: str):
        """Change tmux shell cwd before starting backend process."""
        if not cwd:
            return
        subprocess.run(["tmux", "send-keys", "-t", tmux_name, f"cd {shlex.quote(cwd)}", "Enter"])
        time.sleep(0.2)

    def scan_tmux_sessions(self):
        """Scan tmux for claude-* sessions (registered)."""
        self._sync_paths()
        registered = {}

        try:
            result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}"],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                return registered

            for line in result.stdout.strip().split("\n"):
                if not line:
                    continue
                session_name = line.strip()

                if session_name.startswith(self.tmux_prefix):
                    name = session_name[len(self.tmux_prefix):]
                    backend = normalize_backend(get_tmux_env_value(session_name, "WORKER_BACKEND"))
                    registered[name] = {"tmux": session_name, "backend": backend}
        except Exception as e:
            print(f"Error scanning tmux: {e}")

        return registered

    def get_registered_sessions(self, registered=None):
        """Get registered sessions from tmux (all backends have tmux now)."""
        self._sync_paths()
        if registered is None:
            registered = self.scan_tmux_sessions()

        # Merge persistent registry: workers in registry but not in tmux
        # appear with no "tmux" key.
        # On first run, bootstrap registry from current tmux sessions.
        _registry_bootstrap(registered)
        registry = _load_registry()
        for name, info in registry.get("workers", {}).items():
            if name not in registered:
                entry = {"backend": info.get("backend", DEFAULT_BACKEND)}
                registered[name] = entry

        return registered

    def is_online(self, name: str, session: dict = None) -> bool:
        """Check if worker is online and ready."""
        self._sync_paths()
        if not session:
            sessions = self.get_registered_sessions()
            session = sessions.get(name)
        if not session:
            return False

        backend_name = normalize_backend(session.get("backend"))
        backend = get_backend(backend_name)
        tmux_name = session.get("tmux", f"{self.tmux_prefix}{name}")

        return backend.is_online(tmux_name)

    def send(self, name: str, message: str, chat_id: int = None, session: dict = None) -> bool:
        """Send message to worker using backend registry."""
        self._sync_paths()
        if not session:
            sessions = self.get_registered_sessions()
            session = sessions.get(name)
        if not session:
            return False

        backend_name = normalize_backend(session.get("backend"))
        backend = get_backend(backend_name)
        tmux_name = session.get("tmux", f"{self.tmux_prefix}{name}")

        return backend.send(name, tmux_name, message, BRIDGE_URL, self.sessions_dir)

    def get_workers(self, caller_from: str = None):
        """Get all active workers with their communication details."""
        self._sync_paths()
        workers = []
        registered = self.get_registered_sessions()
        for name, info in registered.items():
            if "tmux" not in info:
                workers.append({
                    "name": name,
                    "machine": "",
                    "protocol": "none",
                    "address": "",
                    "status": "exited",
                    "note": "Worker exited. Reopen its 話題 (or /cd <path> inside it) to restart.",
                })
                continue

            tmux_name = info.get("tmux")
            tmux_cmd = (
                f"echo 'YOUR_NAME: your message here' | "
                f"tmux load-buffer - && "
                f"tmux paste-buffer -p -r -t {tmux_name} && "
                f"sleep 1 && tmux send-keys -t {tmux_name} Enter"
            )
            note = "Uses paste-buffer -p (bracketed paste) for reliable delivery. Sleep 1s before Enter — TUI needs time to render. Always prefix your name."
            workers.append({
                "name": name,
                "machine": "",
                "protocol": "tmux",
                "address": tmux_name,
                "send_example": tmux_cmd,
                "note": note,
            })
        return workers

    def _build_welcome(self, name: str, backend_obj) -> str:
        """Build welcome/instructions message for a worker."""
        if TOPIC_MODE:
            # Topic-native: one 話題 = one dedicated session, so drop the
            # multi-worker framing (/workers discovery, name prefixing,
            # worker-to-worker messaging).
            welcome = (
                "You are connected to Telegram via claudecode-telegram. This 話題 (topic) is your "
                "dedicated session: the manager's messages arrive as prompts and your replies go "
                "straight back into this topic. "
                "RECEIVING FILES: Manager-sent files (images, PDFs, documents) appear as local paths you can read directly. "
                "SENDING FILES: Use [[image:/path/to/photo.png|caption]] for images (jpg/png/webp/bmp) and animations (gif/mp4), or [[file:/path/to/file|caption]] for documents, video (mp4/mov/avi — shows player), audio (mp3/m4a/flac — shows player), and voice (ogg/opus — voice bubble). "
                "WORKING DIRECTORY: the manager switches your project folder from Telegram with /cd <path> (reloads CLAUDE.md). "
                f"REFRESH INSTRUCTIONS: run `curl -s $BRIDGE_URL/checkin?name={name}` to re-read these instructions anytime. "
                "Messages from the manager arrive as prompts — there is NO polling endpoint."
            )
        else:
            welcome = (
                "You are connected to Telegram via claudecode-telegram bridge. "
                "RECEIVING FILES: Manager sends files (images, PDFs, documents) — they appear as local paths you can read directly. "
                "SENDING FILES: Use [[image:/path/to/photo.png|caption]] for images (jpg/png/webp/bmp) and animations (gif/mp4), or [[file:/path/to/file|caption]] for documents, video (mp4/mov/avi — shows player), audio (mp3/m4a/flac — shows player), and voice (ogg/opus — voice bubble). "
                f"MESSAGING WORKERS: Run `curl -s \"$BRIDGE_URL/workers?from={name}\"` to discover other workers — returns JSON with a `send_example` field containing ready-to-use send commands wrapped correctly for your machine (auto-adds ssh when a peer lives elsewhere). Always call /workers?from={name} before messaging, never guess addresses. "
                f"NAME PREFIX: Always prefix your name in messages (e.g., '{name}: your message'). "
                f"REFRESH INSTRUCTIONS: Run `curl -s $BRIDGE_URL/checkin?name={name}` to re-read these instructions anytime. "
                f"WORKING DIRECTORY: To switch project directory (reloads CLAUDE.md), run `curl -s \"$BRIDGE_URL/checkin?name={name}&cwd=/path/to/project\"`. "
                "BRIDGE API: Available endpoints: GET /workers, GET /checkin. Messages from manager arrive as prompts — there is NO polling endpoint. "
                "WARNING: Do NOT output worker messages normally — they go to Telegram. Use the send commands from /workers instead."
            )
        if SANDBOX_ENABLED:
            welcome += " Running in sandbox mode (Docker container)."

        # Append manager note if set (with {name} and {machine} substitution)
        note = read_checkin_note()
        if note:
            rendered = note.replace("{name}", name)
            machine = NODE_NAME or "bridge host"
            rendered = rendered.replace("{machine}", machine)
            welcome += f"\n\nMANAGER NOTE:\n{rendered}"
            print(f"Checkin note included for {name}")

        return welcome

    def hire(self, name: str, backend: str = DEFAULT_BACKEND, chat_id: int = None):
        """Create a new worker instance."""
        self._sync_paths()
        if not is_valid_backend(backend):
            return False, f"Unknown backend '{backend}'. Available: {', '.join(list_backends())}"

        backend_obj = get_backend(backend)

        # Check binary exists before creating tmux session
        if not _which_binary(backend_obj.binary):
            return False, f"'{backend_obj.binary}' not found in PATH. Install it first."

        tmux_name = f"{self.tmux_prefix}{name}"
        if tmux_exists(tmux_name):
            return False, f"Worker '{name}' already exists"

        # Strip CLAUDECODE from env so new tmux shell doesn't inherit it
        # (Claude Code refuses to start if it detects a parent session)
        clean_env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
        # Root fix: start the pane directly in the worker's target cwd via `-c`.
        # Resolving startup_cwd BEFORE new-session lets the shell be *born* in the
        # right directory, so we never inject a `cd` keystroke and then race a
        # pane-cwd readback (the old dance captured #{pane_current_path} mid-line
        # while trust-prompt/welcome keystrokes interleaved, persisting corrupted
        # paths like ".../cc-switch546"). startup_cwd is the RAM hint set by
        # _set_worker_cwd before create_session.
        startup_cwd = self._get_startup_cwd(name)
        new_session = ["tmux", "new-session", "-d", "-s", tmux_name, "-x", "200", "-y", "50"]
        if startup_cwd and os.path.isdir(startup_cwd):
            new_session += ["-c", startup_cwd]
        result = subprocess.run(new_session, capture_output=True, env=clean_env)
        if result.returncode != 0:
            return False, "Could not start the worker workspace"

        # Pane is now born in startup_cwd — no cd keystroke, no readback, no race.
        # Persist the authoritative cwd directly (matches restart()).
        if startup_cwd:
            save_claude_session_cwd(name, startup_cwd)

        time.sleep(0.5)  # let the pane shell finish init before injecting env
        export_hook_env(tmux_name, backend)
        time.sleep(0.3)

        # Inject tmux env vars then unset CLAUDECODE (prevents nested-session error)
        subprocess.run(["tmux", "send-keys", "-t", tmux_name,
                        'eval "$(tmux show-environment -s)" && unset CLAUDECODE', "Enter"])
        time.sleep(0.3)

        ensure_session_dir(name)

        if SANDBOX_ENABLED:
            if startup_cwd:
                self._cd_tmux_to_cwd(tmux_name, startup_cwd)
            docker_cmd = get_docker_run_cmd(name)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, docker_cmd, "Enter"])
            print(f"Started worker '{name}' in sandbox mode")
        else:
            start_cmd = f'unset CLAUDECODE && {backend_obj.start_cmd()}'
            if startup_cwd:
                start_cmd = f'cd {shlex.quote(startup_cwd)} && {start_cmd}'
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, start_cmd, "Enter"])
            # Answer Claude's "Do you trust the files in this folder?" dialog,
            # but only if it actually appears.
            time.sleep(1.5)
            pane = _capture_pane_text(tmux_name, lines=20).lower()
            if any(m in pane for m in ("do you trust", "trust the files", "trust this folder")):
                subprocess.run(["tmux", "send-keys", "-t", tmux_name, "2"])
                time.sleep(0.3)
                subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Enter"])

        time.sleep(2.0 if not SANDBOX_ENABLED else 5.0)

        welcome = self._build_welcome(name, backend_obj)
        if not TOPIC_MODE:
            # In TOPIC_MODE the welcome is delivered folded into the topic's first
            # message by open_topic_session (one turn -> one reply), so skip the
            # standalone greeting here to avoid a duplicate "你好" reply.
            self.send(name, welcome)

        # No focus/active concept: a 話題 IS the addressing — which session you
        # talk to is decided by which topic you type in, never by bridge state.
        _registry_add(name, backend, chat_id)

        return True, None

    def end(self, name: str):
        """Kill a worker instance."""
        self._sync_paths()
        registered = self.get_registered_sessions()
        if name not in registered:
            return False, f"Worker '{name}' not found"

        session = registered[name]
        tmux_name = session.get("tmux", f"{self.tmux_prefix}{name}")

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

        if SANDBOX_ENABLED:
            stop_docker_container(name)

        clear_pending(name)
        _set_worker_cwd(name, "")
        # Kill tmux session if it exists (may already be gone for registry-only workers)
        subprocess.run(["tmux", "kill-session", "-t", tmux_name], capture_output=True)
        cleanup_inbox(name)
        _registry_remove(name)

        return True, None

    def restart(self, name: str, mode: str = "relaunch"):
        """Restart a worker in its existing tmux session.

        If tmux session is gone but worker is in the persistent registry,
        re-creates the tmux session and restarts the backend (dead worker recovery).
        """
        self._sync_paths()
        registered = self.get_registered_sessions()
        if name not in registered:
            return False, f"Worker '{name}' not found"

        session = registered[name]
        backend_name = get_worker_backend(name, session)
        backend = get_backend(backend_name)
        tmux_name = session.get("tmux", f"{self.tmux_prefix}{name}")

        # A restart abandons any in-flight request, so always release pending
        # (covers live-session, dead-worker, resume, relaunch and clean modes).
        clear_pending(name)

        if not tmux_exists(tmux_name):
            # Dead worker recovery: re-create tmux session if worker is in registry
            return self._restart_dead_worker(name, backend_name, backend, tmux_name, mode)

        # Check binary still exists before restarting
        if not _which_binary(backend.binary):
            return False, f"'{backend.binary}' not found in PATH. Install it first."

        resume_id = ""
        resume_cwd = ""
        session_dir = self.sessions_dir / name
        if mode == "resume":
            resume_id = get_claude_session_id(name, authoritative=True)
            resume_cwd = get_claude_session_cwd(name)
        else:
            session_dir.mkdir(parents=True, exist_ok=True)
            for session_id_file in session_dir.glob("*_session_id"):
                session_id_file.unlink()
        startup_cwd = self._get_startup_cwd(name, fallback_cwd=resume_cwd)
        if startup_cwd:
            save_claude_session_cwd(name, startup_cwd)

        # Clear hook failure signal on clean restart
        if mode != "resume":
            _clear_hook_failures(name)

        if is_claude_running(tmux_name):
            # Kill running claude first, then restart (resume keeps session ID, relaunch clears it)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "C-c", ""])
            time.sleep(0.5)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "/exit", "Enter"])
            time.sleep(1.0)
            # If still running, force kill
            if is_claude_running(tmux_name):
                pane_pid = _tmux_pane_pids().get(tmux_name)
                if pane_pid:
                    claude_pid = _get_claude_pid(pane_pid)
                    if claude_pid:
                        subprocess.run(["kill", claude_pid], capture_output=True)
            # Poll until Claude has actually exited (fixed sleep races with slow exits)
            for _ in range(20):
                if not is_claude_running(tmux_name):
                    break
                time.sleep(0.25)
            else:
                print(f"[restart] {name}: Claude still running after 5s kill wait")

        export_hook_env(tmux_name, backend_name)
        time.sleep(0.3)

        # Inject tmux env vars then unset CLAUDECODE (prevents nested-session error)
        subprocess.run(["tmux", "send-keys", "-t", tmux_name,
                        'eval "$(tmux show-environment -s)" && unset CLAUDECODE', "Enter"])
        time.sleep(0.3)

        if SANDBOX_ENABLED:
            stop_docker_container(name)
            time.sleep(0.5)
            if startup_cwd:
                self._cd_tmux_to_cwd(tmux_name, startup_cwd)
            docker_cmd = get_docker_run_cmd(name, resume_id=resume_id)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, docker_cmd, "Enter"])
        else:
            start_cmd = backend.start_cmd(resume_id)
            start_cmd = f'unset CLAUDECODE && {start_cmd}'
            if startup_cwd:
                start_cmd = f'cd {shlex.quote(startup_cwd)} && {start_cmd}'
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, start_cmd, "Enter"])

        # Re-send welcome/instructions so worker gets fresh context after restart
        welcome = self._build_welcome(name, backend)
        time.sleep(2.0 if not SANDBOX_ENABLED else 5.0)
        self.send(name, welcome)

        return True, None

    def _restart_dead_worker(self, name: str, backend_name: str, backend, tmux_name: str, mode: str):
        """Re-create a dead worker (tmux gone) from registry.

        Creates a new tmux session, exports env, starts backend, sends welcome.
        Preserves session files (session_id, cwd) for resume capability.
        """
        if not _which_binary(backend.binary):
            return False, f"'{backend.binary}' not found in PATH. Install it first."

        # Create new tmux session
        clean_env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
        result = subprocess.run(
            ["tmux", "new-session", "-d", "-s", tmux_name, "-x", "200", "-y", "50"],
            capture_output=True, env=clean_env
        )
        if result.returncode != 0:
            return False, "Could not create worker workspace"

        time.sleep(0.5)
        export_hook_env(tmux_name, backend_name)
        time.sleep(0.3)

        subprocess.run(["tmux", "send-keys", "-t", tmux_name,
                        'eval "$(tmux show-environment -s)" && unset CLAUDECODE', "Enter"])
        time.sleep(0.3)

        ensure_session_dir(name)

        resume_id = ""
        resume_cwd = ""
        if mode == "resume":
            resume_id = get_claude_session_id(name, authoritative=True)
            resume_cwd = get_claude_session_cwd(name)
        else:
            session_dir = self.sessions_dir / name
            session_dir.mkdir(parents=True, exist_ok=True)
            for session_id_file in session_dir.glob("*_session_id"):
                session_id_file.unlink()
        startup_cwd = self._get_startup_cwd(name, fallback_cwd=resume_cwd)
        if startup_cwd:
            save_claude_session_cwd(name, startup_cwd)

        if SANDBOX_ENABLED:
            if startup_cwd:
                self._cd_tmux_to_cwd(tmux_name, startup_cwd)
            docker_cmd = get_docker_run_cmd(name, resume_id=resume_id)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, docker_cmd, "Enter"])
        else:
            start_cmd = backend.start_cmd(resume_id)
            start_cmd = f'unset CLAUDECODE && {start_cmd}'
            if startup_cwd:
                start_cmd = f'cd {shlex.quote(startup_cwd)} && {start_cmd}'
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, start_cmd, "Enter"])
            time.sleep(1.5)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "2"])
            time.sleep(0.3)
            subprocess.run(["tmux", "send-keys", "-t", tmux_name, "Enter"])

        welcome = self._build_welcome(name, backend)
        time.sleep(2.0 if not SANDBOX_ENABLED else 5.0)
        self.send(name, welcome)

        print(f"Dead worker '{name}' recovered from registry (mode={mode})")
        return True, None


worker_manager = WorkerManager(SESSIONS_DIR, TMUX_PREFIX)


def _sync_worker_manager():
    worker_manager.sessions_dir = SESSIONS_DIR
    worker_manager.tmux_prefix = TMUX_PREFIX

# ─────────────────────────────────────────────────────────────────────────────
# grug say: one place for backend branching. no scatter.
# Worker Helpers (centralize backend switching)
# ─────────────────────────────────────────────────────────────────────────────

def worker_is_online(name: str, session: dict = None) -> bool:
    """Check if worker is online and ready.

    Args:
        name: Worker name
        session: Session dict from get_registered_sessions() (optional, avoids re-lookup)
    """
    _sync_worker_manager()
    return worker_manager.is_online(name, session)


def worker_set_pending(name: str, chat_id: int):
    """Set pending state for worker."""
    set_pending(name, chat_id)


def worker_send(name: str, message: str, chat_id: int = None, session: dict = None) -> bool:
    """Send message to worker using backend registry.

    Args:
        name: Worker name
        message: Message text to send
        chat_id: Chat ID (unused, kept for compatibility)
        session: Session dict (optional, avoids re-lookup)

    Returns:
        True if send succeeded
    """
    _sync_worker_manager()
    return worker_manager.send(name, message, chat_id, session)


def get_tmux_env_value(tmux_name: str, key: str) -> str:
    """Get a tmux session environment variable value."""
    result = subprocess.run(
        ["tmux", "show-environment", "-t", tmux_name, key],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return ""
    value = result.stdout.strip()
    if "=" not in value:
        return ""
    return value.split("=", 1)[1]


def scan_tmux_sessions():
    """Scan tmux for registered sessions."""
    _sync_worker_manager()
    return worker_manager.scan_tmux_sessions()


def get_registered_sessions(registered=None):
    """Get registered sessions from tmux (all backends have tmux now)."""
    _sync_worker_manager()
    return worker_manager.get_registered_sessions(registered)


def tmux_prompt_empty(tmux_name, timeout=0.5):
    """Check if Claude Code's input prompt is empty (message was accepted).

    After sending a message, polls the tmux pane to verify the prompt
    line (❯) is empty, indicating Claude accepted the input.

    Returns True if prompt is empty within timeout, False otherwise.
    """
    import re
    start = time.time()
    while time.time() - start < timeout:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", tmux_name, "-p"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            # Check for empty prompt: line starting with ❯ followed by only whitespace
            if re.search(r'^❯\s*$', result.stdout, re.MULTILINE):
                return True
        time.sleep(0.1)
    return False


def export_hook_env(tmux_name, backend: str = DEFAULT_WORKER_BACKEND):
    """Export env vars for hook inside tmux session.

    Uses tmux set-environment which persists in session and survives restarts.
    Hook reads these via `tmux show-environment -t $SESSION_NAME`.
    """
    # Guard: don't overwrite env if session belongs to another live bridge.
    # Prevents test/dev bridges from clobbering prod workers.
    our_url = BRIDGE_URL
    try:
        r = subprocess.run(["tmux", "show-environment", "-t", tmux_name, "BRIDGE_URL"],
                           capture_output=True, text=True, timeout=3)
        existing = r.stdout.strip().split("=", 1)[-1] if r.returncode == 0 else ""
        if existing and existing != our_url:
            import urllib.request
            urllib.request.urlopen(existing, timeout=1).read()
            print(f"  SKIP export_hook_env({tmux_name}): owned by live bridge at {existing}")
            return
    except Exception:
        pass  # other bridge dead or unreachable — safe to claim

    subprocess.run(["tmux", "set-environment", "-t", tmux_name, "PORT", str(PORT)])
    subprocess.run(["tmux", "set-environment", "-t", tmux_name, "TMUX_PREFIX", TMUX_PREFIX])
    sessions_dir_val = str(SESSIONS_DIR)
    subprocess.run(["tmux", "set-environment", "-t", tmux_name, "SESSIONS_DIR", sessions_dir_val])
    subprocess.run(["tmux", "set-environment", "-t", tmux_name, "WORKER_BACKEND", normalize_backend(backend)])
    # Always export BRIDGE_URL so workers know where their bridge is
    subprocess.run(["tmux", "set-environment", "-t", tmux_name, "BRIDGE_URL", BRIDGE_URL])


def get_docker_run_cmd(name, resume_id: str = ""):
    """Build docker run command for sandbox mode.

    Default: mounts ~ to /workspace (rw)
    Extra mounts via SANDBOX_EXTRA_MOUNTS (from --mount/--mount-ro flags)

    Args:
        name: Worker name (used for container name)

    Returns:
        Command string to run in tmux
    """
    import platform
    container_name = f"claude-worker-{name}"
    home = Path.home()

    # Base command
    cmd_parts = [
        "docker", "run", "-it",
        f"--name={container_name}",
        "--rm",  # Clean up on exit
    ]

    # Host gateway for bridge communication
    if platform.system() == "Linux":
        cmd_parts.append("--add-host=host.docker.internal:host-gateway")

    # Default mount: ~ → /workspace (rw)
    cmd_parts.append(f"-v={home}:/workspace")

    # Extra mounts from --mount/--mount-ro flags
    for host_path, container_path, readonly in SANDBOX_EXTRA_MOUNTS:
        if readonly:
            cmd_parts.append(f"-v={host_path}:{container_path}:ro")
        else:
            cmd_parts.append(f"-v={host_path}:{container_path}")

    # Mount session files for hook coordination
    cmd_parts.append(f"-v={SESSIONS_DIR}:{SESSIONS_DIR}")

    # Mount temp for file inbox
    FILE_INBOX_ROOT.mkdir(parents=True, exist_ok=True)
    cmd_parts.append(f"-v={FILE_INBOX_ROOT}:{FILE_INBOX_ROOT}")

    # Environment variables for hook
    # Use global BRIDGE_URL if user-provided, otherwise default to host.docker.internal for Docker
    if _bridge_url_env:
        docker_bridge_url = BRIDGE_URL  # User-provided takes precedence
    else:
        docker_bridge_url = f"http://host.docker.internal:{PORT}"
    cmd_parts.extend([
        f"-e=BRIDGE_URL={docker_bridge_url}",
        f"-e=PORT={PORT}",
        f"-e=TMUX_PREFIX={TMUX_PREFIX}",
        f"-e=SESSIONS_DIR={SESSIONS_DIR}",
        f"-e=BRIDGE_SESSION={name}",  # Session name for hook (tmux unavailable inside container)
        "-e=TMUX_FALLBACK=1",
    ])

    # Working directory
    cmd_parts.extend(["-w", "/workspace"])

    # Image
    cmd_parts.append(SANDBOX_IMAGE)

    # Run claude with --dangerously-skip-permissions (same as non-sandbox)
    cmd_parts.append(build_claude_start_cmd(resume_id))

    return " ".join(cmd_parts)


def stop_docker_container(name):
    """Stop and remove a docker container."""
    container_name = f"claude-worker-{name}"
    subprocess.run(["docker", "stop", container_name], capture_output=True)
    subprocess.run(["docker", "rm", "-f", container_name], capture_output=True)


def send_to_worker(name: str, message: str, chat_id: Optional[int] = None) -> bool:
    """Send a message to a worker using the appropriate backend."""
    _sync_worker_manager()
    return worker_manager.send(name, message, chat_id)


def _localize_media(name: str, media_list: list) -> list:
    """Return media paths unchanged; topic-only sessions are local."""
    return media_list


def _build_startup_lines(sessions):
    """Startup notification in topic semantics: how many 話題 sessions survive.

    No Team:/Focused:/hire framing — the topic list IS the session list.
    """
    n = len(sessions)
    if n:
        return [f"✅ Bridge 上線 — {n} 個話題 session 存活（{', '.join(sessions)}）"]
    return ["✅ Bridge 上線 — 目前沒有存活的話題 session，建立新話題即可開工。"]


def _reap_dead_topic(name, result):
    """End a session whose 話題 no longer exists.

    Telegram sends NO event when a topic is deleted, so the only signal is a
    reply bouncing with "message thread not found". Returns True when reaped
    (callers should stop retrying — the thread is gone, not malformed).
    """
    desc = ((result or {}).get("description") or "").lower()
    if "thread not found" not in desc:
        return False
    print(f"話題 gone for {name} ({desc}) — ending its session", flush=True)
    try:
        cid, tid = load_topic_meta(name)
        if cid is not None and tid is not None:
            key = (int(cid), int(tid))
            _awaiting_folder.discard(key)
            _picker_sent_at.pop(key, None)
            _topic_titles.pop(key, None)
    except Exception:
        pass
    try:
        worker_manager.end(name)
    except Exception as e:
        print(f"Failed to end {name} after topic deletion: {e}", flush=True)
    return True


def send_response_to_telegram(name: str, text: str, chat_id: int, log_prefix: str = "Response"):
    """Send a response to Telegram. Shared by hook responses.

    Args:
        name: Session/worker name for message prefix
        text: Response text (may contain image/file tags)
        chat_id: Telegram chat ID
        log_prefix: Prefix for log messages (e.g., "Response", "Hook response")
    """
    # Parse image and file tags from text (before converting to preserve tag syntax)
    # If this session is bound to a forum Topic, route the reply back into it.
    # Thread 0 (tmain / non-forum) must be OMITTED: Telegram rejects a
    # message_thread_id outside forums, and that bounce would trick
    # _reap_dead_topic into killing a healthy tmain session.
    _, topic_thread_id = load_topic_meta(name)
    topic_thread_id = topic_thread_id or None
    clean_text, images = parse_image_tags(text)
    clean_text, files = parse_file_tags(clean_text)

    # Still support explicit [[speak:custom text]] tag for custom voice text
    speak_text = None
    speak_match = re.search(r'\[\[speak(?::([^\]]*))?\]\]', clean_text)
    if speak_match:
        custom = speak_match.group(1)
        clean_text = clean_text[:speak_match.start()] + clean_text[speak_match.end():]
        clean_text = clean_text.strip()
        if custom is not None and custom.strip():
            speak_text = custom.strip()

    images = _localize_media(name, images)
    files = _localize_media(name, files)

    # Auto-TTS: synthesize voice for every response when enabled (/voice on|off)
    # Use explicit [[speak:text]] if provided, otherwise use the clean response text
    if speak_text is None and TTS_ENDPOINT and state.get("tts_enabled", True):
        speak_text = clean_text  # raw text before HTML conversion

    clean_text = markdown_to_telegram_html(clean_text)

    # Send text message if there's text content
    if clean_text:
        prefix_reserve = len(name) + 30
        chunks = split_message(clean_text, TELEGRAM_MAX_LENGTH - prefix_reserve)
        formatted_parts = format_multipart_messages(name, chunks)

        prev_msg_id = None
        for i, part in enumerate(formatted_parts):
            msg_data = {
                "chat_id": chat_id,
                "text": part,
                "parse_mode": "HTML"
            }
            if prev_msg_id:
                msg_data["reply_to_message_id"] = prev_msg_id

            result = transport.send_text(
                chat_id, part, parse_mode="HTML",
                reply_to=prev_msg_id if prev_msg_id else None,
                message_thread_id=topic_thread_id
            )
            if result and result.get("ok"):
                prev_msg_id = result.get("result", {}).get("message_id")
                if len(formatted_parts) > 1:
                    print(f"{log_prefix} sent: {name} part {i+1}/{len(formatted_parts)} -> Telegram OK")
                else:
                    print(f"{log_prefix} sent: {name} -> Telegram OK")
            else:
                # The topic was deleted (no Telegram event exists for that):
                # reap the session instead of retrying into a void.
                if _reap_dead_topic(name, result):
                    return
                # Fallback: retry as plain text on HTTP 400 (HTML parse error)
                desc = (result or {}).get("description", "")
                error_code = (result or {}).get("error_code", 0)
                is_400 = error_code == 400
                if is_400:
                    print(f"{log_prefix} HTML send failed (400: {desc}), retrying as plain text")
                    # Strip HTML tags and decode entities for readable plain text
                    plain_text = re.sub(r'<[^>]+>', '', part)
                    plain_text = plain_text.replace('&lt;', '<').replace('&gt;', '>').replace('&amp;', '&')
                    result = transport.send_text(
                        chat_id, plain_text,
                        reply_to=prev_msg_id if prev_msg_id else None,
                        message_thread_id=topic_thread_id
                    )
                    if result and result.get("ok"):
                        prev_msg_id = result.get("result", {}).get("message_id")
                        print(f"{log_prefix} sent (plain): {name} -> Telegram OK")
                    else:
                        print(f"{log_prefix} failed (plain): {name} -> {result}")
                else:
                    print(f"{log_prefix} failed: {name} -> {result}")

            if i < len(formatted_parts) - 1:
                time.sleep(0.05)

    # Send images
    for img_path, img_caption in images:
        full_caption = f"{name}: {img_caption}" if img_caption else f"{name}:"
        # Use sendAnimation for GIFs and MP4s to preserve animation
        if Path(img_path).suffix.lower() in (".gif", ".mp4"):
            sent = send_animation(chat_id, img_path, full_caption, message_thread_id=topic_thread_id)
        else:
            sent = send_photo(chat_id, img_path, full_caption, message_thread_id=topic_thread_id)
        if sent:
            print(f"Image sent: {name} -> {img_path}")
        else:
            transport.send_text(chat_id, f"{name}: [Image failed: {img_path}]")

    # Send files — route to specialized API method by extension
    for file_path, file_caption in files:
        full_caption = f"{name}: {file_caption}" if file_caption else f"{name}:"
        ext = Path(file_path).suffix.lower()
        if ext in VIDEO_EXTENSIONS:
            sent = send_video(chat_id, file_path, full_caption, message_thread_id=topic_thread_id)
        elif ext in AUDIO_EXTENSIONS:
            sent = send_audio(chat_id, file_path, full_caption, message_thread_id=topic_thread_id)
        elif ext in VOICE_EXTENSIONS:
            sent = send_voice(chat_id, file_path, full_caption, message_thread_id=topic_thread_id)
        elif ext in STICKER_EXTENSIONS:
            sent = send_sticker(chat_id, file_path, message_thread_id=topic_thread_id)
        else:
            sent = send_document(chat_id, file_path, full_caption, message_thread_id=topic_thread_id)
        if sent:
            print(f"File sent: {name} -> {file_path}")
        else:
            transport.send_text(chat_id, f"{name}: [File failed: {file_path}]")

    # Auto-TTS: synthesize and send voice alongside text
    # Skip TTS for messages >1000 chars. Split into paragraphs for separate voice messages.
    if speak_text is not None and speak_text and len(speak_text) <= 1000:
        # Split into paragraphs (double newline), filter empty
        paragraphs = [p.strip() for p in speak_text.split('\n\n') if p.strip()]
        if not paragraphs:
            paragraphs = [speak_text]
        def _tts_and_send():
            try:
                for i, para in enumerate(paragraphs):
                    print(f"TTS starting: {len(para)} chars for {name} (part {i+1}/{len(paragraphs)})")
                    voice_path = synthesize_speech(para)
                    if voice_path:
                        send_voice(chat_id, voice_path, caption=f"{name}:", message_thread_id=topic_thread_id)
                        try:
                            os.unlink(voice_path)
                        except OSError:
                            pass
            except Exception as e:
                print(f"TTS thread error: {e}")
        # Run TTS in background thread to not block /response return
        threading.Thread(target=_tts_and_send, daemon=True).start()


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
        _mark_topic_request_done(session_name)


def _mark_topic_request_done(name):
    """Stamp the in-flight request message as done (👍) and stop tracking it.

    Clearing the tracking is what prevents a later watchdog tick from clobbering
    the 👍 with a stale state emoji.
    """
    if not TOPIC_MODE:
        return
    rec = _topic_request_msg.pop(name, None)
    _topic_reaction_set.pop(name, None)
    if not rec:
        return
    chat_id, msg_id = rec
    try:
        transport.set_reaction(chat_id, msg_id, [{"type": "emoji", "emoji": TOPIC_REACTION_DONE}])
    except Exception as e:
        print(f"[topic] done set_reaction failed for {name}: {e}")


def create_session(name, backend: str = DEFAULT_BACKEND, chat_id: int = None):
    """Create a new worker instance."""
    _sync_worker_manager()
    return worker_manager.hire(name, backend, chat_id=chat_id)


def kill_session(name):
    """Kill a worker instance."""
    _sync_worker_manager()
    return worker_manager.end(name)


def restart_claude(name, mode: str = "relaunch"):
    """Restart claude in an existing tmux session."""
    _sync_worker_manager()
    return worker_manager.restart(name, mode=mode)


# ============================================================
# MESSAGE ROUTING
# ============================================================

# ─────────────────────────────────────────────────────────────────────────────
# Typing indicator + per-request liveness reaction (TOPIC_MODE)
# ─────────────────────────────────────────────────────────────────────────────
#
# The typing indicator alone is a lie: it is driven purely by the `pending`
# file flag (set on receipt, cleared only by the Stop hook), so a dead or stuck
# worker shows "typing…" forever and the user cannot tell "thinking hard" from
# "never coming back". We already compute a precise worker state every 4s in the
# watchdog (compute_state → BUSY_THINKING / WAITING / STUCK / DEAD / …); surface
# it on the triggering message as an evolving emoji reaction, and stop the typing
# indicator once the worker is no longer making progress.
#
# Only emojis from Telegram's default allowed reaction set are used.
TOPIC_REACTION_RECEIVED = "👀"   # received & pasted into the pane, no clear work yet
TOPIC_REACTION_WORKING = "✍"    # claude is actively thinking / running tools
TOPIC_REACTION_STALLED = "😴"    # stuck / poisoned / dead — not making progress
TOPIC_REACTION_DONE = "👍"       # response delivered

# session_name -> (chat_id, msg_id) of the in-flight request message
_topic_request_msg = {}
# session_name -> last reaction emoji we set (dedup, avoid redundant API calls)
_topic_reaction_set = {}


def topic_reaction_for_state(state):
    """Map a watchdog worker state to a reaction emoji (or None to leave as-is)."""
    if state in ("BUSY_THINKING", "BUSY_TOOL", "UNTRACKED_BUSY"):
        return TOPIC_REACTION_WORKING
    if state == "WAITING":
        return TOPIC_REACTION_RECEIVED
    if state in ("STUCK", "POISONED", "DEAD", "OFFLINE", "EXITED"):
        return TOPIC_REACTION_STALLED
    return None  # READY / WAITING_INPUT / unknown — don't override


def topic_request_stalled(state):
    """True when an in-flight request is no longer making progress.

    Used to stop the typing indicator: a dead/stuck worker should not keep
    pretending to type.
    """
    return state in ("STUCK", "POISONED", "DEAD", "OFFLINE", "EXITED")


def _update_topic_reaction(name, state):
    """Surface a worker's live state as a reaction on its in-flight request.

    No-op unless TOPIC_MODE is on and the session has a tracked request message.
    Dedups so the Telegram API is only called when the emoji actually changes.
    """
    if not TOPIC_MODE:
        return
    rec = _topic_request_msg.get(name)
    if not rec:
        return
    emoji = topic_reaction_for_state(state)
    if not emoji or _topic_reaction_set.get(name) == emoji:
        return
    chat_id, msg_id = rec
    try:
        transport.set_reaction(chat_id, msg_id, [{"type": "emoji", "emoji": emoji}])
        _topic_reaction_set[name] = emoji
    except Exception as e:
        print(f"[topic] set_reaction failed for {name}: {e}")


def send_typing_loop(chat_id, session_name):
    """Send typing indicator while a request is pending AND still progressing.

    Keeps the familiar one-on-one "typing…" feel, but breaks out the moment the
    watchdog marks the worker stalled/dead so it never types into the void.

    In TOPIC_MODE the action MUST carry the topic's message_thread_id, otherwise
    Telegram shows "typing…" in the group's General view instead of inside the
    話題 the user is actually chatting in. (thread 0 = non-forum/General → omit.)
    """
    thread_id = None
    if TOPIC_MODE:
        _, tid = load_topic_meta(session_name)
        thread_id = tid or None
    while is_pending(session_name):
        st = _worker_states.get(session_name)
        if st and topic_request_stalled(st[0]):
            break
        transport.send_chat_action(chat_id, "typing", message_thread_id=thread_id)
        time.sleep(4)


def get_all_chat_ids():
    """Get all unique chat_ids from session files."""
    chat_ids = set()
    if SESSIONS_DIR.exists():
        for session_dir in SESSIONS_DIR.iterdir():
            if session_dir.is_dir():
                chat_id_file = session_dir / "chat_id"
                if chat_id_file.exists():
                    try:
                        chat_id = chat_id_file.read_text().strip()
                        if chat_id:
                            chat_ids.add(chat_id)
                    except Exception:
                        pass
    # Also include current admin if known
    if admin_chat_id:
        chat_ids.add(str(admin_chat_id))
    return chat_ids


def send_shutdown_message():
    """Send shutdown notification to all known chat_ids."""
    chat_ids = get_all_chat_ids()
    if not chat_ids:
        print("No chat_ids to notify")
        return

    print(f"Sending shutdown to {len(chat_ids)} chat(s)...")
    for chat_id in chat_ids:
        transport.send_text(chat_id, "Going offline briefly. Your team stays the same.")
    print("Shutdown notifications sent")


# ============================================================
# NON-CORE: CommandRouter
# ============================================================

class _LegacyTransportAdapter(MessageTransport):
    """Wraps legacy TelegramAPI-style objects (with send_message/set_reaction)
    for backward compat with tests that pass FakeTelegram to CommandRouter."""

    def __init__(self, legacy):
        self._legacy = legacy

    @property
    def name(self) -> str:
        return "legacy-adapter"

    def send_text(self, chat_id, text, parse_mode=None, reply_to=None, message_thread_id=None) -> dict | None:
        result = self._legacy.send_message(chat_id, text)
        return result if result else {"ok": True, "result": {"message_id": 1}}

    def send_photo(self, chat_id, photo_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_document(self, chat_id, doc_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_animation(self, chat_id, animation_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_video(self, chat_id, video_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_audio(self, chat_id, audio_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_voice(self, chat_id, voice_path, caption=None, message_thread_id=None) -> bool:
        return False

    def send_sticker(self, chat_id, sticker_path, message_thread_id=None) -> bool:
        return False

    def send_chat_action(self, chat_id, action, message_thread_id=None) -> None:
        pass

    def set_reaction(self, chat_id, message_id, reaction) -> None:
        if hasattr(self._legacy, 'set_reaction'):
            self._legacy.set_reaction(chat_id, message_id, reaction)

    def edit_message(self, chat_id, message_id, text, parse_mode=None) -> dict | None:
        return {"ok": True, "result": {"message_id": message_id}}

    def setup_commands(self, commands) -> None:
        pass

    def download_file(self, file_id, session_name) -> str | None:
        return None


class CommandRouter:
    def __init__(self, transport, workers: WorkerManager):
        # Accept MessageTransport or legacy TelegramAPI-style objects (for test compat)
        if transport is not None and not isinstance(transport, MessageTransport):
            transport = _LegacyTransportAdapter(transport)
        self.transport = transport
        self.workers = workers

    def reply(self, chat_id, text, outcome=None, message_thread_id=None):
        # Replies raised while handling a topic message inherit that topic's
        # thread via _reply_ctx (set in _handle_topic_message; each Telegram
        # update runs in its own thread, so threading.local cannot leak
        # across topics). Thread 0 (tmain / non-forum) is omitted entirely.
        if message_thread_id is None:
            message_thread_id = getattr(_reply_ctx, "thread_id", None)
        if self.transport is not None:
            self.transport.send_text(chat_id, text,
                                     message_thread_id=message_thread_id or None)

    def send_startup_message(self, chat_id):
        sessions = list(self.workers.get_registered_sessions().keys())
        self.reply(chat_id, "\n".join(_build_startup_lines(sessions)))

    def handle_callback(self, update):
        """Handle a Telegram callback_query from the folder navigator keyboard.

        ``cd:<path>`` edits the message's inline keyboard to browse ``<path>``;
        ``use:<path>`` records the chosen cwd and opens the topic session.
        Paths are clamped under TOPIC_ROOT via ``_norm_under_root``. The
        callback spinner is always cleared via ``answerCallbackQuery``.
        """
        cq = update.get("callback_query", {})
        data = cq.get("data", "") or ""
        cq_id = cq.get("id")
        msg = cq.get("message", {}) or {}
        chat_id = msg.get("chat", {}).get("id")
        message_id = msg.get("message_id")
        thread_id = msg.get("message_thread_id")
        # Same admin gate as handle_message: only the admin's taps count.
        sender = (cq.get("from") or {}).get("id")
        if admin_chat_id is not None and sender != admin_chat_id and chat_id != admin_chat_id:
            print(f"Rejected non-admin callback: sender={sender} chat={chat_id}")
            return
        if thread_id is None:
            # Symmetric to _handle_topic_message: a non-forum DM carries no
            # message_thread_id, so normalize to the default thread (0 -> 'tmain')
            # so the awaiting-folder key and open_topic_session line up.
            thread_id = 0

        try:
            if data.startswith("cd:"):
                # Resolve the short token back to a path (fall back to root if the
                # token is stale, e.g. the picker survived a bridge restart).
                path = _norm_under_root(_folder_from_token(data[3:]) or TOPIC_ROOT)
                telegram_api(
                    "editMessageReplyMarkup",
                    {
                        "chat_id": chat_id,
                        "message_id": message_id,
                        "reply_markup": {"inline_keyboard": build_folder_keyboard(path)},
                    },
                )
            elif data.startswith("use:"):
                path = _norm_under_root(_folder_from_token(data[4:]) or TOPIC_ROOT)
                self.open_topic_session(chat_id, thread_id, cwd=path)
        finally:
            # Always clear the spinner on the tapped button.
            if cq_id is not None:
                try:
                    telegram_api("answerCallbackQuery", {"callback_query_id": cq_id})
                except Exception:
                    pass

    def open_topic_session(self, chat_id, thread_id, cwd):
        """Spawn the session for a forum Topic thread in ``cwd``.

        Names the worker ``topic_session_name(thread_id)`` (e.g. ``t4321``),
        sets its startup cwd before launch (reusing the ``/checkin`` cwd path),
        creates it, and persists the ``(chat_id, message_thread_id)`` binding.
        Text typed before the folder pick is never forwarded — it is just the
        trigger Telegram requires to create the topic.
        """
        name = resolve_topic_session_name(
            chat_id, thread_id, self.workers.get_registered_sessions()
        )
        # Set startup cwd before launch so the worker starts in the chosen folder.
        _set_worker_cwd(name, cwd)
        create_session(name, chat_id=chat_id)
        save_topic_meta(name, chat_id, thread_id)
        # Session is bound now — stop treating typed replies as folder-pick attempts.
        _awaiting_folder.discard((chat_id, thread_id))
        _picker_sent_at.pop((chat_id, thread_id), None)
        # hire() skips the standalone welcome in TOPIC_MODE; deliver it here so
        # the worker greets ONCE. route_message keeps the typing/request tracking.
        welcome = self.workers._build_welcome(name, get_backend(DEFAULT_BACKEND))
        self.route_message(name, welcome, chat_id, None)

    def _topic_media_text(self, msg, caption, name):
        """Download any media in a topic message into ``name``'s inbox and
        return the text to route (caption + local path), or None if the
        message carries no media.

        The topic IS the addressing, so unlike the legacy path there is no
        focus check — media lands in the session the 話題 is bound to. Voice
        is transcribed transparently (the worker sees plain text).
        """
        photo = msg.get("photo")
        document = msg.get("document")
        animation = msg.get("animation")
        audio = msg.get("audio")
        voice = msg.get("voice")
        video = msg.get("video")
        video_note = msg.get("video_note")
        sticker = msg.get("sticker")

        doc_is_image = bool(document) and document.get("mime_type", "").startswith("image/")

        def with_caption(body):
            return f"{caption}\n\n{body}" if caption else body

        if animation:
            local = download_telegram_file(animation.get("file_id"), name)
            if not local:
                self.reply(msg.get("chat", {}).get("id"), "GIF 下載失敗，請再試一次。")
                return ""
            return with_caption(f"Manager sent GIF: `{local}`")

        if photo or doc_is_image:
            if photo:
                largest = max(photo, key=lambda p: p.get("file_size", 0))
                file_id = largest.get("file_id")
            else:
                file_id = document.get("file_id")
            local = download_telegram_file(file_id, name)
            if not local:
                self.reply(msg.get("chat", {}).get("id"), "圖片下載失敗，請再試一次。")
                return ""
            return with_caption(f"Manager sent image: `{local}`")

        if document:
            local = download_telegram_file(document.get("file_id"), name)
            if not local:
                self.reply(msg.get("chat", {}).get("id"), "檔案下載失敗，請再試一次。")
                return ""
            size_str = format_file_size(document.get("file_size", 0))
            return with_caption(
                f"Manager sent file: {document.get('file_name', 'unknown')} "
                f"({size_str}, {document.get('mime_type', 'unknown')})\nPath: `{local}`"
            )

        media_item = audio or voice or video or video_note or sticker
        if media_item:
            local = download_telegram_file(media_item.get("file_id"), name)
            if not local:
                self.reply(msg.get("chat", {}).get("id"), "媒體下載失敗，請再試一次。")
                return ""
            if voice:
                transcript = transcribe_voice(local)
                if transcript:
                    # Transparent: the worker receives just the text, as if typed.
                    return f"{caption}\n\n{transcript}" if caption else transcript
                return with_caption(
                    f"Manager sent voice message: ({voice.get('duration', 0)}s)\nPath: `{local}`")
            if audio:
                title = audio.get("title", audio.get("file_name", "audio"))
                return with_caption(
                    f"Manager sent audio: {title} ({audio.get('duration', 0)}s)\nPath: `{local}`")
            if video:
                return with_caption(
                    f"Manager sent video: {video.get('file_name', 'video')} "
                    f"({video.get('duration', 0)}s)\nPath: `{local}`")
            if video_note:
                return with_caption(
                    f"Manager sent video note: ({video_note.get('duration', 0)}s)\nPath: `{local}`")
            if sticker:
                return with_caption(
                    f"Manager sent sticker: {sticker.get('emoji', '')}\nPath: {local}")

        return None

    def _end_topic_session(self, chat_id, thread_id, reason=""):
        """End the session bound to (chat_id, thread_id) and drop its topic state.

        The single lifecycle exit shared by /close, the forum_topic_closed
        service message, and the dead-topic reaper. Returns the ended session
        name, or None if the topic had no session.
        """
        key = (int(chat_id), int(thread_id))
        _awaiting_folder.discard(key)
        _picker_sent_at.pop(key, None)
        _topic_titles.pop(key, None)
        name = find_topic_session(chat_id, thread_id, self.workers.get_registered_sessions())
        if name:
            self.workers.end(name)
            print(f"Topic session ended ({reason or 'closed'}): {name} thread={thread_id}",
                  flush=True)
        return name

    def _send_folder_picker(self, chat_id, thread_id):
        """Show the root-confined folder navigator in a 話題 thread.

        Sends an inline keyboard rooted at TOPIC_ROOT into ``thread_id`` so the
        user can pick the cwd for a new topic session.
        """
        _awaiting_folder.add((chat_id, thread_id))
        _picker_sent_at[(chat_id, thread_id)] = time.time()
        resp = telegram_api(
            "sendMessage",
            {
                "chat_id": chat_id,
                "text": (
                    "選擇這個話題要在哪個資料夾開工（請點下方按鈕）：\n"
                    "📌 第一則訊息只是開啟選單的觸發，不會傳給 AI；"
                    "選好資料夾後再下指令。"
                ),
                "message_thread_id": thread_id,
                "reply_markup": {"inline_keyboard": build_folder_keyboard(TOPIC_ROOT)},
            },
        )
        # Fail loudly: a silently-dropped picker looks like "the bot ignored me".
        if isinstance(resp, dict) and not resp.get("ok", True):
            print(f"Folder picker send FAILED (thread={thread_id}): {resp}", flush=True)

    def _handle_topic_message(self, msg, text, chat_id, msg_id):
        """Route an inbound message by forum thread (話題) when TOPIC_MODE is on.

        - No thread (plain DM / general chat) → fixed default session (thread 0,
          named ``tmain``), using the same open/route logic keyed by chat only.
        - Known thread → deliver to its bound session.
        - Unknown thread → the message is just the trigger Telegram requires to
          create the topic; show the folder picker and never forward it.
        """
        thread_id = msg.get("message_thread_id")
        if thread_id is None:
            # Non-forum fallback: a plain DM with no message_thread_id maps to
            # one default session keyed by chat only (thread 0 -> 'tmain').
            thread_id = 0

        # Route every reply() in this update back into this 話題 (0 → omit).
        _reply_ctx.thread_id = thread_id or None

        # A forum_topic_created service message carries the 話題 title; capture
        # it (keyed by the topic's thread id) so the session is named after it.
        # Telegram only commits a topic when its first message is sent, so this
        # event arrives TOGETHER with that message — the picker can never appear
        # before the user types something. Show it now; the companion message
        # lands moments later and is swallowed by the grace window below.
        created = msg.get("forum_topic_created")
        if created:
            tid = msg.get("message_thread_id") or msg.get("message_id") or thread_id
            _topic_titles[(int(chat_id), int(tid))] = created.get("name", "")
            if not find_topic_session(chat_id, tid, self.workers.get_registered_sessions()):
                self._send_folder_picker(chat_id, tid)
            return

        # Topic lifecycle is symmetric: closing the 話題 ends its session (the
        # spec's "closing/deleting the 話題 → ends that session"). NOTE: these
        # service payloads are EMPTY objects, so test membership — not truthiness.
        if "forum_topic_closed" in msg:
            self._end_topic_session(chat_id, thread_id, reason="話題已關閉")
            return
        # Reopening is a fresh start: the old session was ended on close, so an
        # unbound reopened topic gets the folder picker again. If a session is
        # still bound (close event was missed), just keep routing to it.
        if "forum_topic_reopened" in msg:
            if not find_topic_session(chat_id, thread_id, self.workers.get_registered_sessions()):
                self._send_folder_picker(chat_id, thread_id)
            return

        registered = self.workers.get_registered_sessions()

        # Parse a leading command token the same way handle_command does:
        # split on whitespace, lowercase, and strip any @botname suffix so the
        # command matches EXACTLY (groups send "/cd@mybot /path").
        parts = text.split(maxsplit=1)
        cmd = parts[0].lower() if parts else ""
        if "@" in cmd:
            cmd = cmd.split("@")[0]
        arg = parts[1].strip() if len(parts) > 1 else ""

        # /quota — show subscriber usage; works with or without a thread session.
        if cmd == "/quota":
            self.reply(chat_id, format_quota(read_usage_snapshot()))
            return

        # /close — end this thread's session (same lifecycle path as the
        # forum_topic_closed service message).
        if cmd == "/close":
            name = self._end_topic_session(chat_id, thread_id, reason="/close")
            if name:
                self.reply(chat_id, f"已關閉這個話題的工作階段（{name}）。")
            else:
                self.reply(chat_id, "這個話題還沒有工作階段。")
            return

        # /cd — change this thread's folder. With a path arg, set the cwd and
        # restart in place; bare /cd reopens the folder picker.
        if cmd == "/cd":
            if arg:
                # Clamp under TOPIC_ROOT and require a real dir: a relative arg
                # would otherwise resolve against the bridge cwd and escape the
                # root (e.g. "/cd ../cc-switch546" -> a phantom path).
                clamped = _norm_under_root(os.path.expanduser(arg))
                if not os.path.isdir(clamped):
                    self.reply(chat_id, f"找不到資料夾（或超出允許範圍）：{arg}")
                    return
                name = find_topic_session(chat_id, thread_id, registered)
                if name:
                    _set_worker_cwd(name, clamped)
                    self.workers.restart(name)
                    self.reply(chat_id, f"已切換資料夾並重啟：{clamped}")
                else:
                    self.open_topic_session(chat_id, thread_id, cwd=clamped)
            else:
                self._send_folder_picker(chat_id, thread_id)
            return

        # One 話題 = one session: the multi-worker orchestration commands are
        # meaningless here. Answer with a hint instead of leaking them to the
        # worker as chat text.
        if cmd in TOPIC_LEGACY_CMDS:
            self.reply(chat_id,
                       "話題模式不需要這個指令 —— 每個話題就是一個獨立的工作階段。\n"
                       "用 /cd 換資料夾、/close 結束、/memory 搜尋記憶。")
            return
        # Global commands behave the same inside a 話題 — delegate to the shared
        # dispatcher rather than leaking them to the worker.
        if cmd in TOPIC_GLOBAL_CMDS:
            self.handle_command(text, chat_id, msg_id)
            return

        name = find_topic_session(chat_id, thread_id, registered)
        if (chat_id, thread_id) in _awaiting_folder:
            # Picker open / session still being created: never route a typed
            # reply to a worker. The message that created the topic lands here
            # right after the picker — swallow it silently (the picker text
            # already explains it). Later text gets a nudge.
            sent_at = _picker_sent_at.get((chat_id, thread_id), 0)
            if time.time() - sent_at <= _PICKER_GRACE_SECS:
                return
            self.reply(chat_id, "請點上面的資料夾按鈕來選擇工作目錄（輸入文字無法選擇）。")
        elif name:
            # Media (photo/file/voice/...) is downloaded into this session's
            # inbox and delivered as a local path; '' means a failed download
            # (already reported), None means a plain text message.
            media_text = self._topic_media_text(msg, text, name)
            if media_text == "":
                return
            outgoing = media_text if media_text is not None else text
            if not outgoing:
                return
            self.route_message(name, outgoing, chat_id, msg_id)
        else:
            # Unknown topic with no picker yet (created-event missed, e.g.
            # after a bridge restart): the message is just the trigger — show
            # the picker, never forward the text (or media).
            self._send_folder_picker(chat_id, thread_id)

    def handle_message(self, update):
        global admin_chat_id
        msg = update.get("message", {})
        text = msg.get("text", "") or msg.get("caption", "")
        chat_id = msg.get("chat", {}).get("id")
        msg_id = msg.get("message_id")
        if not chat_id:
            return

        # Admin gate. In topic mode messages arrive from the forum GROUP, so
        # the gate is on the SENDER's user id (a private chat's id equals the
        # user's id, so a preset ADMIN_CHAT_ID works for both). First sender
        # becomes admin; everyone else is silently rejected.
        sender = (msg.get("from") or {}).get("id")
        if admin_chat_id is None:
            admin_chat_id = sender or chat_id
            save_last_chat_id(chat_id)
            print(f"Admin registered: {admin_chat_id}")
        elif sender != admin_chat_id and chat_id != admin_chat_id:
            print(f"Rejected non-admin: sender={sender} chat={chat_id}")
            return
        else:
            save_last_chat_id(chat_id)

        # Topic-only bridge: every inbound message is routed by its 話題
        # thread. Media is handled inside the topic path (downloaded into the
        # bound session's inbox and delivered as a local path).
        return self._handle_topic_message(msg, text, chat_id, msg_id)

    def parse_at_mentions(self, text):
        """Extract all @mentions from anywhere in text. Returns (targets, cleaned_text)."""
        if not text:
            return [], ""
        registered = self.workers.get_registered_sessions()
        found = []
        for match in re.finditer(r'@([a-zA-Z0-9-]+)', text):
            name = match.group(1).lower()
            if name in registered and name not in found:
                found.append(name)
        if not found:
            return [], text
        # Remove matched @mentions from text
        cleaned = re.sub(r'@([a-zA-Z0-9-]+)', lambda m: '' if m.group(1).lower() in found else m.group(0), text)
        cleaned = re.sub(r'\s+', ' ', cleaned).strip()
        return found, cleaned

    def parse_worker_prefix(self, text):
        """Parse 'name: message' prefix from bot-sent messages."""
        if not text:
            return None, ""
        match = re.match(r'^\s*([a-zA-Z0-9-]+):\s*(.*)$', text, re.DOTALL)
        if not match:
            return None, ""
        name = match.group(1).lower()
        message = match.group(2).strip()
        registered = self.workers.get_registered_sessions()
        if name not in registered:
            return None, ""
        return name, message

    def get_reply_context(self, reply_msg):
        """Extract text from a replied-to message (context only, no routing)."""
        if not reply_msg:
            return ""
        return reply_msg.get("text") or reply_msg.get("caption") or ""

    def format_reply_context(self, reply_text, context_text):
        reply_text = (reply_text or "").strip()
        context_text = (context_text or "").strip()
        if context_text:
            return (
                "Manager reply:\n"
                f"{reply_text}\n\n"
                "Context (your previous message):\n"
                f"{context_text}"
            )
        return f"Manager reply:\n{reply_text}"

    def handle_command(self, text, chat_id, msg_id):
        parts = text.split(maxsplit=1)
        cmd = parts[0].lower()
        if "@" in cmd:
            cmd = cmd.split("@")[0]
        arg = parts[1].strip() if len(parts) > 1 else ""

        # Topic-only command surface: the orchestration commands (/hire /focus
        # /team /end /progress /pause /restart) and per-worker /<name> shortcuts
        # are gone — a 話題 IS the session, addressing happens by typing in it.
        if cmd == "/settings":
            return self.cmd_settings(chat_id)
        elif cmd == "/voice":
            return self.cmd_voice(arg, chat_id)
        elif cmd == "/rewind":
            return self.cmd_rewind(arg, chat_id)
        elif cmd == "/pr":
            return self.cmd_pr_review(arg, chat_id)
        elif cmd == "/memory":
            return self.cmd_memory(arg, chat_id)
        elif cmd == "/quota":
            return self.cmd_quota(chat_id)
        elif cmd in BLOCKED_COMMANDS:
            self.reply(chat_id, f"{cmd} is interactive and not supported here.", outcome="Needs decision")
            return True

        return False

    def cmd_quota(self, chat_id):
        """Show subscriber usage (5h/7d) from claude-hud's external snapshot."""
        self.reply(chat_id, format_quota(read_usage_snapshot()))
        return True

    def cmd_rewind(self, name, chat_id):
        if not name:
            self.reply(chat_id, "Usage: /rewind <name>\n/rewind team — view team chat", outcome="Needs decision")
            return True
        name = name.lower().strip()
        import time as _time
        token = secrets.token_urlsafe(32)
        base_url = BRIDGE_PUBLIC_URL or f"http://localhost:{PORT}"
        # Team chat viewer
        if name in ("team", "--team"):
            REWIND_TOKENS[token] = {"name": "__team__", "expires_at": _time.time() + REWIND_TIMEOUT}
            url = f"{base_url}/team-chat?token={token}"
            self.reply(chat_id, f"\U0001f4ac Team chat (5min)\n{url}")
            return True
        REWIND_TOKENS[token] = {"name": name, "expires_at": _time.time() + REWIND_TIMEOUT}
        # Use Tailscale IP (private network) — never route through cloudflare
        url = f"{base_url}/transcript/{name}?token={token}"
        self.reply(chat_id, f"⏪ Rewind for {name} (5min)\n{url}")
        return True

    def cmd_pr_review(self, arg, chat_id):
        if not arg:
            self.reply(chat_id, "Usage: /pr <github_pr_url>\nExample: /pr https://github.com/BasedHardware/omi/pull/6426", outcome="Needs decision")
            return True
        arg = arg.strip()
        # Parse PR URL (supports #issuecomment-XXXXX fragments)
        clean_url = arg.split('#')[0]
        m = re.match(r'https://github\.com/([^/]+)/([^/]+)/pull/(\d+)', clean_url)
        if not m:
            # Try bare number (assume BasedHardware/omi)
            try:
                pr_num = int(clean_url)
                owner, repo = 'BasedHardware', 'omi'
            except ValueError:
                self.reply(chat_id, "Invalid PR URL. Example: /pr https://github.com/BasedHardware/omi/pull/6426", outcome="Needs decision")
                return True
        else:
            owner, repo, pr_num = m.group(1), m.group(2), int(m.group(3))

        self.reply(chat_id, f"Generating PR review for {owner}/{repo}#{pr_num}...")

        # Run pr-review.py — pass full URL (with fragment) so it can highlight linked comment
        script_path = Path(__file__).parent / "pr-review.py"
        out_path = f"/tmp/pr-review-{pr_num}.html"
        try:
            r = subprocess.run(
                [sys.executable, str(script_path), arg, "--no-serve"],
                capture_output=True, text=True, timeout=300)
            if r.returncode != 0 or not os.path.exists(out_path):
                self.reply(chat_id, f"Failed to generate PR review:\n{r.stderr[:500]}", outcome="Needs decision")
                return True
        except subprocess.TimeoutExpired:
            self.reply(chat_id, "PR review generation timed out (>300s).", outcome="Needs decision")
            return True

        # Generate token and serve via existing transcript-like endpoint
        import time as _time
        token = secrets.token_urlsafe(32)
        PR_REVIEW_TOKENS[token] = {"pr_num": pr_num, "owner": owner, "repo": repo, "expires_at": _time.time() + 300}
        base_url = BRIDGE_PUBLIC_URL or f"http://localhost:{PORT}"
        url = f"{base_url}/pr-review/{pr_num}?token={token}"
        self.reply(chat_id, f"PR #{pr_num}: {owner}/{repo}\n{url}")
        return True

    def cmd_memory(self, query, chat_id):
        """Search team chat memory. /memory <query> [--agent X] [--days N] [--from X]"""
        if not query:
            self.reply(chat_id,
                       "Usage: /memory <query>\n"
                       "Examples:\n"
                       "  /memory what did I tell kai about auth\n"
                       "  /memory PR 6377 --agent taro\n"
                       "  /memory OTP problem --days 30\n"
                       "  /memory update  (re-index latest export)\n"
                       "  /memory status  (stack health)\n"
                       "  /memory wake-up [wing]  (L0+L1 context)\n"
                       "  /memory recall --wing=X [--room=Y]",
                       outcome="Needs decision")
            return True

        # Subcommand: /memory update — trigger incremental ingest
        if query.strip().lower() == "update":
            return self._memory_update(chat_id)

        # Subcommand: /memory status — memory stack health
        if query.strip().lower() == "status":
            try:
                from team_memory.memory_stack import MemoryStack
                stack = MemoryStack()
                info = stack.status()
                wings = info.get("wing_distribution", {})
                wing_str = ", ".join(f"{w}: {n}" for w, n in sorted(wings.items(), key=lambda x: -x[1]))
                lines = [
                    "Memory Stack Status:",
                    f"  Chunks: {info.get('total_chunks', 0)} ({wing_str})",
                    f"  Messages: {info.get('total_messages', 0)}",
                    f"  Summaries: {info.get('total_summaries', 0)}",
                    f"  L0 identity: {info['L0_identity']['tokens']} tokens ({info['L0_identity']['agents']} agents, {info['L0_identity']['projects']} projects, {info['L0_identity']['wings']} wings)",
                    "  L1 essential: last 7 days, top 15 items",
                ]
                self.reply(chat_id, "\n".join(lines))
            except Exception as e:
                self.reply(chat_id, f"Memory status failed: {e}")
            return True

        # Subcommand: /memory wake-up [wing] — L0+L1 wake-up text
        if query.strip().lower().startswith("wake-up"):
            try:
                from team_memory.memory_stack import MemoryStack
                stack = MemoryStack()
                parts = query.strip().split()
                wing = parts[1] if len(parts) > 1 else None
                text = stack.wake_up(wing=wing)
                if len(text) > 4000:
                    text = text[:3997] + "..."
                self.reply(chat_id, text)
            except Exception as e:
                self.reply(chat_id, f"Memory wake-up failed: {e}")
            return True

        # Subcommand: /memory recall --wing=X --room=Y — L2 on-demand
        if query.strip().lower().startswith("recall"):
            try:
                from team_memory.memory_stack import MemoryStack
                stack = MemoryStack()
                wing = room = None
                for part in query.split():
                    if part.startswith("--wing="):
                        wing = part.split("=", 1)[1]
                    elif part.startswith("--room="):
                        room = part.split("=", 1)[1]
                text = stack.recall(wing=wing, room=room)
                if len(text) > 4000:
                    text = text[:3997] + "..."
                self.reply(chat_id, text)
            except Exception as e:
                self.reply(chat_id, f"Memory recall failed: {e}")
            return True

        self.reply(chat_id, "Searching memory...")

        try:
            from team_memory.search import search_memory
            result = search_memory(query)
        except Exception as e:
            self.reply(chat_id, f"Memory search failed: {e}", outcome="Needs decision")
            return True

        answer = result.get("answer", "")
        sources = result.get("results", [])

        if not answer and not sources:
            self.reply(chat_id, "No results found.")
            return True

        # Format response per spec
        lines = []
        if answer:
            lines.append(f"\U0001f9e0 {answer}")
        else:
            lines.append("\U0001f9e0 No direct answer found.")

        if sources:
            lines.append("")
            # Generate a single rewind token for all source links
            import secrets
            import time as _time
            tc_token = secrets.token_urlsafe(32)
            REWIND_TOKENS[tc_token] = {"name": "__team__", "expires_at": _time.time() + REWIND_TIMEOUT}
            base_url = BRIDGE_PUBLIC_URL or f"http://localhost:{PORT}"

            lines.append("\U0001f4ce Sources:")
            for i, r in enumerate(sources[:3], 1):
                # Show first 2 lines of chunk, truncated
                chunk_lines = r.get("text", "").split("\n")
                preview = "\n".join(chunk_lines[:2])
                if len(preview) > 200:
                    preview = preview[:197] + "..."
                # Deep link to team chat page
                source_link = ""
                chunk_id = r.get("_id", "")
                if chunk_id.startswith("tg_"):
                    parts = chunk_id.split("_")
                    if len(parts) >= 2:
                        try:
                            first_msg_id = int(parts[1])
                            page_info = _run_team_chat_query("page-for-msg", msg_id=first_msg_id)
                            if page_info and page_info.get("page"):
                                source_link = f"\n{base_url}/team-chat?token={tc_token}&page={page_info['page']}#msg-{first_msg_id}"
                        except (ValueError, IndexError):
                            pass
                lines.append(f"{i}. {preview}{source_link}")

        self.reply(chat_id, "\n".join(lines))
        return True

    def _memory_update(self, chat_id):
        """Run incremental ingest from latest export in ~/team/exports/."""
        import glob as _glob
        exports_dir = os.path.expanduser("~/team/exports")
        zips = sorted(_glob.glob(os.path.join(exports_dir, "ChatExport_*.json.zip")))
        if not zips:
            self.reply(chat_id, f"No exports found in {exports_dir}/", outcome="Needs decision")
            return True

        latest = zips[-1]
        self.reply(chat_id, f"Indexing from {os.path.basename(latest)}...")

        try:
            # Parse
            parse_script = str(Path(__file__).parent / "team_memory" / "parse.py")
            parsed_path = "/tmp/team-memory-parsed-full.jsonl"
            r = subprocess.run(
                [sys.executable, parse_script, "--zip", latest, "--out", parsed_path],
                capture_output=True, text=True, timeout=120)
            if r.returncode != 0:
                self.reply(chat_id, f"Parse failed: {r.stderr[:300]}", outcome="Needs decision")
                return True

            # Ingest (incremental)
            ingest_script = str(Path(__file__).parent / "team_memory" / "ingest.py")
            r = subprocess.run(
                [sys.executable, ingest_script, parsed_path, "--incremental"],
                capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                self.reply(chat_id, f"Ingest failed: {r.stderr[:300]}", outcome="Needs decision")
                return True

            # Extract stats from output
            lines = r.stdout.strip().split("\n")
            summary = lines[-1] if lines else "Done"
            self.reply(chat_id, f"Memory updated.\n{summary}")

        except subprocess.TimeoutExpired:
            self.reply(chat_id, "Memory update timed out.", outcome="Needs decision")
        except Exception as e:
            self.reply(chat_id, f"Memory update failed: {e}", outcome="Needs decision")
        return True

    def cmd_voice(self, arg, chat_id):
        """Toggle auto-TTS for worker responses. /voice on|off or /voice to show status."""
        arg = arg.strip().lower()
        if arg == "on":
            state["tts_enabled"] = True
            self.reply(chat_id, "Voice mode ON — responses include voice messages.")
        elif arg == "off":
            state["tts_enabled"] = False
            self.reply(chat_id, "Voice mode OFF — text only.")
        else:
            status = "ON" if state["tts_enabled"] else "OFF"
            self.reply(chat_id, f"Voice mode: {status}\n/voice on — responses include voice\n/voice off — text only")
        return True

    def cmd_settings(self, chat_id):
        def redact(s):
            if not s:
                return "(not set)"
            if len(s) <= 8:
                return "***"
            return s[:4] + "..." + s[-4:]

        registered = self.workers.get_registered_sessions()
        team_list = ", ".join(registered.keys()) if registered else "(none)"
        lines = [
            f"claudecode-telegram v{VERSION}",
            PERSISTENCE_NOTE,
            "",
            f"Bot token: {redact(BOT_TOKEN)}",
            f"Admin: {admin_chat_id or '(auto-learn)'}",
            f"Webhook verification: {redact(WEBHOOK_SECRET) if WEBHOOK_SECRET else '(disabled)'}",
            f"Team storage: {SESSIONS_DIR.parent}",
            "",
            "話題 sessions",
            f"Sessions: {team_list}",
        ]

        lines.append("")
        if SANDBOX_ENABLED:
            lines.append("Sandbox: enabled (Docker isolation)")
            lines.append(f"Image: {SANDBOX_IMAGE}")
            lines.append(f"Default mount: {Path.home()} → /workspace")
            if SANDBOX_EXTRA_MOUNTS:
                lines.append("Extra mounts:")
                for host, container, ro in SANDBOX_EXTRA_MOUNTS:
                    ro_flag = " (ro)" if ro else ""
                    lines.append(f"  {host} → {container}{ro_flag}")
            lines.append("")
            lines.append("Note: Workers run in containers with access")
            lines.append("only to mounted directories. System paths")
            lines.append("outside mounts are not accessible.")
        else:
            lines.append("Sandbox: disabled (direct execution)")
            lines.append("Workers run with full system access.")

        self.reply(chat_id, "\n".join(lines))
        return True

    def _extract_reply_media(self, reply_to, target_worker):
        """Download media from a reply-to message. Returns media text or None."""
        # Check for media types in priority order
        animation = reply_to.get("animation")
        photo = reply_to.get("photo")
        document = reply_to.get("document")
        audio = reply_to.get("audio")
        voice = reply_to.get("voice")
        video = reply_to.get("video")
        sticker = reply_to.get("sticker")

        file_id = None
        media_label = "media"

        if animation:
            file_id = animation.get("file_id")
            media_label = "GIF"
        elif photo:
            largest = max(photo, key=lambda p: p.get("file_size", 0))
            file_id = largest.get("file_id")
            media_label = "image"
        elif video:
            file_id = video.get("file_id")
            media_label = "video"
        elif document:
            file_id = document.get("file_id")
            media_label = f"file: {document.get('file_name', 'unknown')}"
        elif audio:
            file_id = audio.get("file_id")
            media_label = "audio"
        elif voice:
            file_id = voice.get("file_id")
            media_label = "voice message"
            # Will attempt transcription after download below
        elif sticker:
            file_id = sticker.get("file_id")
            media_label = f"sticker: {sticker.get('emoji', '')}"

        if not file_id:
            return None

        local_path = download_telegram_file(file_id, target_worker)
        if not local_path:
            return None

        # Transcribe voice — deliver just the text transparently
        if voice:
            transcript = transcribe_voice(local_path)
            if transcript:
                return transcript

        return f"Manager forwarded {media_label}: {local_path}"

    def _worker_from_reply(self, msg):
        """Extract worker name from a reply-to message's text prefix (e.g. 'bob:\\n...')."""
        reply_to = msg.get("reply_to_message") if msg else None
        if not reply_to:
            return None
        reply_text = reply_to.get("text") or reply_to.get("caption") or ""
        if not reply_text:
            return None
        # Worker messages are formatted as "name:\n..." — extract the name
        first_line = reply_text.split("\n", 1)[0]
        if first_line.endswith(":"):
            candidate = first_line[:-1].strip().lower()
            registered = self.workers.get_registered_sessions()
            if candidate in registered:
                return candidate
        return None

    def route_message(self, session_name, text, chat_id, msg_id, one_off=False):
        registered = self.workers.get_registered_sessions()
        session = registered.get(session_name)
        if not session:
            self.reply(chat_id, f"找不到 {session_name} 的工作階段。請 /close 後重開這個話題。")
            return

        if not self.workers.is_online(session_name, session):
            self.reply(chat_id,
                       f"{session_name} 離線了。在這個話題用 /cd <路徑> 原地重啟，"
                       "或 /close 後重開話題。")
            return

        # Interactive prompt shortcut: if worker is at a selection prompt and
        # manager sends a single digit or "skip", translate to keystrokes
        shortcut = text.strip().lower()
        if shortcut in (
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "skip", "cancel"
        ):
            tmux_name = session.get("tmux", f"{self.workers.tmux_prefix}{session_name}")
            _, _, raw_lines = _read_tmux_activity(tmux_name)
            if raw_lines:
                details = _extract_question_details(raw_lines)
                if details:
                    if _send_interactive_reply(tmux_name, shortcut, details):
                        action = "Skipped" if shortcut in ("skip", "cancel") else f"Picked option {shortcut}"
                        self.reply(chat_id, f"{action}.")
                        return

        # Prefix manager messages so workers can distinguish from inter-worker messages.
        # Skip if text already has a "Manager sent ..." prefix (media messages).
        if not text.startswith("Manager sent "):
            text = f"manager: {text}"

        print(f"[{chat_id}] -> {session_name}: {text[:50]}...")

        worker_set_pending(session_name, chat_id)
        threading.Thread(
            target=send_typing_loop,
            args=(chat_id, session_name),
            daemon=True
        ).start()

        send_ok = self.workers.send(session_name, text, chat_id, session)
        if not send_ok:
            clear_pending(session_name)
            self.reply(
                chat_id,
                f"Could not send to {session_name.capitalize()}. Try /restart.",
                outcome="Needs decision"
            )
            return

        if msg_id and send_ok:
            if tmux_prompt_empty(session.get("tmux", "")):
                self.transport.set_reaction(chat_id, msg_id, [{"type": "emoji", "emoji": "👀"}])
                if TOPIC_MODE:
                    _topic_reaction_set[session_name] = TOPIC_REACTION_RECEIVED
            # Track the in-flight request so the watchdog can evolve this message's
            # reaction (✍ working → 😴 stalled) and delivery can stamp it 👍 done.
            if TOPIC_MODE:
                _topic_request_msg[session_name] = (chat_id, msg_id)


command_router = CommandRouter(transport, worker_manager)

# ============================================================
# TRANSCRIPT VIEWER
# ============================================================

# Path to transcript-index.py script (same directory as bridge.py)
TRANSCRIPT_INDEX_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcript-index.py")
TEAM_CHAT_INDEX_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "team-chat-index.py")
TEAM_CHAT_JSONL = "/tmp/team-memory-parsed-full.jsonl"
TEAM_CHAT_DB = "/tmp/team-chat-cache/team.db"
TEAM_CHAT_MEDIA_DIR = os.path.expanduser("~/team/exports/chat-full")


def _render_md_to_html(md_text):
    """Simple markdown to HTML renderer for file previews."""
    import re as _re
    import html as _html
    h = _html.escape(md_text)
    # Headers
    h = _re.sub(r'^######\s+(.+)$', r'<h6>\1</h6>', h, flags=_re.MULTILINE)
    h = _re.sub(r'^#####\s+(.+)$', r'<h5>\1</h5>', h, flags=_re.MULTILINE)
    h = _re.sub(r'^####\s+(.+)$', r'<h4>\1</h4>', h, flags=_re.MULTILINE)
    h = _re.sub(r'^###\s+(.+)$', r'<h3>\1</h3>', h, flags=_re.MULTILINE)
    h = _re.sub(r'^##\s+(.+)$', r'<h2>\1</h2>', h, flags=_re.MULTILINE)
    h = _re.sub(r'^#\s+(.+)$', r'<h1>\1</h1>', h, flags=_re.MULTILINE)
    # Code blocks (fenced)
    h = _re.sub(r'```[a-z]*\n(.*?)```', r'<pre class="md-code"><code>\1</code></pre>', h, flags=_re.DOTALL)
    # Inline code
    h = _re.sub(r'`([^`]+)`', r'<code class="md-inline">\1</code>', h)
    # Bold + italic
    h = _re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', h)
    h = _re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', h)
    h = _re.sub(r'\*(.+?)\*', r'<em>\1</em>', h)
    # Horizontal rule
    h = _re.sub(r'^---+$', r'<hr>', h, flags=_re.MULTILINE)
    # Unordered lists
    h = _re.sub(r'^[-*]\s+(.+)$', r'<li>\1</li>', h, flags=_re.MULTILINE)
    # Links
    h = _re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2" target="_blank">\1</a>', h)
    # Line breaks → paragraphs (double newline)
    h = _re.sub(r'\n{2,}', '</p><p>', h)
    # Single newlines → <br>
    h = h.replace('\n', '<br>')
    # Clean up br inside pre
    h = _re.sub(r'(<pre[^>]*>.*?</pre>)', lambda m: m.group(0).replace('<br>', '\n'), h, flags=_re.DOTALL)
    # Clean up br inside headers
    for tag in ('h1', 'h2', 'h3', 'h4', 'h5', 'h6'):
        h = _re.sub(rf'(<{tag}>.*?</{tag}>)', lambda m: m.group(0).replace('<br>', ''), h, flags=_re.DOTALL)
    return f'<p>{h}</p>'


def _render_csv_to_html(csv_text):
    """Render CSV as an HTML table."""
    import csv as _csv
    import io as _io
    import html as _html
    esc = _html.escape
    reader = _csv.reader(_io.StringIO(csv_text))
    rows = []
    for i, row in enumerate(reader):
        if i > 200:  # cap rows
            break
        cells = ''.join(f'<td>{esc(c)}</td>' for c in row)
        if i == 0:
            cells = ''.join(f'<th>{esc(c)}</th>' for c in row)
        rows.append(f'<tr>{cells}</tr>')
    header = rows[0] if rows else ''
    body = ''.join(rows[1:]) if len(rows) > 1 else ''
    return f'<div class="file-body file-body-csv"><table><thead>{header}</thead><tbody>{body}</tbody></table></div>'


def _run_team_chat_query(query_type, **kwargs):
    """Run team-chat-index.py via subprocess. Returns parsed JSON dict."""
    cmd = ["python3", TEAM_CHAT_INDEX_SCRIPT,
           "--jsonl", TEAM_CHAT_JSONL,
           "--db", TEAM_CHAT_DB,
           "--query", query_type]
    if kwargs.get("page") is not None:
        cmd.extend(["--page", str(kwargs["page"])])
    if kwargs.get("per_page") is not None:
        cmd.extend(["--per-page", str(kwargs["per_page"])])
    if kwargs.get("search"):
        cmd.extend(["--search", kwargs["search"]])
    if kwargs.get("msg_id") is not None:
        cmd.extend(["--msg-id", str(kwargs["msg_id"])])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
    except Exception as e:
        print(f"Team chat query error: {e}")
    return None


def _run_transcript_query(jsonl_path, sid, query, **kwargs):
    """Run transcript-index.py locally. Returns parsed JSON dict."""
    db_path = f"/tmp/transcript-cache/{sid}.db"
    script_path = TRANSCRIPT_INDEX_SCRIPT
    cmd = ["python3", script_path, "--jsonl", str(jsonl_path),
           "--db", db_path, "--query", query]
    if kwargs.get("page") is not None:
        cmd.extend(["--page", str(kwargs["page"])])
    if kwargs.get("per_page") is not None:
        cmd.extend(["--per-page", str(kwargs["per_page"])])
    if kwargs.get("search"):
        cmd.extend(["--search", kwargs["search"]])
    if kwargs.get("filter_mode"):
        cmd.extend(["--filter", kwargs["filter_mode"]])
    if kwargs.get("sort") and kwargs["sort"] != "relevance":
        cmd.extend(["--sort", kwargs["sort"]])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
    except Exception as e:
        print(f"Transcript query error: {e}")
    return None


def _resolve_transcript_path(name: str, session_id: str = None):
    """Resolve transcript JSONL path for a worker.

    Returns (transcript_path, sid, cwd) or (None, sid, cwd) if not found.
    """
    cwd = get_claude_session_cwd(name) or os.path.expanduser("~")
    sid = session_id or get_claude_session_id(name, authoritative=True)
    if not sid:
        return None, "", cwd

    slug = cwd.replace("/", "-")
    transcript_path = Path.home() / ".claude" / "projects" / slug / f"{sid}.jsonl"

    if transcript_path.exists():
        return transcript_path, sid, cwd
    return None, sid, cwd


def _parse_transcript_entries(transcript_path) -> list:
    """Parse JSONL transcript into a list of visible entries (skip noise)."""
    entries = []
    with open(transcript_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            etype = entry.get("type", "")
            if etype in ("progress", "queue-operation", "file-history-snapshot"):
                continue
            if etype == "system":
                continue
            entries.append(entry)
    return entries


def _generate_member_avatar(name: str) -> str:
    """Generate a unique SVG avatar for a team member based on name hash.

    Produces 1000+ unique variants via:
    - Hue (36 steps) × shape (6) × accent (5) × saturation (2) = 2160 combos
    """
    h = hash(name) & 0xFFFFFFFF
    hue = (h % 36) * 10  # 0-350 in steps of 10
    sat = 55 + (h >> 6 & 1) * 15  # 55 or 70
    shape_idx = (h >> 7) % 6
    accent_idx = (h >> 10) % 5
    initials = name[:2].upper() if len(name) >= 2 else name.upper()

    bg = f"hsl({hue},{sat}%,42%)"
    fg = f"hsl({hue},{max(sat-20,30)}%,75%)"

    # Base shapes for the background
    shapes = [
        '<circle cx="14" cy="14" r="14"/>',  # circle
        '<rect x="1" y="1" width="26" height="26" rx="6"/>',  # rounded rect
        '<polygon points="14,0 28,7 28,21 14,28 0,21 0,7"/>',  # hexagon
        '<polygon points="14,1 27,14 14,27 1,14"/>',  # diamond
        '<polygon points="14,0 28,10 22,28 6,28 0,10"/>',  # pentagon
        '<rect x="0" y="0" width="28" height="28" rx="10"/>',  # squircle
    ]
    # Accent overlays
    accents = [
        '',  # none
        f'<circle cx="14" cy="14" r="8" fill="none" stroke="{fg}" stroke-width="1.5" opacity=".3"/>',  # ring
        f'<circle cx="7" cy="7" r="2" fill="{fg}" opacity=".2"/><circle cx="21" cy="7" r="2" fill="{fg}" opacity=".2"/>',  # dots
        f'<line x1="4" y1="4" x2="24" y2="24" stroke="{fg}" stroke-width="1" opacity=".15"/><line x1="4" y1="24" x2="24" y2="4" stroke="{fg}" stroke-width="1" opacity=".15"/>',  # cross
        f'<rect x="4" y="12" width="20" height="4" rx="2" fill="{fg}" opacity=".15"/>',  # bar
    ]

    return (f'<div class="u-av"><svg viewBox="0 0 28 28" xmlns="http://www.w3.org/2000/svg">'
            f'<g fill="{bg}">{shapes[shape_idx]}</g>'
            f'{accents[accent_idx]}'
            f'<text x="14" y="14" text-anchor="middle" dominant-baseline="central" '
            f'fill="#fff" font-family="Inter,system-ui,sans-serif" font-size="11" font-weight="600" '
            f'opacity=".9">{initials}</text></svg></div>')


# Known team member prefixes for avatar detection
_TEAM_MEMBERS = {
    "chen", "geni", "hiro", "jin", "kai", "kelvin", "kenji",
    "lee", "luck", "mon", "noa", "ren", "ryo", "sora", "taro",
    "x", "yuki", "finn",
}

# Manager GitHub avatar
_MANAGER_AV = '<div class="u-av"><img src="https://avatars.githubusercontent.com/u/4256921" alt="manager"></div>'


def _detect_message_author(text: str) -> tuple:
    """Detect author from message prefix like 'ryo: message'.

    Returns (author_name, avatar_html, display_text).
    - Team member prefix → generated avatar, text without prefix
    - 'manager:' prefix → GitHub avatar, text without prefix
    - No prefix → GitHub avatar (default = manager), original text
    """
    stripped = text.strip()
    # Check for "name: " prefix (1-10 chars before colon)
    colon_pos = stripped.find(":")
    if 0 < colon_pos <= 10:
        prefix = stripped[:colon_pos].lower().strip()
        rest = stripped[colon_pos + 1:].strip()
        if prefix == "manager":
            return "manager", _MANAGER_AV, rest or stripped
        if prefix in _TEAM_MEMBERS:
            return prefix, _generate_member_avatar(prefix), rest or stripped
    # Default: manager avatar, full text
    return "manager", _MANAGER_AV, stripped


def _transcript_entry_to_html(entry: dict, esc, tool_results: dict = None) -> str:
    """Convert a single transcript entry to HTML block(s).

    Matches ampcode.com visual style: tool results merged into tool_use blocks,
    Edit diffs with +/- coloring, collapsible thinking.
    tool_results: map of tool_use_id → {content: str, is_error: bool}
    """
    import base64 as _b64
    if tool_results is None:
        tool_results = {}
    etype = entry.get("type", "")
    msg = entry.get("message", {})
    role = msg.get("role", "")
    content = msg.get("content", "")
    # Chevron SVG for expand/collapse
    _chev = '<svg class="chev" viewBox="0 0 16 16" fill="currentColor"><path d="M6.22 3.22a.75.75 0 011.06 0l4.25 4.25a.75.75 0 010 1.06l-4.25 4.25a.75.75 0 01-1.06-1.06L9.94 8 6.22 4.28a.75.75 0 010-1.06z"/></svg>'
    # Claude sparkle avatar (Anthropic brand icon)
    _claude_av = '<div class="cl-av"><svg viewBox="0 0 24 24" fill="none"><path d="M16.98 5.35L12 2L7.02 5.35L1.28 6.35L3.28 12.1L1.28 17.85L7.02 18.85L12 22.2L16.98 18.85L22.72 17.85L20.72 12.1L22.72 6.35L16.98 5.35Z" fill="currentColor"/></svg></div>'
    # Tool-specific SVG icons
    _tool_svgs = {
        "Read": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M3.75 1.5a.25.25 0 00-.25.25v11.5c0 .138.112.25.25.25h8.5a.25.25 0 00.25-.25V6H9.75A1.75 1.75 0 018 4.25V1.5H3.75zm5.75.56v2.19c0 .138.112.25.25.25h2.19L9.5 2.06zM2 1.75C2 .784 2.784 0 3.75 0h5.086c.464 0 .909.184 1.237.513l3.414 3.414c.329.328.513.773.513 1.237v8.086A1.75 1.75 0 0112.25 15h-8.5A1.75 1.75 0 012 13.25V1.75z"/></svg>',
        "Write": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M3.75 1.5a.25.25 0 00-.25.25v11.5c0 .138.112.25.25.25h8.5a.25.25 0 00.25-.25V6H9.75A1.75 1.75 0 018 4.25V1.5H3.75zm5.75.56v2.19c0 .138.112.25.25.25h2.19L9.5 2.06zM2 1.75C2 .784 2.784 0 3.75 0h5.086c.464 0 .909.184 1.237.513l3.414 3.414c.329.328.513.773.513 1.237v8.086A1.75 1.75 0 0112.25 15h-8.5A1.75 1.75 0 012 13.25V1.75z"/></svg>',
        "Edit": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M11.013 1.427a1.75 1.75 0 012.474 0l1.086 1.086a1.75 1.75 0 010 2.474l-8.61 8.61c-.21.21-.47.364-.756.445l-3.251.93a.75.75 0 01-.927-.928l.929-3.25c.081-.286.235-.547.445-.758l8.61-8.61zm1.414 1.06a.25.25 0 00-.354 0L10.811 3.75l1.439 1.44 1.263-1.263a.25.25 0 000-.354l-1.086-1.086zM11.189 6.25L9.75 4.811l-6.286 6.287a.25.25 0 00-.064.108l-.558 1.953 1.953-.558a.249.249 0 00.108-.064l6.286-6.287z"/></svg>',
        "Bash": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M0 2.75C0 1.784.784 1 1.75 1h12.5c.966 0 1.75.784 1.75 1.75v10.5A1.75 1.75 0 0114.25 15H1.75A1.75 1.75 0 010 13.25V2.75zm1.75-.25a.25.25 0 00-.25.25v10.5c0 .138.112.25.25.25h12.5a.25.25 0 00.25-.25V2.75a.25.25 0 00-.25-.25H1.75zM7.25 8a.75.75 0 01-.22.53l-2.25 2.25a.75.75 0 11-1.06-1.06L5.44 8 3.72 6.28a.75.75 0 111.06-1.06l2.25 2.25c.141.14.22.331.22.53zm1.5 1.5a.75.75 0 000 1.5h3a.75.75 0 000-1.5h-3z"/></svg>',
        "Grep": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M10.68 11.74a6 6 0 01-7.922-8.982 6 6 0 018.982 7.922l3.04 3.04a.749.749 0 01-.326 1.275.749.749 0 01-.734-.215l-3.04-3.04zM11.5 7a4.499 4.499 0 10-8.997 0A4.499 4.499 0 0011.5 7z"/></svg>',
        "Glob": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M1.75 1A1.75 1.75 0 000 2.75v10.5C0 14.216.784 15 1.75 15h12.5A1.75 1.75 0 0016 13.25v-8.5A1.75 1.75 0 0014.25 3H7.5a.25.25 0 01-.2-.1l-.9-1.2C6.07 1.26 5.55 1 5 1H1.75z"/></svg>',
        "Agent": '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M6.5.75a.75.75 0 00-1.5 0V2H3.75A1.75 1.75 0 002 3.75V5h-.25a.75.75 0 000 1.5H2v3h-.25a.75.75 0 000 1.5H2v1.25c0 .966.784 1.75 1.75 1.75h8.5A1.75 1.75 0 0014 12.25V11h.25a.75.75 0 000-1.5H14v-3h.25a.75.75 0 000-1.5H14V3.75A1.75 1.75 0 0012.25 2H11V.75a.75.75 0 00-1.5 0V2h-3V.75z"/></svg>',
    }
    _default_tool_svg = '<svg class="t-icon" viewBox="0 0 16 16" fill="currentColor"><path d="M5.433 2.304A4.49 4.49 0 003.5 6c0 1.598.832 3.002 2.09 3.802.518.328.929.923.902 1.64v.008l-.164 3.337a.75.75 0 11-1.498-.073l.163-3.34c.007-.14-.1-.313-.357-.476A5.994 5.994 0 012 6c0-2.033 1.01-3.83 2.555-4.916A1.89 1.89 0 015.433 2.304zM10.567 2.304A4.49 4.49 0 0112.5 6c0 1.598-.832 3.002-2.09 3.802-.518.328-.929.923-.902 1.64v.008l.164 3.337a.75.75 0 101.498-.073l-.163-3.34c-.007-.14.1-.313.357-.476A5.994 5.994 0 0114 6c0-2.033-1.01-3.83-2.555-4.916a1.89 1.89 0 00-.878 1.22z"/></svg>'
    parts = []

    # Timestamp for the entry
    ts_raw = entry.get("timestamp", "")
    ts_html = ""
    if ts_raw:
        # Store raw ISO timestamp; JS renders in browser timezone
        ts_html = f'<span class="ts" data-ts="{esc(ts_raw)}">{esc(ts_raw[:16].replace("T"," "))}</span>'

    if etype == "user" and role == "user":
        if isinstance(content, str) and content.strip():
            raw = content.strip()
            # Skip system/internal messages (task notifications, hook file/image syntax)
            if raw.startswith("<task-notification>") or raw.startswith("<system-reminder>"):
                return ""
            # Detect author from prefix for avatar selection
            _author, _avatar, _display = _detect_message_author(raw)
            text = esc(_display)
            if len(text) > 2000:
                text = text[:2000] + "\n\n<em>… truncated</em>"
            # Show author name label for team members
            _name_html = f'<span class="u-name">{esc(_author)}</span>' if _author != "manager" else ""
            parts.append(f'<div class="user-msg">{_avatar}<div class="u-body">{_name_html}<div class="u-text">{text}{ts_html}</div></div></div>')
        elif isinstance(content, list):
            # tool_result entries are merged into their tool_use blocks — skip here
            pass

    elif etype == "assistant" and role == "assistant":
        if isinstance(content, list):
            for item in content:
                ct = item.get("type", "")
                if ct == "thinking":
                    raw_thinking = item.get("thinking", "")
                    if raw_thinking and raw_thinking.strip():
                        tt = esc(raw_thinking[:3000])
                        if len(raw_thinking) > 3000:
                            tt += "\n… truncated"
                        parts.append(f'<details class="think"><summary class="think-h">{_chev} Thinking</summary><div class="think-t">{tt}</div></details>')
                elif ct == "text":
                    text = item.get("text", "")
                    if text and text != "(no content)":
                        b64 = _b64.b64encode(text.encode("utf-8")).decode("ascii")
                        parts.append(f'<div class="a-text markdown" data-md="{b64}"></div>')
                elif ct == "tool_use":
                    tn = item.get("name", "?")
                    ti = item.get("input", {})
                    tool_svg = _tool_svgs.get(tn, _default_tool_svg)
                    # Extract compact display info
                    inp = ""
                    is_fp = False
                    if tn in ("Read", "Write"):
                        inp = ti.get("file_path", "")
                        is_fp = bool(inp and "/" in inp)
                    elif tn == "Edit":
                        inp = ti.get("file_path", "")
                        is_fp = bool(inp and "/" in inp)
                    elif tn == "Glob":
                        inp = ti.get("pattern", "")
                    elif tn == "Bash":
                        inp = ti.get("command", "")
                    elif tn in ("Grep", "Search"):
                        inp = ti.get("pattern", "")
                    elif tn == "Agent":
                        inp = ti.get("description", "") or str(ti.get("prompt", ""))[:80]
                    else:
                        inp = json.dumps(ti, ensure_ascii=False)[:200]
                    inp = str(inp)[:300]

                    # Look up merged result for this tool call
                    tool_id = item.get("id", "")
                    tr = tool_results.get(tool_id, {})
                    tr_text = tr.get("content", "")
                    tr_err = tr.get("is_error", False)
                    # Skip empty/noise results
                    _skip_result = (not tr_text or tr_text == "Bash completed with no output"
                                    or tr_text.strip() == "")
                    tr_esc = ""
                    if not _skip_result:
                        tr_str = str(tr_text)[:5000]
                        tr_esc = esc(tr_str)
                        if len(str(tr_text)) > 5000:
                            tr_esc += "\n… truncated"

                    # Edit tool with old_string/new_string → render as diff
                    if tn == "Edit" and ti.get("old_string") is not None:
                        fp = esc(ti.get("file_path", "?"))
                        old_s = ti.get("old_string", "")
                        new_s = ti.get("new_string", "")
                        old_lines = old_s.splitlines(True)
                        new_lines = new_s.splitlines(True)
                        n_del = len(old_lines)
                        n_add = len(new_lines)
                        diff_html_lines = []
                        ln_old = 1
                        for ln in old_lines[:60]:
                            diff_html_lines.append(f'<div class="diff-del"><span class="diff-ln">{ln_old}</span><span class="diff-sign">-</span>{esc(ln.rstrip())}</div>')
                            ln_old += 1
                        ln_new = 1
                        for ln in new_lines[:60]:
                            diff_html_lines.append(f'<div class="diff-add"><span class="diff-ln">{ln_new}</span><span class="diff-sign">+</span>{esc(ln.rstrip())}</div>')
                            ln_new += 1
                        if len(old_lines) > 60 or len(new_lines) > 60:
                            diff_html_lines.append('<div class="diff-ctx"><span class="diff-ln"></span><span class="diff-sign"> </span>… truncated</div>')
                        diff_body = "\n".join(diff_html_lines)
                        n_overlap = min(n_del, n_add)
                        n_pure_add = n_add - n_overlap
                        n_pure_del = n_del - n_overlap
                        stats_html = f'<span class="diff-stat"><span class="diff-plus">+{n_pure_add}</span> <span class="diff-minus">-{n_pure_del}</span> <span class="diff-mod">~{n_overlap}</span></span>'
                        pp = fp.rsplit("/", 1)
                        fp_html = f'<span class="fp-dir">{esc(pp[0])}/</span>{esc(pp[1])}' if len(pp) > 1 else esc(fp)
                        err_cls = " act-err" if tr_err else ""
                        parts.append(f'<details class="act diff-act{err_cls}"><summary class="act-h">{tool_svg}<span class="fp">{fp_html}</span>{stats_html}{_chev}</summary><div class="diff-body">{diff_body}</div></details>')
                    elif tn == "Bash" and inp:
                        # Bash: single block with command + output merged
                        body_parts = [f'<div class="act-cmd">{esc(inp)}</div>']
                        if tr_esc:
                            body_parts.append(f'<div class="act-out{" act-out-err" if tr_err else ""}">{tr_esc}</div>')
                        err_cls = " act-err" if tr_err else ""
                        parts.append(f'<details class="act{err_cls}"><summary class="act-h">{tool_svg}<span class="t-det">{esc(inp[:80])}</span>{_chev}</summary><div class="act-body">{"".join(body_parts)}</div></details>')
                    elif is_fp:
                        pp = inp.rsplit("/", 1)
                        dp = esc(pp[0]) if len(pp) > 1 else ""
                        bp = esc(pp[-1])
                        fp = f'<span class="fp-dir">{dp}/</span>{bp}' if dp else bp
                        if tr_esc and not _skip_result:
                            # File tool with result → expandable
                            err_cls = " act-err" if tr_err else ""
                            parts.append(f'<details class="act{err_cls}"><summary class="act-h">{tool_svg}<span class="fp">{fp}</span>{_chev}</summary><div class="act-body"><pre class="t-out">{tr_esc}</pre></div></details>')
                        else:
                            parts.append(f'<div class="chip">{tool_svg}<span class="fp">{fp}</span></div>')
                    else:
                        if tr_esc and not _skip_result:
                            err_cls = " act-err" if tr_err else ""
                            parts.append(f'<details class="act{err_cls}"><summary class="act-h">{tool_svg}<span class="t-det">{esc(inp[:80])}</span>{_chev}</summary><div class="act-body"><pre class="t-out">{tr_esc}</pre></div></details>')
                        else:
                            parts.append(f'<div class="chip">{tool_svg}<span class="t-det">{esc(inp)}</span></div>')
        elif isinstance(content, str) and content.strip():
            b64 = _b64.b64encode(content.encode("utf-8")).decode("ascii")
            parts.append(f'<div class="a-text markdown" data-md="{b64}"></div>')

    return "\n".join(parts)


def _format_model_name(model_name: str) -> str:
    """Format model ID into display name: 'claude-opus-4-6' → 'Opus 4.6'."""
    import re as _re
    s = model_name.replace("claude-", "")
    # Strip date suffixes like -20251001
    s = _re.sub(r"-\d{8}$", "", s)
    # Convert version numbers: "opus-4-6" → "opus-4.6" (last dash before final digit = dot)
    s = _re.sub(r"-(\d+)-(\d+)$", r"-\1.\2", s)
    # Also handle "haiku-4-5" pattern
    s = _re.sub(r"-(\d+)\.(\d+)$", r" \1.\2", s)
    # Remaining dashes to spaces
    s = s.replace("-", " ").title()
    return s


def _transcript_stats(entries: list) -> dict:
    """Extract metadata stats from transcript entries."""
    n_user = sum(1 for e in entries if e.get("type") == "user"
                 and e.get("message", {}).get("role") == "user"
                 and isinstance(e.get("message", {}).get("content"), str))
    n_tool = 0
    n_edit = 0
    lines_add = 0
    lines_del = 0
    lines_mod = 0
    files_modified = set()
    for e in entries:
        if e.get("type") != "assistant":
            continue
        for c in (e.get("message", {}).get("content") or []):
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            n_tool += 1
            ti = c.get("input", {})
            if c.get("name") == "Edit" and ti.get("old_string") is not None:
                n_edit += 1
                fp = ti.get("file_path", "")
                if fp:
                    files_modified.add(fp)
                n_old = len(ti.get("old_string", "").splitlines(True))
                n_new = len(ti.get("new_string", "").splitlines(True))
                overlap = min(n_old, n_new)
                lines_mod += overlap
                lines_del += n_old - overlap
                lines_add += n_new - overlap
            elif c.get("name") in ("Write", "Read", "Edit"):
                fp = ti.get("file_path", "")
                if fp:
                    files_modified.add(fp)
    model = version = git_branch = ""
    first_ts = last_ts = ""
    input_tokens = output_tokens = 0
    for e in entries:
        if not model:
            model = e.get("message", {}).get("model", "")
        if not version:
            version = e.get("version", "")
        if not git_branch:
            git_branch = e.get("gitBranch", "")
        ts = e.get("timestamp", "")
        if ts and not first_ts:
            first_ts = ts
        if ts:
            last_ts = ts
        # Token usage from Claude response entries (in message.usage)
        usage = e.get("message", {}).get("usage", {})
        turn_in = (usage.get("input_tokens", 0)
                   + usage.get("cache_read_input_tokens", 0)
                   + usage.get("cache_creation_input_tokens", 0))
        turn_out = usage.get("output_tokens", 0)
        input_tokens += turn_in
        output_tokens += turn_out
    # Compute duration
    duration_str = ""
    if first_ts and last_ts:
        try:
            from datetime import datetime
            t0 = datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
            t1 = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
            delta = t1 - t0
            total_s = int(delta.total_seconds())
            if total_s < 0:
                total_s = 0
            days = total_s // 86400
            hours = (total_s % 86400) // 3600
            mins = (total_s % 3600) // 60
            if days > 0:
                duration_str = f"{days}d {hours}h"
            elif hours > 0:
                duration_str = f"{hours}h {mins}m"
            else:
                duration_str = f"{mins}m"
        except Exception:
            pass
    return {"n_user": n_user, "n_tool": n_tool, "n_edit": n_edit,
            "lines_add": lines_add, "lines_del": lines_del,
            "lines_mod": lines_mod, "n_files": len(files_modified), "model": model,
            "version": version, "git_branch": git_branch,
            "first_ts": first_ts, "last_ts": last_ts,
            "input_tokens": input_tokens, "output_tokens": output_tokens,
            "duration": duration_str}

def _render_team_chat_html(page: int = None, per_page: int = 50,
                           search_query: str = "", token: str = "") -> str:
    """Render team Telegram chat as paginated HTML page."""
    import html as html_mod
    esc = html_mod.escape

    if search_query:
        query_result = _run_team_chat_query("search", search=search_query,
                                            page=page or 1, per_page=per_page)
    else:
        query_result = _run_team_chat_query("entries", page=page, per_page=per_page)

    if not query_result:
        return ('<html><body style="background:#0b0d0b;color:#e5e5e0;font-family:system-ui;padding:40px">'
                '<h1>Team chat not available</h1>'
                '<p>Run <code>/memory update</code> to index the latest export.</p></body></html>')

    messages = query_result.get("messages", [])
    if search_query:
        total = query_result.get("total_results", 0)
    else:
        total = query_result.get("total", 0)
    total_pages = query_result.get("total_pages", 1)
    page = query_result.get("page", 1)

    # Pagination query string (needed by message blocks for reply/context links)
    qs_parts = []
    if token:
        qs_parts.append(f"token={esc(token)}")
    if per_page != 50:
        qs_parts.append(f"per_page={per_page}")
    if search_query:
        qs_parts.append(f"q={esc(search_query)}")
    qs_base = "&".join(qs_parts)

    def page_url(p):
        parts = [f"page={p}"]
        if qs_base:
            parts.append(qs_base)
        return "?" + "&".join(parts)

    # Build msg_id → message lookup for reply context
    msg_by_id = {m.get("msg_id"): m for m in messages if m.get("msg_id")}

    # For reply-to messages not on this page, batch-fetch from DB
    missing_reply_ids = set()
    for msg in messages:
        rid = msg.get("reply_to")
        if rid and rid not in msg_by_id:
            missing_reply_ids.add(rid)
    reply_cache = {}
    if missing_reply_ids:
        for rid in missing_reply_ids:
            r = _run_team_chat_query("msg-by-id", msg_id=rid)
            if r and r.get("idx") is not None:
                reply_cache[rid] = r

    # Build message blocks
    blocks = []
    for msg in messages:
        msg_id = msg.get("msg_id", 0)
        sender = msg.get("display_sender", "")
        text = esc(msg.get("text", ""))
        ts = msg.get("timestamp", "")
        reply_to = msg.get("reply_to")
        # Auto-link URLs
        text = re.sub(r'(https?://\S+)', r'<a href="\1" target="_blank" rel="noopener">\1</a>', text)
        # Newlines to <br>
        text = text.replace("\n", "<br>")

        # Reply context
        reply_html = ""
        if reply_to:
            replied = msg_by_id.get(reply_to)
            if replied:
                rsender = esc(replied.get("display_sender", ""))
                rtext = esc(replied.get("text", "")[:120])
                if len(replied.get("text", "")) > 120:
                    rtext += "..."
                reply_html = (f'<a class="reply-ctx" href="#msg-{reply_to}">'
                              f'<span class="reply-name">{rsender}</span> {rtext}</a>')
            else:
                # Reply to message on another page — fetch text and link to its page
                rinfo = reply_cache.get(reply_to)
                if rinfo and rinfo.get("page"):
                    rpage = rinfo["page"]
                    rurl = f"?page={rpage}&{qs_base}#msg-{reply_to}" if qs_base else f"?page={rpage}#msg-{reply_to}"
                    rsender = esc(rinfo.get("display_sender", ""))
                    rtext_raw = rinfo.get("text", "")
                    rtext = esc(rtext_raw[:120])
                    if len(rtext_raw) > 120:
                        rtext += "..."
                    reply_html = (f'<a class="reply-ctx" href="{rurl}">'
                                  f'<span class="reply-name">{rsender}</span> {rtext}</a>')

        # Avatar
        if sender == "manager":
            av = _MANAGER_AV
        elif sender in _TEAM_MEMBERS:
            av = _generate_member_avatar(sender)
        else:
            av = _generate_member_avatar(sender or "system")

        name_html = f'<span class="u-name">{esc(sender)}</span>'
        ts_html = f'<span class="ts" data-ts="{esc(ts)}">{esc(ts[11:16]) if len(ts) > 16 else ""}</span>'

        # In search mode, add "view in context" link
        ctx_link = ""
        if search_query and msg.get("idx") is not None:
            ctx_page = (msg["idx"] // per_page) + 1
            ctx_qs = f"page={ctx_page}"
            if token:
                ctx_qs += f"&token={esc(token)}"
            if per_page != 50:
                ctx_qs += f"&per_page={per_page}"
            ctx_link = f' <a class="ctx-link" href="?{ctx_qs}#msg-{msg_id}" title="View in context">\u2197</a>'

        # Media rendering (photo / file)
        media_html = ""
        photo = msg.get("photo", "")
        file_path_val = msg.get("file", "")
        file_name = msg.get("file_name", "")
        media_token = f"token={esc(token)}" if token else ""
        if photo:
            from urllib.parse import quote as _url_quote
            media_url = f"/team-chat-media/{_url_quote(photo, safe='/')}?{media_token}"
            media_html = (f'<div class="media-wrap">'
                          f'<a href="{media_url}" target="_blank">'
                          f'<img class="chat-photo" src="{media_url}" loading="lazy" alt=""></a>'
                          f'</div>')
        elif file_path_val and not file_path_val.startswith("(File not included"):
            from urllib.parse import quote as _url_quote
            media_url = f"/team-chat-media/{_url_quote(file_path_val, safe='/')}?{media_token}"
            display_name = esc(file_name) if file_name else esc(file_path_val.split("/")[-1])
            ext = os.path.splitext(file_path_val)[1].lower()
            # Image files — render inline like photos
            if ext in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg"):
                media_html = (f'<div class="media-wrap">'
                              f'<a href="{media_url}" target="_blank">'
                              f'<img class="chat-photo" src="{media_url}" loading="lazy" alt=""></a>'
                              f'<a class="file-dl" href="{media_url}" download="{esc(file_name or "")}">{display_name}</a>'
                              f'</div>')
            # Previewable text/code files — render inline, open by default
            elif ext in (".md", ".txt", ".csv", ".json", ".yaml", ".yml", ".py",
                         ".sh", ".js", ".ts", ".go", ".rs", ".toml", ".log"):
                _chev = '<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18l6-6-6-6"/></svg>'
                # Read file content for inline rendering
                _file_full = os.path.join(TEAM_CHAT_MEDIA_DIR, file_path_val)
                _file_content = ""
                try:
                    with open(_file_full, "r", encoding="utf-8", errors="replace") as _ff:
                        _file_content = _ff.read(64_000)  # cap at 64KB
                except Exception:
                    pass
                if ext == ".md":
                    # Render markdown to HTML
                    _rendered = _render_md_to_html(_file_content)
                    _body = f'<div class="file-body file-body-md">{_rendered}</div>'
                elif ext in (".py", ".sh", ".js", ".ts", ".go", ".rs"):
                    _body = f'<pre class="file-body file-body-code"><code>{esc(_file_content)}</code></pre>'
                elif ext in (".json", ".yaml", ".yml", ".toml"):
                    _body = f'<pre class="file-body file-body-code"><code>{esc(_file_content)}</code></pre>'
                elif ext == ".csv":
                    _body = _render_csv_to_html(_file_content)
                else:
                    # .txt, .log — plain preformatted
                    _body = f'<pre class="file-body file-body-text">{esc(_file_content)}</pre>'
                media_html = (f'<div class="media-wrap">'
                              f'<details class="file-card" open>'
                              f'<summary class="file-header">'
                              f'<span class="file-icon">&#128196;</span> {display_name}'
                              f'<a class="file-dl-btn" href="{media_url}" download="{esc(file_name or "")}" onclick="event.stopPropagation()">&#8615;</a>'
                              f'{_chev}'
                              f'</summary>'
                              f'{_body}'
                              f'</details></div>')
            # PDF — collapsible viewer (iframe, open by default)
            elif ext == ".pdf":
                _chev = '<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18l6-6-6-6"/></svg>'
                media_html = (f'<div class="media-wrap">'
                              f'<details class="file-card" open>'
                              f'<summary class="file-header">'
                              f'<span class="file-icon">&#128195;</span> {display_name}'
                              f'<a class="file-dl-btn" href="{media_url}" download="{esc(file_name or "")}" onclick="event.stopPropagation()">&#8615;</a>'
                              f'{_chev}'
                              f'</summary>'
                              f'<iframe class="file-preview file-preview-pdf" src="{media_url}"></iframe>'
                              f'</details></div>')
            # Other files — download card
            else:
                media_html = (f'<div class="media-wrap">'
                              f'<a class="file-card-link" href="{media_url}" download="{esc(file_name or "")}">'
                              f'<span class="file-icon">&#128206;</span> {display_name}'
                              f'</a></div>')

        blocks.append(
            f'<div class="chat-msg" id="msg-{msg_id}">'
            f'{av}<div class="chat-body">'
            f'{name_html} {ts_html}{ctx_link}'
            f'{reply_html}'
            f'{media_html}'
            f'<div class="chat-text">{text}</div>'
            f'</div></div>'
        )

    # Pagination nav
    nav_html = ""
    if total_pages > 1:
        nav_items = []
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page <= 1 else ""}" href="{page_url(1)}">First</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page <= 1 else ""}" href="{page_url(page-1)}">Prev</a>')
        start_p = max(1, page - 3)
        end_p = min(total_pages, start_p + 6)
        start_p = max(1, end_p - 6)
        for p in range(start_p, end_p + 1):
            cls = " pg-cur" if p == page else ""
            nav_items.append(f'<a class="pg-btn{cls}" href="{page_url(p)}">{p}</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page >= total_pages else ""}" href="{page_url(page+1)}">Next</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page >= total_pages else ""}" href="{page_url(total_pages)}">Last</a>')
        nav_html = f'<nav class="pg">{"".join(nav_items)}<span class="pg-info">Page {page}/{total_pages} ({total} messages)</span></nav>'

    search_val = esc(search_query) if search_query else ""
    search_result = ""
    if search_query:
        search_result = f'<div class="search-info">Found {total} matching messages for "<strong>{esc(search_query)}</strong>"</div>'

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Team Chat</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap">
<style>
:root {{
  --bg:#0b0d0b; --fg:#e5e5e0; --border:rgba(135,139,134,.12); --muted:#9ca49c;
  --user-bg:rgba(255,255,255,.04); --code-bg:#1a1c1a; --link:#75dbf0; --radius:6px;
  --sans:"Inter",ui-sans-serif,system-ui,-apple-system,sans-serif;
}}
@media(prefers-color-scheme:light){{
  :root{{--bg:#fafaf8;--fg:#1a1a1a;--muted:#595959;--border:rgba(135,139,134,.2);
    --user-bg:rgba(0,0,0,.03);--code-bg:#f4f4f0;--link:#0969da;}}
}}
*{{margin:0;padding:0;box-sizing:border-box}}
html{{font-size:14px}}
body{{font-family:var(--sans);background:var(--bg);color:var(--fg);line-height:1.6;
  -webkit-font-smoothing:antialiased}}
.wrap{{max-width:48rem;margin:0 auto;padding:24px 16px 80px}}
header{{border-bottom:1px solid var(--border);padding-bottom:16px;margin-bottom:20px}}
h1{{font-size:1.3rem;font-weight:700}}
.meta{{color:var(--muted);font-size:.85rem;margin-top:4px}}
/* Search */
.search-bar{{display:flex;gap:8px;margin-bottom:16px}}
.search-bar input{{flex:1;background:var(--code-bg);border:1px solid var(--border);
  border-radius:var(--radius);padding:8px 12px;color:var(--fg);font-size:.9rem;
  font-family:var(--sans);outline:none}}
.search-bar input:focus{{border-color:var(--link)}}
.search-bar button{{background:var(--code-bg);border:1px solid var(--border);
  border-radius:var(--radius);padding:8px 16px;color:var(--fg);cursor:pointer;
  font-family:var(--sans);font-size:.9rem}}
.search-bar button:hover{{border-color:var(--muted)}}
.search-info{{background:rgba(117,219,240,.06);border:1px solid rgba(117,219,240,.15);
  border-radius:var(--radius);padding:8px 12px;margin-bottom:16px;font-size:.85rem;color:var(--link)}}
/* Pagination */
.pg{{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin:16px 0;font-size:.85rem}}
.pg-btn{{padding:4px 10px;border:1px solid var(--border);border-radius:var(--radius);
  color:var(--fg);text-decoration:none;transition:border-color .15s}}
.pg-btn:hover{{border-color:var(--muted)}}
.pg-cur{{background:var(--link);color:#000;border-color:var(--link);font-weight:600}}
.pg-dis{{opacity:.3;pointer-events:none}}
.pg-info{{margin-left:8px;color:var(--muted)}}
/* Chat messages */
.thread{{display:flex;flex-direction:column;gap:4px}}
.chat-msg{{display:grid;grid-template-columns:28px 1fr;gap:10px;padding:8px 8px;
  border-radius:8px;transition:background .2s}}
.chat-msg:target{{background:rgba(117,219,240,.1)}}
.chat-msg:hover{{background:var(--user-bg)}}
.chat-body{{min-width:0}}
.u-av{{width:28px;height:28px;border-radius:50%;overflow:hidden;flex-shrink:0;margin-top:2px}}
.u-av img{{width:100%;height:100%;object-fit:cover;border-radius:50%}}
.u-av svg{{width:100%;height:100%}}
.u-name{{font-weight:600;font-size:.85rem;margin-right:6px}}
.ts{{font-size:.75rem;color:var(--muted)}}
.chat-text{{white-space:pre-wrap;word-break:break-word;font-size:.9rem;line-height:1.6;margin-top:2px}}
.chat-text a{{color:var(--link)}}
/* Media */
.media-wrap{{margin:4px 0 6px}}
.chat-photo{{max-width:100%;border-radius:8px;display:block;cursor:pointer;
  border:1px solid var(--border)}}
.chat-photo:hover{{opacity:.9}}
.file-dl{{display:block;font-size:.75rem;color:var(--muted);margin-top:2px;text-decoration:none}}
.file-dl:hover{{color:var(--link)}}
.file-card{{background:var(--code-bg);border:1px solid var(--border);border-radius:var(--radius);
  overflow:hidden}}
.file-header{{display:flex;align-items:center;gap:6px;padding:8px 10px;font-size:.85rem;
  color:var(--fg);cursor:pointer;list-style:none}}
.file-header::-webkit-details-marker{{display:none}}
.file-header:hover{{background:var(--user-bg)}}
.file-header .chev{{margin-left:auto;width:14px;height:14px;color:var(--muted);
  transition:transform .15s;flex-shrink:0}}
details.file-card[open] .chev{{transform:rotate(90deg)}}
details.file-card[open] .file-header{{border-bottom:1px solid var(--border)}}
.file-icon{{font-size:1rem}}
.file-dl-btn{{margin-left:auto;color:var(--muted);text-decoration:none;font-size:1rem;
  padding:0 4px;border-radius:4px}}
.file-dl-btn:hover{{color:var(--link);background:rgba(117,219,240,.08)}}
.file-preview{{width:100%;height:300px;border:0;background:var(--bg);color:var(--fg)}}
.file-preview-pdf{{height:500px}}
/* Inline file content */
.file-body{{padding:12px 14px;font-size:.85rem;line-height:1.6;color:var(--fg);
  max-height:500px;overflow:auto;border-top:1px solid var(--border)}}
.file-body-md{{font-family:var(--sans)}}
.file-body-md h1,.file-body-md h2,.file-body-md h3,.file-body-md h4{{margin:12px 0 6px;font-weight:600}}
.file-body-md h1{{font-size:1.3rem}}.file-body-md h2{{font-size:1.1rem}}.file-body-md h3{{font-size:.95rem}}
.file-body-md p{{margin:4px 0}}.file-body-md li{{margin:2px 0 2px 16px;list-style:disc}}
.file-body-md hr{{border:0;border-top:1px solid var(--border);margin:10px 0}}
.file-body-md a{{color:var(--link)}}.file-body-md strong{{font-weight:600}}
.file-body-md .md-code{{background:var(--code-bg);padding:8px 10px;border-radius:4px;display:block;
  font-family:var(--mono);font-size:.8rem;overflow-x:auto;white-space:pre;margin:6px 0}}
.file-body-md .md-inline{{background:var(--code-bg);padding:1px 4px;border-radius:3px;font-family:var(--mono);font-size:.8rem}}
.file-body-code{{font-family:var(--mono);white-space:pre;overflow-x:auto;margin:0;
  background:var(--code-bg);border-top:1px solid var(--border)}}
.file-body-code code{{font-size:.8rem;line-height:1.5}}
.file-body-text{{font-family:var(--mono);white-space:pre-wrap;word-break:break-word;margin:0;
  background:var(--code-bg);border-top:1px solid var(--border)}}
.file-body-csv{{overflow-x:auto;border-top:1px solid var(--border)}}
.file-body-csv table{{width:100%;border-collapse:collapse;font-size:.8rem}}
.file-body-csv th,.file-body-csv td{{padding:4px 8px;border:1px solid var(--border);text-align:left}}
.file-body-csv th{{background:var(--card);font-weight:600;position:sticky;top:0}}
.file-card-link{{display:inline-flex;align-items:center;gap:6px;padding:6px 12px;
  background:var(--code-bg);border:1px solid var(--border);border-radius:var(--radius);
  color:var(--fg);text-decoration:none;font-size:.85rem}}
.file-card-link:hover{{border-color:var(--link);color:var(--link)}}
/* Reply context */
.reply-ctx{{display:block;border-left:3px solid var(--link);padding:2px 8px;margin:2px 0 4px;
  font-size:.8rem;color:var(--muted);text-decoration:none;border-radius:2px;
  background:rgba(117,219,240,.04);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}}
.reply-ctx:hover{{background:rgba(117,219,240,.1);color:var(--fg)}}
.reply-name{{font-weight:600;color:var(--link);margin-right:4px}}
/* Context link (search → full view) */
.ctx-link{{font-size:.75rem;color:var(--muted);text-decoration:none;margin-left:4px;
  opacity:.6;transition:opacity .15s}}
.ctx-link:hover{{opacity:1;color:var(--link)}}
/* Jump buttons */
.jump{{position:fixed;bottom:20px;right:20px;display:flex;flex-direction:column;gap:6px}}
.jump a{{width:32px;height:32px;border-radius:50%;background:var(--code-bg);border:1px solid var(--border);
  display:flex;align-items:center;justify-content:center;color:var(--muted);text-decoration:none;font-size:1rem;
  transition:border-color .15s}}
.jump a:hover{{border-color:var(--muted);color:var(--fg)}}
</style>
</head>
<body>
<div class="wrap">
<header>
<h1>Team Chat</h1>
<div class="meta">Telegram chat history</div>
</header>

<form class="search-bar" method="get">
<input type="text" name="q" value="{search_val}" placeholder="Search messages...">
<button type="submit">Search</button>
<input type="hidden" name="token" value="{esc(token)}">
{"" if per_page == 50 else f'<input type="hidden" name="per_page" value="{per_page}">'}
</form>

{search_result}
{nav_html}

<div class="thread" id="thread">
{"".join(blocks)}
</div>

{nav_html}
</div>

<div class="jump">
<a href="#" onclick="window.scrollTo(0,0);return false">&uarr;</a>
<a href="#" onclick="window.scrollTo(0,document.body.scrollHeight);return false">&darr;</a>
</div>

<script>
// Render timestamps in browser timezone
document.querySelectorAll('.ts[data-ts]').forEach(el => {{
  try {{
    const d = new Date(el.dataset.ts);
    if (!isNaN(d)) el.textContent = d.toLocaleString(undefined, {{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}});
  }} catch(e) {{}}
}});
// Scroll to target anchor if present
if (location.hash) {{
  const el = document.querySelector(location.hash);
  if (el) setTimeout(() => el.scrollIntoView({{behavior:'smooth',block:'center'}}), 100);
}}
</script>
</body>
</html>'''


def _render_transcript_html(name: str, session_id: str = None,
                            page: int = None, per_page: int = 50,
                            search_query: str = "", token: str = "",
                            filter_mode: str = "", search_sort: str = "relevance") -> str:
    """Render a worker's transcript as polished HTML (ampcode.com style).

    Supports pagination (?page=N&per_page=50) and search (?q=term).
    filter_mode="prompts" shows only user messages.
    page=None means "show last page" (most recent entries).
    Uses marked.js for markdown and highlight.js for syntax highlighting.
    """
    import html as html_mod
    esc = html_mod.escape

    transcript_path, sid, cwd = _resolve_transcript_path(name, session_id)
    if not sid:
        return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>No session found for {esc(name)}</h1></body></html>"
    if not transcript_path:
        return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>Transcript not found</h1><p>Worker: {esc(name)}</p><p>Session: {esc(sid)}</p></body></html>"
    jsonl_path = str(transcript_path)

    # Query transcript-index.py — combined entries+stats in single call.
    if search_query:
        query_result = _run_transcript_query(
            jsonl_path, sid, "search+stats",
            search=search_query, page=page or 1, per_page=per_page, sort=search_sort)
    else:
        query_result = _run_transcript_query(
            jsonl_path, sid, "entries+stats",
            page=page, per_page=per_page, filter_mode=filter_mode)
    stats_result = query_result.pop("stats", None) if query_result else None

    # Fallback to old parsing if script fails
    if not query_result:
        if not transcript_path or not Path(str(transcript_path)).exists():
            return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>Transcript not available</h1><p>Worker: {esc(name)}</p><p>Session: {esc(sid)}</p></body></html>"
        all_entries = _parse_transcript_entries(transcript_path)
        total = len(all_entries)
        for _i, _e in enumerate(all_entries):
            _e["_idx"] = _i
        total_pages = max(1, (total + per_page - 1) // per_page)
        if page is None:
            page = total_pages
        page = max(1, min(page, total_pages))
        start = (page - 1) * per_page
        page_entries = all_entries[start:start + per_page]
        stats = _transcript_stats(all_entries)
        file_size_str = ""
    else:
        # Reconstruct entry dicts from raw_json
        page_entries = []
        for e in query_result.get("entries", []):
            try:
                entry = json.loads(e["raw_json"])
                entry["_idx"] = e.get("idx", -1)
                page_entries.append(entry)
            except (json.JSONDecodeError, KeyError):
                continue

        if search_query:
            total = query_result.get("total_results", 0)
        else:
            total = query_result.get("total", 0)
        total_pages = query_result.get("total_pages", 1)
        page = query_result.get("page", 1)

        _empty_stats = {"n_user": 0, "n_tool": 0, "n_edit": 0, "lines_add": 0,
                        "lines_del": 0, "lines_mod": 0, "n_files": 0, "model": "",
                        "version": "", "git_branch": "", "first_ts": "", "last_ts": "",
                        "input_tokens": 0, "output_tokens": 0, "duration": ""}
        stats = stats_result if stats_result else _empty_stats

    # File size of the transcript JSONL (local only)
    file_size_str = ""
    try:
        file_size_bytes = os.path.getsize(transcript_path)
        if file_size_bytes >= 1_048_576:
            file_size_str = f"{file_size_bytes / 1_048_576:.1f} MB"
        elif file_size_bytes >= 1024:
            file_size_str = f"{file_size_bytes / 1024:.0f} KB"
        else:
            file_size_str = f"{file_size_bytes} B"
    except OSError:
        pass

    # Pre-index tool results by tool_use_id for merging into tool_use blocks
    _tool_results = {}
    for entry in page_entries:
        if entry.get("type") == "user":
            ct = entry.get("message", {}).get("content", [])
            if isinstance(ct, list):
                for item in ct:
                    if isinstance(item, dict) and item.get("type") == "tool_result":
                        tuid = item.get("tool_use_id", "")
                        rt = item.get("content", "")
                        if isinstance(rt, list):
                            rt = "\n".join(r.get("text", "") for r in rt if isinstance(r, dict) and r.get("type") == "text")
                        _tool_results[tuid] = {"content": str(rt), "is_error": bool(item.get("is_error"))}

    # Render blocks — group consecutive assistant entries into a turn-body
    # No avatar/label on assistant turns (matches AmpCode: only user has avatar)
    blocks = []
    in_assistant_turn = False

    # Build context URL for search mode (click message → jump to full transcript)
    def _ctx_url(entry):
        if not search_query:
            return ""
        idx = entry.get("_idx", -1)
        if idx < 0:
            return ""
        ctx_page = (idx // per_page) + 1
        ctx_qs = []
        if token:
            ctx_qs.append(f"token={esc(token)}")
        if session_id:
            ctx_qs.append(f"sid={esc(session_id)}")
        if per_page != 50:
            ctx_qs.append(f"per_page={per_page}")
        ctx_qs.append(f"page={ctx_page}")
        return f'?{"&".join(ctx_qs)}#e-{idx}'

    for entry in page_entries:
        etype = entry.get("type", "")
        role = entry.get("message", {}).get("role", "")
        # Skip tool_result entries — they're merged into tool_use blocks
        is_tool_result = (etype == "user" and role == "user" and
                          isinstance(entry.get("message", {}).get("content"), list) and
                          any(c.get("type") == "tool_result" for c in entry.get("message", {}).get("content", []) if isinstance(c, dict)))
        if is_tool_result:
            continue
        h = _transcript_entry_to_html(entry, esc, tool_results=_tool_results)
        if not h:
            continue
        eidx = entry.get("_idx", -1)
        anchor = f' id="e-{eidx}"' if eidx >= 0 else ""
        curl = _ctx_url(entry)
        is_assistant = (etype == "assistant" and role == "assistant")
        if is_assistant:
            if curl:
                if in_assistant_turn:
                    blocks.append('</div>')
                    in_assistant_turn = False
                h = f'<a class="ctx-wrap" href="{curl}"{anchor}>{h}</a>'
                blocks.append(h)
            else:
                if not in_assistant_turn:
                    blocks.append(f'<div class="turn-body"{anchor}>')
                    in_assistant_turn = True
                blocks.append(h)
        else:
            if in_assistant_turn:
                blocks.append('</div>')
                in_assistant_turn = False
            if curl:
                h = f'<a class="ctx-wrap" href="{curl}"{anchor}>{h}</a>'
            elif anchor:
                h = f'<div{anchor}>{h}</div>'
            blocks.append(h)
    if in_assistant_turn:
        blocks.append('</div>')

    # Build query string for pagination links (token first to preserve auth)
    qs_parts = []
    if token:
        qs_parts.append(f"token={esc(token)}")
    if session_id:
        qs_parts.append(f"sid={esc(session_id)}")
    if per_page != 50:
        qs_parts.append(f"per_page={per_page}")
    if search_query:
        qs_parts.append(f"q={esc(search_query)}")
    if filter_mode:
        qs_parts.append(f"filter={esc(filter_mode)}")
    qs_base = "&".join(qs_parts)

    def page_url(p):
        parts = [f"page={p}"]
        if qs_base:
            parts.append(qs_base)
        return "?" + "&".join(parts)

    # Pagination nav
    nav_html = ""
    if total_pages > 1:
        nav_items = []
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page <= 1 else ""}" href="{page_url(1)}">First</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page <= 1 else ""}" href="{page_url(page-1)}">Prev</a>')
        # Page numbers: show up to 7 centered on current
        start_p = max(1, page - 3)
        end_p = min(total_pages, start_p + 6)
        start_p = max(1, end_p - 6)
        for p in range(start_p, end_p + 1):
            cls = " pg-cur" if p == page else ""
            nav_items.append(f'<a class="pg-btn{cls}" href="{page_url(p)}">{p}</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page >= total_pages else ""}" href="{page_url(page+1)}">Next</a>')
        nav_items.append(f'<a class="pg-btn{" pg-dis" if page >= total_pages else ""}" href="{page_url(total_pages)}">Last</a>')
        nav_html = f'<nav class="pg">{"".join(nav_items)}<span class="pg-info">Page {page}/{total_pages} ({total} entries)</span></nav>'

    search_val = esc(search_query) if search_query else ""
    search_result = ""
    if search_query:
        sort_label = "by time" if search_sort == "time" else "by relevance"
        alt_sort = "time" if search_sort == "relevance" else "relevance"
        alt_label = "time" if search_sort == "relevance" else "relevance"
        sort_qs = []
        if token:
            sort_qs.append(f"token={esc(token)}")
        if session_id:
            sort_qs.append(f"sid={esc(session_id)}")
        sort_qs.append(f"q={esc(search_query)}")
        if per_page != 50:
            sort_qs.append(f"per_page={per_page}")
        sort_qs.append(f"sort={alt_sort}")
        sort_url = f'?{"&".join(sort_qs)}'
        search_result = (
            f'<div class="search-info">Found {total} matching entries for "<strong>{esc(search_query)}</strong>" '
            f'(sorted {sort_label}) &middot; <a href="{sort_url}">sort by {alt_label}</a></div>'
        )

    # Build prompts filter URL (toggle on/off)
    _filt_qs = []
    if token:
        _filt_qs.append(f"token={esc(token)}")
    if session_id:
        _filt_qs.append(f"sid={esc(session_id)}")
    if per_page != 50:
        _filt_qs.append(f"per_page={per_page}")
    if filter_mode != "prompts":
        _filt_qs.append("filter=prompts")
    prompts_filter_url = "?" + "&".join(_filt_qs) if _filt_qs else "?"
    filter_banner = ""
    if filter_mode == "prompts":
        _clear_qs = [p for p in _filt_qs]  # already excludes filter=prompts
        _clear_url = "?" + "&".join(_clear_qs) if _clear_qs else "?"
        filter_banner = f'<div class="search-info">Showing prompts only — <a href="{_clear_url}">show all</a></div>'

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(name)} — Transcript</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css" media="(prefers-color-scheme: dark)">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css" media="(prefers-color-scheme: light)">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.1/marked.min.js"></script>
<style>
:root {{
  --bg:#0b0d0b; --fg:#e5e5e0; --border:rgba(135,139,134,.12); --muted:#9ca49c;
  --card:rgba(11,13,11,.02); --user-bg:rgba(255,255,255,.04);
  --user-border:rgba(135,139,134,.12); --code-bg:#1a1c1a;
  --green:#22c55e; --red:#bd2b2b; --link:#75dbf0; --radius:6px;
  --claude:#d4a574; --claude-bg:rgba(212,165,116,.08);
  --mono:"JetBrains Mono","Berkeley Mono","Fira Code","SF Mono",monospace;
  --sans:"Inter",ui-sans-serif,system-ui,-apple-system,sans-serif;
  --diff-add-bg:rgba(34,197,94,.1); --diff-add-fg:#22c55e;
  --diff-del-bg:rgba(239,68,68,.1); --diff-del-fg:#ef4444;
}}
@media(prefers-color-scheme:light){{
  :root{{--bg:#fafaf8;--fg:#1a1a1a;--muted:#595959;--border:rgba(135,139,134,.2);
    --card:rgba(246,255,245,.03);--user-bg:rgba(0,0,0,.03);--user-border:rgba(135,139,134,.2);
    --code-bg:#f4f4f0;--green:#16a34a;--red:#d44444;--link:#0969da;
    --claude:#b07d4f;--claude-bg:rgba(176,125,79,.06);
    --diff-add-bg:rgba(34,197,94,.1);--diff-add-fg:#16a34a;
    --diff-del-bg:rgba(239,68,68,.1);--diff-del-fg:#dc2626;}}
}}
*{{margin:0;padding:0;box-sizing:border-box}}
html{{font-size:14px}}
body{{font-family:var(--sans);background:var(--bg);color:var(--fg);line-height:1.6;
  -webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}}
.wrap{{display:flex;flex-direction:column;min-height:100vh}}
.main{{flex:1;display:flex;justify-content:center;padding:24px 16px 80px;gap:24px}}
.content{{flex:1;min-width:0;max-width:42rem}}
/* Sidebar */
.sidebar{{width:240px;flex-shrink:0;position:sticky;top:24px;align-self:flex-start;
  font-size:.8rem;color:var(--muted)}}
.sidebar-inner{{border:1px solid var(--border);border-radius:10px;padding:16px;
  background:var(--card);display:flex;flex-direction:column;gap:12px}}
.sb-title{{font-weight:600;color:var(--fg);font-size:.85rem;margin-bottom:4px}}
.sb-row{{display:flex;justify-content:space-between;align-items:center}}
.sb-label{{color:var(--muted)}}
.sb-val{{color:var(--fg);font-weight:500;font-family:var(--mono);font-size:.75rem}}
.sb-divider{{border-top:1px solid var(--border);margin:4px 0}}
.sb-lines{{display:flex;gap:10px;font-family:var(--mono);font-size:.75rem;font-weight:600}}
.sb-lines .plus{{color:var(--green)}}.sb-lines .minus{{color:var(--red)}}.sb-lines .mod{{color:#f59e0b}}
/* Mobile sidebar toggle (in header) */
.sb-toggle{{display:none;background:none;border:none;color:var(--muted);cursor:pointer;
  padding:2px;line-height:0;transition:color .15s}}
.sb-toggle:hover{{color:var(--fg)}}
@media(max-width:900px){{
  .sidebar{{display:none;position:fixed;top:0;right:0;bottom:0;width:260px;z-index:100;
    padding:16px;background:var(--bg);border-left:1px solid var(--border);
    overflow-y:auto;box-shadow:-4px 0 20px rgba(0,0,0,.3)}}
  .sidebar.sb-open{{display:block}}
  .sb-toggle{{display:inline-flex}}
  .main{{justify-content:center}}
}}
/* Header */
header{{border-bottom:1px solid var(--border);padding-bottom:20px;margin-bottom:24px}}
.h-row{{display:flex;align-items:center;gap:8px}}
h1{{font-size:1.5rem;font-weight:600;letter-spacing:-.02em}}
.meta{{display:flex;flex-wrap:wrap;gap:16px;margin-top:10px;color:var(--muted);font-size:.8rem}}
.mi{{display:inline-flex;align-items:center;gap:5px}}
.mi svg{{width:14px;height:14px;opacity:.7;flex-shrink:0}}
/* Search */
.search-bar{{margin-bottom:16px;display:flex;gap:8px}}
.search-bar input{{flex:1;padding:8px 12px;border:1px solid var(--border);border-radius:8px;
  background:var(--card);color:var(--fg);font-size:.875rem;font-family:var(--sans);outline:none;
  transition:border-color .15s}}
.search-bar input:focus{{border-color:var(--link)}}
.search-bar button{{padding:8px 16px;border:1px solid var(--border);border-radius:8px;
  background:var(--card);color:var(--fg);cursor:pointer;font-size:.8rem;transition:all .15s}}
.search-bar button:hover{{border-color:var(--link);color:var(--link)}}
.search-info{{color:var(--muted);font-size:.8rem;margin-bottom:12px;padding:8px 12px;
  border:1px dashed var(--border);border-radius:8px}}
.ctx-wrap{{display:block;text-decoration:none;color:inherit;border-radius:8px;
  padding:4px;margin:-4px;transition:background .15s;cursor:pointer}}
.ctx-wrap:hover{{background:var(--user-bg);text-decoration:none}}
mark{{background:rgba(250,204,21,.25);color:inherit;border-radius:2px;padding:0 1px}}
/* Pagination */
.pg{{display:flex;align-items:center;gap:4px;flex-wrap:wrap;margin:16px 0;font-size:.8rem}}
.pg-btn{{padding:5px 12px;border:1px solid var(--border);border-radius:6px;color:var(--fg);
  text-decoration:none;transition:all .15s}}
.pg-btn:hover{{border-color:var(--link);color:var(--link);text-decoration:none}}
.pg-cur{{background:var(--link);color:var(--bg);border-color:var(--link);font-weight:600}}
.pg-cur:hover{{color:var(--bg)}}
.pg-dis{{opacity:.3;pointer-events:none}}
.pg-info{{margin-left:auto;color:var(--muted)}}
/* Thread */
.thread{{display:flex;flex-direction:column;gap:20px}}
/* Assistant turn body (no avatar — matches AmpCode) */
.turn-body{{display:flex;flex-direction:column;gap:8px;min-width:0}}
/* User messages */
.user-msg{{display:grid;grid-template-columns:28px 1fr;gap:10px;align-items:start}}
.u-av{{width:28px;height:28px;border-radius:50%;overflow:hidden;flex-shrink:0;margin-top:2px;
  border:1px solid var(--border)}}
.u-av img{{width:100%;height:100%;object-fit:cover;display:block}}
.ts{{font-size:.65rem;font-weight:400;color:var(--muted);float:right;margin-left:8px;margin-top:4px}}
.u-body{{min-width:0}}
.u-name{{display:block;font-size:.7rem;font-weight:600;color:var(--muted);margin-bottom:2px;text-transform:capitalize}}
.u-text{{white-space:pre-wrap;word-break:break-word;font-size:1rem;line-height:1.6}}
/* Assistant text (rendered by marked.js) */
.a-text{{font-size:1rem;line-height:1.6;word-break:break-word}}
.a-text p{{margin:.5em 0}}
.a-text ul,.a-text ol{{padding-left:1.5rem;margin:.5em 0}}
.a-text li{{margin:.3em 0}}
.a-text strong{{font-weight:600}}
.a-text h1{{font-size:1.4em;font-weight:600;margin:.8em 0 .4em}}
.a-text h2{{font-size:1.2em;font-weight:600;margin:.7em 0 .3em}}
.a-text h3{{font-size:1.1em;font-weight:600;margin:.6em 0 .2em}}
.a-text blockquote{{border-left:3px solid var(--border);padding-left:12px;color:var(--muted);margin:.5em 0}}
.a-text .table-wrap{{overflow-x:auto;margin:.75em 0}}
.a-text .table-wrap table{{margin:0}}
.a-text table{{border-collapse:collapse;box-shadow:0 0 0 1px var(--border);border-radius:.25rem;overflow:hidden;margin:.75em 0;font-size:.93em}}
.a-text thead{{background:color-mix(in srgb,var(--muted) 20%,transparent)}}
.a-text th{{text-align:left;font-weight:600;border-bottom:1px solid var(--border);border-right:1px solid var(--border);padding:.375rem .5rem;white-space:nowrap}}
.a-text th:last-child{{border-right:none}}
.a-text td{{border-bottom:1px solid var(--border);border-right:1px solid var(--border);padding:.375rem .5rem;white-space:nowrap}}
.a-text td:last-child{{border-right:none}}
.a-text tbody tr:last-child td{{border-bottom:none}}
.a-text tbody tr:hover{{background:color-mix(in srgb,var(--muted) 15%,transparent)}}
.a-text a{{color:var(--link)}}
.a-text img{{max-width:100%;border-radius:8px}}
/* Code (hljs themed) */
.a-text pre{{background:var(--code-bg);border:1px solid var(--border);border-radius:6px;
  padding:12px 14px;overflow-x:auto;font-family:var(--mono);font-size:.8rem;line-height:1.6;margin:.6em 0}}
.a-text pre code{{background:none!important;padding:0!important;font-size:inherit}}
.a-text code{{background:var(--code-bg);padding:2px 6px;border-radius:4px;
  font-family:var(--mono);font-size:.85em}}
.a-text pre code{{background:none;padding:0;border-radius:0}}
.hljs{{background:transparent!important;padding:0!important}}
/* Copy button on code blocks */
.a-text pre{{position:relative}}
.copy-btn{{position:absolute;top:6px;right:6px;padding:3px 8px;border:1px solid var(--border);
  border-radius:4px;background:var(--bg);color:var(--muted);cursor:pointer;font-size:.65rem;
  opacity:0;transition:opacity .15s;font-family:var(--sans)}}
.a-text pre:hover .copy-btn{{opacity:1}}
.copy-btn:hover{{color:var(--fg);border-color:var(--muted)}}
.copy-btn.copied{{color:var(--green);border-color:var(--green)}}
/* Tool chips */
.chip{{display:inline-flex;align-items:center;gap:6px;padding:4px 8px;border-radius:6px;
  border:1px solid var(--border);background:var(--card);font-size:.875rem;font-weight:400;overflow:hidden;
  transition:border-color .15s;width:fit-content}}
.chip:hover{{border-color:var(--muted)}}
.t-icon{{flex-shrink:0;width:14px;height:14px;color:var(--muted);opacity:.8}}
.t-det{{color:var(--fg);font-family:var(--mono);font-size:.8rem;font-weight:400;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}}
.fp{{font-family:var(--mono);font-size:.8rem;font-weight:400}}
.fp-dir{{opacity:.6}}
/* Action blocks (Bash, expandable tools) */
.act{{border-radius:6px;border:1px solid var(--border);overflow:hidden}}
.act-h{{display:flex;align-items:center;gap:6px;padding:6px 8px;background:var(--card);
  font-size:.875rem;font-weight:400;cursor:pointer;user-select:none;list-style:none;transition:background .1s}}
.act-h::-webkit-details-marker{{display:none}}
.act-h:hover{{background:var(--user-bg)}}
.act-h svg{{width:14px;height:14px;color:var(--muted);flex-shrink:0}}
.act-body{{border-top:1px solid var(--border);padding:0;font-family:var(--mono);
  font-size:.75rem;line-height:1.6;white-space:pre-wrap;word-break:break-all;
  color:var(--muted);background:var(--code-bg)}}
.act-cmd{{padding:8px 12px;color:var(--fg)}}
.act-out{{padding:8px 12px;border-top:1px solid var(--border);color:var(--muted)}}
.act-out-err{{color:var(--red)}}
.act-err>.act-h .chev{{color:#bd2b2b}}
.act-body .t-out{{padding:8px 12px;white-space:pre-wrap;word-break:break-word;font-size:.75rem;
  color:var(--muted);font-family:var(--mono);line-height:1.6;border:0}}
/* Diff display */
.diff-act .act-h{{gap:8px}}
.diff-body{{border-top:1px solid var(--border);padding:0;font-family:var(--mono);
  font-size:.75rem;line-height:1.7;overflow-x:auto;background:var(--code-bg)}}
.diff-add,.diff-del,.diff-ctx{{padding:0 12px 0 0;white-space:pre;display:flex}}
.diff-add{{background:var(--diff-add-bg);color:var(--diff-add-fg)}}
.diff-del{{background:var(--diff-del-bg);color:var(--diff-del-fg)}}
.diff-ctx{{color:var(--muted)}}
.diff-ln{{display:inline-block;width:36px;text-align:right;padding-right:8px;color:var(--muted);
  opacity:.5;user-select:none;flex-shrink:0}}
.diff-sign{{display:inline-block;width:16px;text-align:center;flex-shrink:0;font-weight:600}}
.diff-stat{{display:inline-flex;gap:6px;margin-left:auto;font-family:var(--mono);font-size:.7rem}}
.diff-plus{{color:var(--green)}}.diff-minus{{color:var(--red)}}.diff-mod{{color:#f59e0b}}
/* Thinking */
.think{{border-radius:6px;border:1px solid transparent;background:var(--card)}}
.think-h{{display:flex;align-items:center;gap:4px;padding:6px 10px;cursor:pointer;
  user-select:none;color:var(--muted);font-size:.8rem;list-style:none;transition:color .1s}}
.think-h::-webkit-details-marker{{display:none}}
.think-h:hover{{color:var(--fg)}}
.think-t{{padding:10px 12px;white-space:pre-wrap;word-break:break-word;font-size:.8rem;
  color:var(--muted);font-family:var(--sans);font-style:italic;line-height:1.6}}
/* (tool outputs merged into tool_use blocks) */
/* Chevrons */
.chev{{width:14px;height:14px;transition:transform .15s ease;flex-shrink:0}}
.act-h .chev{{margin-left:auto}}
details[open] .chev{{transform:rotate(90deg)}}
/* Jump buttons */
.jump{{position:fixed;bottom:20px;right:20px;display:flex;flex-direction:column;gap:6px;z-index:50}}
.jump a{{width:36px;height:36px;border-radius:50%;border:1px solid var(--border);
  background:var(--bg);display:flex;align-items:center;justify-content:center;
  color:var(--muted);text-decoration:none;font-size:1.1rem;transition:all .15s;
  box-shadow:0 2px 8px rgba(0,0,0,.15)}}
.jump a:hover{{border-color:var(--link);color:var(--link)}}
a{{color:var(--link);text-decoration:none}}
a:hover{{text-decoration:underline}}
</style>
</head>
<body>
<div class="wrap">
<div class="main">
<div class="content">
<header>
<div class="h-row"><h1>{esc(name)}</h1><button class="sb-toggle" onclick="document.querySelector('.sidebar').classList.toggle('sb-open')" title="Session info"><svg viewBox="0 0 16 16" fill="currentColor" width="16" height="16"><path d="M0 8a8 8 0 1116 0A8 8 0 010 8zm8-6.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM6.5 7.75A.75.75 0 017.25 7h1a.75.75 0 01.75.75v2.75h.25a.75.75 0 010 1.5h-2a.75.75 0 010-1.5h.25v-2h-.25a.75.75 0 01-.75-.75zM8 6a1 1 0 110-2 1 1 0 010 2z"/></svg></button></div>
<div class="meta">
{"<span class='mi'><svg viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M8 16A8 8 0 108 0a8 8 0 000 16zm.25-11.75v4l3 1.5-.5 1-3.5-1.75v-4.75h1z\"/></svg>" + esc(stats["first_ts"][:10]) + "</span>" if stats["first_ts"] else ""}
{"<span class='mi'><svg viewBox='0 0 16 16' fill='currentColor'><path d='M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 01-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 00-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.75.75 0 01-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848l.213-.253c.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75zM6 15.25a.75.75 0 01.75-.75h2.5a.75.75 0 010 1.5h-2.5a.75.75 0 01-.75-.75zM5.75 12a.75.75 0 000 1.5h4.5a.75.75 0 000-1.5h-4.5z'/></svg>" + esc(stats["model"]) + "</span>" if stats["model"] else ""}
{"<span class='mi'><svg viewBox='0 0 16 16' fill='currentColor'><path d='M11.93 8.5a4.002 4.002 0 01-7.86 0H.75a.75.75 0 010-1.5h3.32a4.002 4.002 0 017.86 0h3.32a.75.75 0 010 1.5h-3.32zm-1.43-.75a2.5 2.5 0 10-5 0 2.5 2.5 0 005 0z'/></svg>" + esc(stats["git_branch"]) + "</span>" if stats["git_branch"] else ""}
<a class="mi" href="{prompts_filter_url}" style="cursor:pointer" title="Filter to prompts only"><svg viewBox="0 0 16 16" fill="currentColor"><path d="M1.75 1h8.5c.966 0 1.75.784 1.75 1.75v5.5A1.75 1.75 0 0110.25 10H7.061l-2.574 2.573A1.458 1.458 0 012 11.543V10h-.25A1.75 1.75 0 010 8.25v-5.5C0 1.784.784 1 1.75 1z"/></svg>{stats["n_user"]} prompts</a>
<span class="mi"><svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.433 2.304A4.49 4.49 0 003.5 6c0 1.598.832 3.002 2.09 3.802.518.328.929.923.902 1.64v.008l-.164 3.337a.75.75 0 11-1.498-.073l.163-3.34c.007-.14-.1-.313-.357-.476A5.994 5.994 0 012 6c0-2.033 1.01-3.83 2.555-4.916A1.89 1.89 0 015.433 2.304z"/></svg>{stats["n_tool"]} tool call{"s" if stats["n_tool"] != 1 else ""}</span>
</div>
</header>
<form class="search-bar" method="get">
<input type="text" name="q" placeholder="Search transcript…" value="{search_val}">
<button type="submit">Search</button>
{"<input type='hidden' name='token' value='" + esc(token) + "'>" if token else ""}
{"<input type='hidden' name='sid' value='" + esc(session_id) + "'>" if session_id else ""}
{"<input type='hidden' name='per_page' value='" + str(per_page) + "'>" if per_page != 50 else ""}
{"<input type='hidden' name='filter' value='prompts'>" if filter_mode == "prompts" else ""}
</form>
{filter_banner}
{search_result}
{nav_html}
<div class="thread" id="thread"{' data-search="' + esc(search_query) + '"' if search_query else ''}>
{"".join(blocks)}
</div>
{nav_html}
</div>
<aside class="sidebar"><div class="sidebar-inner">
<div class="sb-title">Session Info</div>
<div class="sb-row"><span class="sb-label">Session</span><span class="sb-val">{esc(sid[:12])}</span></div>
{"<div class='sb-row'><span class='sb-label'>Model</span><span class='sb-val'>" + esc(_format_model_name(stats["model"])) + "</span></div>" if stats["model"] else ""}
{"<div class='sb-row'><span class='sb-label'>Version</span><span class='sb-val'>" + esc(stats["version"]) + "</span></div>" if stats["version"] else ""}
{"<div class='sb-row'><span class='sb-label'>Branch</span><span class='sb-val'>" + esc(stats["git_branch"]) + "</span></div>" if stats["git_branch"] else ""}
<div class="sb-divider"></div>
<div class="sb-row"><span class="sb-label">Prompts</span><span class="sb-val">{stats["n_user"]}</span></div>
<div class="sb-row"><span class="sb-label">Tool calls</span><span class="sb-val">{stats["n_tool"]}</span></div>
{"<div class='sb-row'><span class='sb-label'>Edits</span><span class='sb-val'>" + str(stats["n_edit"]) + "</span></div>" if stats["n_edit"] else ""}
{"<div class='sb-row'><span class='sb-label'>Files touched</span><span class='sb-val'>" + str(stats["n_files"]) + "</span></div>" if stats["n_files"] else ""}
{"<div class='sb-divider'></div><div class='sb-lines'><span class='plus'>+" + str(stats["lines_add"]) + "</span><span class='minus'>-" + str(stats["lines_del"]) + "</span><span class='mod'>~" + str(stats["lines_mod"]) + "</span></div>" if stats["lines_add"] or stats["lines_del"] or stats["lines_mod"] else ""}
{"<div class='sb-divider'></div>" if stats["duration"] or file_size_str or stats["input_tokens"] else ""}
{"<div class='sb-row'><span class='sb-label'>Duration</span><span class='sb-val'>" + esc(stats["duration"]) + "</span></div>" if stats["duration"] else ""}
{"<div class='sb-row'><span class='sb-label'>File size</span><span class='sb-val'>" + esc(file_size_str) + "</span></div>" if file_size_str else ""}
{"<div class='sb-row'><span class='sb-label'>Input tokens</span><span class='sb-val'>" + f'{stats["input_tokens"]:,}' + "</span></div>" if stats["input_tokens"] else ""}
{"<div class='sb-row'><span class='sb-label'>Output tokens</span><span class='sb-val'>" + f'{stats["output_tokens"]:,}' + "</span></div>" if stats["output_tokens"] else ""}
<div class="sb-divider"></div>
<div class="sb-row"><span class="sb-label">Total entries</span><span class="sb-val">{total}</span></div>
<div class="sb-row"><span class="sb-label">Page</span><span class="sb-val">{page}/{total_pages}</span></div>
</div></aside>
</div>
</div>
<div class="jump">
<a href="#" title="Top" onclick="window.scrollTo(0,0);return false">↑</a>
<a href="#" title="Bottom" onclick="window.scrollTo(0,document.body.scrollHeight);return false">↓</a>
</div>
<script>
// Render markdown blocks with marked.js + highlight.js
marked.setOptions({{
  highlight: function(code, lang) {{
    if (lang && hljs.getLanguage(lang)) {{
      return hljs.highlight(code, {{language: lang}}).value;
    }}
    return hljs.highlightAuto(code).value;
  }},
  breaks: true,
  gfm: true
}});
function decodeB64Utf8(b64) {{
  var bin = atob(b64);
  var bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder('utf-8').decode(bytes);
}}
document.querySelectorAll('.markdown[data-md]').forEach(function(el) {{
  try {{
    var md = decodeB64Utf8(el.getAttribute('data-md'));
    el.innerHTML = marked.parse(md);
  }} catch(e) {{
    el.textContent = 'Error rendering markdown: ' + e.message;
  }}
}});
// Wrap tables in scroll containers
document.querySelectorAll('.a-text table').forEach(function(table) {{
  var wrap = document.createElement('div');
  wrap.className = 'table-wrap';
  table.parentNode.insertBefore(wrap, table);
  wrap.appendChild(table);
}});
// Add copy buttons to code blocks
document.querySelectorAll('.a-text pre').forEach(function(pre) {{
  var btn = document.createElement('button');
  btn.className = 'copy-btn';
  btn.textContent = 'Copy';
  btn.onclick = function() {{
    var code = pre.querySelector('code');
    navigator.clipboard.writeText(code ? code.textContent : pre.textContent).then(function() {{
      btn.textContent = 'Copied!';
      btn.classList.add('copied');
      setTimeout(function() {{ btn.textContent = 'Copy'; btn.classList.remove('copied'); }}, 2000);
    }});
  }};
  pre.appendChild(btn);
}});
// Keyboard shortcuts
document.addEventListener('keydown', function(e) {{
  if (e.target.tagName === 'INPUT') return;
  if (e.key === '/') {{ e.preventDefault(); document.querySelector('.search-bar input').focus(); }}
  if (e.key === 'Home') {{ window.scrollTo(0,0); }}
  if (e.key === 'End') {{ window.scrollTo(0,document.body.scrollHeight); }}
}});
// Highlight search terms in thread content
(function() {{
  var thread = document.getElementById('thread');
  var q = thread && thread.getAttribute('data-search');
  if (!q) return;
  var terms = q.split(/\\s+/).filter(function(t) {{ return t.length > 0; }});
  if (!terms.length) return;
  var pattern = new RegExp('(' + terms.map(function(t) {{
    return t.replace(/[.*+?^${{}}()|[\\]\\\\]/g, '\\\\$&');
  }}).join('|') + ')', 'gi');
  function walk(node) {{
    if (node.nodeType === 3) {{
      var text = node.textContent;
      if (!pattern.test(text)) return;
      pattern.lastIndex = 0;
      var frag = document.createDocumentFragment();
      var last = 0;
      var match;
      while ((match = pattern.exec(text)) !== null) {{
        if (match.index > last) frag.appendChild(document.createTextNode(text.slice(last, match.index)));
        var mark = document.createElement('mark');
        mark.textContent = match[0];
        frag.appendChild(mark);
        last = pattern.lastIndex;
      }}
      if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
      node.parentNode.replaceChild(frag, node);
    }} else if (node.nodeType === 1 && !/^(script|style|mark|code|pre)$/i.test(node.tagName)) {{
      var children = Array.from(node.childNodes);
      for (var i = 0; i < children.length; i++) walk(children[i]);
    }}
  }}
  // Highlight in user messages and assistant text
  thread.querySelectorAll('.u-text, .a-text').forEach(function(el) {{ walk(el); }});
}})();
// Render timestamps in browser timezone
var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
document.querySelectorAll('.ts[data-ts]').forEach(function(el) {{
  try {{
    var d = new Date(el.getAttribute('data-ts'));
    if (!isNaN(d)) {{
      var mon = months[d.getMonth()];
      var day = d.getDate();
      var h = String(d.getHours()).padStart(2,'0');
      var m = String(d.getMinutes()).padStart(2,'0');
      el.textContent = mon + ' ' + day + ' ' + h + ':' + m;
    }}
  }} catch(e) {{}}
}});
</script>
</body>
</html>'''


# ============================================================
# NON-CORE: HTTP Handler
# ============================================================

class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, data: dict):
        """Send a JSON response with proper Content-Type."""
        body = json.dumps(data).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, body: bytes, status: int = 200):
        """Send HTML response, gzip-compressed if client supports it."""
        accept = self.headers.get("Accept-Encoding", "")
        if "gzip" in accept and len(body) > 1024:
            import gzip as _gzip
            compressed = _gzip.compress(body, compresslevel=6)
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(compressed)))
            self.end_headers()
            self.wfile.write(compressed)
        else:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def _send_unknown_endpoint(self, method: str, path: str):
        """Return 404 JSON for unrecognized endpoints with available alternatives."""
        self._send_json(404, {
            "error": f"Unknown endpoint: {method} {path}",
            "available_endpoints": API_ENDPOINTS,
            "hint": "Messages from manager arrive as prompts. There is no polling endpoint.",
        })

    def do_POST(self):
        # Route based on path
        if self.path == "/response":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.handle_hook_response(body)
            return

        if self.path == "/notify":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.handle_notify(body)
            return

        # PR comment endpoint
        if self.path == "/pr-comment":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.handle_pr_comment(body)
            return

        if self.path == "/pr-general-comment":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.handle_pr_general_comment(body)
            return

        if self.path == "/pr-merge":
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.handle_pr_merge(body)
            return

        # Only accept Telegram webhook on root path — 404 for unknown POST paths
        parsed = urlparse(self.path)
        if parsed.path != "/":
            self._send_unknown_endpoint("POST", parsed.path)
            return

        # Telegram webhook - optional secret verification
        if WEBHOOK_SECRET:
            header_token = self.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
            if header_token != WEBHOOK_SECRET:
                print("Webhook rejected: invalid secret token")
                self.send_response(403)
                self.end_headers()
                self.wfile.write(b"Forbidden")
                return

        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        # Respond 200 immediately so Telegram gets the ACK fast
        # (prevents missing read receipts and webhook retries during
        # slow operations like remote restart which blocks 30-60s).
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")
        try:
            update = json.loads(body)
            # Debug: show what update type we received
            update_types = [k for k in update.keys() if k != "update_id"]
            if update_types and update_types[0] != "message":
                print(f"Received update type: {update_types}")
            if "message" in update:
                threading.Thread(
                    target=command_router.handle_message,
                    args=(update,),
                    daemon=True,
                ).start()
            if "callback_query" in update:
                threading.Thread(
                    target=command_router.handle_callback,
                    args=(update,),
                    daemon=True,
                ).start()
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()

    def handle_notify(self, body: bytes = b""):
        """Handle system notification request (internal, HMAC-authenticated).

        SECURITY: This endpoint allows the shell script to trigger
        notifications without having access to the bot token.
        Used for tunnel watchdog alerts.
        """
        try:
            data = json.loads(body)
            text = data.get("text", "")

            if not text:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Missing text")
                return

            # Send to all known chat_ids
            chat_ids = get_all_chat_ids()
            sent = 0
            for chat_id in chat_ids:
                result = transport.send_text(chat_id, text)
                if result and result.get("ok"):
                    sent += 1

            print(f"Notify: sent to {sent}/{len(chat_ids)} chats: {text[:50]}...")

            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"Sent to {sent} chats".encode())
        except Exception as e:
            print(f"Notify error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_hook_response(self, body: bytes = b""):
        """Handle response forwarded from Claude hook.

        SECURITY: This is how Claude responses get to Telegram without
        Claude ever having access to the bot token. Hook POSTs here,
        bridge sends to Telegram. HMAC-authenticated.

        FILE SUPPORT: Parses [[image:/path|caption]] (photos, animations) and [[file:/path|caption]] (documents, video, audio, voice, stickers) tags.
        """
        try:
            data = json.loads(body)
            session_name = data.get("session")
            text = data.get("text", "")

            if not session_name or not text:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Missing session or text")
                return

            # Get chat_id from session's file
            chat_id_file = get_chat_id_file(session_name)
            if not chat_id_file.exists():
                print(f"Hook response: no chat_id for session '{session_name}'")
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"No chat_id for session")
                return

            chat_id = chat_id_file.read_text().strip()
            print(f"Hook response: {session_name} -> chat {chat_id} ({len(text)} chars)")

            # Update session ID cache if provided (keeps VPS in sync with remote workers)
            hook_sid = data.get("session_id", "")
            if hook_sid:
                try:
                    sid_file = ensure_session_dir(session_name) / "claude_session_id"
                    old_sid = sid_file.read_text().strip() if sid_file.exists() else ""
                    if old_sid != hook_sid:
                        sid_file.write_text(hook_sid)
                        sid_file.chmod(0o600)
                except Exception:
                    pass

            # Send response and always release pending (even if the send raises).
            deliver_hook_response(session_name, text, int(chat_id), log_prefix="Response")

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
        except Exception as e:
            print(f"Hook response error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())


    def do_GET(self):
        parsed = urlparse(self.path)

        # Handle /workers endpoint for inter-worker discovery
        if parsed.path == "/workers":
            self.handle_workers_endpoint(parsed)
            return

        # Handle /checkin endpoint for worker instruction refresh
        if parsed.path == "/checkin":
            self.handle_checkin_endpoint(parsed)
            return
        if parsed.path == "/health/workers":
            self.handle_health_workers_endpoint()
            return

        # Handle /transcript/<name> endpoint
        if parsed.path.startswith("/transcript/"):
            self.handle_transcript_endpoint(parsed)
            return

        # Handle /team-chat-media/<path> endpoint (photos/files from chat export)
        # Must be checked BEFORE /team-chat to avoid prefix collision
        if parsed.path.startswith("/team-chat-media/"):
            self.handle_team_chat_media(parsed)
            return

        # Handle /team-chat endpoint
        if parsed.path.startswith("/team-chat"):
            self.handle_team_chat_endpoint(parsed)
            return

        # Handle /pr-file-content (lazy fetch for expand context)
        if parsed.path == "/pr-file-content":
            self.handle_pr_file_content(parsed)
            return

        if parsed.path == "/pr-keepalive":
            self.handle_pr_keepalive(parsed)
            return

        # Handle /pr-review/<pr_num> endpoint
        if parsed.path.startswith("/pr-review/"):
            self.handle_pr_review_endpoint(parsed)
            return

        # API index (also serves as health check — returns 200)
        if parsed.path == "/":
            self._send_json(200, {
                "name": "claudecode-telegram bridge",
                "endpoints": API_ENDPOINTS,
                "note": "Messages from manager arrive as prompts. There is no polling endpoint.",
            })
            return

        # Unknown GET endpoint
        self._send_unknown_endpoint("GET", parsed.path)

    def handle_workers_endpoint(self, parsed=None):
        """Return list of active workers with communication details.

        GET /workers                 — bridge-POV send_example (legacy)
        GET /workers?from=<name>     — caller-POV send_example, wraps ssh if cross-machine
        Response: {"workers": [{"name": ..., "machine": ..., "protocol": ..., "address": ..., "send_example": ...}, ...]}
        """
        try:
            caller_from = None
            if parsed is not None:
                caller_from = parse_qs(parsed.query).get("from", [None])[0]
            workers = worker_manager.get_workers(caller_from=caller_from)
            response = {"workers": workers}

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        except Exception as e:
            print(f"Workers endpoint error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_checkin_endpoint(self, parsed):
        """Return worker instructions as plain text.

        GET /checkin                    — generic instructions (uses default backend)
        GET /checkin?name=lee           — personalized instructions for worker 'lee'
        GET /checkin?name=lee&cwd=/dir  — set startup cwd (RAM); restart worker if cwd changed
        """
        try:
            params = parse_qs(parsed.query)
            name = params.get("name", ["worker"])[0]
            raw_cwd = params.get("cwd", [None])[0]
            requested_cwd = ""
            if raw_cwd is not None:
                requested_cwd, cwd_err = validate_cwd(raw_cwd)
                if cwd_err:
                    self.send_response(400)
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    self.wfile.write(f"Invalid cwd: {cwd_err}".encode())
                    return

            # If worker exists, use their actual backend; otherwise default
            _sync_worker_manager()
            registered = worker_manager.get_registered_sessions()
            tmux_name = ""
            if name in registered:
                backend_name = get_worker_backend(name, registered[name])
                # Re-export hook env on checkin (refreshes BRIDGE_URL after restart)
                tmux_name = registered[name].get("tmux", f"{TMUX_PREFIX}{name}")
                if tmux_exists(tmux_name):
                    export_hook_env(tmux_name, backend_name)
            else:
                backend_name = DEFAULT_BACKEND
            backend_obj = get_backend(backend_name)

            if requested_cwd:
                _set_worker_cwd(name, requested_cwd)
                save_claude_session_cwd(name, requested_cwd)
                print(f"[checkin] {name}: requested_cwd={requested_cwd}, tmux={tmux_name}")
                if tmux_name and tmux_exists(tmux_name):
                    pane_cwd = normalize_cwd(worker_manager._get_tmux_pane_cwd(tmux_name))
                    # Compare normalized paths without resolving symlinks; workers use the typed path.
                    same_cwd = pane_cwd and pane_cwd.rstrip("/") == requested_cwd.rstrip("/")
                    print(f"[checkin] {name}: pane_cwd={pane_cwd}, same_cwd={same_cwd}")
                    if not same_cwd:
                        notify_chat_id = get_manager_chat_id(name)

                        # Cooldown: prevent restart loops from repeated checkins
                        last_restart = _recent_restarts.get(name, 0)
                        elapsed = time.time() - last_restart
                        if elapsed < RESTART_COOLDOWN:
                            # Narrow exemption: allow one CWD repair after force restart
                            if _force_restart_pending_cwd.pop(name, False):
                                print(f"[checkin] {name}: cooldown bypassed (post-force CWD repair)")
                            else:
                                print(f"[checkin] {name}: BLOCKED restart (cooldown {elapsed:.0f}s < {RESTART_COOLDOWN}s)")
                                msg = (f"Checkin restart blocked: {name} was restarted {elapsed:.0f}s ago "
                                       f"(cooldown {RESTART_COOLDOWN}s). CWD mismatch: pane={pane_cwd} vs requested={requested_cwd}")
                                if notify_chat_id is not None:
                                    send_telegram_message(notify_chat_id, msg)
                                self.send_response(200)
                                self.send_header("Content-Type", "text/plain")
                                self.end_headers()
                                self.wfile.write(msg.encode())
                                return

                        # Guard: skip if worker is already running Claude
                        if is_claude_running(tmux_name):
                            print(f"[checkin] {name}: BLOCKED restart (Claude already running in tmux)")
                            msg = (f"Checkin restart skipped: {name} has Claude running. "
                                   f"CWD mismatch: pane={pane_cwd} vs requested={requested_cwd}")
                            if notify_chat_id is not None:
                                send_telegram_message(notify_chat_id, msg)
                            self.send_response(200)
                            self.send_header("Content-Type", "text/plain")
                            self.end_headers()
                            self.wfile.write(msg.encode())
                            return

                        # In-flight dedupe: skip if restart already in progress
                        with _restart_lock:
                            inflight_ts = _restart_in_progress.get(name)
                            if inflight_ts and time.time() - inflight_ts < 120:
                                print(f"[checkin] {name}: BLOCKED restart (in-flight since {time.time() - inflight_ts:.0f}s ago)")
                                msg = f"Checkin restart blocked: {name} restart already in progress ({time.time() - inflight_ts:.0f}s)."
                                if notify_chat_id is not None:
                                    send_telegram_message(notify_chat_id, msg)
                                self.send_response(200)
                                self.send_header("Content-Type", "text/plain")
                                self.end_headers()
                                self.wfile.write(msg.encode())
                                return
                            _restart_in_progress[name] = time.time()

                        print(f"[checkin] {name}: triggering restart (cwd mismatch: pane={pane_cwd} vs requested={requested_cwd})")
                        try:
                            notify_chat_id = get_manager_chat_id(name)
                            if notify_chat_id is not None:
                                send_telegram_message(
                                    notify_chat_id,
                                    f"{name} is restarting in a new directory. "
                                    "Messages during restart may be lost.",
                                )

                            ok, err = worker_manager.restart(name, mode="relaunch")

                            _recent_restarts[name] = time.time()
                            print(f"[checkin] {name}: restart result ok={ok}, err={err}")

                            if not ok:
                                if notify_chat_id is not None:
                                    send_telegram_message(
                                        notify_chat_id,
                                        f"{name} could not restart. "
                                        f"Run /restart {name} before sending new messages.",
                                    )
                                self.send_response(500)
                                self.send_header("Content-Type", "text/plain")
                                self.end_headers()
                                self.wfile.write(f"Failed to restart in {requested_cwd}: {err}".encode())
                                return

                            if notify_chat_id is not None:
                                if _wait_for_restart_ready(tmux_name, backend_name):
                                    send_telegram_message(
                                        notify_chat_id,
                                        f"{name} is ready. Safe to send messages now.",
                                    )
                                else:
                                    send_telegram_message(
                                        notify_chat_id,
                                        f"{name} restarted but is not ready yet. "
                                        f"Hold messages for now. If this continues, run /restart {name}.",
                                    )

                            self.send_response(200)
                            self.send_header("Content-Type", "text/plain")
                            self.end_headers()
                            self.wfile.write(f"Restarting in {requested_cwd}...".encode())
                            return
                        finally:
                            with _restart_lock:
                                _restart_in_progress.pop(name, None)

            welcome = worker_manager._build_welcome(name, backend_obj)

            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(welcome.encode())
        except Exception as e:
            print(f"Checkin endpoint error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_health_workers_endpoint(self):
        """Return watchdog worker states as JSON (debug endpoint)."""
        try:
            now = time.time()
            registered = get_registered_sessions()
            with _watchdog_lock:
                state_snapshot = dict(_worker_states)
            workers = {}
            for name in sorted(registered.keys()):
                entry = state_snapshot.get(name)
                if entry:
                    state, reason, since = entry
                    workers[name] = {
                        "state": state,
                        "reason": reason,
                        "since": since,
                        "age_sec": int(now - since) if since else None,
                    }
                else:
                    workers[name] = {"state": "unknown"}

            response = {"workers": workers}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        except Exception as e:
            print(f"Health workers endpoint error: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_pr_file_content(self, parsed):
        """Fetch file content from GitHub for diff context expansion."""
        import time as _time
        import base64 as _b64
        params = dict(parse_qs(parsed.query))
        token = params.get("token", [None])[0]

        now = _time.time()
        if not token or token not in PR_REVIEW_TOKENS or PR_REVIEW_TOKENS[token]["expires_at"] <= now:
            self.send_response(403)
            self.end_headers()
            return

        PR_REVIEW_TOKENS[token]["expires_at"] = now + 300

        owner = params.get("owner", [None])[0]
        repo = params.get("repo", [None])[0]
        path = params.get("path", [None])[0]
        ref = params.get("ref", [None])[0]

        if not all([owner, repo, path, ref]):
            self.send_response(400)
            self.end_headers()
            return

        try:
            r = subprocess.run(
                ["gh", "api", f"repos/{owner}/{repo}/contents/{path}?ref={ref}",
                 "--jq", ".content"],
                capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                self.send_response(404)
                self.end_headers()
                return
            raw = _b64.b64decode(r.stdout.strip()).decode('utf-8', errors='replace')
            lines = raw.splitlines()
            body = json.dumps(lines, ensure_ascii=False).encode('utf-8')
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.end_headers()
        except Exception:
            self.send_response(500)
            self.end_headers()

    def handle_pr_keepalive(self, parsed):
        """Extend PR review token expiry on client activity."""
        import time as _time
        params = dict(parse_qs(parsed.query))
        token = params.get("token", [None])[0]
        now = _time.time()
        if not token or token not in PR_REVIEW_TOKENS or PR_REVIEW_TOKENS[token]["expires_at"] <= now:
            self.send_response(403)
            self.end_headers()
            return
        PR_REVIEW_TOKENS[token]["expires_at"] = now + 300
        self.send_response(204)
        self.end_headers()

    def handle_pr_general_comment(self, body: bytes):
        """Post a general (non-inline) comment on a PR via GitHub API."""
        import time as _time
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Invalid JSON")
            return

        token = data.get("token", "")
        now = _time.time()
        if not token or token not in PR_REVIEW_TOKENS or PR_REVIEW_TOKENS[token].get("expires_at", 0) <= now:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Token expired")
            return
        PR_REVIEW_TOKENS[token]["expires_at"] = now + 300

        owner = data.get("owner", "")
        repo = data.get("repo", "")
        pr_num = data.get("pr_num", 0)
        comment_body = data.get("body", "").strip()
        if not all([owner, repo, pr_num, comment_body]):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing required fields")
            return

        try:
            r = subprocess.run(
                ["gh", "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments",
                 "--method", "POST", "-f", f"body={comment_body}"],
                capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f"GitHub API error: {r.stderr[:200]}".encode())
                return
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.end_headers()
            self.wfile.write(b"GitHub API timeout")
            return

        # Notify Telegram
        try:
            notify_text = f"\U0001f4ac PR #{pr_num} comment:\n{comment_body[:500]}"
            import urllib.request
            req = urllib.request.Request(
                f"{BRIDGE_PUBLIC_URL or f'http://localhost:{PORT}'}/notify",
                data=json.dumps({"text": notify_text}).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass

        # Route to workers via @mentions
        targets, _ = command_router.parse_at_mentions(comment_body)
        if targets:
            worker_msg = (
                f"manager: PR #{pr_num} review comment\n\n"
                f"{comment_body}"
            )
            for t in targets:
                send_to_worker(t, worker_msg)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok": true}')

    def handle_pr_merge(self, body: bytes):
        """Merge a PR via GitHub API."""
        import time as _time
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Invalid JSON")
            return

        token = data.get("token", "")
        now = _time.time()
        if not token or token not in PR_REVIEW_TOKENS or PR_REVIEW_TOKENS[token].get("expires_at", 0) <= now:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Token expired")
            return
        PR_REVIEW_TOKENS[token]["expires_at"] = now + 300

        owner = data.get("owner", "")
        repo = data.get("repo", "")
        pr_num = data.get("pr_num", 0)
        merge_method = data.get("merge_method", "merge")
        if merge_method not in ("merge", "squash", "rebase"):
            merge_method = "merge"

        if not all([owner, repo, pr_num]):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing required fields")
            return

        try:
            r = subprocess.run(
                ["gh", "api", f"repos/{owner}/{repo}/pulls/{pr_num}/merge",
                 "--method", "PUT", "-f", f"merge_method={merge_method}"],
                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                err = r.stderr.strip()[:300] or r.stdout.strip()[:300]
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f"Merge failed: {err}".encode())
                return
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.end_headers()
            self.wfile.write(b"Merge API timeout")
            return

        # Notify Telegram
        try:
            notify_text = f"\u2705 PR #{pr_num} merged ({merge_method}) via review page"
            import urllib.request
            req = urllib.request.Request(
                f"{BRIDGE_PUBLIC_URL or f'http://localhost:{PORT}'}/notify",
                data=json.dumps({"text": notify_text}).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok": true}')

    def handle_pr_review_endpoint(self, parsed):
        """Serve generated PR review HTML.

        Requires a valid token (?token=...) generated by /pr command.
        Token expires after 5 minutes (same as rewind).
        """
        import time as _time
        params = dict(parse_qs(parsed.query))
        token = params.get("token", [None])[0]

        # Cleanup expired tokens
        now = _time.time()
        expired = [k for k, v in PR_REVIEW_TOKENS.items() if v["expires_at"] <= now]
        for k in expired:
            del PR_REVIEW_TOKENS[k]

        if not token or token not in PR_REVIEW_TOKENS:
            self.send_response(403)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<h2>Link expired</h2><p>Send <code>/pr &lt;url&gt;</code> in Telegram to get a fresh 5-minute link.</p>")
            return

        info = PR_REVIEW_TOKENS[token]
        pr_num = info["pr_num"]
        html_path = f"/tmp/pr-review-{pr_num}.html"

        if not os.path.exists(html_path):
            self.send_response(404)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(f"<h2>PR review not found</h2><p>File {html_path} missing. Re-run /pr command.</p>".encode())
            return

        with open(html_path, "rb") as f:
            self._send_html(f.read())

    def handle_pr_comment(self, body: bytes):
        """Post an inline comment on a PR via GitHub API + notify Telegram."""
        import time as _time
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Invalid JSON")
            return

        token = data.get("token", "")
        now = _time.time()
        expired = [k for k, v in PR_REVIEW_TOKENS.items() if v["expires_at"] <= now]
        for k in expired:
            del PR_REVIEW_TOKENS[k]
        if not token or token not in PR_REVIEW_TOKENS:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Token expired - reload the PR review page")
            return

        # Extend token expiry on use
        PR_REVIEW_TOKENS[token]["expires_at"] = now + 300

        owner = data.get("owner", "")
        repo = data.get("repo", "")
        pr_num = data.get("pr_num", 0)
        path = data.get("path", "")
        line = data.get("line", 0)
        side = data.get("side", "RIGHT")
        comment_body = data.get("body", "").strip()
        head_sha = data.get("head_sha", "")

        if not all([owner, repo, pr_num, path, line, comment_body, head_sha]):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing required fields")
            return

        # Post to GitHub via gh api
        try:
            gh_payload = json.dumps({
                "body": comment_body,
                "commit_id": head_sha,
                "path": path,
                "line": line,
                "side": side,
            })
            r = subprocess.run(
                ["gh", "api", f"repos/{owner}/{repo}/pulls/{pr_num}/comments",
                 "--method", "POST", "--input", "-"],
                input=gh_payload, capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                err = r.stderr.strip() or r.stdout.strip()
                print(f"[pr-comment] GitHub API error: {err}")
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f"GitHub API error: {err}".encode())
                return
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.end_headers()
            self.wfile.write(b"GitHub API timeout")
            return

        # Send to Telegram as manager notification
        if admin_chat_id:
            tg_text = (
                f"\U0001f4ac PR #{pr_num} comment\n"
                f"{path}:{line}\n\n"
                f"{comment_body}"
            )
            transport.send_text(admin_chat_id, tg_text)

        # Route to workers via @mentions (same rule as Telegram messages)
        targets, _ = command_router.parse_at_mentions(comment_body)
        if targets:
            worker_msg = (
                f"manager: PR #{pr_num} review comment on {path}:{line}\n\n"
                f"{comment_body}"
            )
            for t in targets:
                send_to_worker(t, worker_msg)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True}).encode())

    def handle_transcript_endpoint(self, parsed):
        """Serve polished HTML transcript for a worker.

        Requires a valid rewind token (?token=...) generated by /rewind command.
        GET /transcript/<name>?token=...      — required auth
        GET /transcript/<name>?token=...&sid=...        — specific session ID
        GET /transcript/<name>?token=...&page=2         — pagination
        GET /transcript/<name>?token=...&per_page=100   — entries per page (default 50)
        GET /transcript/<name>?token=...&q=search+term  — full-text search
        """
        try:
            import time as _time
            qs = parse_qs(parsed.query)
            # Token auth — clean up expired tokens first
            now = _time.time()
            expired = [k for k, v in REWIND_TOKENS.items() if v["expires_at"] <= now]
            for k in expired:
                del REWIND_TOKENS[k]
            token = qs.get("token", [None])[0]
            if not token or token not in REWIND_TOKENS:
                body = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Session Expired</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;
align-items:center;justify-content:center;min-height:100vh;margin:0;
background:#0b0d0b;color:#e5e5e0}
.card{text-align:center;max-width:400px;padding:40px}
h1{font-size:1.5rem;margin-bottom:12px}
p{color:#878b86;line-height:1.6;margin:8px 0}
code{background:#1a1c1a;padding:3px 8px;border-radius:4px;font-size:.9em}
</style></head><body><div class="card">
<h1>Session Expired</h1>
<p>This link has expired or is invalid.</p>
<p>Send <code>/rewind &lt;name&gt;</code> in Telegram to get a fresh 5-minute link.</p>
</div></body></html>""".encode("utf-8")
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            # Refresh token expiry on each valid interaction (sliding window)
            REWIND_TOKENS[token]["expires_at"] = now + REWIND_TIMEOUT

            parts = parsed.path.rstrip("/").split("/")
            # /transcript/<name>
            if len(parts) < 3 or not parts[2]:
                self._send_json(400, {"error": "Usage: /transcript/<worker_name>"})
                return
            name = parts[2]
            qs = parse_qs(parsed.query)
            session_id = qs.get("sid", [None])[0]
            page_raw = qs.get("page", [None])[0]
            try:
                page = max(1, int(page_raw)) if page_raw is not None else None
            except (ValueError, TypeError):
                page = None
            try:
                per_page = max(1, min(500, int(qs.get("per_page", [50])[0])))
            except (ValueError, TypeError):
                per_page = 50
            search_query = qs.get("q", [""])[0].strip()
            search_sort = qs.get("sort", ["relevance"])[0].strip()
            if search_sort not in ("relevance", "time"):
                search_sort = "relevance"
            filter_mode = qs.get("filter", [""])[0].strip()
            html_content = _render_transcript_html(
                    name, session_id=session_id,
                    page=page, per_page=per_page, search_query=search_query,
                    token=token or "", filter_mode=filter_mode, search_sort=search_sort)
            self._send_html(html_content.encode("utf-8"))
        except Exception as e:
            print(f"Transcript endpoint error: {e}")
            import traceback
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_team_chat_endpoint(self, parsed):
        """Serve team Telegram chat viewer.

        GET /team-chat?token=...
        GET /team-chat?token=...&page=2
        GET /team-chat?token=...&q=search+term
        """
        try:
            import time as _time
            qs = parse_qs(parsed.query)
            # Token auth — same as transcript endpoint
            now = _time.time()
            expired = [k for k, v in REWIND_TOKENS.items() if v["expires_at"] <= now]
            for k in expired:
                del REWIND_TOKENS[k]
            token = qs.get("token", [None])[0]
            if not token or token not in REWIND_TOKENS:
                body = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Session Expired</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;
align-items:center;justify-content:center;min-height:100vh;margin:0;
background:#0b0d0b;color:#e5e5e0}
.card{text-align:center;max-width:400px;padding:40px}
h1{font-size:1.5rem;margin-bottom:12px}
p{color:#878b86;line-height:1.6;margin:8px 0}
code{background:#1a1c1a;padding:3px 8px;border-radius:4px;font-size:.9em}
</style></head><body><div class="card">
<h1>Session Expired</h1>
<p>This link has expired or is invalid.</p>
<p>Send <code>/rewind team</code> in Telegram to get a fresh 5-minute link.</p>
</div></body></html>""".encode("utf-8")
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            REWIND_TOKENS[token]["expires_at"] = now + REWIND_TIMEOUT

            page_raw = qs.get("page", [None])[0]
            try:
                page = max(1, int(page_raw)) if page_raw is not None else None
            except (ValueError, TypeError):
                page = None
            try:
                per_page = max(1, min(500, int(qs.get("per_page", [50])[0])))
            except (ValueError, TypeError):
                per_page = 50
            search_query = qs.get("q", [""])[0].strip()

            html_content = _render_team_chat_html(
                page=page, per_page=per_page,
                search_query=search_query, token=token)
            self._send_html(html_content.encode("utf-8"))
        except Exception as e:
            print(f"Team chat endpoint error: {e}")
            import traceback
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def handle_team_chat_media(self, parsed):
        """Serve media files (photos/files) from team chat export.

        GET /team-chat-media/photos/photo_1@28-01-2026_18-09-13.jpg?token=...
        GET /team-chat-media/files/somefile.pdf?token=...

        Requires valid rewind token (same as /team-chat).
        Only serves files under TEAM_CHAT_MEDIA_DIR (no path traversal).
        """
        import time as _time
        qs = parse_qs(parsed.query)

        # Token auth
        now = _time.time()
        token = qs.get("token", [None])[0]
        if not token or token not in REWIND_TOKENS or REWIND_TOKENS[token]["expires_at"] <= now:
            self.send_response(403)
            self.end_headers()
            return

        # Refresh token expiry on access
        REWIND_TOKENS[token]["expires_at"] = now + REWIND_TIMEOUT

        # Extract relative path (after /team-chat-media/)
        from urllib.parse import unquote
        rel_path = unquote(parsed.path[len("/team-chat-media/"):])
        # Security: prevent path traversal
        rel_path = os.path.normpath(rel_path)
        if rel_path.startswith("..") or rel_path.startswith("/"):
            self.send_response(403)
            self.end_headers()
            return

        full_path = os.path.join(TEAM_CHAT_MEDIA_DIR, rel_path)
        # Double-check it's still under the media dir
        if not os.path.abspath(full_path).startswith(os.path.abspath(TEAM_CHAT_MEDIA_DIR)):
            self.send_response(403)
            self.end_headers()
            return

        if not os.path.isfile(full_path):
            self.send_response(404)
            self.end_headers()
            return

        # Determine content type
        ext = os.path.splitext(full_path)[1].lower()
        content_types = {
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
            ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
            ".mp4": "video/mp4", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
            ".pdf": "application/pdf", ".txt": "text/plain",
            ".md": "text/plain", ".json": "application/json",
            ".csv": "text/csv", ".zip": "application/zip",
        }
        ctype = content_types.get(ext, "application/octet-stream")

        try:
            with open(full_path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            self.send_response(500)
            self.end_headers()


# ============================================================
# MAIN
# ============================================================

def graceful_shutdown(signum, frame):
    """Handle shutdown signals gracefully with diagnostic info."""
    from datetime import datetime
    sig_name = signal.Signals(signum).name if signum else "unknown"
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    ppid = os.getppid()

    # Try to get parent process info
    parent_info = f"ppid={ppid}"
    try:
        with open(f"/proc/{ppid}/cmdline", "rb") as f:
            cmdline = f.read().decode().replace("\x00", " ").strip()
            parent_info = f"ppid={ppid} cmd={cmdline[:100]}"
    except Exception:
        pass

    print(f"\n[{timestamp}] Received {sig_name} ({parent_info}), shutting down...")

    if gmail_connector_instance is not None:
        try:
            gmail_connector_instance.stop()
            print("Gmail connector stopped")
        except Exception:
            pass

    if github_connector_instance is not None:
        try:
            github_connector_instance.stop()
            print("GitHub connector stopped")
        except Exception:
            pass

    send_shutdown_message()
    sys.exit(0)


def main():
    global admin_chat_id, gmail_connector_instance, github_connector_instance

    if TRANSPORT_MODE == "telegram" and not BOT_TOKEN:
        print("Error: TELEGRAM_BOT_TOKEN not set")
        return

    # Set up signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, graceful_shutdown)
    signal.signal(signal.SIGINT, graceful_shutdown)

    # Create sessions directory with secure permissions (0o700)
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    SESSIONS_DIR.chmod(0o700)

    # Discover existing sessions
    registered = scan_tmux_sessions()
    registered = get_registered_sessions(registered)
    if registered:
        print(f"Discovered sessions: {list(registered.keys())}")
        for name, info in registered.items():
            # SAFETY: only touch sessions that match OUR prefix to avoid
            # overwriting env vars of workers belonging to other nodes
            tmux_name = info.get("tmux", f"{TMUX_PREFIX}{name}")
            if not tmux_name.startswith(TMUX_PREFIX):
                print(f"  SKIP {name}: tmux '{tmux_name}' doesn't match prefix '{TMUX_PREFIX}'")
                continue
            backend_name = get_worker_backend(name, info)
            # Re-export hook env so workers get the current BRIDGE_URL
            if tmux_exists(tmux_name):
                export_hook_env(tmux_name, backend_name)

    # No focus/active restoration: in topic mode the 話題 decides which session
    # a message reaches — the bridge keeps no "current worker" state.

    # Log team dir and checkin note status
    if os.path.isdir(TEAM_DIR):
        print(f"Team dir: {TEAM_DIR}")
        _startup_note = read_checkin_note()
        if _startup_note:
            print(f"  Checkin note: {_CHECKIN_NOTE_PATH} ({len(_startup_note)} chars)")
        else:
            print(f"  No checkin note at {_CHECKIN_NOTE_PATH}")
    else:
        print(f"Team dir not found: {TEAM_DIR} (checkin note disabled)")

    # Load last chat ID for auto-notification
    last_chat_id = load_last_chat_id()
    if last_chat_id:
        if admin_chat_id is None:
            admin_chat_id = last_chat_id
            print(f"Restored admin from last_chat_id: {admin_chat_id}")

    setup_bot_commands()
    print(f"Multi-Session Bridge on {BRIDGE_BIND}:{PORT}")
    print(f"Hook endpoint: http://localhost:{PORT}/response")
    print(f"Sessions: {list(registered.keys()) or 'none'}")
    if WEBHOOK_SECRET:
        print("Webhook verification: enabled")
    else:
        print("Webhook verification: disabled (set TELEGRAM_WEBHOOK_SECRET to enable)")
    print("Hook endpoint auth: disabled (localhost-only)")
    if admin_chat_id:
        print(f"Admin: {admin_chat_id} (pre-configured)")
    else:
        print("Admin: auto-learn (first user to message becomes admin)")

    # Sandbox status
    if SANDBOX_ENABLED:
        print("Sandbox mode: Workers run in Docker containers")
        print(f"Mounted: {Path.home()} → /workspace")
        if SANDBOX_EXTRA_MOUNTS:
            for host, container, ro in SANDBOX_EXTRA_MOUNTS:
                ro_flag = " (ro)" if ro else ""
                print(f"Mounted: {host} → {container}{ro_flag}")
        print("Workers can only access mounted directories")
    else:
        print("Sandbox mode: disabled (direct execution)")

    # Send startup notification if we have a last known chat ID
    if last_chat_id:
        state["startup_notified"] = True
        result = transport.send_text(
            last_chat_id, "\n".join(_build_startup_lines(list(registered.keys())))
        )
        if result and result.get("ok"):
            print(f"Sent startup notification to chat {last_chat_id}")
        else:
            print(f"Failed to send startup notification: {result}")

    watchdog = threading.Thread(target=watchdog_loop, daemon=True)
    watchdog.start()

    gmail_connector_instance = None
    if GMAIL_ENABLED and GmailConnector is not None:
        def _gmail_on_message(targets, html_text, plain_text=None, attachments=None):
            if plain_text is None:
                plain_text = html_text
            if admin_chat_id:
                try:
                    send_telegram_message(admin_chat_id, html_text, parse_mode="HTML")
                except Exception:
                    send_telegram_message(admin_chat_id, plain_text)
                for att in (attachments or []):
                    fpath = att.get("path", "")
                    fname = att.get("filename", "")
                    if not fpath or not os.path.isfile(fpath):
                        continue
                    ext = os.path.splitext(fname)[1].lower()
                    caption = f"📧 {fname}"
                    if ext in ALLOWED_IMAGE_EXTENSIONS:
                        send_photo(admin_chat_id, fpath, caption)
                    elif ext in VIDEO_EXTENSIONS:
                        send_video(admin_chat_id, fpath, caption)
                    else:
                        send_document(admin_chat_id, fpath, caption)
                    print(f"[gmail] attachment -> Telegram: {fname}")
            if targets:
                for name in targets:
                    send_to_worker(name, plain_text)
                    print(f"[gmail] -> {name}: {plain_text[:80]}...")
            else:
                print(f"[gmail] -> Telegram only (no mentions): {plain_text[:80]}...")

        def _gmail_get_workers():
            return set(get_registered_sessions().keys())

        def _gmail_on_alert(text):
            if admin_chat_id:
                try:
                    send_telegram_message(admin_chat_id, text)
                except Exception as e:
                    print(f"[gmail] Failed to send Telegram alert: {e}")

        gmail_connector_instance = GmailConnector(
            gws_bin=GMAIL_GWS_BIN,
            from_filter=GMAIL_FROM_FILTER,
            poll_interval=GMAIL_POLL_INTERVAL,
            on_message=_gmail_on_message,
            get_registered_workers=_gmail_get_workers,
            on_alert=_gmail_on_alert,
        )
        gmail_connector_instance.start()
        print(f"Gmail connector: polling every {GMAIL_POLL_INTERVAL}s for {GMAIL_FROM_FILTER}")
    elif GMAIL_ENABLED and GmailConnector is None:
        print(f"Gmail connector disabled: {GMAIL_IMPORT_ERROR}")

    github_connector_instance = None
    if GITHUB_ENABLED and GitHubConnector is not None:
        def _github_on_message(targets, html_text, plain_text=None, attachments=None):
            if plain_text is None:
                plain_text = html_text
            if admin_chat_id:
                try:
                    send_telegram_message(admin_chat_id, html_text, parse_mode="HTML")
                except Exception:
                    send_telegram_message(admin_chat_id, plain_text)
            if targets:
                for name in targets:
                    send_to_worker(name, plain_text)
                    print(f"[github] -> {name}: {plain_text[:80]}...")
            else:
                print(f"[github] -> Telegram only (no mentions): {plain_text[:80]}...")

        def _github_get_workers():
            return set(get_registered_sessions().keys())

        def _github_on_alert(text):
            if admin_chat_id:
                try:
                    send_telegram_message(admin_chat_id, text)
                except Exception as e:
                    print(f"[github] Failed to send Telegram alert: {e}")

        github_connector_instance = GitHubConnector(
            repo=GITHUB_REPO,
            from_user=GITHUB_FROM_USER,
            poll_interval=GITHUB_POLL_INTERVAL,
            on_message=_github_on_message,
            get_registered_workers=_github_get_workers,
            on_alert=_github_on_alert,
        )
        github_connector_instance.start()
        print(f"GitHub connector: polling every {GITHUB_POLL_INTERVAL}s for {GITHUB_FROM_USER} on {GITHUB_REPO}")
    elif GITHUB_ENABLED and GitHubConnector is None:
        print(f"GitHub connector disabled: {GITHUB_IMPORT_ERROR}")

    try:
        ReuseAddrServer((BRIDGE_BIND, PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        graceful_shutdown(signal.SIGINT, None)


if __name__ == "__main__":
    main()
