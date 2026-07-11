log() {
    echo "$(date): $*"
}

# Create 16GB swap file to handle large data extractions.
if [ ! -f /swapfile ]; then
    log "Creating 16GB swap file"
    fallocate -l 16G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# Check to fix permissions issues to nominatim data volume
# chown -R 101:103 /var/lib/docker/volumes/nominatim-data/_data
# chmod 700 /var/lib/docker/volumes/nominatim-data/_data

log "Starting Nominatim geocoding server..."
docker run --name nominatim --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --env=IMPORT_STYLE=extratags \
    --env=PBF_PATH=/nominatim/data/us-northeast-latest.osm.pbf \
    --env=IMPORT_WIKIPEDIA=/nominatim/data/wikimedia-importance.sql.gz \
    --volume=/opt/osm_dump/osm_dump:/nominatim/data \
    --volume=nominatim-data:/var/lib/postgresql/14/main \
    --volume=nominatim-flatnode:/nominatim/flatnode \
    -p 8085:8080 -d mediagis/nominatim:4.2 /app/start.sh

sleep 60

log "Starting OSRM routing servers..."

docker run --name osrm-car --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/car:/data -p 5000:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

sleep 30

docker run --name osrm-bike --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/bike:/data -p 5001:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

sleep 30

docker run --name osrm-foot --restart unless-stopped \
    --memory=4g --memory-swap=8g \
    --volume=/opt/osrm/foot:/data -p 5002:5000 -d \
    ghcr.io/project-osrm/osrm-backend:v5.27.1 osrm-routed --algorithm mld /data/us-northeast-latest.osrm

sleep 30 

log "All services started. Waiting for initialization..."

log "Verifying service health..."
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
