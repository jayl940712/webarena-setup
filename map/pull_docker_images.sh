echo "$(date): Pulling Docker images"
docker pull overv/openstreetmap-tile-server
docker pull mediagis/nominatim:4.2
docker pull ghcr.io/project-osrm/osrm-backend:v5.27.1

docker rm -f tile nominatim osrm-car osrm-bike osrm-foot 2>/dev/null || true

