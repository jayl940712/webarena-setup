#!/usr/bin/env bash

HOST="http://10.186.197.203:7777"
RESET_ENDPOINT="$HOST/reset"
STATUS_ENDPOINT="$HOST/status"

# Trigger reset
echo "Triggering reset..."
reset_response=$(curl -s -o /dev/null -w "%{http_code}" "$RESET_ENDPOINT")

if [[ "$reset_response" != "200" && "$reset_response" != "418" ]]; then
  echo "Failed to trigger reset (HTTP $reset_response)"
  # Don't exit — just keep going or retry later
else
  echo "Reset triggered. Waiting for completion..."
  sleep 10
fi

# Poll status
while true; do
  response=$(curl -s -w "\n%{http_code}" "$STATUS_ENDPOINT")
  body=$(echo "$response" | head -n1)
  code=$(echo "$response" | tail -n1)

  if [[ "$code" == "200" && "$body" == *"Ready for duty!"* ]]; then
    echo "Reset completed successfully!"
    break   # stop loop, but don't exit script forcefully
  elif [[ "$code" == "200" && "$body" == *"Reset ongoing"* ]]; then
    echo "Still resetting..."
  elif [[ "$code" == "500" ]]; then
    echo "Reset failed:"
    echo "$body"
    # Don't exit — just keep monitoring or retry
  else
    echo "Unexpected response (HTTP $code): $body"
  fi

  sleep 30
done

echo "Script finished (but shell stays open)."