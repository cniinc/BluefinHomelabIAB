Homelab Automation for Bluefin

An Ansible-first approach to building a complete homelab on Bluefin (immutable Fedora).
Repository Structure

homelab-automation/
├── scripts/
│   └── phase0-setup.sh          # Download automation (run during install)
├── ansible/
│   ├── ansible.cfg              # Ansible configuration
│   ├── phase1.yml               # System configuration playbook
│   ├── phase2.yml               # Infrastructure deployment playbook
│   ├── inventory/
│   │   └── localhost            # Inventory file
│   └── tasks/
│       ├── zfs.yml              # ZFS storage management
│       ├── zfs_snapshots.yml    # Snapshot automation
│       ├── docker.yml           # Docker setup
│       ├── samba.yml            # SAMBA file sharing
│       ├── dockge.yml           # Dockge stack manager
│       ├── stacks.yml           # Application stack creation
│       └── configure_apps.yml   # Application configuration
├── config.json                 # Sample configuration
└── README.md

Quick Start

    Create your config.json with your preferences:

    json

    {
      "username": "yourname",
      "enable_developer_mode": true,
      "enable_tailscale": true,
      "tailscale_key": "tskey-auth-xxxxx",
      "zfs_enabled": true,
      "smb_enabled": true,
      "stacks": ["media", "audio", "books"]
    }

    Run during Bluefin installation (via iVentoy):

    bash

    bash <(curl -L https://raw.githubusercontent.com/yourusername/homelab-automation/main/scripts/phase0-setup.sh)

    Or run manually after installation:

    bash

    git clone https://github.com/yourusername/homelab-automation.git ~/homelab
    cd ~/homelab
    # Copy your config.json to ~/.config/homelab/config.json
    ./scripts/phase0-setup.sh

What It Does
Phase 1: System Configuration

    ✅ Rebase to bluefin-dx if developer mode requested
    ✅ Configure Tailscale VPN
    ✅ Set up Docker for containers
    ✅ Prepare user environment

Phase 2: Infrastructure Deployment

    ✅ ZFS Storage: Automatic pool creation with optimized datasets
    ✅ Docker Networks: Isolated networks for different application stacks
    ✅ SAMBA Shares: Network file sharing
    ✅ Dockge: Web-based Docker Compose stack manager
    ✅ Application Stacks: Pre-configured media, audio, and book management

Application Stacks
Media Stack ("media")

    Jellyfin: Media server
    Sonarr: TV show automation
    Radarr: Movie automation
    Prowlarr: Indexer management
    Deluge: Download client
    Jellyseerr: Request management
    Bazarr: Subtitle automation
    FileBot: Media organization

Audio Stack ("audio")

    AudioBookshelf: Audiobook server
    Lidarr: Music automation
    Navidrome: Music streaming server

Book Stack ("books")

    Readarr: Book automation
    Mylar3: Comic book management
    Calibre: E-book library management
    Calibre-Web: Web-based e-book reader

Configuration Options

Option	Type	Default	Description
username	string	required	Your username
enable_developer_mode	boolean	false	Rebase to bluefin-dx
enable_tailscale	boolean	false	Enable Tailscale VPN
tailscale_key	string	""	Tailscale auth key
zfs_enabled	boolean	false	Set up ZFS storage
smb_enabled	boolean	false	Enable SAMBA shares
stacks	array	[]	Application stacks to deploy
jellyfin_password	string	"homelab123"	Jellyfin admin password
calibre_password	string	"homelab123"	Calibre password
smb_username	string	"homelab"	SAMBA username
smb_password	string	"homelab123"	SAMBA password

Testing Individual Components

bash

# Test ZFS setup only
ansible-playbook -i inventory/localhost phase2.yml --extra-vars "@config.json" --tags zfs

# Test SAMBA setup only
ansible-playbook -i inventory/localhost phase2.yml --extra-vars "@config.json" --tags samba

# Test application stacks only
ansible-playbook -i inventory/localhost phase2.yml --extra-vars "@config.json" --tags stacks

Security Considerations

⚠️ Important: This setup uses default passwords for convenience. For production use:

    Change all default passwords in your config.json
    Consider using environment variables or Ansible Vault for secrets
    Configure firewall rules if exposing services externally
    Set up proper backups beyond ZFS snapshots

Troubleshooting
Phase 1 Issues

    Docker not available: Ensure you're using bluefin-dx image
    Tailscale connection fails: Check your auth key validity
    Permission errors: Verify user is in docker group

Phase 2 Issues

    ZFS pool creation fails: Check available drives with lsblk
    Container startup issues: Check docker logs <container-name>
    Network connectivity: Verify Docker networks with docker network ls

Manual Recovery

bash

# Check phase status
cat ~/.config/homelab/current-phase

# Restart specific services
systemctl --user restart homelab-phase1.service
systemctl --user restart homelab-phase2.service

# View logs
journalctl --user -u homelab-phase1.service -f
journalctl --user -u homelab-phase2.service -f

Contributing

    Fork the repository
    Create a feature branch
    Test your changes with different configurations
    Submit a pull request

License

MIT License - Feel free to modify for your needs!
