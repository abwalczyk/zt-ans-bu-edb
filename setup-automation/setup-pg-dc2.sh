#!/bin/bash
set -euo pipefail

echo "=== Setting up pg-dc2: EDB Postgres Advanced Server 16 (STANDBY) ==="

# ---------- Helper ----------
retry() {
  local n=1 max=3 delay=5
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max in ${delay}s..."
        sleep $delay
      else
        echo "Command failed after $max attempts."
        return 1
      fi
    }
  done
}

# ---------- 1. Register with Satellite ----------
echo "--- Registering with Red Hat Satellite ---"
if [ -n "${SATELLITE_URL:-}" ]; then
  retry rpm -Uvh "${SATELLITE_URL}/pub/katello-ca-consumer-latest.noarch.rpm" || true
  retry subscription-manager register \
    --org="${SATELLITE_ORG}" \
    --activationkey="${SATELLITE_ACTIVATIONKEY}" \
    --force || true
fi

# ---------- 2. Install EDB Postgres Advanced Server 16 ----------
echo "--- Installing EDB Postgres Advanced Server 16 ---"

EDB_TOKEN="${EDB_SUBSCRIPTION_TOKEN:-${EDB_REPO_TOKEN:-}}"
if [ -z "${EDB_TOKEN}" ]; then
  echo "ERROR: EDB_SUBSCRIPTION_TOKEN (or EDB_REPO_TOKEN) must be set"
  exit 1
fi
curl -1sSLf "https://downloads.enterprisedb.com/${EDB_TOKEN}/enterprise/setup.rpm.sh" | bash

retry dnf -y install edb-as16-server edb-as16-contrib

# ---------- 3. Wait for pg-dc1 to be ready ----------
echo "--- Waiting for pg-dc1 primary to accept connections ---"
MAX_WAIT=120
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if /usr/edb/as16/bin/pg_isready -h pg-dc1 -p 5432 -U enterprisedb 2>/dev/null; then
    echo "pg-dc1 is ready."
    break
  fi
  echo "Waiting for pg-dc1... (${ELAPSED}s/${MAX_WAIT}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "ERROR: pg-dc1 not reachable after ${MAX_WAIT}s"
  exit 1
fi

# ---------- 4. Base backup from primary ----------
echo "--- Taking base backup from pg-dc1 ---"
PGDATA="/var/lib/edb/as16/data"

systemctl stop edb-as-16 2>/dev/null || true

if [ -d "${PGDATA}" ]; then
  rm -rf "${PGDATA}"/*
fi

sudo -u enterprisedb PGPASSWORD="ReplicatorPass2026!" \
  /usr/edb/as16/bin/pg_basebackup \
    -h pg-dc1 \
    -U replicator \
    -D "${PGDATA}" \
    -P -Xs -R \
    --slot=pg_dc2_slot

# ---------- 5. Verify standby configuration ----------
echo "--- Verifying standby.signal and primary_conninfo ---"
if [ -f "${PGDATA}/standby.signal" ]; then
  echo "standby.signal exists (created by pg_basebackup -R)"
else
  echo "Creating standby.signal"
  sudo -u enterprisedb touch "${PGDATA}/standby.signal"
fi

grep -q "primary_conninfo" "${PGDATA}/postgresql.auto.conf" && \
  echo "primary_conninfo is configured" || {
    echo "Adding primary_conninfo"
    cat >> "${PGDATA}/postgresql.auto.conf" <<AUTOCONF
primary_conninfo = 'host=pg-dc1 port=5432 user=replicator password=ReplicatorPass2026! application_name=pg-dc2'
primary_slot_name = 'pg_dc2_slot'
AUTOCONF
  }

# ---------- 6. Start EDB Postgres as standby ----------
echo "--- Starting EDB Postgres (standby mode) ---"
systemctl start edb-as-16
systemctl enable edb-as-16

sleep 5

# ---------- 7. Verify replication ----------
echo "--- Verifying standby status ---"
IS_STANDBY=$(sudo -u enterprisedb psql -t -c "SELECT pg_is_in_recovery();" | tr -d '[:space:]')
if [ "${IS_STANDBY}" = "t" ]; then
  echo "OK: pg-dc2 is in recovery mode (standby)"
else
  echo "WARNING: pg-dc2 is NOT in recovery mode -- check configuration"
fi

echo "--- Checking replication lag ---"
sudo -u enterprisedb psql -c "SELECT CASE WHEN pg_last_wal_receive_lsn() IS NOT NULL THEN 'Receiving WAL from primary' ELSE 'NOT receiving WAL' END AS replication_status;"

echo "=== pg-dc2 setup complete: EDB Postgres STANDBY replicating from pg-dc1 ==="
