#!/usr/bin/env bash
# One-command test runner: loads credentials from ~/.config/claudecode-telegram/
# test.env (set -a — the file has no `export` lines), picks the mode, optional
# filter. Saves re-typing the token dance on every TDD iteration.
#
# Usage: run-tests.sh [fast|default|full] [filter-substring]
#   run-tests.sh                       # FAST suite
#   run-tests.sh fast test_topic_cd    # one focused test, TDD inner loop
#   run-tests.sh default               # pre-commit gate
#   run-tests.sh full                  # pre-push gate (needs TEST_CHAT_ID)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ENV_FILE="$HOME/.config/claudecode-telegram/test.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (needs TELEGRAM_BOT_TOKEN; TEST_CHAT_ID for default/full)" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

MODE="${1:-fast}"
FILTER="${2:-}"
export TEST_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
[[ -n "${TEST_CHAT_ID:-}" ]] && export TEST_CHAT_ID
[[ -n "$FILTER" ]] && export TEST_FILTER="$FILTER"

cd "$REPO"
case "$MODE" in
  fast)    FAST=1 ./test.sh ;;
  default) ./test.sh ;;
  full)    FULL=1 ./test.sh ;;
  *) echo "usage: run-tests.sh [fast|default|full] [filter-substring]" >&2; exit 2 ;;
esac
