#!/bin/bash
set -euo pipefail

echo "=== Setting up aap-dc2: AAP Controller (STANDBY -- services stopped) ==="

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
  SAT="${SATELLITE_URL#https://}"
  SAT="${SAT#http://}"
  retry rpm -Uvh "https://${SAT}/pub/katello-ca-consumer-latest.noarch.rpm" || true
  retry subscription-manager register \
    --org="${SATELLITE_ORG}" \
    --activationkey="${SATELLITE_ACTIVATIONKEY}" \
    --force || true
fi

# ---------- 2. Basic setup ----------
echo "--- Installing prerequisites ---"
dnf config-manager --set-disabled '*rhui*' 2>/dev/null || true
retry dnf -y install jq curl || echo "WARNING: Could not install jq/curl (may already be present)"

echo "--- Granting rhel passwordless sudo ---"
echo "rhel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/rhel

# ---------- 3. Configure AAP to use pg-dc2 as external database ----------
echo "--- Configuring AAP to use pg-dc2 as external database ---"

# The AAP 2.6 container image comes pre-installed.
# We need to update the database connection to point to pg-dc2.
# The exact config path depends on the AAP container image.

# Update controller settings to point to pg-dc2
AAP_SETTINGS_DIR="/etc/tower"
if [ -d "${AAP_SETTINGS_DIR}" ]; then
  # Update database host in AAP settings
  if [ -f "${AAP_SETTINGS_DIR}/conf.d/db.py" ]; then
    sed -i "s/'HOST':.*/'HOST': 'pg-dc2',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
    sed -i "s/'PASSWORD':.*/'PASSWORD': 'RedHatEDB2026!',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
    sed -i "s/'USER':.*/'USER': 'aap',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
    echo "Updated AAP database config to point to pg-dc2"
  fi

  # Copy SECRET_KEY from DC1 if available
  if [ -n "${AAP_SECRET_KEY:-}" ]; then
    echo "${AAP_SECRET_KEY}" > "${AAP_SETTINGS_DIR}/SECRET_KEY"
    chmod 600 "${AAP_SETTINGS_DIR}/SECRET_KEY"
    chown awx:awx "${AAP_SETTINGS_DIR}/SECRET_KEY"
    echo "SECRET_KEY synchronized from DC1"
  else
    echo "WARNING: AAP_SECRET_KEY not set. Copy /etc/tower/SECRET_KEY from control manually."
  fi
fi

# For containerized AAP (podman-based), update the container env/config
AAP_CONTAINERS_CONF="/etc/ansible-automation-platform"
if [ -d "${AAP_CONTAINERS_CONF}" ]; then
  for conf_file in $(find "${AAP_CONTAINERS_CONF}" -name "*.conf" -o -name "*.env" 2>/dev/null); do
    if grep -q "DATABASES" "${conf_file}" 2>/dev/null || grep -q "pg_host" "${conf_file}" 2>/dev/null; then
      sed -i "s/pg_host=.*/pg_host=pg-dc2/" "${conf_file}"
      sed -i "s/pg_password=.*/pg_password=RedHatEDB2026!/" "${conf_file}"
      echo "Updated ${conf_file} to point to pg-dc2"
    fi
  done
fi

# ---------- 4. Stop all AAP services (standby mode) ----------
echo "--- Stopping AAP services (standby posture) ---"

# Stop all AAP-related services and containers
AAP_SERVICES=(
  automation-controller-web
  automation-controller-task
  automation-gateway
  automation-hub-api
  automation-hub-content
  automation-hub-worker
  automation-eda-activation-worker
  receptor
  redis
  nginx
  pulpcore-api
  pulpcore-content
  pulpcore-worker@1
  pulpcore-worker@2
)

for svc in "${AAP_SERVICES[@]}"; do
  systemctl stop "${svc}" 2>/dev/null || true
  systemctl disable "${svc}" 2>/dev/null || true
done

# Stop any podman containers related to AAP
podman stop --all 2>/dev/null || true

echo "--- AAP services stopped and disabled ---"

# ---------- 5. Verify standby state ----------
echo "--- Verifying standby state ---"
RUNNING_AAP=$(systemctl list-units --type=service --state=running | grep -cE "automation|receptor|redis|pulp|nginx" || true)
if [ "${RUNNING_AAP}" -eq 0 ]; then
  echo "OK: No AAP services running (standby mode)"
else
  echo "WARNING: ${RUNNING_AAP} AAP service(s) still running"
  systemctl list-units --type=service --state=running | grep -E "automation|receptor|redis|pulp|nginx"
fi

echo "=== aap-dc2 setup complete: AAP STANDBY (all services stopped) ==="
echo "=== To activate: systemctl start automation-controller-web automation-controller-task ==="
