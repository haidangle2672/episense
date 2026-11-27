#!/usr/bin/env bash
# Build website tĩnh (Astro) bằng container Node tạm. Node không chạy thường trực.
set -euo pipefail
cd "$(dirname "$0")/.."
NODE_IMAGE="${NODE_IMAGE:-node:26.13.1-slim}"
# --user: file sinh ra thuộc user hiện tại, không thuộc root
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/web:/app" -w /app "$NODE_IMAGE" \
  sh -c 'npm ci && npm run build'
echo 'Build xong: web/dist'