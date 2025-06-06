#!/bin/bash
set -e

echo "=== GitHub-based Phase 0 Setup ==="

# Configuration
GITHUB_REPO="https://raw.githubusercontent.com/yourusername/homelab-automation/main"
CONFIG_FILE="/tmp/homelab-config/config.json"
USERNAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('username', 'user'))")
USER_HOME="/var/home/$USERNAME"

echo "Setting up homelab for user: $USERNAME"

# Verify configuration exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

echo "Configuration loaded successfully"

# Create user directories
mkdir -p "$USER_HOME/.config/homelab"
mkdir -p "$USER_HOME/.local/bin"
mkdir -p "$USER_HOME/.local/share/containers"
mkdir -p "$USER_HOME/homelab"

# Copy configuration to user space
cp "$CONFIG_FILE" "$USER_HOME/.config/homelab/config.json"

# Download and set up the homelab repository
echo "Cloning homelab automation repository..."
cd "$USER_HOME"
if [[ ! -d "homelab/.git" ]]; then
    git clone https://github.com/yourusername/homelab-automation.git homelab
fi

# Download Phase 1 script
echo "Downloading Phase 1 setup script..."
curl -fsSL "${GITHUB_REPO}/scripts/phase1-setup.sh" -o "$USER_HOME/.local/bin/homelab-phase1.sh"
chmod +x "$USER_HOME/.local/bin/homelab-phase1.sh"

# Download Phase 2 script
echo "Downloading Phase 2 setup script..."
curl -fsSL "${GITHUB_REPO}/scripts/phase2-setup.sh" -o "$USER_HOME/.local/bin/homelab-phase2.sh"
chmod +x "$USER_HOME/.local/bin/homelab-phase2.sh"

# Create systemd user services
mkdir -p "$USER_HOME/.config/systemd/user"

# Phase 1 service (runs on first login)
cat > "$USER_HOME/.config/systemd/user/homelab-phase1.service" << 'EOF'
[Unit]
Description=Homelab Phase 1 (System Config)
After=graphical-session.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/homelab-phase1.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Phase 2 service (runs after Phase 1 completion)
cat > "$USER_HOME/.config/systemd/user/homelab-phase2.service" << 'EOF'
[Unit]
Description=Homelab Phase 2 (Containers & Services)
After=graphical-session.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/homelab-phase2.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Set ownership
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.local"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/homelab"

# Enable Phase 1 service
sudo -u "$USERNAME" systemctl --user enable homelab-phase1.service

# Create a trigger service to start the user setup
cat > /etc/systemd/system/homelab-trigger.service << 'EOF'
[Unit]
Description=Trigger Homelab User Setup
After=graphical.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

systemctl enable homelab-trigger.service

echo "Phase 0 setup complete!"
echo "Phase 1 will run automatically on first user login"
echo "User: $USERNAME"
echo "Configuration stored in: $USER_HOME/.config/homelab/config.json"