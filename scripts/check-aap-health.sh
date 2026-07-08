#!/bin/bash
# Check AAP health on both DC1 and DC2.
set -euo pipefail

echo "=== AAP Health Check ==="
echo ""

check_aap() {
  local name="$1"
  local host="$2"
  local http_code

  http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://${host}/api/v2/ping/" 2>/dev/null || echo "000")

  if [ "${http_code}" = "200" ]; then
    echo "  ${name} (${host}): ACTIVE (HTTP 200)"
  elif [ "${http_code}" = "000" ]; then
    echo "  ${name} (${host}): UNREACHABLE"
  else
    echo "  ${name} (${host}): ERROR (HTTP ${http_code})"
  fi
}

echo "--- AAP Controller Status ---"
check_aap "DC1 AAP" "control"
check_aap "DC2 AAP" "aap-dc2"

echo ""
echo "--- EDB Postgres Status ---"
for host in pg-dc1 pg-dc2; do
  RECOVERY=$(ssh -o StrictHostKeyChecking=no "rhel@${host}" \
    "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
  if [ "${RECOVERY}" = "f" ]; then
    echo "  ${host}: PRIMARY"
  elif [ "${RECOVERY}" = "t" ]; then
    echo "  ${host}: STANDBY"
  else
    echo "  ${host}: UNREACHABLE"
  fi
done

echo ""
echo "=== Health check complete ==="
