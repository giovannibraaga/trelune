#!/bin/bash
# Builds and starts the always-on MCP containers and makes Docker (Colima) start at login.
set -euo pipefail
cd "$(dirname "$0")"
command -v colima >/dev/null || { echo "Instale o Colima: brew install colima docker docker-compose"; exit 1; }
brew services start colima >/dev/null   # starts the Docker VM at every login
colima status >/dev/null 2>&1 || colima start
docker compose up -d --build
docker exec trelune-mcp node /app/server.mjs --check-network
