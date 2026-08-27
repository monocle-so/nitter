#!/usr/bin/env bash
# Manually log into one or more accounts and append their sessions to sessions.jsonl.
#
# Usage:
#   ./tools/add-accounts.sh label1 [label2 ...]
#
# Each label is just a local name to tag the session with (handle, email,
# nickname, whatever) — login itself uses whatever x.com asks for.
#
# Opens a browser window per account at x.com/i/flow/login and waits for you
# to complete login (password, TOTP, captcha, passkey, whatever it asks for).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV="$REPO_ROOT/.venv-sessions"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 label1 [label2 ...]" >&2
  exit 1
fi

if [ ! -x "$VENV/bin/python3" ]; then
  echo "Error: venv not found at $VENV" >&2
  exit 1
fi

ACCOUNTS_JSON=$(mktemp -t add-accounts.XXXXXX.json)
trap 'rm -f "$ACCOUNTS_JSON"' EXIT

python3 - "$ACCOUNTS_JSON" "$@" <<'EOF'
import json, sys
out_path, labels = sys.argv[1], sys.argv[2:]
with open(out_path, "w") as f:
    json.dump([{"label": label} for label in labels], f)
EOF

exec "$VENV/bin/python3" "$SCRIPT_DIR/create_sessions_manual_browser.py" \
  "$ACCOUNTS_JSON" --append "$REPO_ROOT/sessions.jsonl"
