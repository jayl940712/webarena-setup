#!/usr/bin/env bash

DATA_ROOT="/webarena"
DOCKER_ROOT="/dockerroot"
DOCKER_VOLUMES="$DOCKER_ROOT/volumes"
MAP_SETUP_DIR="$DATA_ROOT/map_setup_data"
OSM_DUMP_DIR="$DATA_ROOT/osm_dump"
OSRM_DIR="$DATA_ROOT/osrm"

echo "$(date): Creating directories"
mkdir -p "$DOCKER_VOLUMES" "$OSM_DUMP_DIR" "$OSRM_DIR"

tar -C "$DOCKER_VOLUMES" --strip-components=5 -xf $MAP_SETUP_DIR/osm_tile_server.tar
rm -f $MAP_SETUP_DIR/osm_tile_server.tar

tar -C "$DOCKER_VOLUMES" --strip-components=5 -xf $MAP_SETUP_DIR/nominatim_volumes.tar
rm -f $MAP_SETUP_DIR/nominatim_volumes.tar

echo "$(date): Extracting OSM dump"
tar -C "$OSM_DUMP_DIR" -xf $MAP_SETUP_DIR/osm_dump.tar
rm -f $MAP_SETUP_DIR/osm_dump.tar

echo "$(date): Extracting OSRM data"
tar -C "$OSRM_DIR" -xf $MAP_SETUP_DIR/osrm_routing.tar
rm -f $MAP_SETUP_DIR/osrm_routing.tar
