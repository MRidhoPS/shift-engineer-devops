#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-shift-engineer-devops}"
CONTAINER_BINARY="${CONTAINER_BINARY:-runtime/server}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"

BACKUP_FILE="${1:-}"

if [[ -z "${BACKUP_FILE}" ]]; then
    echo "Usage:"
    echo "  $0 <backup-file>"
    echo
    echo "Example:"
    echo "  $0 backups/server-20260927-104500"
    exit 1
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
    echo "ERROR: Backup file not found:"
    echo "  ${BACKUP_FILE}"
    exit 1
fi

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Container does not exist:"
    echo "  ${CONTAINER_NAME}"
    exit 1
fi

CONTAINER_ID_BEFORE="$(docker inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
IMAGE_ID_BEFORE="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")"

echo "========================================"
echo " Manual Rollback"
echo "========================================"

echo "Container : ${CONTAINER_NAME}"
echo "Backup    : ${BACKUP_FILE}"

echo
echo "==> Restoring binary"

install -m 0755 "${BACKUP_FILE}" "${CONTAINER_BINARY}.tmp"
mv -f "${CONTAINER_BINARY}.tmp" "${CONTAINER_BINARY}"

echo
echo "==> Restarting container"

docker restart "${CONTAINER_NAME}" >/dev/null

sleep 1

echo
echo "==> Running health check"

curl \
    --fail \
    --silent \
    --show-error \
    "${HEALTH_URL}"

echo

CONTAINER_ID_AFTER="$(docker inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
IMAGE_ID_AFTER="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")"

if [[ "${CONTAINER_ID_BEFORE}" != "${CONTAINER_ID_AFTER}" ]]; then
    echo "ERROR: Container ID changed."
    exit 1
fi

if [[ "${IMAGE_ID_BEFORE}" != "${IMAGE_ID_AFTER}" ]]; then
    echo "ERROR: Image ID changed."
    exit 1
fi

echo
echo "Rollback successful."
echo "Container ID unchanged: ${CONTAINER_ID_AFTER}"
echo "Image ID unchanged: ${IMAGE_ID_AFTER}"