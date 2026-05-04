echo "$(date): Starting tile server"
docker run --name tile --restart unless-stopped \
  --memory=2g --memory-swap=4g \
  --volume=osm-data:/data/database/ \
  --volume=osm-tiles:/data/tiles/ \
  -p 8080:80 \
  -d overv/openstreetmap-tile-server run

sleep 30

echo "$(date): Starting Nominatim"
docker run --name nominatim --restart unless-stopped \
  --memory=4g --memory-swap=8g \
  --env=IMPORT_STYLE=extratags \
  --env=PBF_PATH=/nominatim/data/us-northeast-latest.osm.pbf \
  --env=IMPORT_WIKIPEDIA=/nominatim/data/wikimedia-importance.sql.gz \
  --volume="$OSM_DUMP_DIR":/nominatim/data \
  --volume=nominatim-data:/var/lib/postgresql/14/main \
  --volume=nominatim-flatnode:/nominatim/flatnode \
  -p 8085:8080 \
  -d mediagis/nominatim:4.2 /app/start.sh

sleep 60

echo "$(date): Starting OSRM"

docker run --name osrm-car --restart unless-stopped \
  --memory=4g --memory-swap=8g \
  --volume="$OSRM_DIR/car":/data \
  -p 5000:5000 \
  -d ghcr.io/project-osrm/osrm-backend:v5.27.1 \
  osrm-routed --algorithm mld /data/us-northeast-latest.osrm

docker run --name osrm-bike --restart unless-stopped \
  --memory=4g --memory-swap=8g \
  --volume="$OSRM_DIR/bike":/data \
  -p 5001:5000 \
  -d ghcr.io/project-osrm/osrm-backend:v5.27.1 \
  osrm-routed --algorithm mld /data/us-northeast-latest.osrm

docker run --name osrm-foot --restart unless-stopped \
  --memory=4g --memory-swap=8g \
  --volume="$OSRM_DIR/foot":/data \
  -p 5002:5000 \
  -d ghcr.io/project-osrm/osrm-backend:v5.27.1 \
  osrm-routed --algorithm mld /data/us-northeast-latest.osrm

echo "$(date): Setup complete"
