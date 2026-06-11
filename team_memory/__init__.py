"""team_memory — layered team-chat memory used by the /memory commands.

Exposes the API that bridge.py's /memory subcommands consume:
  - memory_stack.MemoryStack: status / wake_up / recall over a layered index
  - search.search_memory: semantic search over the index

This is a graceful-degradation baseline. With no index built yet (the common
case), it returns empty/zero results instead of raising, so /memory stays
usable. Wiring a real backing index (see team-chat-index.py / TEAM_CHAT_DB)
only requires filling in the read paths; the public surface stays stable.
"""
