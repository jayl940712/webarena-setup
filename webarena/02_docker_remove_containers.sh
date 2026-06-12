#!/bin/bash

# Force removal makes reset repeat-safe when containers are stopped or missing.
docker rm -f shopping_admin forum gitlab shopping wikipedia openstreetmap-website-db-1 openstreetmap-website-web-1 2>/dev/null || true

