#!/bin/bash
set -e

echo "=== Phase 1: System Configuration ==="

CONFIG_FILE="$HOME/.config/homelab/config.json"
PHASE_FILE="$HOME/.config/homelab/current-phase"

# Load configuration helper
get_config_value() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$1', ''))"
}

# Wait for network
echo "Waiting for network connectivity..."
until ping -c 1 8.8.8.8 &>/dev/null; do sleep 2; done

echo "Phase 1 started at $(date)"

# Check for updates to scripts from GitHub
echo "Checking for script updates..."
cd "$HOME/homelab"
git pull origin main || echo "Failed to update from GitHub, continuing with local versions"

ENABLE_DEV=$(get_config_value 'enable_developer_mode')
NEEDS_REBOOT=false

# Handle developer mode
if [[ "$ENABLE_DEV" == "true" ]]; then
    echo "Developer mode requested..."
    if ! rpm-ostree status | grep -q "bluefin-dx"; then
        echo "Switching to bluefin-dx for developer mode..."
        rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/bluefin-dx:gts
        NEEDS_REBOOT=true
        echo "phase1-post-reboot" > "$PHASE_FILE"
    else
        echo "Already on bluefin-dx, setting up groups..."
        ujust dx-group
        echo "phase2" > "$PHASE_FILE"
    fi
else
    echo "phase2" > "$PHASE_FILE"
fi

# Handle Tailscale
ENABLE_TAILSCALE=$(get_config_value 'enable_tailscale')
if [[ "$ENABLE_TAILSCALE" == "true" ]]; then
    TAILSCALE_KEY=$(get_config_value 'tailscale_key')
    if [[ "$TAILSCALE_KEY" != "" && "$TAILSCALE_KEY" != "null" ]]; then
        echo "Setting up Tailscale..."
        sudo tailscale up --authkey="$TAILSCALE_KEY" --accept-routes || echo "Tailscale setup failed"
    fi
else
    echo "Disabling Tailscale..."
    ujust toggle-tailscale || echo "Tailscale toggle failed"
fi

# Disable this phase and prepare for next
systemctl --user disable homelab-phase1.service

if [[ "$NEEDS_REBOOT" == "true" ]]; then
    echo "System needs reboot for bluefin-dx. Rebooting in 10 seconds..."
    systemctl --user enable homelab-phase1-post-reboot.service
    sleep 10
    sudo reboot
else
    echo "No reboot needed, enabling Phase 2..."
    systemctl --user enable homelab-phase2.service
    echo "Phase 1 complete. Log out and back in for all changes to take effect."
fi