#!/bin/bash
# Download the WebArena map backend data archives from the public AWS S3 bucket.

set -euo pipefail

BUCKET_NAME="${BUCKET_NAME:-webarena-map-server-data}"
AWS_REGION="${AWS_REGION:-us-east-2}"
OUTPUT_DIR="${1:-${OUTPUT_DIR:-/root}}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-false}"

FILES=(
    "nominatim_volumes.tar"
    "osm_dump.tar"
    "osrm_routing.tar"
)

log() {
    echo "$(date): $*"
}

retry() {
    local n=1
    local max="${RETRY_MAX:-5}"
    local delay="${RETRY_DELAY:-30}"

    while true; do
        "$@" && break || {
            if [[ "$n" -lt "$max" ]]; then
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

download_with_aws() {
    local file="$1"
    local destination="$2"

    aws s3 cp \
        --no-sign-request \
        --region "$AWS_REGION" \
        "s3://${BUCKET_NAME}/${file}" \
        "$destination"
}

download_with_http() {
    local file="$1"
    local destination="$2"
    local url="https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${file}"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-delay 10 -o "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        log "ERROR: aws, curl, or wget is required to download ${file}"
        return 1
    fi
}

download_file() {
    local file="$1"
    local destination="${OUTPUT_DIR}/${file}"

    if [[ -s "$destination" && "$FORCE_DOWNLOAD" != "true" ]]; then
        log "Skipping ${file}; ${destination} already exists"
        return 0
    fi

    log "Downloading ${file} to ${destination}"
    if command -v aws >/dev/null 2>&1; then
        retry download_with_aws "$file" "$destination"
    else
        retry download_with_http "$file" "$destination"
    fi
}

wait_for_download() {
    local pid="$1"
    local file="$2"

    if wait "$pid"; then
        log "OK: ${file} downloaded"
    else
        log "ERROR: ${file} download failed"
        return 1
    fi
}

mkdir -p "$OUTPUT_DIR"

log "Downloading WebArena map data archives to ${OUTPUT_DIR}"
log "Set FORCE_DOWNLOAD=true to overwrite existing archives"

declare -a DOWNLOAD_PIDS=()
declare -a DOWNLOAD_FILES=()

for file in "${FILES[@]}"; do
    download_file "$file" &
    DOWNLOAD_PIDS+=("$!")
    DOWNLOAD_FILES+=("$file")
done

for idx in "${!DOWNLOAD_PIDS[@]}"; do
    wait_for_download "${DOWNLOAD_PIDS[$idx]}" "${DOWNLOAD_FILES[$idx]}"
done

log "All WebArena map data archives downloaded"

log "Extracting Nominatim Docker volumes..."
tar -C /var/lib/docker/volumes --strip-components=5 -xf "${OUTPUT_DIR}/nominatim_volumes.tar"
log "OK: Nominatim Docker volumes extracted"

log "Extracting OSM dump..."
tar -C /opt/osm_dump -xf "${OUTPUT_DIR}/osm_dump.tar"
log "OK: OSM dump extracted"

log "Extracting OSRM routing data..."
tar -C /opt/osrm -xf "${OUTPUT_DIR}/osrm_routing.tar"
log "OK: OSRM routing data extracted"

log "All WebArena map data archives extracted"
