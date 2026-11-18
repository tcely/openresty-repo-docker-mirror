#!/usr/bin/env bash

set -euo pipefail

SOURCES_FILE="/etc/apt/sources.list.d/openresty.sources"
KEY_FILENAME="openresty-mirror.asc"
KEYRING_PATH="/etc/apt/keyrings/${KEY_FILENAME}"
GITHUB_BASE_URL="$(printf '%s://%s/%s/%s' 'https' 'github.com' 'tcely' 'openresty-repo-docker-mirror')"

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "Error: APT source file not found: ${SOURCES_FILE}" >&2
    exit 1
fi

MIRROR_BASE_URL="$(awk '/^URIs:/ { print $2; exit }' "$SOURCES_FILE")"
if [[ -z "$MIRROR_BASE_URL" ]]; then
    echo "Error: No URIs entry found in ${SOURCES_FILE}" >&2
    exit 1
fi

MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fetch() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo "Error: curl or wget is required." >&2
        exit 1
    fi
}

# Fetch candidate key from the mirror's root path to discover the tag
MIRROR_KEY="${WORK_DIR}/mirror.asc"
fetch "${MIRROR_BASE_URL}/${KEY_FILENAME}" "$MIRROR_KEY"

# Extract the vYYYY.0MM.DD tag from the key's User ID packet
UID_STR="$(gpg --batch --with-colons --import-options show-only --import "$MIRROR_KEY" 2>/dev/null \
    | awk -F: '$1 == "uid" { print $10; exit }')"

if [[ "$UID_STR" =~ \((v[0-9]{4}\.[0-9]{3}\.[0-9]{2})\) ]]; then
    TAG="${BASH_REMATCH[1]}"
else
    echo "Error: Could not extract valid vYYYY.0MM.DD tag from key UID: '${UID_STR}'" >&2
    exit 1
fi

# Fetch the authoritative key for that tag from GitHub Releases over HTTPS
TRUSTED_KEY="${WORK_DIR}/trusted.asc"
fetch "${GITHUB_BASE_URL}/releases/download/${TAG}/${KEY_FILENAME}" "$TRUSTED_KEY"

# Atomically install the authoritative key into /etc/apt/keyrings
install -d -m 0755 -o 0 -g 0 /etc/apt/keyrings
install -m 0644 -o 0 -g 0 "$TRUSTED_KEY" "$KEYRING_PATH"
