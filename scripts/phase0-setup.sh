#!/bin/bash
# scripts/phase0-setup.sh - Download Ansible automation for Bluefin
set -e

echo "=== Phase 0: Download Ansible automation ==="

CONFIG_FILE="/tmp/homelab-config/config.json"
USERNAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('username', 'user'))")
USER_HOME="/var/home/$USERNAME"

echo "Setting up Ansible-first homelab for user: $USERNAME"

# Create user directories
mkdir -p "$USER_HOME/.config/homelab"
mkdir -p "$USER_HOME/.local/bin"
mkdir -p "$USER_HOME/homelab"

# Copy configuration to user space
cp "$CONFIG_FILE" "$USER_HOME/.config/homelab/config.json"

# Download the complete Ansible-based homelab repository
echo "Cloning Ansible homelab automation..."
cd "$USER_HOME"
if [[ ! -d "homelab/.git" ]]; then
    git clone https://github.com/yourusername/homelab-automation.git homelab
fi

# Create simplified Phase 1 script (just calls Ansible)
cat > "$USER_HOME/.local/bin/homelab-phase1.sh" << 'EOF'
#!/bin/bash
set -e

CONFIG_FILE="$HOME/.config/homelab/config.json"

echo "=== Phase 1: System Configuration via Ansible ==="

# Wait for network
until ping -c 1 8.8.8.8 &>/dev/null; do sleep 2; done

# Update repo
cd "$HOME/homelab"
git pull origin main || echo "Git update failed, continuing"

# Build Ansible container if it doesn't exist (Bluefin-compatible)
if ! docker images | grep -q homelab-ansible; then
    echo "Building Ansible container for Bluefin..."
    mkdir -p "$HOME/.local/share/ansible"
    cat > "$HOME/.local/share/ansible/Containerfile" << 'CONTAINER_EOF'
FROM registry.fedoraproject.org/fedora:39
RUN dnf update -y && \
    dnf install -y ansible-core python3-pip git sudo util-linux && \
    pip3 install --no-cache-dir ansible-runner && \
    dnf clean all && \
    rm -rf /var/cache/dnf
WORKDIR /workspace
CONTAINER_EOF
    
    cd "$HOME/.local/share/ansible"
    docker build -t homelab-ansible .
fi

# Run Ansible for Phase 1
echo "Running Ansible for Phase 1..."
docker run --rm \
    --privileged \
    --network host \
    -v /:/mnt/host \
    -v "$HOME/homelab/ansible:/workspace:Z" \
    -v "$CONFIG_FILE:/workspace/config.json:Z" \
    homelab-ansible \
    ansible-playbook -i inventory/localhost phase1.yml --extra-vars "@config.json"

echo "Phase 1 complete via Ansible"
EOF

# Create simplified Phase 2 script (just calls Ansible)
cat > "$USER_HOME/.local/bin/homelab-phase2.sh" << 'EOF'
#!/bin/bash
set -e

CONFIG_FILE="$HOME/.config/homelab/config.json"
LOG_FILE="$HOME/.config/homelab/phase2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Phase 2: Infrastructure via Ansible ==="

# Wait for network
until ping -c 1 8.8.8.8 &>/dev/null; do sleep 2; done

# Update repo
cd "$HOME/homelab"
git pull origin main || echo "Git update failed, continuing"

# Ensure Ansible container exists
if ! docker images | grep -q homelab-ansible; then
    echo "Building Ansible container..."
    mkdir -p "$HOME/.local/share/ansible"
    cat > "$HOME/.local/share/ansible/Containerfile" << 'CONTAINER_EOF'
FROM registry.fedoraproject.org/fedora:39
RUN dnf update -y && \
    dnf install -y ansible-core python3-pip git sudo util-linux && \
    pip3 install --no-cache-dir ansible-runner docker && \
    dnf clean all && \
    rm -rf /var/cache/dnf
WORKDIR /workspace
CONTAINER_EOF
    
    cd "$HOME/.local/share/ansible"
    docker build -t homelab-ansible .
fi

# Run Ansible for ALL Phase 2 tasks
echo "Running Ansible for Phase 2 setup..."
docker run --rm \
    --privileged \
    --network host \
    -v /:/mnt/host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOME/homelab/ansible:/workspace:Z" \
    -v "$CONFIG_FILE:/workspace/config.json:Z" \
    homelab-ansible \
    ansible-playbook -i inventory/localhost phase2.yml --extra-vars "@config.json"

echo "Phase 2 complete via Ansible"
EOF

chmod +x "$USER_HOME/.local/bin/homelab-phase1.sh"
chmod +x "$USER_HOME/.local/bin/homelab-phase2.sh"

# Create systemd user services with better dependencies
mkdir -p "$USER_HOME/.config/systemd/user"

cat > "$USER_HOME/.config/systemd/user/homelab-phase1.service" << 'EOF'
[Unit]
Description=Homelab Phase 1 (Ansible-managed)
After=graphical-session.target network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/homelab-phase1.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1200
Restart=no

[Install]
WantedBy=default.target
EOF

cat > "$USER_HOME/.config/systemd/user/homelab-phase2.service" << 'EOF'
[Unit]
Description=Homelab Phase 2 (Ansible-managed)
After=graphical-session.target network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/homelab-phase2.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800
Restart=no

[Install]
WantedBy=default.target
EOF

# Set ownership
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.local"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/homelab"

# Enable Phase 1 service
sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/1000" systemctl --user enable homelab-phase1.service

echo "Phase 0 complete! Ansible-first automation ready."
echo "Phase 1 will run automatically on first user login"