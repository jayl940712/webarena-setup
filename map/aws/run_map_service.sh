log() {
    echo "$(date): $*"
}

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