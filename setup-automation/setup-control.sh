#!/bin/bash
set -euo pipefail

echo "=== Setting up control: AAP Controller DC1 (ACTIVE) ==="

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
retry subscription-manager clean || true
retry curl -k -L "https://${SATELLITE_URL}/pub/katello-server-ca.crt" \
  -o "/etc/pki/ca-trust/source/anchors/${SATELLITE_URL}.ca.crt"
update-ca-trust

KATELLO_INSTALLED=$(rpm -qa | grep -c katello || true)
if [ "$KATELLO_INSTALLED" -eq 0 ]; then
  retry rpm -Uhv "https://${SATELLITE_URL}/pub/katello-ca-consumer-latest.noarch.rpm"
fi

subscription-manager status >/dev/null 2>&1 || \
  retry subscription-manager register \
    --org="${SATELLITE_ORG}" \
    --activationkey="${SATELLITE_ACTIVATIONKEY}" \
    --force

dnf config-manager --set-enabled rhel-9-baseos-rpms rhel-9-appstream-rpms 2>/dev/null || true

# ---------- 2. Install prerequisites ----------
echo "--- Installing prerequisites ---"
dnf install -y jq curl certbot || true

echo "--- Granting rhel passwordless sudo ---"
echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
chmod 440 /etc/sudoers.d/rhel_sudoers

# ---------- 3. Wait for pg-dc1 database ----------
echo "--- Waiting for pg-dc1 database ---"
MAX_WAIT=180
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if timeout 5 bash -c "echo > /dev/tcp/pg-dc1/5432" 2>/dev/null; then
    echo "pg-dc1 port 5432 is reachable."
    break
  fi
  echo "Waiting for pg-dc1:5432... (${ELAPSED}s/${MAX_WAIT}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

# ---------- 4. Configure AAP to use pg-dc1 as external database ----------
echo "--- Configuring AAP to use pg-dc1 as external database ---"

AAP_SETTINGS_DIR="/etc/tower"
if [ -d "${AAP_SETTINGS_DIR}" ] && [ -f "${AAP_SETTINGS_DIR}/conf.d/db.py" ]; then
  sed -i "s/'HOST':.*/'HOST': 'pg-dc1',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
  sed -i "s/'PASSWORD':.*/'PASSWORD': 'RedHatEDB2026!',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
  sed -i "s/'USER':.*/'USER': 'aap',/" "${AAP_SETTINGS_DIR}/conf.d/db.py"
  echo "Updated AAP database config to point to pg-dc1"
fi

AAP_CONTAINERS_CONF="/etc/ansible-automation-platform"
if [ -d "${AAP_CONTAINERS_CONF}" ]; then
  for conf_file in $(find "${AAP_CONTAINERS_CONF}" -name "*.conf" -o -name "*.env" 2>/dev/null); do
    if grep -q "pg_host" "${conf_file}" 2>/dev/null; then
      sed -i "s/pg_host=.*/pg_host=pg-dc1/" "${conf_file}"
      sed -i "s/pg_password=.*/pg_password=RedHatEDB2026!/" "${conf_file}"
      echo "Updated ${conf_file} to point to pg-dc1"
    fi
  done
fi

# ---------- 5. Restart AAP services ----------
echo "--- Restarting AAP services ---"
for svc in redis receptor automation-controller-web automation-controller-task nginx; do
  systemctl restart "${svc}" 2>/dev/null || true
  systemctl enable "${svc}" 2>/dev/null || true
done

# ---------- 6. Wait for AAP API ----------
echo "--- Waiting for AAP API ---"
MAX_WAIT=300
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://localhost/api/v2/ping/" 2>/dev/null || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "AAP API is responding (HTTP ${HTTP_CODE})"
    break
  fi
  echo "Waiting for AAP API... HTTP ${HTTP_CODE} (${ELAPSED}s/${MAX_WAIT}s)"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

# ---------- 7. Install collections and configure demo content ----------
echo "--- Installing Ansible collections ---"
ansible-galaxy collection install ansible.controller community.general --force 2>/dev/null || true

echo "--- Configuring AAP demo content ---"
cat > /tmp/setup-aap.yml <<'SETUP_YML'
---
- name: Configure AAP demo content for EDB HA lab
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    controller_host: "https://localhost"
    controller_username: "admin"
    controller_password: "ansible123!"
    controller_validate_certs: false
  collections:
    - ansible.controller

  tasks:
    - name: Create Machine credential for lab nodes
      ansible.controller.credential:
        name: "Lab Nodes"
        organization: "Default"
        credential_type: "Machine"
        inputs:
          username: "rhel"
          password: "ansible123!"
          become_method: "sudo"
          become_username: "root"
        state: present

    - name: Create inventory for EDB HA demo
      ansible.controller.inventory:
        name: "EDB HA Demo"
        organization: "Default"
        description: "EDB Postgres HA / DR demo infrastructure"
        state: present

    - name: Add pg-dc1 host
      ansible.controller.host:
        name: "pg-dc1"
        inventory: "EDB HA Demo"
        variables:
          ansible_host: "pg-dc1"
          dc: "dc1"
          role: "postgres_primary"
        state: present

    - name: Add pg-dc2 host
      ansible.controller.host:
        name: "pg-dc2"
        inventory: "EDB HA Demo"
        variables:
          ansible_host: "pg-dc2"
          dc: "dc2"
          role: "postgres_standby"
        state: present

    - name: Add aap-dc2 host
      ansible.controller.host:
        name: "aap-dc2"
        inventory: "EDB HA Demo"
        variables:
          ansible_host: "aap-dc2"
          dc: "dc2"
          role: "aap_standby"
        state: present

    - name: Create DC1 Postgres group
      ansible.controller.group:
        name: "dc1_postgres"
        inventory: "EDB HA Demo"
        hosts:
          - "pg-dc1"
        state: present

    - name: Create DC2 group
      ansible.controller.group:
        name: "dc2"
        inventory: "EDB HA Demo"
        hosts:
          - "pg-dc2"
          - "aap-dc2"
        state: present

    - name: Create Check Replication Status template
      ansible.controller.job_template:
        name: "Check Replication Status"
        organization: "Default"
        inventory: "EDB HA Demo"
        project: "Demo Job Templates"
        playbook: "hello_world.yml"
        credential: "Lab Nodes"
        extra_vars:
          target_host: "pg-dc1"
        state: present
      ignore_errors: true

    - name: Create Health Check template
      ansible.controller.job_template:
        name: "AAP Health Check"
        organization: "Default"
        inventory: "EDB HA Demo"
        project: "Demo Job Templates"
        playbook: "hello_world.yml"
        credential: "Lab Nodes"
        state: present
      ignore_errors: true
SETUP_YML

ansible-playbook /tmp/setup-aap.yml || echo "WARNING: Demo content setup had errors (may need manual config)"

# ---------- 8. Export SECRET_KEY ----------
echo "--- SECRET_KEY info ---"
if [ -f "/etc/tower/SECRET_KEY" ]; then
  echo "SECRET_KEY exists at /etc/tower/SECRET_KEY"
  echo "This must be copied to aap-dc2 for failover to work."
fi

echo "=== control setup complete: AAP DC1 ACTIVE, connected to pg-dc1 ==="
