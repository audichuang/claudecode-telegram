"""Transcript / team-chat HTML viewer — extracted from bridge.py (v1.1.0).

Reads bridge config lazily (`import bridge` inside functions) so test.sh
monkeypatches on the bridge module keep working.
"""

import json
import os
import re
import subprocess
from pathlib import Path


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
    import bridge
    cmd = ["python3", bridge.TEAM_CHAT_INDEX_SCRIPT,
           "--jsonl", bridge.TEAM_CHAT_JSONL,
           "--db", bridge.TEAM_CHAT_DB,
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
    import bridge
    db_path = f"/tmp/transcript-cache/{sid}.db"
    script_path = bridge.TRANSCRIPT_INDEX_SCRIPT
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
    import bridge
    cwd = bridge.get_claude_session_cwd(name) or os.path.expanduser("~")
    sid = session_id or bridge.get_claude_session_id(name, authoritative=True)
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
    import bridge
    stripped = text.strip()
    # Check for "name: " prefix (1-10 chars before colon)
    colon_pos = stripped.find(":")
    if 0 < colon_pos <= 10:
        prefix = stripped[:colon_pos].lower().strip()
        rest = stripped[colon_pos + 1:].strip()
        if prefix == "manager":
            return "manager", bridge._MANAGER_AV, rest or stripped
        if prefix in bridge._TEAM_MEMBERS:
            return prefix, bridge._generate_member_avatar(prefix), rest or stripped
    # Default: manager avatar, full text
    return "manager", bridge._MANAGER_AV, stripped


def _transcript_entry_to_html(entry: dict, esc, tool_results: dict = None) -> str:
    """Convert a single transcript entry to HTML block(s).

    Matches ampcode.com visual style: tool results merged into tool_use blocks,
    Edit diffs with +/- coloring, collapsible thinking.
    tool_results: map of tool_use_id → {content: str, is_error: bool}
    """
    import bridge
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
            _author, _avatar, _display = bridge._detect_message_author(raw)
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
    import bridge
    import html as html_mod
    esc = html_mod.escape

    if search_query:
        query_result = bridge._run_team_chat_query("search", search=search_query,
                                            page=page or 1, per_page=per_page)
    else:
        query_result = bridge._run_team_chat_query("entries", page=page, per_page=per_page)

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
            r = bridge._run_team_chat_query("msg-by-id", msg_id=rid)
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
            av = bridge._MANAGER_AV
        elif sender in bridge._TEAM_MEMBERS:
            av = bridge._generate_member_avatar(sender)
        else:
            av = bridge._generate_member_avatar(sender or "system")

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
                _file_full = os.path.join(bridge.TEAM_CHAT_MEDIA_DIR, file_path_val)
                _file_content = ""
                try:
                    with open(_file_full, "r", encoding="utf-8", errors="replace") as _ff:
                        _file_content = _ff.read(64_000)  # cap at 64KB
                except Exception:
                    pass
                if ext == ".md":
                    # Render markdown to HTML
                    _rendered = bridge._render_md_to_html(_file_content)
                    _body = f'<div class="file-body file-body-md">{_rendered}</div>'
                elif ext in (".py", ".sh", ".js", ".ts", ".go", ".rs"):
                    _body = f'<pre class="file-body file-body-code"><code>{esc(_file_content)}</code></pre>'
                elif ext in (".json", ".yaml", ".yml", ".toml"):
                    _body = f'<pre class="file-body file-body-code"><code>{esc(_file_content)}</code></pre>'
                elif ext == ".csv":
                    _body = bridge._render_csv_to_html(_file_content)
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
    import bridge
    import html as html_mod
    esc = html_mod.escape

    transcript_path, sid, cwd = bridge._resolve_transcript_path(name, session_id)
    if not sid:
        return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>No session found for {esc(name)}</h1></body></html>"
    if not transcript_path:
        return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>Transcript not found</h1><p>Worker: {esc(name)}</p><p>Session: {esc(sid)}</p></body></html>"
    jsonl_path = str(transcript_path)

    # Query transcript-index.py — combined entries+stats in single call.
    if search_query:
        query_result = bridge._run_transcript_query(
            jsonl_path, sid, "search+stats",
            search=search_query, page=page or 1, per_page=per_page, sort=search_sort)
    else:
        query_result = bridge._run_transcript_query(
            jsonl_path, sid, "entries+stats",
            page=page, per_page=per_page, filter_mode=filter_mode)
    stats_result = query_result.pop("stats", None) if query_result else None

    # Fallback to old parsing if script fails
    if not query_result:
        if not transcript_path or not Path(str(transcript_path)).exists():
            return f"<html><body style='background:#0b0d0b;color:#f6fff5;font-family:system-ui;padding:40px'><h1>Transcript not available</h1><p>Worker: {esc(name)}</p><p>Session: {esc(sid)}</p></body></html>"
        all_entries = bridge._parse_transcript_entries(transcript_path)
        total = len(all_entries)
        for _i, _e in enumerate(all_entries):
            _e["_idx"] = _i
        total_pages = max(1, (total + per_page - 1) // per_page)
        if page is None:
            page = total_pages
        page = max(1, min(page, total_pages))
        start = (page - 1) * per_page
        page_entries = all_entries[start:start + per_page]
        stats = bridge._transcript_stats(all_entries)
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
        h = bridge._transcript_entry_to_html(entry, esc, tool_results=_tool_results)
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
{"<div class='sb-row'><span class='sb-label'>Model</span><span class='sb-val'>" + esc(bridge._format_model_name(stats["model"])) + "</span></div>" if stats["model"] else ""}
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


