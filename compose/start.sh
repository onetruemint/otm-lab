#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

podman compose --env-file ${SCRIPT_DIR}/.env -f ${SCRIPT_DIR}/docker-compose.yml down

podman compose --env-file ${SCRIPT_DIR}/.env -f ${SCRIPT_DIR}/docker-compose.yml up -d
