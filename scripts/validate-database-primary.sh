#!/bin/bash
# Split-brain prevention: Verify a database host is actually PRIMARY
# before allowing AAP services to start against it.
# Adapted from EDB_Testing's validate_database_primary() pattern.
#
# Usage: ./validate-database-primary.sh <hostname>
# Exit 0 = host is PRIMARY (safe to start AAP)
# Exit 1 = host is STANDBY or unreachable (do NOT start AAP)
set -euo pipefail

HOST="${1:?Usage: $0 <hostname>}"

echo "Validating ${HOST} is a PRIMARY database..."

IS_RECOVERY=$(ssh -o StrictHostKeyChecking=no "rhel@${HOST}" \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')

if [ "${IS_RECOVERY}" = "f" ]; then
  echo "OK: ${HOST} is PRIMARY (pg_is_in_recovery = false)"
  echo "It is safe to start AAP services against this database."
  exit 0
elif [ "${IS_RECOVERY}" = "t" ]; then
  echo "BLOCKED: ${HOST} is a STANDBY (pg_is_in_recovery = true)"
  echo ""
  echo "Starting AAP against a read-only standby database will cause failures."
  echo "This check prevents split-brain scenarios where two AAP instances"
  echo "could write to different databases simultaneously."
  echo ""
  echo "To proceed, promote this database first:"
  echo "  sudo -u enterprisedb /usr/edb/as16/bin/pg_ctl promote -D /var/lib/edb/as16/data"
  exit 1
else
  echo "ERROR: Could not determine database role on ${HOST}"
  echo "The database may be unreachable or not running."
  exit 1
fi
