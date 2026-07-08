#!/bin/bash
# Check EDB Postgres streaming replication status.
# Run from any host with SSH access to pg-dc1 and pg-dc2.
set -euo pipefail

echo "=== EDB Postgres Replication Status ==="
echo ""

echo "--- pg-dc1 (expected: PRIMARY) ---"
DC1_RECOVERY=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc1 \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
echo "  Role: $([ "${DC1_RECOVERY}" = "f" ] && echo 'PRIMARY' || echo 'STANDBY')"

echo ""
echo "--- pg-dc2 (expected: STANDBY) ---"
DC2_RECOVERY=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
echo "  Role: $([ "${DC2_RECOVERY}" = "t" ] && echo 'STANDBY' || echo 'PRIMARY')"

echo ""
echo "--- Replication Details (from primary) ---"
if [ "${DC1_RECOVERY}" = "f" ]; then
  ssh -o StrictHostKeyChecking=no rhel@pg-dc1 \
    "sudo -u enterprisedb psql -c \"
      SELECT application_name,
             state,
             sync_state,
             pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
             pg_wal_lsn_diff(sent_lsn, replay_lsn) / 1024 / 1024 AS lag_mb
      FROM pg_stat_replication;\"" 2>/dev/null
elif [ "${DC2_RECOVERY}" = "f" ]; then
  echo "  (pg-dc2 is the current primary -- post-failover state)"
  ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
    "sudo -u enterprisedb psql -c \"
      SELECT application_name,
             state,
             sync_state,
             pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
      FROM pg_stat_replication;\"" 2>/dev/null
else
  echo "  WARNING: Could not determine primary"
fi

echo ""
echo "--- AAP Databases ---"
PRIMARY_HOST=$([ "${DC1_RECOVERY}" = "f" ] && echo "pg-dc1" || echo "pg-dc2")
ssh -o StrictHostKeyChecking=no "rhel@${PRIMARY_HOST}" \
  "sudo -u enterprisedb psql -c \"
    SELECT datname,
           pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database
    WHERE datname IN ('awx','automationhub','automationedacontroller','automationgateway')
    ORDER BY datname;\"" 2>/dev/null

echo ""
echo "=== Check complete ==="
