#!/bin/bash

# stop if any error occur
set -e

source 00_vars.sh

RESET_PORT="${RESET_PORT:-7777}"
RESET_BIND_HOST="${RESET_BIND_HOST:-0.0.0.0}"
RESET_TOKEN_FILE="${RESET_TOKEN_FILE:-/etc/webarena/reset_token}"
RESET_TLS_CERT="${RESET_TLS_CERT:-/etc/webarena/reset.crt}"
RESET_TLS_KEY="${RESET_TLS_KEY:-/etc/webarena/reset.key}"

if [[ ! -s "$RESET_TOKEN_FILE" ]]; then
  echo "Missing reset bearer token file: $RESET_TOKEN_FILE" >&2
  exit 1
fi

if [[ ! -r "$RESET_TLS_CERT" || ! -r "$RESET_TLS_KEY" ]]; then
  echo "Missing reset TLS certificate or key: $RESET_TLS_CERT / $RESET_TLS_KEY" >&2
  exit 1
fi

# install flask in a venv
apt install python3-venv -y
python3 -m venv venv_reset
source venv_reset/bin/activate

cd reset_server/
python server.py \
  --host "$RESET_BIND_HOST" \
  --port "$RESET_PORT" \
  --token-file "$RESET_TOKEN_FILE" \
  --certfile "$RESET_TLS_CERT" \
  --keyfile "$RESET_TLS_KEY" \
  2>&1 | tee -a server.log
