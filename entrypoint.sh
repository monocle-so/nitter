#!/bin/sh
set -eu

if [ -n "${NITTER_SESSIONS_JSON:-}" ]; then
	printf '%s\n' "$NITTER_SESSIONS_JSON" > "$NITTER_SESSIONS_FILE"
fi

exec ./nitter
