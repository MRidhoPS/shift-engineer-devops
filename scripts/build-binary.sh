#!/usr/bin/env bash

set -euo pipefail

OUTPUT="${OUTPUT:-build/server}"
VERSION_FILE="${VERSION_FILE:-.version}"

if [[ -n "${1:-}" ]]; then
    VERSION="$1"
else
    N=$(( $(cat "${VERSION_FILE}" 2>/dev/null || echo 0) + 1 ))
    echo "${N}" > "${VERSION_FILE}"
    VERSION="v${N}"
fi

echo "==> Building Go binary"
echo "    Version : ${VERSION}"
echo "    Output  : ${OUTPUT}"

mkdir -p "$(dirname "${OUTPUT}")"

CGO_ENABLED=0 \
GOOS=linux \
GOARCH=amd64 \
go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -o "${OUTPUT}" \
    ./cmd/server

echo "==> Build completed"

file "${OUTPUT}" 2>/dev/null || true
ls -lh "${OUTPUT}"