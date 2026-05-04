#!/usr/bin/env bash
set -u

HOST="${1:-localhost}"
FAILED=0

echo "Testing WebArena endpoints on: $HOST"
echo

echo -n "Tile server: "
HTTP_CODE=$(curl -s -o /tmp/webarena_tile.png -w "%{http_code}" \
  "http://${HOST}:8080/tile/5/5/12.png")

if [ "$HTTP_CODE" = "200" ] && file /tmp/webarena_tile.png | grep -q "PNG image data"; then
  echo "PASS"
else
  echo "FAIL (HTTP $HTTP_CODE)"
  FAILED=$((FAILED+1))
fi

echo -n "Nominatim: "
HTTP_CODE=$(curl -s -o /tmp/webarena_nominatim.json -w "%{http_code}" \
  "http://${HOST}:8085/search?q=Houston&format=json&limit=1")

if [ "$HTTP_CODE" = "200" ] && grep -q "Houston" /tmp/webarena_nominatim.json; then
  echo "PASS"
else
  echo "FAIL (HTTP $HTTP_CODE)"
  FAILED=$((FAILED+1))
fi

echo -n "OSRM car: "
HTTP_CODE=$(curl -s -o /tmp/webarena_osrm_car.json -w "%{http_code}" \
  "http://${HOST}:5000/route/v1/car/-95.3698,29.7604;-95.36,29.75?overview=false")

if [ "$HTTP_CODE" = "200" ] && grep -q '"code":"Ok"' /tmp/webarena_osrm_car.json; then
  echo "PASS"
else
  echo "FAIL (HTTP $HTTP_CODE)"
  FAILED=$((FAILED+1))
fi

echo -n "OSRM bike: "
HTTP_CODE=$(curl -s -o /tmp/webarena_osrm_bike.json -w "%{http_code}" \
  "http://${HOST}:5001/route/v1/bike/-95.3698,29.7604;-95.36,29.75?overview=false")

if [ "$HTTP_CODE" = "200" ] && grep -q '"code":"Ok"' /tmp/webarena_osrm_bike.json; then
  echo "PASS"
else
  echo "FAIL (HTTP $HTTP_CODE)"
  FAILED=$((FAILED+1))
fi

echo -n "OSRM foot: "
HTTP_CODE=$(curl -s -o /tmp/webarena_osrm_foot.json -w "%{http_code}" \
  "http://${HOST}:5002/route/v1/foot/-95.3698,29.7604;-95.36,29.75?overview=false")

if [ "$HTTP_CODE" = "200" ] && grep -q '"code":"Ok"' /tmp/webarena_osrm_foot.json; then
  echo "PASS"
else
  echo "FAIL (HTTP $HTTP_CODE)"
  FAILED=$((FAILED+1))
fi

echo
echo "Docker containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All tests PASSED"
else
  echo "$FAILED test(s) FAILED"
fi