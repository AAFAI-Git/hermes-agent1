#!/bin/bash
# Railway bootstrap for Hermes Agent.
#
# Railway injects PORT for the public HTTP listener. Hermes binds the
# OpenAI-compatible API server (and /health) there. Upstream refuses to bind
# 0.0.0.0 without API_SERVER_KEY — we enforce the same before delegating to
# the stock docker/entrypoint.sh (non-root drop, HERMES_HOME, etc.).
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/opt/data}"

# --- Public HTTP surface (Railway edge proxy -> container) ---
if [ -n "${PORT:-}" ]; then
  export API_SERVER_PORT="${API_SERVER_PORT:-$PORT}"
fi
export API_SERVER_HOST="${API_SERVER_HOST:-0.0.0.0}"
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-1}"

_bind_is_public() {
  local h="${API_SERVER_HOST:-127.0.0.1}"
  case "$h" in
    0.0.0.0|::|\:\:0) return 0 ;;
    *) return 1 ;;
  esac
}

if _bind_is_public && [ -z "${API_SERVER_KEY:-}" ]; then
  echo "============================================================" >&2
  echo "Hermes (Railway): missing API_SERVER_KEY." >&2
  echo "Add a secret in Railway → Variables, for example:" >&2
  echo "  openssl rand -hex 32" >&2
  echo "Hermes will not bind 0.0.0.0 without a real key (security)." >&2
  echo "============================================================" >&2
  exit 1
fi

# Predictable ownership for mounted volumes (optional; entrypoint still chowns).
export HERMES_UID="${HERMES_UID:-1000}"
export HERMES_GID="${HERMES_GID:-1000}"

exec /opt/hermes/docker/entrypoint.sh "$@"
