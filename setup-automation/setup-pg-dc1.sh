#!/bin/bash
set -euo pipefail

echo "=== Setting up pg-dc1: EDB Postgres Advanced Server 16 (PRIMARY) ==="

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

retry dnf install -y https://yum.enterprisedb.com/edb-repo-rpms/edb-repo-latest.noarch.rpm
retry dnf -y install edb-as16-server edb-as16-contrib

# ---------- 3. Initialize database cluster ----------
echo "--- Initializing EDB database cluster ---"
PGDATA="/var/lib/edb/as16/data"

if [ ! -f "${PGDATA}/PG_VERSION" ]; then
  /usr/edb/as16/bin/edb-as-16-setup initdb
fi

# ---------- 4. Configure as PRIMARY ----------
echo "--- Configuring postgresql.conf for primary role ---"
cat >> "${PGDATA}/postgresql.conf" <<'PGCONF'

# --- EDB HA Demo: Primary configuration ---
listen_addresses = '*'
port = 5432
max_connections = 500
shared_buffers = 2GB
effective_cache_size = 4GB
work_mem = 32MB

# Replication
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 512MB
hot_standby = on
hot_standby_feedback = on
synchronous_commit = on

# Performance
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
PGCONF

# ---------- 5. Configure pg_hba.conf ----------
echo "--- Configuring pg_hba.conf ---"
cat >> "${PGDATA}/pg_hba.conf" <<'PGHBA'

# --- EDB HA Demo: Replication and AAP access ---
# Replication from pg-dc2 (standby)
host    replication     replicator      0.0.0.0/0               scram-sha-256

# AAP database access from any lab VM
host    awx                     aap     0.0.0.0/0               scram-sha-256
host    automationhub           aap     0.0.0.0/0               scram-sha-256
host    automationedacontroller aap     0.0.0.0/0               scram-sha-256
host    automationgateway       aap     0.0.0.0/0               scram-sha-256

# General access for demo/troubleshooting
host    all             all     0.0.0.0/0               scram-sha-256
PGHBA

# ---------- 6. Start EDB Postgres ----------
echo "--- Starting EDB Postgres ---"
systemctl start edb-as-16
systemctl enable edb-as-16

sleep 5

# ---------- 7. Create replication user ----------
echo "--- Creating replication user ---"
sudo -u enterprisedb psql -c "CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'ReplicatorPass2026!';" 2>/dev/null || \
  echo "Role replicator may already exist."

# ---------- 8. Create replication slot for pg-dc2 ----------
echo "--- Creating replication slot ---"
sudo -u enterprisedb psql -c "SELECT pg_create_physical_replication_slot('pg_dc2_slot');" 2>/dev/null || \
  echo "Replication slot may already exist."

# ---------- 9. Bootstrap AAP databases ----------
echo "--- Creating AAP databases ---"
BOOTSTRAP_SQL="/tmp/setup-scripts/create-aap-databases.sql"

if [ -f "${BOOTSTRAP_SQL}" ]; then
  sudo -u enterprisedb psql -f "${BOOTSTRAP_SQL}"
else
  # Inline fallback
  sudo -u enterprisedb psql <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aap') THEN
    CREATE ROLE aap LOGIN PASSWORD 'RedHatEDB2026!';
  END IF;
END
$$;
SQL
  for db in awx automationhub automationedacontroller automationgateway; do
    sudo -u enterprisedb psql -tc "SELECT 1 FROM pg_database WHERE datname='${db}';" | grep -q 1 || \
      sudo -u enterprisedb createdb -O aap "${db}"
  done
  sudo -u enterprisedb psql -d automationhub -c "CREATE EXTENSION IF NOT EXISTS hstore;"
fi

# ---------- 10. Verify ----------
echo "--- Verifying primary setup ---"
sudo -u enterprisedb psql -c "SELECT pg_is_in_recovery();"
sudo -u enterprisedb psql -c "\l" | grep -E "awx|automationhub|automationeda|automationgateway"

echo "=== pg-dc1 setup complete: EDB Postgres PRIMARY ready ==="
