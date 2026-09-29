#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-shift-engineer-devops}"
BINARY="${1:-build/server}"
CONTAINER_BINARY="${CONTAINER_BINARY:-runtime/server}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-backups}"
BACKUP_FILE="${BACKUP_DIR}/server-${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

echo "========================================"
echo " Binary Hotfix Deployment"
echo "========================================"

if [[ ! -f "${BINARY}" ]]; then
    echo "ERROR: Binary not found: ${BINARY}"
    exit 1
fi

if [[ ! -f "${CONTAINER_BINARY}" ]]; then
    echo "ERROR: Active binary not found: ${CONTAINER_BINARY}"
    exit 1
fi

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Container does not exist: ${CONTAINER_NAME}"
    exit 1
fi

CONTAINER_ID_BEFORE="$(docker inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
IMAGE_ID_BEFORE="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")"

echo "Container : ${CONTAINER_NAME}"
echo "Container ID : ${CONTAINER_ID_BEFORE}"
echo "Image ID     : ${IMAGE_ID_BEFORE}"
echo

echo "==> Backing up current binary"

cp "${CONTAINER_BINARY}" "${BACKUP_FILE}"

echo "Backup created:"
echo "  ${BACKUP_FILE}"

echo
echo "==> Replacing binary"

install -m 0755 "${BINARY}" "${CONTAINER_BINARY}.tmp"
mv -f "${CONTAINER_BINARY}.tmp" "${CONTAINER_BINARY}"

echo "Binary replaced successfully."

echo
echo "==> Restarting container"

docker restart "${CONTAINER_NAME}" >/dev/null

echo "Container restarted."

echo
echo "==> Waiting for application"

sleep 1

echo
echo "==> Checking application health"

if ! curl --fail --silent --show-error "${HEALTH_URL}"; then
    echo
    echo "ERROR: Health check failed."
    echo "The hotfix will be rolled back automatically."

    install -m 0755 "${BACKUP_FILE}" "${CONTAINER_BINARY}.tmp"
    mv -f "${CONTAINER_BINARY}.tmp" "${CONTAINER_BINARY}"

    docker restart "${CONTAINER_NAME}" >/dev/null

    sleep 1

    echo "Rollback completed."

    exit 1
fi

echo

CONTAINER_ID_AFTER="$(docker inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
IMAGE_ID_AFTER="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")"

echo
echo "==> Verifying container identity"

if [[ "${CONTAINER_ID_BEFORE}" != "${CONTAINER_ID_AFTER}" ]]; then
    echo "ERROR: Container ID changed."
    exit 1
fi

echo "Container ID unchanged: ${CONTAINER_ID_AFTER}"

if [[ "${IMAGE_ID_BEFORE}" != "${IMAGE_ID_AFTER}" ]]; then
    echo "ERROR: Image ID changed."
    exit 1
fi

echo "Image ID unchanged: ${IMAGE_ID_AFTER}"

echo
echo "========================================"
echo " Hotfix deployment successful"
echo "========================================"