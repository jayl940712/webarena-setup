#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/00_vars.sh"; then
  echo "Failed to load config: $SCRIPT_DIR/00_vars.sh" >&2
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to close..." </dev/tty
  fi
  exit 0
fi

pause_before_exit() {
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to close..." </dev/tty
  fi
}

stop_after_error() {
  echo "Script stopped."
  pause_before_exit
  exit 0
}

RESET_PORT="${RESET_PORT:-7777}"
RESET_SCHEME="${RESET_SCHEME:-https}"

RESET_HOST="${RESET_HOST:-$PUBLIC_HOSTNAME}"
RESET_TOKEN_FILE="${RESET_TOKEN_FILE:-/etc/webarena/reset_token}"
RESET_TLS_CA_CERT="${RESET_TLS_CA_CERT:-/etc/webarena/reset.crt}"

if [[ ! -s "$RESET_TOKEN_FILE" ]]; then
  echo "Missing reset bearer token file: $RESET_TOKEN_FILE" >&2
  stop_after_error
fi

if ! RESET_TOKEN="$(<"$RESET_TOKEN_FILE")"; then
  echo "Failed to read reset bearer token file: $RESET_TOKEN_FILE" >&2
  stop_after_error
fi

HOST="${RESET_SCHEME}://${RESET_HOST}:${RESET_PORT}"
RESET_ENDPOINT="$HOST/reset"
STATUS_ENDPOINT="$HOST/status"
CURL_ARGS=(-sS -H "Authorization: Bearer ${RESET_TOKEN}")

if [[ -n "$RESET_TLS_CA_CERT" ]]; then
  if [[ ! -r "$RESET_TLS_CA_CERT" ]]; then
    echo "Missing reset TLS CA certificate: $RESET_TLS_CA_CERT" >&2
    stop_after_error
  fi
  CURL_ARGS+=(--cacert "$RESET_TLS_CA_CERT")
fi

# Trigger reset
echo "Triggering reset..."
if ! reset_response=$(curl "${CURL_ARGS[@]}" -o /dev/null -w "%{http_code}" "$RESET_ENDPOINT"); then
  echo "Reset trigger request ended with a curl error."
  echo "The server may still have received it; checking status..."
  reset_response=""
fi

if [[ -z "$reset_response" ]]; then
  sleep 10
elif [[ "$reset_response" != "200" && "$reset_response" != "202" ]]; then
  echo "Failed to trigger reset (HTTP $reset_response)"
  stop_after_error
else
  echo "Reset triggered. Waiting for completion..."
  sleep 10
fi

# Poll status
while true; do
  if ! response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "$STATUS_ENDPOINT"); then
    echo "Failed to check reset status."
    stop_after_error
  fi

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
    stop_after_error
  else
    echo "Unexpected response (HTTP $code): $body"
    stop_after_error
  fi

  sleep 30
done

echo "Script finished."
pause_before_exit
