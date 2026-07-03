#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00_vars.sh"

RESET_PORT="${RESET_PORT:-7777}"
RESET_SCHEME="${RESET_SCHEME:-https}"
RESET_HOST="${RESET_HOST:-$PUBLIC_HOSTNAME}"
RESET_TOKEN_FILE="${RESET_TOKEN_FILE:-/etc/webarena/reset_token}"
RESET_TLS_CA_CERT="${RESET_TLS_CA_CERT:-/etc/webarena/reset.crt}"

if [[ ! -s "$RESET_TOKEN_FILE" ]]; then
  echo "Missing reset bearer token file: $RESET_TOKEN_FILE" >&2
  exit 1
fi

RESET_TOKEN="$(<"$RESET_TOKEN_FILE")"
HOST="${RESET_SCHEME}://${RESET_HOST}:${RESET_PORT}"
RESET_ENDPOINT="$HOST/reset"
STATUS_ENDPOINT="$HOST/status"
CURL_ARGS=(-sS -H "Authorization: Bearer ${RESET_TOKEN}")

if [[ -n "$RESET_TLS_CA_CERT" ]]; then
  CURL_ARGS+=(--cacert "$RESET_TLS_CA_CERT")
fi

# Trigger reset
echo "Triggering reset..."
reset_response=$(curl "${CURL_ARGS[@]}" -o /dev/null -w "%{http_code}" "$RESET_ENDPOINT")

if [[ "$reset_response" != "200" && "$reset_response" != "202" ]]; then
  echo "Failed to trigger reset (HTTP $reset_response)"
  # Don't exit; keep polling in case a reset was already in progress.
else
  echo "Reset triggered. Waiting for completion..."
  sleep 10
fi

# Poll status
while true; do
  response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "$STATUS_ENDPOINT")
  body="${response%$'\n'*}"
  code="${response##*$'\n'}"

  if [[ "$code" == "200" && "$body" == *"Ready for duty!"* ]]; then
    echo "Reset completed successfully!"
    break
  elif [[ "$code" == "200" && "$body" == *"Reset ongoing"* ]]; then
    echo "Still resetting..."
  elif [[ "$code" == "500" ]]; then
    echo "Reset failed:"
    echo "$body"
    # Don't exit; keep monitoring so operators can see recovery.
  else
    echo "Unexpected response (HTTP $code): $body"
  fi

  sleep 30
done

echo "Script finished (but shell stays open)."