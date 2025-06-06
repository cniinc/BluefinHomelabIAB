#!/bin/bash
set -e

echo "=== Phase 2: Containers and Services Setup ==="

CONFIG_FILE="$HOME/.config/homelab/config.json"
PHASE_FILE="$HOME/.config/homelab/current-phase"
LOG_FILE="$HOME/.config/homelab/phase2.log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Phase 2 started at $(date)"

# Load configuration helper
get_config_value() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$1', ''))"
}

# Wait for network
echo "Waiting for network connectivity..."
until ping -c 1 8.8.8.8 &>/dev/null; do sleep 2; done

# Update scripts from GitHub
echo "Checking for script updates..."
cd "$HOME/homelab"
git pull origin main || echo "Failed to update from GitHub, continuing with local versions"

# Verify developer mode and Docker availability
ENABLE_DEV=$(get_config_value 'enable_developer_mode')
if [[ "$ENABLE_DEV" == "true" ]]; then
    if rpm-ostree status | grep -q "bluefin-dx"; then
        echo "✓ Successfully running on bluefin-dx"
        
        if command -v docker &> /dev/null; then
            echo "✓ Docker is available"
            
            # Test Docker daemon
            if docker info &>/dev/null; then
                echo "✓ Docker daemon is running"
            else
                echo "Starting Docker daemon..."
                sudo systemctl start docker
                sudo systemctl enable docker
            fi
            
            # Check user permissions
            if docker ps &>/dev/null; then
                echo "✓ User can access Docker without sudo"
            else
                echo "⚠ User needs to be in docker group - may need to log out/in"
                echo "  Run: newgrp docker (or log out and back in)"
            fi
        else
            echo "✗ Docker not found despite being on bluefin-dx"
            exit 1
        fi
    else
        echo "✗ Not on bluefin-dx but developer mode was requested"
        exit 1
    fi
else
    echo "⚠ Developer mode not enabled - some features may not work"
    echo "⚠ Consider enabling developer mode for full Docker support"
fi

# Function to find the largest available drive (excluding OS drive)
find_largest_drive() {
    echo "=== Detecting available drives for ZFS ==="
    
    OS_DRIVE=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null | head -1)
    echo "OS is installed on: $OS_DRIVE"
    
    AVAILABLE_DRIVES=$(lsblk -d -n -o NAME,SIZE,TYPE,MOUNTPOINT | \
        awk -v os_drive="$OS_DRIVE" '
        $3=="disk" && 
        $1!=os_drive && 
        $4=="" && 
        $1!~/^loop/ && 
        $1!~/^ram/ && 
        $1!~/^sr/ 
        {print $1 " " $2}')
    
    if [[ -z "$AVAILABLE_DRIVES" ]]; then
        echo "No additional drives found for ZFS"
        return 1
    fi
    
    echo "Available drives for ZFS:"
    echo "$AVAILABLE_DRIVES"
    
    LARGEST_DRIVE=""
    LARGEST_SIZE=0
    LARGEST_SIZE_HUMAN=""
    
    while IFS=' ' read -r drive size; do
        if [[ -n "$drive" && -n "$size" ]]; then
            size_bytes=$(echo "$size" | python3 -c "
import sys, re
size = sys.stdin.read().strip()
match = re.match(r'([0-9.]+)([KMGT]?)', size.upper())
if match:
    num, unit = match.groups()
    multipliers = {'': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3, 'T': 1024**4}
    print(int(float(num) * multipliers.get(unit, 1)))
else:
    print(0)
")
            
            echo "Drive $drive: $size ($size_bytes bytes)"
            
            if [[ $size_bytes -gt $LARGEST_SIZE ]]; then
                LARGEST_SIZE=$size_bytes
                LARGEST_DRIVE=$drive
                LARGEST_SIZE_HUMAN=$size
            fi
        fi
    done <<< "$AVAILABLE_DRIVES"
    
    if [[ -n "$LARGEST_DRIVE" ]]; then
        echo "Selected largest drive: $LARGEST_DRIVE ($LARGEST_SIZE_HUMAN)"
        echo "/dev/$LARGEST_DRIVE"
        return 0
    else
        echo "Could not determine largest drive"
        return 1
    fi
}

# Function to setup ZFS pool using NATIVE ZFS (included in Bluefin)
setup_zfs_pool() {
    local drive_path="$1"
    local pool_name="homelab-drive"
    
    echo "=== Setting up ZFS pool '$pool_name' using NATIVE ZFS ==="
    
    # Verify ZFS is available (should be included in Bluefin)
    if ! command -v zpool &> /dev/null; then
        echo "✗ ZFS not found! This is unexpected on Bluefin."
        return 1
    fi
    
    echo "✓ Native ZFS is available"
    zfs version || echo "ZFS version info not available"
    
    # Check if the pool already exists
    if sudo zpool list "$pool_name" &>/dev/null; then
        echo "✓ ZFS pool '$pool_name' already exists"
        sudo zpool status "$pool_name"
        return 0
    fi
    
    if [[ ! -b "$drive_path" ]]; then
        echo "✗ Error: Drive $drive_path does not exist or is not a block device"
        return 1
    fi
    
    if mount | grep -q "$drive_path"; then
        echo "✗ Error: Drive $drive_path is currently mounted"
        return 1
    fi
    
    echo "About to create ZFS pool on $drive_path"
    echo "This will DESTROY ALL DATA on this drive!"
    sleep 3
    
    echo "Creating ZFS pool '$pool_name' on $drive_path using native ZFS..."
    if sudo zpool create -f \
        -o ashift=12 \
        -o autoexpand=on \
        -o autotrim=on \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O acltype=posixacl \
        -O recordsize=1M \
        -m "/$pool_name" \
        "$pool_name" "$drive_path"; then
        
        echo "✓ ZFS pool '$pool_name' created successfully with native ZFS"
        
        # Create main datasets with optimized settings for media
        sudo zfs create -o recordsize=128K "$pool_name/shared"     # Good for SAMBA
        sudo zfs create -o recordsize=1M "$pool_name/media"        # Good for large media files
        sudo zfs create -o compression=gzip-9 "$pool_name/backups" # High compression for backups
        
        # Create media directory structure as ZFS datasets
        sudo zfs create "$pool_name/media/books"
        sudo zfs create "$pool_name/media/comics"
        sudo zfs create "$pool_name/media/movies"
        sudo zfs create "$pool_name/media/shows"
        sudo zfs create "$pool_name/media/xxx"
        sudo zfs create "$pool_name/media/audiobooks"
        sudo zfs create "$pool_name/media/webvids"
        sudo zfs create "$pool_name/media/music"
        sudo zfs create "$pool_name/media/downloads"
        
        # Create download subdirectories (regular directories, not datasets)
        sudo mkdir -p "/$pool_name/media/downloads/incomplete"
        sudo mkdir -p "/$pool_name/media/downloads/complete"
        
        # Set ownership and permissions
        sudo chown -R 1000:1000 "/$pool_name"
        sudo chmod -R 755 "/$pool_name"
        
        echo "✓ ZFS datasets created with optimized settings for media:"
        echo "  - /$pool_name/shared (128K recordsize for SAMBA)"
        echo "  - /$pool_name/media/* (1M recordsize for large media files)"
        echo "  - /$pool_name/backups (high compression)"
        
        # Enable useful ZFS features
        sudo zfs set snapdir=visible "$pool_name"
        sudo zfs set relatime=on "$pool_name"
        
        # Display pool status
        sudo zpool status "$pool_name"
        sudo zfs list -r "$pool_name"
        
        return 0
    else
        echo "✗ Failed to create ZFS pool"
        return 1
    fi
}

# Function to setup ZFS snapshots for media protection
setup_zfs_snapshots() {
    local pool_name="homelab-drive"
    
    echo "=== Setting up ZFS snapshot automation for media protection ==="
    
    # Create snapshot script in user space
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/zfs-snapshot.sh" << 'SNAPEOF'
#!/bin/bash
# ZFS Snapshot Management Script for Media Hub

POOL_NAME="homelab-drive"
DATE=$(date +%Y%m%d-%H%M%S)

echo "Creating ZFS snapshots for media protection..."

# Create snapshots of main datasets
sudo zfs snapshot "${POOL_NAME}/shared@auto-${DATE}"
sudo zfs snapshot "${POOL_NAME}/media@auto-${DATE}"

# Keep only last 3 weekly snapshots (good for media workloads)
echo "Cleaning up old snapshots..."
for dataset in "shared" "media"; do
    SNAPSHOTS=$(sudo zfs list -t snapshot -o name -s creation | grep "${POOL_NAME}/${dataset}@auto-" | head -n -3)
    if [[ -n "$SNAPSHOTS" ]]; then
        echo "Cleaning up old ${dataset} snapshots:"
        echo "$SNAPSHOTS" | while read snapshot; do
            if [[ -n "$snapshot" ]]; then
                echo "Destroying: $snapshot"
                sudo zfs destroy "$snapshot" || echo "Failed to destroy $snapshot"
            fi
        done
    fi
done

echo "ZFS snapshots created: auto-${DATE}"
echo "Snapshot space usage:"
sudo zfs list -t snapshot | grep "auto-"
SNAPEOF

    chmod +x "$HOME/.local/bin/zfs-snapshot.sh"
    
    # Create systemd timer for weekly snapshots (perfect for media)
    mkdir -p "$HOME/.config/systemd/user"
    
    cat > "$HOME/.config/systemd/user/zfs-snapshot.service" << 'SERVICEEOF'
[Unit]
Description=ZFS Automatic Snapshots for Media Protection
After=multi-user.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/zfs-snapshot.sh
StandardOutput=journal
StandardError=journal
SERVICEEOF

    cat > "$HOME/.config/systemd/user/zfs-snapshot.timer" << 'TIMEREOF'
[Unit]
Description=Weekly ZFS Snapshots for Media Hub
Requires=zfs-snapshot.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

    # Enable the timer
    systemctl --user daemon-reload
    systemctl --user enable zfs-snapshot.timer
    systemctl --user start zfs-snapshot.timer
    
    echo "✓ ZFS snapshot automation configured for media hub:"
    echo "  - Weekly snapshots (perfect for media workloads)"
    echo "  - Keeps last 3 snapshots (~3 weeks protection)"
    echo "  - Expected space usage: <5% of pool (media files rarely change)"
    echo "  - Manual snapshot: $HOME/.local/bin/zfs-snapshot.sh"
    echo "  - Check status: systemctl --user status zfs-snapshot.timer"
}

# Function to setup SAMBA container (SAMBA not included in Bluefin)
setup_samba_container() {
    local share_path="$1"
    
    echo "=== Setting up SAMBA container (not included in Bluefin) ==="
    
    # Create SAMBA directory in user space
    mkdir -p "$HOME/.local/share/containers/samba"
    
    # Ensure share path exists and has correct permissions
    if [[ ! -d "$share_path" ]]; then
        sudo mkdir -p "$share_path"
    fi
    
    sudo chown -R 1000:1000 "$share_path"
    sudo chmod -R 755 "$share_path"
    
    # Stop existing container if running
    docker stop homelab-samba 2>/dev/null || true
    docker rm homelab-samba 2>/dev/null || true
    
    # Create docker-compose file for SAMBA
    cat > "$HOME/.local/share/containers/samba/compose.yml" << SAMBAEOF
version: '3.8'
services:
  samba:
    image: dperson/samba:latest
    container_name: homelab-samba
    restart: unless-stopped
    ports:
      - "445:445"
      - "139:139"
      - "137:137/udp"
      - "138:138/udp"
    volumes:
      - ${share_path}:/shared:rw
    environment:
      - USERID=1000
      - GROUPID=1000
      - TZ=America/New_York
    command: >
      -u "homelab;homelab123;1000;1000;Homelab User;/shared"
      -s "homelab-drive;/shared;yes;no;yes;homelab;homelab;Full access to homelab drive including all media"
      -p
    cap_add:
      - NET_ADMIN
    network_mode: host
SAMBAEOF

    echo "Starting SAMBA container with Docker Compose V2..."
    cd "$HOME/.local/share/containers/samba"
    
    # Use Docker Compose V2 (docker compose, not docker-compose)
    docker compose up -d
    
    if [[ $? -eq 0 ]]; then
        SERVER_IP=$(ip route get 8.8.8.8 | head -1 | awk '{print $7}')
        
        echo "✓ SAMBA container started successfully with Docker Compose V2"
        echo ""
        echo "=== SAMBA Share Information ==="
        echo "Network Path: \\\\$SERVER_IP\\homelab-drive"
        echo "Local Path: $share_path"
        echo "Username: homelab"
        echo "Password: homelab123"
        echo "Media Path: $share_path/media (includes all media folders)"
        echo ""
        echo "Connection instructions:"
        echo "Windows: Map network drive to \\\\$SERVER_IP\\homelab-drive"
        echo "Mac: Finder → Go → Connect to Server → smb://$SERVER_IP/homelab-drive"
        echo "Linux: Files → Other Locations → smb://$SERVER_IP/homelab-drive"
        echo ""
        
        # Test the container
        sleep 5
        if docker ps | grep -q "homelab-samba"; then
            echo "✓ SAMBA container is running and accessible"
        else
            echo "⚠ SAMBA container may have issues"
            docker logs homelab-samba | tail -10
        fi
        
        return 0
    else
        echo "✗ Failed to start SAMBA container"
        return 1
    fi
}

# Function to setup Dockge stack manager
setup_dockge() {
    local base_path="$1"
    
    echo "=== Setting up Dockge Stack Manager ==="
    
    # Create Dockge directories in user space AND on ZFS/storage
    mkdir -p "$HOME/.local/share/dockge"
    sudo mkdir -p "$base_path/dockge/data"
    sudo mkdir -p "$base_path/dockge/stacks"
    sudo chown -R 1000:1000 "$base_path/dockge"
    
    # Stop existing container
    docker stop dockge 2>/dev/null || true
    docker rm dockge 2>/dev/null || true
    
    # Create Dockge compose file in user space
    cat > "$HOME/.local/share/dockge/compose.yml" << DOCKGEEOF
version: '3.8'
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports:
      - 5001:5001
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $base_path/dockge/data:/app/data
      - $base_path/dockge/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
DOCKGEEOF
    
    # Start Dockge with Docker Compose V2
    cd "$HOME/.local/share/dockge"
    docker compose up -d
    
    if [[ $? -eq 0 ]]; then
        SERVER_IP=$(ip route get 8.8.8.8 | head -1 | awk '{print $7}')
        echo "✓ Dockge started successfully with Docker Compose V2"
        echo "✓ Dockge UI: http://$SERVER_IP:5001"
        echo "✓ Stacks directory: $base_path/dockge/stacks"
        return 0
    else
        echo "✗ Failed to start Dockge"
        return 1
    fi
}

# Function to create media stack with all requested applications
create_media_stack() {
    local stacks_path="$1"
    local media_path="$2"
    
    echo "=== Creating Media Stack ==="
    
    mkdir -p "$stacks_path/media-stack"
    
    cat > "$stacks_path/media-stack/compose.yml" << MEDIASTACKEOF
version: '3.8'

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - 8096:8096
    volumes:
      - ./jellyfin-config:/config
      - ./jellyfin-cache:/cache
      - ${media_path}/media:/media:ro
    environment:
      - JELLYFIN_PublishedServerUrl=http://\${SERVER_IP}:8096
    user: 1000:1000

  deluge:
    image: lscr.io/linuxserver/deluge:latest
    container_name: deluge
    restart: unless-stopped
    ports:
      - 8112:8112
      - 6881:6881
      - 6881:6881/udp
    volumes:
      - ./deluge-config:/config
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports:
      - 8989:8989
    volumes:
      - ./sonarr-config:/config
      - ${media_path}/media/shows:/tv
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports:
      - 7878:7878
    volumes:
      - ./radarr-config:/config
      - ${media_path}/media/movies:/movies
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports:
      - 9696:9696
    volumes:
      - ./prowlarr-config:/config
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    restart: unless-stopped
    ports:
      - 8191:8191
    environment:
      - LOG_LEVEL=info

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports:
      - 6767:6767
    volumes:
      - ./bazarr-config:/config
      - ${media_path}/media/movies:/movies
      - ${media_path}/media/shows:/tv
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  whisparr:
    image: ghcr.io/hotio/whisparr:latest
    container_name: whisparr
    restart: unless-stopped
    ports:
      - 6969:6969
    volumes:
      - ./whisparr-config:/config
      - ${media_path}/media/xxx:/adult
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    ports:
      - 5055:5055
    volumes:
      - ./jellyseerr-config:/app/config
    environment:
      - LOG_LEVEL=debug
      - TZ=America/New_York

  filebot:
    image: jlesage/filebot:latest
    container_name: filebot
    restart: unless-stopped
    ports:
      - 5800:5800
    volumes:
      - ./filebot-config:/config
      - ${media_path}/media:/storage
      - ${media_path}/media/downloads:/watch
    environment:
      - USER_ID=1000
      - GROUP_ID=1000
      - TZ=America/New_York

networks:
  default:
    name: media-network
MEDIASTACKEOF

    # Replace media path in compose file
    sed -i "s|\${media_path}|$media_path|g" "$stacks_path/media-stack/compose.yml"
    
    echo "✓ Media stack created at: $stacks_path/media-stack/"
    echo "  Includes: Jellyfin, Deluge, Sonarr, Radarr, Prowlarr, Flaresolverr, Bazarr, Whisparr, Jellyseerr, FileBot"
}

# Function to create audio stack
create_audio_stack() {
    local stacks_path="$1"
    local media_path="$2"
    
    echo "=== Creating Audio Stack ==="
    
    mkdir -p "$stacks_path/audio-stack"
    
    cat > "$stacks_path/audio-stack/compose.yml" << AUDIOSTACKEOF
version: '3.8'

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    restart: unless-stopped
    ports:
      - 13378:80
    volumes:
      - ./audiobookshelf-config:/config
      - ./audiobookshelf-metadata:/metadata
      - ${media_path}/media/audiobooks:/audiobooks
      - ${media_path}/media/books:/books
    environment:
      - AUDIOBOOKSHELF_UID=1000
      - AUDIOBOOKSHELF_GID=1000

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    restart: unless-stopped
    ports:
      - 8686:8686
    volumes:
      - ./lidarr-config:/config
      - ${media_path}/media/music:/music
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    ports:
      - 4533:4533
    volumes:
      - ./navidrome-config:/data
      - ${media_path}/media/music:/music:ro
    environment:
      - ND_SCANSCHEDULE=1h
      - ND_LOGLEVEL=info
      - ND_SESSIONTIMEOUT=24h
      - ND_BASEURL=""

networks:
  default:
    name: audio-network
AUDIOSTACKEOF

    sed -i "s|\${media_path}|$media_path|g" "$stacks_path/audio-stack/compose.yml"
    
    echo "✓ Audio stack created at: $stacks_path/audio-stack/"
    echo "  Includes: Audiobookshelf, Lidarr, Navidrome"
}

# Function to create book stack
create_book_stack() {
    local stacks_path="$1"
    local media_path="$2"
    
    echo "=== Creating Book Stack ==="
    
    mkdir -p "$stacks_path/book-stack"
    
    cat > "$stacks_path/book-stack/compose.yml" << BOOKSTACKEOF
version: '3.8'

services:
  readarr:
    image: lscr.io/linuxserver/readarr:develop
    container_name: readarr
    restart: unless-stopped
    ports:
      - 8787:8787
    volumes:
      - ./readarr-config:/config
      - ${media_path}/media/books:/books
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  mylar3:
    image: lscr.io/linuxserver/mylar3:latest
    container_name: mylar3
    restart: unless-stopped
    ports:
      - 8090:8090
    volumes:
      - ./mylar3-config:/config
      - ${media_path}/media/comics:/comics
      - ${media_path}/media/downloads:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York

  calibre:
    image: lscr.io/linuxserver/calibre:latest
    container_name: calibre
    restart: unless-stopped
    ports:
      - 8080:8080
      - 8081:8081
    volumes:
      - ./calibre-config:/config
      - ${media_path}/media/books:/books
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - PASSWORD=homelab123

  calibre-web:
    image: lscr.io/linuxserver/calibre-web:latest
    container_name: calibre-web
    restart: unless-stopped
    ports:
      - 8083:8083
    volumes:
      - ./calibre-web-config:/config
      - ${media_path}/media/books:/books
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - DOCKER_MODS=linuxserver/mods:universal-calibre

networks:
  default:
    name: book-network
BOOKSTACKEOF

    sed -i "s|\${media_path}|$media_path|g" "$stacks_path/book-stack/compose.yml"
    
    echo "✓ Book stack created at: $stacks_path/book-stack/"
    echo "  Includes: Readarr, Mylar3, Calibre, Calibre-web"
}

# Function to create Docker management user service
create_docker_management_service() {
    echo "=== Creating Docker management user service ==="
    
    mkdir -p "$HOME/.config/systemd/user"
    
    cat > "$HOME/.config/systemd/user/homelab-docker.service" << 'DOCKERSERVICEEOF'
[Unit]
Description=Homelab Docker Containers
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'cd $HOME/.local/share/dockge && docker compose up -d'
ExecStop=/bin/bash -c 'cd $HOME/.local/share/dockge && docker compose down'

[Install]
WantedBy=default.target
DOCKERSERVICEEOF
    
    systemctl --user daemon-reload
    systemctl --user enable homelab-docker.service
    
    echo "✓ Docker management user service created and enabled"
}

# Function to setup Ansible container for automation
setup_ansible_container() {
    echo "=== Setting up Ansible container for automation ==="
    
    mkdir -p "$HOME/.local/share/containers/ansible"
    cat > "$HOME/.local/share/containers/ansible/Containerfile" << 'ANSIBLEEOF'
FROM registry.fedoraproject.org/fedora:latest
RUN dnf install -y ansible-core python3-pip git && \
    pip3 install ansible-runner && \
    dnf clean all
WORKDIR /workspace
ANSIBLEEOF

    cd "$HOME/.local/share/containers/ansible"
    if docker build -t homelab-ansible .; then
        echo "✓ Ansible container built successfully"
        
        if [[ -f "$HOME/homelab/ansible/site.yml" ]]; then
            echo "Running Ansible playbook..."
            docker run --rm \
                -v "$HOME/homelab/ansible:/workspace:Z" \
                -v "$CONFIG_FILE:/workspace/config.json:Z" \
                homelab-ansible \
                ansible-playbook -i inventory/localhost site.yml --extra-vars "@config.json" || echo "Ansible playbook completed with warnings"
        else
            echo "No Ansible playbook found at $HOME/homelab/ansible/site.yml"
        fi
    else
        echo "⚠ Failed to build Ansible container"
    fi
}

# ===== MAIN EXECUTION STARTS HERE =====

echo "=== Starting Phase 2 Main Execution ==="

# Setup ZFS if requested
ZFS_SUCCESS=1
BASE_PATH=""

if [[ "$(get_config_value 'zfs_enabled')" == "true" ]]; then
    echo "ZFS setup requested..."
    
    LARGEST_DRIVE=$(find_largest_drive)
    
    if [[ $? -eq 0 && -n "$LARGEST_DRIVE" ]]; then
        if setup_zfs_pool "$LARGEST_DRIVE"; then
            ZFS_SUCCESS=0
            BASE_PATH="/homelab-drive"
            echo "✓ ZFS setup completed successfully"
            
            # Setup ZFS snapshots for media protection
            setup_zfs_snapshots
        else
            echo "✗ ZFS setup failed"
            ZFS_SUCCESS=1
        fi
    else
        echo "✗ Could not find a suitable drive for ZFS"
        ZFS_SUCCESS=1
    fi
else
    echo "ZFS not requested, skipping..."
    ZFS_SUCCESS=0
fi

# Set fallback path if ZFS failed or wasn't requested
if [[ $ZFS_SUCCESS -ne 0 || ! -d "/homelab-drive" ]]; then
    BASE_PATH="$HOME"
    echo "Using fallback directory: $BASE_PATH"
    
    # Create media structure in home directory as fallback
    mkdir -p "$BASE_PATH/media"
    local directories=(
        "media/books"
        "media/comics"
        "media/movies"
        "media/shows"
        "media/xxx"
        "media/audiobooks"
        "media/webvids"
        "media/downloads/incomplete"
        "media/downloads/complete"
        "media/music"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$BASE_PATH/$dir"
        echo "Created: $BASE_PATH/$dir"
    done
    
    chown -R 1000:1000 "$BASE_PATH/media"
    chmod -R 755 "$BASE_PATH/media"
fi

# Setup SAMBA with Docker (SAMBA not included in Bluefin)
if [[ "$(get_config_value 'smb_enabled')" == "true" ]]; then
    setup_samba_container "$BASE_PATH"
else
    echo "SAMBA not requested, skipping..."
fi

# Setup Dockge stack manager
setup_dockge "$BASE_PATH"

# Create Docker management service (user service only)
create_docker_management_service

# Create all the stacks
STACKS_PATH="$BASE_PATH/dockge/stacks"

# Create media stack (always create this one)
create_media_stack "$STACKS_PATH" "$BASE_PATH"

# Create audio stack
create_audio_stack "$STACKS_PATH" "$BASE_PATH"

# Create book stack
create_book_stack "$STACKS_PATH" "$BASE_PATH"

# Setup Ansible container for future automation
setup_ansible_container

# Mark setup as complete
echo "complete" > "$PHASE_FILE"
systemctl --user disable homelab-phase2.service

# Final status report
echo ""
echo "=== Homelab Setup Complete! ==="
echo "Phase 2 completed at $(date)"
echo ""

if [[ -d "/homelab-drive" ]]; then
    echo "✓ ZFS Configuration:"
    echo "  Pool: homelab-drive"
    echo "  Mount: /homelab-drive"
    echo "  Media: /homelab-drive/media"
    echo "  Snapshots: Weekly, keeps 3 (optimal for media)"
    echo "  Expected snapshot overhead: <5% of pool size"
    sudo zpool status homelab-drive | head -10
    echo ""
    
    echo "✓ ZFS Snapshot Status:"
    systemctl --user status zfs-snapshot.timer --no-pager
    echo ""
fi

SERVER_IP=$(ip route get 8.8.8.8 | head -1 | awk '{print $7}')

echo "✓ Dockge Stack Manager:"
echo "  URL: http://$SERVER_IP:5001"
echo "  Stacks: $STACKS_PATH"
echo ""

echo "✓ Media Stacks Created (use Dockge to start them):"
echo "  - Media Stack: Jellyfin, Sonarr, Radarr, Deluge, Prowlarr, Flaresolverr, Bazarr, Whisparr, Jellyseerr, FileBot"
echo "  - Audio Stack: Audiobookshelf, Lidarr, Navidrome"
echo "  - Book Stack: Readarr, Mylar3, Calibre, Calibre-web"
echo ""

echo "✓ Media Directory Structure:"
echo "  $BASE_PATH/media/books"
echo "  $BASE_PATH/media/comics" 
echo "  $BASE_PATH/media/movies"
echo "  $BASE_PATH/media/shows"
echo "  $BASE_PATH/media/xxx"
echo "  $BASE_PATH/media/audiobooks"
echo "  $BASE_PATH/media/webvids"
echo "  $BASE_PATH/media/music"
echo "  $BASE_PATH/media/downloads/{incomplete,complete}"
echo ""

if [[ "$(get_config_value 'smb_enabled')" == "true" ]]; then
    echo "✓ SAMBA Share Active:"
    echo "  Network: \\\\$SERVER_IP\\homelab-drive"
    echo "  Local: $BASE_PATH (includes all media folders)"
    echo "  Username: homelab"
    echo "  Password: homelab123"
    echo ""
    echo "  Your friend can access ALL media via:"
    echo "  Windows: \\\\$SERVER_IP\\homelab-drive\\media"
    echo "  Mac: smb://$SERVER_IP/homelab-drive/media"
    echo "  Linux: smb://$SERVER_IP/homelab-drive/media"
    echo ""
fi

echo "✓ Application Ports (access via http://$SERVER_IP:PORT):"
echo "  Dockge (Stack Manager):  5001"
echo "  Jellyfin (Media Server): 8096"
echo "  Sonarr (TV Shows):       8989"
echo "  Radarr (Movies):         7878"
echo "  Lidarr (Music):          8686"
echo "  Readarr (Books):         8787"
echo "  Prowlarr (Indexers):     9696"
echo "  Deluge (Downloads):      8112"
echo "  Bazarr (Subtitles):      6767"
echo "  Whisparr (Adult):        6969"
echo "  Jellyseerr (Requests):   5055"
echo "  FileBot (Organization):  5800"
echo "  Audiobookshelf:          13378"
echo "  Navidrome (Music):       4533"
echo "  Calibre (eBooks):        8080, 8081"
echo "  Calibre-web:             8083"
echo "  Mylar3 (Comics):         8090"
echo "  Flaresolverr:            8191"
echo ""

echo "✓ Next Steps:"
echo "  1. Visit http://$SERVER_IP:5001 to access Dockge"
echo "  2. Start the stacks you want to use (media-stack recommended first)"
echo "  3. Configure each application through their web interfaces"
echo "  4. Set up Prowlarr indexers first, then connect *arr apps to it"
echo "  5. Configure Deluge as download client in *arr apps"
echo "  6. Add media libraries in Jellyfin pointing to /media folders"
if [[ "$(get_config_value 'smb_enabled')" == "true" ]]; then
    echo "  7. Share \\\\$SERVER_IP\\homelab-drive with your friend"
fi
echo ""

if [[ -d "/homelab-drive" ]]; then
    echo "✓ ZFS Commands (for your reference):"
    echo "  Check pool status: sudo zpool status homelab-drive"
    echo "  List datasets: sudo zfs list -r homelab-drive"
    echo "  Manual snapshot: $HOME/.local/bin/zfs-snapshot.sh"
    echo "  List snapshots: sudo zfs list -t snapshot"
    echo ""
fi

echo "✓ Container Management:"
echo "  Check status: docker ps"
echo "  View logs: docker logs [container-name]"
echo "  Restart stack: cd $STACKS_PATH/[stack-name] && docker compose restart"
echo ""

echo "✓ Troubleshooting:"
echo "  System logs: journalctl --user -u homelab-phase2.service"
echo "  Phase 2 log: $LOG_FILE"
echo "  ZFS snapshot timer: systemctl --user status zfs-snapshot.timer"
echo "  Docker service: systemctl --user status homelab-docker.service"
echo ""

echo "🎉 Your homelab is ready! Enjoy your media hub with ZFS protection and Docker stack management."