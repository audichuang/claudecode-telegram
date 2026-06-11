"""Team-memory semantic search — graceful-degradation baseline.

Returns an empty result set until a memory index is built, matching the
``{"answer": str, "results": list}`` contract bridge.py's /memory search expects.
"""


def search_memory(query):
    """Search team memory for ``query``.

    Returns ``{"answer": str, "results": list}``. Empty when no index exists.
    """
    return {"answer": "", "results": []}
