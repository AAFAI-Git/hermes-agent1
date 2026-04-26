#!/usr/bin/env bash
# Railway: gateway + web dashboard in ONE container, shared HERMES_HOME (/opt/data).
# Public $PORT (Railway edge) -> nginx -> /health + /v1* = gateway, everything else = dashboard.
set -euo pipefail

RAILWAY_EDGE_PORT="${PORT:?PORT must be set by Railway}"
GW_PORT="${HERMES_GATEWAY_INTERNAL_PORT:-18080}"
DASH_PORT="${HERMES_DASHBOARD_INTERNAL_PORT:-9119}"

NGINX_CONF="/tmp/hermes-railway-nginx.conf"
GWPID=""
DASHPID=""
NGPID=""

_term() {
  echo "railway-fullstack: shutting down..." >&2
  [ -n "${NGPID}" ] && kill "${NGPID}" 2>/dev/null || true
  [ -n "${DASHPID}" ] && kill "${DASHPID}" 2>/dev/null || true
  [ -n "${GWPID}" ] && kill "${GWPID}" 2>/dev/null || true
  if [ -f /tmp/hermes-nginx.pid ]; then
    kill "$(cat /tmp/hermes-nginx.pid)" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  exit 0
}
trap _term SIGINT SIGTERM

echo "railway-fullstack: edge :${RAILWAY_EDGE_PORT} -> gateway :${GW_PORT}, dashboard :${DASH_PORT}" >&2

# The first railway-entrypoint pass merged API_SERVER_PORT=${RAILWAY_EDGE_PORT} into .env.
# If the gateway then reads 8080 while nginx also binds 8080, nothing listens and healthchecks
# fail. Strip the auto stanza so the nested gateway merge writes the internal port only.
_data="${HERMES_HOME:-/opt/data}"
if [ -f "${_data}/.env" ]; then
  sed -i '/^# railway-auto-begin/,/^# railway-auto-end/d' "${_data}/.env" 2>/dev/null || true
fi

# --- Gateway (internal API + /health) ---
PORT="${GW_PORT}" API_SERVER_PORT="${GW_PORT}" \
  /usr/bin/tini -g -- /opt/hermes/docker/railway-entrypoint.sh \
  hermes gateway run --replace -v &
GWPID=$!

echo "railway-fullstack: waiting for gateway health..." >&2
_ok=0
for _i in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:${GW_PORT}/health" >/dev/null; then
    _ok=1
    break
  fi
  sleep 1
done
if [ "${_ok}" != 1 ]; then
  echo "railway-fullstack: gateway did not become healthy in time" >&2
  exit 1
fi

# --- Dashboard (bind 0.0.0.0: nginx forwards Host: <public>; loopback-only rejects that) ---
# Port ${DASH_PORT} is not published by Railway; only nginx on $PORT is on the edge.
export GATEWAY_HEALTH_URL="http://127.0.0.1:${GW_PORT}"
/usr/bin/tini -g -- /opt/hermes/docker/entrypoint.sh \
  hermes dashboard --host 0.0.0.0 --port "${DASH_PORT}" --no-open --insecure &
DASHPID=$!

echo "railway-fullstack: waiting for dashboard /api/status..." >&2
_ok=0
for _i in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${DASH_PORT}/api/status" >/dev/null; then
    _ok=1
    break
  fi
  sleep 1
done
if [ "${_ok}" != 1 ]; then
  echo "railway-fullstack: dashboard did not start in time" >&2
  exit 1
fi

# --- nginx: single public listener ---
cat >"${NGINX_CONF}" <<EOF
pid /tmp/hermes-nginx.pid;
events { worker_connections 2048; }
http {
  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }
  access_log /dev/stdout;
  error_log /dev/stderr warn;
  server {
    listen ${RAILWAY_EDGE_PORT};
    client_max_body_size 80m;
    location /health {
      proxy_pass http://127.0.0.1:${GW_PORT};
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
    }
    location /v1/ {
      proxy_pass http://127.0.0.1:${GW_PORT};
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header Authorization \$http_authorization;
    }
    location /v1 {
      proxy_pass http://127.0.0.1:${GW_PORT};
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header Authorization \$http_authorization;
    }
    location / {
      proxy_pass http://127.0.0.1:${DASH_PORT};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
    }
  }
}
EOF

echo "railway-fullstack: nginx config test..." >&2
nginx -t -c "${NGINX_CONF}" >&2

echo "railway-fullstack: starting nginx on :${RAILWAY_EDGE_PORT}" >&2
nginx -g "daemon off;" -c "${NGINX_CONF}" &
NGPID=$!
wait "${NGPID}"
