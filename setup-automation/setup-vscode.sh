#!/bin/bash
set -euo pipefail

echo "=== Setting up vscode: VS Code IDE with EDB demo tools ==="

# ---------- 1. Register with Satellite ----------
curl -k -L "https://${SATELLITE_URL}/pub/katello-server-ca.crt" \
  -o "/etc/pki/ca-trust/source/anchors/${SATELLITE_URL}.ca.crt"
update-ca-trust
rpm -Uhv "https://${SATELLITE_URL}/pub/katello-ca-consumer-latest.noarch.rpm" || true

tee /etc/profile.d/domain_guid.sh <<EOF
export DOMAIN="${DOMAIN}"
export GUID="${GUID}"
EOF
chmod 644 /etc/profile.d/domain_guid.sh

subscription-manager status >/dev/null 2>&1 || \
  subscription-manager register \
    --org="${SATELLITE_ORG}" \
    --activationkey="${SATELLITE_ACTIVATIONKEY}" \
    --force

setenforce 0

# ---------- 2. User setup ----------
echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
chmod 440 /etc/sudoers.d/rhel_sudoers
sudo -u rhel mkdir -p /home/rhel/.ssh
sudo -u rhel chmod 700 /home/rhel/.ssh
if [ ! -f /home/rhel/.ssh/id_rsa ]; then
  sudo -u rhel ssh-keygen -q -t rsa -b 4096 -C "rhel@$(hostname)" \
    -f /home/rhel/.ssh/id_rsa -N ""
fi
sudo -u rhel chmod 600 /home/rhel/.ssh/id_rsa*

# ---------- 3. Configure code-server ----------
systemctl stop firewalld 2>/dev/null || true
systemctl stop code-server 2>/dev/null || true

mkdir -p /home/rhel/.config/code-server
tee /home/rhel/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8080
auth: none
cert: false
EOF
chown -R rhel:rhel /home/rhel/.config/code-server

systemctl start code-server || true

# ---------- 4. Install dev tools ----------
dnf install -y unzip nano git podman ansible-core python3-pip jq || true

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
  python3 -m pip install ansible-core >/dev/null 2>&1 || true
fi

sudo -u rhel bash -lc \
  'python3 -m pip install --user --upgrade pip >/dev/null 2>&1 && python3 -m pip install --user ansible-lint >/dev/null 2>&1' || true

# ---------- 5. Install Ansible collections ----------
GALAXY_BIN="/usr/bin/ansible-galaxy"
[ -x "$GALAXY_BIN" ] || GALAXY_BIN="/home/rhel/.local/bin/ansible-galaxy"

sudo -u rhel mkdir -p /home/rhel/.ansible/collections
sudo -u rhel "$GALAXY_BIN" collection install -p /home/rhel/.ansible/collections \
  community.general community.postgresql ansible.controller || true

# ---------- 6. Create EDB demo workspace ----------
echo "--- Creating EDB demo workspace ---"
DEMO_DIR="/home/rhel/edb-ha-demo"
sudo -u rhel mkdir -p "${DEMO_DIR}"

# Create inventory file for the lab
sudo -u rhel tee "${DEMO_DIR}/inventory" <<'INV'
[dc1_postgres]
pg-dc1 ansible_host=pg-dc1

[dc2_postgres]
pg-dc2 ansible_host=pg-dc2

[dc1_aap]
control ansible_host=control

[dc2_aap]
aap-dc2 ansible_host=aap-dc2

[postgres:children]
dc1_postgres
dc2_postgres

[aap:children]
dc1_aap
dc2_aap

[all:vars]
ansible_user=rhel
ansible_password=ansible123!
ansible_become=true
ansible_become_method=sudo
INV

# Create ansible.cfg
sudo -u rhel tee "${DEMO_DIR}/ansible.cfg" <<'CFG'
[defaults]
inventory = inventory
host_key_checking = False
retry_files_enabled = False
CFG

# Create a simple replication check playbook
sudo -u rhel tee "${DEMO_DIR}/check-replication.yml" <<'PLAYBOOK'
---
- name: Check EDB Postgres replication status
  hosts: dc1_postgres
  become: true
  become_user: enterprisedb
  tasks:
    - name: Check if this node is primary
      ansible.builtin.command: psql -t -c "SELECT pg_is_in_recovery();"
      register: recovery_status
      changed_when: false

    - name: Show primary status
      ansible.builtin.debug:
        msg: "pg-dc1 is {{ 'STANDBY' if 't' in recovery_status.stdout else 'PRIMARY' }}"

    - name: Check replication status
      ansible.builtin.command: >
        psql -c "SELECT application_name, state, sync_state,
                        pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
                 FROM pg_stat_replication;"
      register: repl_status
      changed_when: false

    - name: Show replication
      ansible.builtin.debug:
        var: repl_status.stdout_lines

- name: Check standby status
  hosts: dc2_postgres
  become: true
  become_user: enterprisedb
  tasks:
    - name: Check if this node is standby
      ansible.builtin.command: psql -t -c "SELECT pg_is_in_recovery();"
      register: recovery_status
      changed_when: false

    - name: Show standby status
      ansible.builtin.debug:
        msg: "pg-dc2 is {{ 'STANDBY (replicating)' if 't' in recovery_status.stdout else 'PRIMARY (promoted!)' }}"
PLAYBOOK

# Create a DR failover playbook
sudo -u rhel tee "${DEMO_DIR}/dr-failover.yml" <<'PLAYBOOK'
---
- name: "DR Failover: Promote DC2 and activate standby AAP"
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    pg_dc1_host: pg-dc1
    pg_dc2_host: pg-dc2
    aap_dc2_host: aap-dc2

  tasks:
    - name: "Step 1: Show current state"
      ansible.builtin.debug:
        msg: "Starting DR failover -- DC1 (active) -> DC2 (will become active)"

    - name: "Step 2: Stop EDB Postgres on DC1 (simulate failure)"
      ansible.builtin.command: >
        ssh -o StrictHostKeyChecking=no rhel@{{ pg_dc1_host }}
        "sudo systemctl stop edb-as-16"
      ignore_errors: true

    - name: "Step 3: Promote DC2 Postgres to primary"
      ansible.builtin.command: >
        ssh -o StrictHostKeyChecking=no rhel@{{ pg_dc2_host }}
        "sudo -u enterprisedb /usr/edb/as16/bin/pg_ctl promote -D /var/lib/edb/as16/data"

    - name: "Step 3a: Wait for promotion to complete"
      ansible.builtin.pause:
        seconds: 10

    - name: "Step 3b: Verify DC2 is now primary"
      ansible.builtin.command: >
        ssh -o StrictHostKeyChecking=no rhel@{{ pg_dc2_host }}
        "sudo -u enterprisedb psql -t -c 'SELECT pg_is_in_recovery();'"
      register: dc2_recovery
      until: "'f' in dc2_recovery.stdout"
      retries: 6
      delay: 5

    - name: "Step 4: Start AAP services on DC2"
      ansible.builtin.command: >
        ssh -o StrictHostKeyChecking=no rhel@{{ aap_dc2_host }}
        "sudo systemctl start redis receptor automation-controller-web automation-controller-task nginx"

    - name: "Step 5: Wait for AAP API on DC2"
      ansible.builtin.uri:
        url: "https://{{ aap_dc2_host }}/api/v2/ping/"
        validate_certs: false
        status_code: 200
      register: aap_ping
      until: aap_ping.status == 200
      retries: 20
      delay: 15
      ignore_errors: true

    - name: "Step 6: Failover complete"
      ansible.builtin.debug:
        msg: >-
          DR Failover complete!
          DC2 Postgres is now PRIMARY.
          DC2 AAP is now ACTIVE at https://{{ aap_dc2_host }}.
          HTTP status: {{ aap_ping.status | default('unknown') }}
PLAYBOOK

chown -R rhel:rhel "${DEMO_DIR}"

echo "=== vscode setup complete: IDE ready with EDB demo workspace ==="
