#!/usr/bin/env bash
# Release gate: the version string lives in THREE places and they must agree
# (/settings reports bridge.py's copy — a 0.29.1 stowaway once shipped in 1.0.0).
# Exits non-zero on mismatch. Run before any version-bump commit.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

SH=$(sed -nE 's/^VERSION="([^"]+)".*/\1/p' "$REPO/claudecode-telegram.sh" | head -1)
PY=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$REPO/pyproject.toml" | head -1)
BR=$(sed -nE 's/^VERSION = "([^"]+)".*/\1/p' "$REPO/bridge.py" | head -1)

echo "claudecode-telegram.sh : $SH"
echo "pyproject.toml         : $PY"
echo "bridge.py              : $BR"

if [[ "$SH" == "$PY" && "$PY" == "$BR" ]]; then
  echo "✓ versions in sync ($SH)"
else
  echo "✗ VERSION MISMATCH — sync all three before committing" >&2
  exit 1
fi
