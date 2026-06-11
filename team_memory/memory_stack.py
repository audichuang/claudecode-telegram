"""Layered team-chat memory stack (L0 identity / L1 essential / L2 on-demand).

Graceful-degradation baseline: exposes the surface bridge.py's /memory commands
consume and returns empty/zero results when no memory index has been built yet,
rather than raising. To back it with a real index, fill in the read paths below
(see team-chat-index.py / the TEAM_CHAT_DB env var); the public API stays the same.
"""
import os


class MemoryStack:
    """Layered view over the team-chat memory index.

    Degrades gracefully: with no index present, ``status()`` reports zeros and
    ``wake_up()`` / ``recall()`` return clearly-empty but well-formed text, so the
    /memory commands stay usable before any data is ingested.
    """

    def __init__(self, db_path=None):
        # Backing index location; absent until an index is built.
        self.db_path = db_path or os.environ.get("TEAM_CHAT_DB")
        self.available = bool(self.db_path) and os.path.exists(self.db_path)

    def status(self):
        """Return memory-stack health counts. Zeros when no index exists."""
        return {
            "total_chunks": 0,
            "total_messages": 0,
            "total_summaries": 0,
            "wing_distribution": {},
            "L0_identity": {"tokens": 0, "agents": 0, "projects": 0, "wings": 0},
        }

    def wake_up(self, wing=None):
        """Return L0 (identity) + L1 (essential story) wake-up context as text.

        Empty-but-structured when no index has been built.
        """
        scope = f" — wing: {wing}" if wing else ""
        return (
            f"## L0 — TEAM IDENTITY{scope}\n"
            "(no team-memory index built yet)\n\n"
            "## L1 — ESSENTIAL STORY (last 7 days)\n"
            "(no recent activity indexed)"
        )

    def recall(self, wing=None, room=None):
        """Return L2 on-demand recall text for a wing/room. Empty when no index."""
        target = "/".join(p for p in (wing, room) if p) or "all"
        return f"L2 recall for {target}: no memory index built yet."
