#!/bin/bash
# Download the WebArena map backend data archives from the public AWS S3 bucket.

set -euo pipefail

BUCKET_NAME="${BUCKET_NAME:-webarena-map-server-data}"
AWS_REGION="${AWS_REGION:-us-east-2}"
OUTPUT_DIR="${1:-${OUTPUT_DIR:-/root}}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-true}"

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

validate_archive() {
    local file="$1"
    local path="${OUTPUT_DIR}/${file}"

    if tar -tf "$path" >/dev/null 2>&1; then
        return 0
    fi

    log "ERROR: ${path} is not a valid tar archive"
    log "This usually means the download returned an S3 error page instead of data."
    rm -f "$path"
    return 1
}

download_file() {
    local file="$1"
    local destination="${OUTPUT_DIR}/${file}"

    if [[ -s "$destination" && "$FORCE_DOWNLOAD" != "true" ]]; then
        if validate_archive "$file"; then
            log "Skipping ${file}; ${destination} already exists"
            return 0
        fi

        log "Retrying ${file}; removed invalid existing file"
    fi

    log "Downloading ${file} to ${destination}"
    retry download_with_aws "$file" "$destination"
    validate_archive "$file"
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

if ! command -v aws >/dev/null 2>&1; then
    log "ERROR: AWS CLI is required to download from s3://${BUCKET_NAME}"
    log "Install it first, then rerun this script."
    exit 1
fi

log "Downloading WebArena map data archives to ${OUTPUT_DIR}"
log "Existing archives will be overwritten by default"
log "Set FORCE_DOWNLOAD=false to reuse existing valid archives"

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

mkdir -p /var/lib/docker/volumes /opt/osm_dump /opt/osrm

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
