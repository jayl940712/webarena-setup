#!/bin/bash
# WebArena Map Backend Server startup script for AWS user data.
# Sets up tile server, geocoding server, and routing servers.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
    echo "$(date): $*"
}

wait_for_apt_locks() {
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log "Waiting for dpkg lock..."
        sleep 5
    done

    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        log "Waiting for apt lock..."
        sleep 5
    done
}

resolve_docker_pkg_conflicts() {
    # Some AMIs ship Docker CE packages (containerd.io) which conflict with
    # Ubuntu's docker.io dependency chain (containerd).
    local held_packages
    held_packages="$(apt-mark showhold || true)"
    for pkg in containerd containerd.io docker.io docker-ce docker-ce-cli; do
        if echo "$held_packages" | grep -qx "$pkg"; then
            log "Removing apt hold on $pkg"
            apt-mark unhold "$pkg" || true
        fi
    done

    if dpkg -s containerd.io >/dev/null 2>&1; then
        log "Detected containerd.io; removing Docker CE packages to install docker.io"
        wait_for_apt_locks
        apt-get remove -y containerd.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin || true
        wait_for_apt_locks
        apt-get autoremove -y || true
    fi
}

log "Starting WebArena map server startup setup"

# Configure APT with retry logic and better error handling.
cat > /etc/apt/apt.conf.d/99webarena-retries <<'EOF'
APT::Acquire::Retries "3";
APT::Acquire::http::Timeout "30";
APT::Acquire::https::Timeout "30";
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
EOF

# Create 4GB swap file to handle large data extractions.
if [ ! -f /swapfile ]; then
    log "Creating 4GB swap file"
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

wait_for_apt_locks
apt-get update
wait_for_apt_locks
resolve_docker_pkg_conflicts
if ! apt-get install -y docker.io curl wget htop unzip; then
    log "Initial package install failed, trying to repair dependencies and retry"
    wait_for_apt_locks
    apt-get -f install -y || true
    wait_for_apt_locks
    apt-get install -y docker.io curl wget htop unzip
fi

# Enable and start Docker with retries.
systemctl enable docker
systemctl start docker
sleep 10

# Add ubuntu user to docker group when present.
if id ubuntu >/dev/null 2>&1; then
    usermod -aG docker ubuntu
fi

# Create necessary directories.
mkdir -p /opt/osm_dump /opt/osrm /var/lib/docker/volumes /root/logs

# Install AWS CLI v2.
if ! command -v aws >/dev/null 2>&1; then
    log "Installing AWS CLI v2"
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# Configure AWS CLI for public S3 access.
mkdir -p /root/.aws
cat > /root/.aws/config <<'EOF'
[default]
region = us-east-2
output = json
EOF

# Create a comprehensive bootstrap script that runs in the background.
cat > /root/bootstrap.sh <<'BOOTSTRAP_EOF'
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/webarena-map-bootstrap.log) 2>&1

log() {
    echo "$(date): $*"
}

log "Starting WebArena map server bootstrap"
log "System info: $(uname -a)"
log "Available memory: $(free -h)"
log "Available disk space: $(df -h)"

# Check if there is enough disk space. The data load needs at least 200GB free.
AVAILABLE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
log "Available disk space: ${AVAILABLE_GB}GB"
if [ "$AVAILABLE_GB" -lt 200 ]; then
    log "ERROR: Insufficient disk space. Need at least 200GB, have ${AVAILABLE_GB}GB"
    exit 1
fi

retry() {
    local n=1
    local max=5
    local delay=30

    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                log "Command failed. Attempt $n/$max. Waiting ${delay}s..."
                sleep "$delay"
                delay=$((delay * 2))
            else
                log "Command failed after $n attempts: $*"
                return 1
            fi
        }
    done
}

monitor_extraction() {
    local pid=$1
    local desc=$2

    log "Monitoring $desc (PID: $pid)"
    while kill -0 "$pid" 2>/dev/null; do
        log "$desc still running..."
        sleep 60
    done

    wait "$pid"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        log "OK: $desc completed successfully"
    else
        log "ERROR: $desc failed with exit code $exit_code"
        return "$exit_code"
    fi
}

log "Starting data downloads..."

log "Downloading OSM tile server data..."
retry aws s3 cp --no-sign-request s3://webarena-map-server-data/osm_tile_server.tar /root/osm_tile_server.tar &
DOWNLOAD_TILE_PID=$!

log "Downloading Nominatim data..."
retry aws s3 cp --no-sign-request s3://webarena-map-server-data/nominatim_volumes.tar /root/nominatim_volumes.tar &
DOWNLOAD_NOM_PID=$!

log "Downloading OSM dump..."
retry aws s3 cp --no-sign-request s3://webarena-map-server-data/osm_dump.tar /root/osm_dump.tar &
DOWNLOAD_DUMP_PID=$!

log "Downloading OSRM routing data..."
retry aws s3 cp --no-sign-request s3://webarena-map-server-data/osrm_routing.tar /root/osrm_routing.tar &
DOWNLOAD_OSRM_PID=$!

log "Waiting for downloads to complete..."
monitor_extraction "$DOWNLOAD_TILE_PID" "OSM tile server download"
monitor_extraction "$DOWNLOAD_NOM_PID" "Nominatim download"
monitor_extraction "$DOWNLOAD_DUMP_PID" "OSM dump download"
monitor_extraction "$DOWNLOAD_OSRM_PID" "OSRM routing download"

log "All downloads completed. Starting extractions..."

log "Extracting OSM tile server data..."
tar -C /var/lib/docker/volumes --strip-components=5 -xf /root/osm_tile_server.tar
rm -f /root/osm_tile_server.tar
log "OK: OSM tile server data extracted and cleaned up"

log "Extracting Nominatim data..."
tar -C /var/lib/docker/volumes --strip-components=5 -xf /root/nominatim_volumes.tar
rm -f /root/nominatim_volumes.tar
log "OK: Nominatim data extracted and cleaned up"

log "Extracting OSM dump..."
tar -C /opt/osm_dump -xf /root/osm_dump.tar
rm -f /root/osm_dump.tar
log "OK: OSM dump extracted and cleaned up"

log "Extracting OSRM routing data..."
tar -C /opt/osrm -xf /root/osrm_routing.tar
rm -f /root/osrm_routing.tar
log "OK: OSRM routing data extracted and cleaned up"

log "Verifying extracted data..."
ls -la /var/lib/docker/volumes/ | head -20
ls -la /opt/osm_dump/ | head -10
ls -la /opt/osrm/ | head -10

log "Pulling Docker images..."
docker pull overv/openstreetmap-tile-server
docker pull mediagis/nominatim:4.2
docker pull ghcr.io/project-osrm/osrm-backend:v5.27.1

log "Starting tile server..."
docker run --name tile --restart unless-stopped \
    --memory=2g --memory-swap=4g \
    --volume=osm-data:/data/database/ --volume=osm-tiles:/data/tiles/ \
    -p 8080:80 -d overv/openstreetmap-tile-server run

sleep 30

log "Starting Nominatim geocoding server..."
docker run --name nominatim --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --env=IMPORT_STYLE=extratags \
    --env=PBF_PATH=/nominatim/data/us-northeast-latest.osm.pbf \
    --env=IMPORT_WIKIPEDIA=/nominatim/data/wikimedia-importance.sql.gz \
    --volume=/opt/osm_dump:/nominatim/data \
    --volume=nominatim-data:/var/lib/postgresql/14/main \
    --volume=nominatim-flatnode:/nominatim/flatnode \
    -p 8085:8080 -d mediagis/nominatim:4.2 /app/start.sh

sleep 60

log "Starting OSRM routing servers..."

docker run --name osrm-car --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/car:/data -p 5000:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

docker run --name osrm-bike --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/bike:/data -p 5001:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

docker run --name osrm-foot --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/foot:/data -p 5002:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

log "All services started. Waiting for initialization..."
sleep 120

log "Verifying service health..."
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

log "Testing service endpoints..."

if curl -f -s -o /dev/null "http://localhost:8080/tile/0/0/0.png"; then
    log "OK: Tile server is responding"
else
    log "ERROR: Tile server is not responding"
fi

if curl -f -s -o /dev/null "http://localhost:8085/search?q=test&format=json&limit=1"; then
    log "OK: Nominatim is responding"
else
    log "ERROR: Nominatim is not responding"
fi

for service in car bike foot; do
    case "$service" in
        car) port=5000 ;;
        bike) port=5001 ;;
        foot) port=5002 ;;
    esac

    if curl -f -s -o /dev/null "http://localhost:$port/route/v1/$service/-79.9959,40.4406;-79.9,40.45?overview=false"; then
        log "OK: OSRM $service routing is responding"
    else
        log "ERROR: OSRM $service routing is not responding"
    fi
done

log "Bootstrap completed!"
log "Final service status:"
docker ps
log "Available disk space after cleanup:"
df -h
log "Memory usage:"
free -h

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)

log "Services are available at:"
echo "  - Tile server: http://${PUBLIC_IP}:8080/tile/{z}/{x}/{y}.png"
echo "  - Geocoding: http://${PUBLIC_IP}:8085/"
echo "  - OSRM Car: http://${PUBLIC_IP}:5000/"
echo "  - OSRM Bike: http://${PUBLIC_IP}:5001/"
echo "  - OSRM Foot: http://${PUBLIC_IP}:5002/"

log "Bootstrap script completed successfully!"
BOOTSTRAP_EOF

chmod +x /root/bootstrap.sh
nohup /root/bootstrap.sh > /var/log/webarena-map-bootstrap.log 2>&1 &

cat > /root/cloud-init-completed <<EOF
Cloud-init completed at $(date)
Bootstrap script started in background
Check /var/log/webarena-map-bootstrap.log for progress
EOF
chmod 0644 /root/cloud-init-completed

log "WebArena map server startup setup completed"
log "Bootstrap script is running in background."
log "Check /var/log/webarena-map-bootstrap.log for progress."
