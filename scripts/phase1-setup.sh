
#!/bin/bash
# scripts/phase1-setup.sh - Ansible-first approach

set -e
echo "=== Phase 1: Initial System Setup ==="

CONFIG_FILE="$HOME/.config/homelab/config.json"
PHASE_FILE="$HOME/.config/homelab/current-phase"

get_config_value() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$1', ''))"
}

# Wait for network
until ping -c 1 8.8.8.8 &>/dev/null; do sleep 2; done

# Update repo
cd "$HOME/homelab"
git pull origin main || echo "Git update failed, continuing"

# Create minimal Ansible container for system tasks
echo "Building Ansible container for system management..."
mkdir -p "$HOME/.local/share/ansible"
cat > "$HOME/.local/share/ansible/Containerfile" << 'EOF'
FROM registry.fedoraproject.org/fedora:latest
RUN dnf install -y ansible-core python3-pip git sudo && \
    pip3 install ansible-runner && \
    dnf clean all
WORKDIR /workspace
EOF

cd "$HOME/.local/share/ansible"
docker build -t homelab-ansible . || exit 1

# Run Ansible for ALL Phase 1 tasks
echo "Running Ansible for Phase 1 system configuration..."
docker run --rm \
    --privileged \
    --network host \
    -v /:/mnt/host \
    -v "$HOME/homelab/ansible:/workspace:Z" \
    -v "$CONFIG_FILE:/workspace/config.json:Z" \
    homelab-ansible \
    ansible-playbook -i inventory/localhost phase1.yml --extra-vars "@config.json"

echo "Phase 1 complete via Ansible"
