#!/bin/bash
# DR Failover Demo Script
# Simulates a datacenter failure and orchestrates failover from DC1 to DC2.
# Adapted from EDB_Testing's efm-orchestrated-failover.sh for demo use.
#
# Usage: ./dr-failover-demo.sh [--dry-run]
set -euo pipefail

DRY_RUN="${1:-}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[${TIMESTAMP}] $*"; }
log_step() { echo ""; echo "========================================"; echo "  STEP $1: $2"; echo "========================================"; }

log "=== EDB HA / AAP DR Failover Demo ==="
log "Started at: ${TIMESTAMP}"
if [ "${DRY_RUN}" = "--dry-run" ]; then
  log "*** DRY RUN MODE -- no changes will be made ***"
fi

# ---------- Pre-flight ----------
log_step "0" "PRE-FLIGHT CHECKS"

log "Checking pg-dc1 (should be PRIMARY)..."
DC1_RECOVERY=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc1 \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
if [ "${DC1_RECOVERY}" = "f" ]; then
  log "  OK: pg-dc1 is PRIMARY"
else
  log "  ERROR: pg-dc1 is NOT primary (recovery=${DC1_RECOVERY}). Cannot proceed."
  exit 1
fi

log "Checking pg-dc2 (should be STANDBY)..."
DC2_RECOVERY=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
if [ "${DC2_RECOVERY}" = "t" ]; then
  log "  OK: pg-dc2 is STANDBY"
else
  log "  ERROR: pg-dc2 is NOT a standby (recovery=${DC2_RECOVERY}). Cannot proceed."
  exit 1
fi

log "Checking DC1 AAP..."
DC1_HTTP=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://control/api/v2/ping/" 2>/dev/null || echo "000")
log "  DC1 AAP API: HTTP ${DC1_HTTP}"

log "Checking replication lag..."
LAG=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc1 \
  "sudo -u enterprisedb psql -t -c \"SELECT COALESCE(pg_wal_lsn_diff(sent_lsn, replay_lsn)::text, 'N/A') FROM pg_stat_replication LIMIT 1;\"" 2>/dev/null | tr -d '[:space:]')
log "  Replication lag: ${LAG} bytes"

if [ "${DRY_RUN}" = "--dry-run" ]; then
  log ""
  log "Dry run complete. The following would happen:"
  log "  1. Stop EDB Postgres on pg-dc1"
  log "  2. Promote pg-dc2 to primary"
  log "  3. Start AAP services on aap-dc2"
  log "  4. Wait for DC2 AAP API"
  exit 0
fi

# ---------- Step 1: Simulate failure ----------
log_step "1" "SIMULATE DC1 DATABASE FAILURE"
log "Stopping EDB Postgres on pg-dc1..."
ssh -o StrictHostKeyChecking=no rhel@pg-dc1 \
  "sudo systemctl stop edb-as-16" || true
log "  pg-dc1 EDB Postgres: STOPPED"

# ---------- Step 2: Promote DC2 ----------
log_step "2" "PROMOTE DC2 DATABASE TO PRIMARY"
log "Promoting pg-dc2..."
ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
  "sudo -u enterprisedb /usr/edb/as16/bin/pg_ctl promote -D /var/lib/edb/as16/data"

log "Waiting for promotion to complete..."
for i in $(seq 1 12); do
  DC2_CHECK=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
    "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
  if [ "${DC2_CHECK}" = "f" ]; then
    log "  pg-dc2 promoted to PRIMARY (attempt ${i})"
    break
  fi
  log "  Waiting... (attempt ${i}/12)"
  sleep 5
done

if [ "${DC2_CHECK}" != "f" ]; then
  log "  ERROR: pg-dc2 did not promote within timeout"
  exit 1
fi

# ---------- Step 3: Start DC2 AAP ----------
log_step "3" "ACTIVATE AAP ON DC2"

# Split-brain prevention: verify pg-dc2 is actually primary before starting AAP
log "Split-brain check: verifying pg-dc2 is primary before starting AAP..."
DC2_VERIFY=$(ssh -o StrictHostKeyChecking=no rhel@pg-dc2 \
  "sudo -u enterprisedb psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d '[:space:]')
if [ "${DC2_VERIFY}" != "f" ]; then
  log "  ABORT: pg-dc2 is NOT primary. Refusing to start AAP (split-brain prevention)."
  exit 1
fi

log "Starting AAP services on aap-dc2..."
ssh -o StrictHostKeyChecking=no rhel@aap-dc2 \
  "sudo systemctl start redis receptor automation-controller-web automation-controller-task nginx"

# ---------- Step 4: Wait for API ----------
log_step "4" "WAITING FOR DC2 AAP API"
MAX_WAIT=300
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  DC2_HTTP=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://aap-dc2/api/v2/ping/" 2>/dev/null || echo "000")
  if [ "${DC2_HTTP}" = "200" ]; then
    log "  DC2 AAP API is UP (HTTP 200) after ${ELAPSED}s"
    break
  fi
  log "  Waiting... HTTP ${DC2_HTTP} (${ELAPSED}s/${MAX_WAIT}s)"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

if [ "${DC2_HTTP}" != "200" ]; then
  log "  WARNING: DC2 AAP API did not respond within ${MAX_WAIT}s"
fi

# ---------- Summary ----------
log_step "5" "FAILOVER COMPLETE"
log "Summary:"
log "  pg-dc1 (DC1 Primary): STOPPED (simulated failure)"
log "  pg-dc2 (DC2):         PROMOTED to PRIMARY"
log "  aap-dc2 (DC2 AAP):    ACTIVE (HTTP ${DC2_HTTP})"
log ""
log "Access DC2 AAP at: https://aap-dc2"
log "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
