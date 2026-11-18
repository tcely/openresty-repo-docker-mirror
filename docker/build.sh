#!/usr/bin/env bash

set -euxo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"

mkdir -m 0700 "${GNUPGHOME}"

APT_SIGNING_KEY_FILE="${APT_SIGNING_KEY_FILE:-/run/secrets/apt_signing_key}"
test -s "$APT_SIGNING_KEY_FILE"
gpg --batch --import "$APT_SIGNING_KEY_FILE"

FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit; }')"
CONTEXT_FPR="$(gpg --batch --with-colons --import-options show-only --import \
    /etc/apt/keyrings/openresty-mirror.asc | awk -F: '/^fpr:/ { print $10; exit; }')"
test "${FPR}" = "${CONTEXT_FPR}"

gpg --batch --dearmor \
  -o "${WORK_DIR}/openresty-upstream.gpg" \
  /etc/apt/keyrings/openresty-upstream.asc

BASE_URL='https://openresty.org'

mkdir -p /srv/repo/pool/openresty
cd /srv/repo

for arch in amd64 arm64
do
    case "${arch}" in
        (amd64) REPO_PATH='/package/debian' ;;
        (arm64) REPO_PATH='/package/arm64/debian' ;;
    esac

    UPSTREAM="${BASE_URL}${REPO_PATH}"
    ARCH_TMP="${WORK_DIR}/upstream-${arch}"

    mkdir -m 0700 "${ARCH_TMP}"

    PKG_REL="openresty/binary-${arch}/Packages.gz"

    aria2c \
        --force-sequential \
        --remote-time \
        --summary-interval=0 \
        --console-log-level=warn \
        --show-console-readout=false \
        --check-certificate=true \
        --min-tls-version=TLSv1.2 \
        --follow-metalink=false \
        --follow-torrent=false \
        --allow-overwrite=true \
        --auto-file-renaming=false \
        --max-tries=5 \
        --retry-wait=2 \
        --dir="${ARCH_TMP}" \
        "${UPSTREAM}/dists/bookworm/Release" \
        "${UPSTREAM}/dists/bookworm/Release.gpg" \
        "${UPSTREAM}/dists/bookworm/${PKG_REL}"

    gpgv --keyring "${WORK_DIR}/openresty-upstream.gpg" \
        "${ARCH_TMP}/Release.gpg" "${ARCH_TMP}/Release"

    _awk_prog='
        /^SHA256:/ { in_sha=1; next; }
        /^[^ ]/    { in_sha=0; }
        in_sha && $3 == target { print $1; exit; }
    '
    EXPECTED_PKG_SHA256="$(awk -v target="${PKG_REL}" "${_awk_prog}" "${ARCH_TMP}/Release")"
    [[ "${EXPECTED_PKG_SHA256}" =~ ^[0-9a-f]{64}$ ]]
    printf '%s *%s\n' "${EXPECTED_PKG_SHA256}" "${ARCH_TMP}/Packages.gz" | sha256sum -c -

    # Reject CR/NUL bytes in decompressed Packages metadata before parsing.
    gzip -cd "${ARCH_TMP}/Packages.gz" | tr -d '\r' | awk '
        /^Filename:/ { f=$2; }
        /^SHA256:/   { s=$2; }
        /^$/         { if (f && s) print s "\t" f; f=""; s=""; }
        END          { if (f && s) print s "\t" f; }
    ' > "${ARCH_TMP}/debs.tsv"
    test -s "${ARCH_TMP}/debs.tsv"

    set +x
    : > "${ARCH_TMP}/aria2.input"
    while IFS=$'\t' read -r expected_sha relpath extra
    do
        # Ensure strictly two tab-delimited columns.
        test -z "${extra:-}"

        # Validate SHA-256 digest format.
        [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]]

        # Validate relative path: strict pool/*.deb allowlist and no traversal.
        [[ "${relpath}" =~ ^pool/[A-Za-z0-9.+~/_-]+\.deb$ ]]
        [[ "${relpath}" != *"/../"* ]]

        TARGET_FILE="$(realpath -m "/srv/repo/${relpath}")"
        [[ "${TARGET_FILE}" == /srv/repo/pool/* ]]

        mkdir -p "$(dirname "${TARGET_FILE}")"
        printf '%s *%s\n' "${expected_sha}" "${TARGET_FILE}" >| "${TARGET_FILE}.sha256"
        printf '%s/%s\n' "${UPSTREAM}" "${relpath}" >| "${TARGET_FILE}.url"

        {
            cat "${TARGET_FILE}.url"
            printf '  out=%s\n' "${relpath}"
            printf '  checksum=sha-256=%s\n' "${expected_sha}"
        } >> "${ARCH_TMP}/aria2.input"
    done < "${ARCH_TMP}/debs.tsv"
    set -x

    aria2c \
        --remote-time \
        --summary-interval=0 \
        --console-log-level=warn \
        --show-console-readout=false \
        --check-certificate=true \
        --min-tls-version=TLSv1.2 \
        --follow-metalink=false \
        --follow-torrent=false \
        --dir=/srv/repo \
        --input-file="${ARCH_TMP}/aria2.input" \
        --max-concurrent-downloads=6 \
        --max-connection-per-server=2 \
        --min-split-size=1M \
        --auto-file-renaming=false \
        --allow-overwrite=true \
        --max-tries=5 \
        --retry-wait=2

    find /srv/repo/pool -name '*.sha256' -exec cat '{}' + | sha256sum -c --strict --quiet

    rm -rf "${ARCH_TMP}"

    mkdir -p "dists/trixie/openresty/binary-${arch}"
    apt-ftparchive --arch "${arch}" packages pool \
        >| "dists/trixie/openresty/binary-${arch}/Packages"
    gzip -9c "dists/trixie/openresty/binary-${arch}/Packages" \
        >| "dists/trixie/openresty/binary-${arch}/Packages.gz"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="OpenResty-Snapshot" \
    -o APT::FTPArchive::Release::Label="OpenResty-Trixie-Snapshot" \
    -o APT::FTPArchive::Release::Suite="trixie" \
    -o APT::FTPArchive::Release::Codename="trixie" \
    -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
    -o APT::FTPArchive::Release::Components="openresty" \
    -o APT::FTPArchive::Release::ValidTime=157680000 \
    release dists/trixie > dists/trixie/Release

gpg --batch --yes --default-key "${FPR}" \
    --detach-sign --armor -o dists/trixie/Release.gpg dists/trixie/Release
gpg --batch --yes --default-key "${FPR}" \
    --clearsign -o dists/trixie/InRelease dists/trixie/Release

install -m 0644 -o 0 -g 0 \
    /etc/apt/keyrings/openresty-upstream.asc \
    /srv/repo/openresty-upstream.asc
install -m 0644 -o 0 -g 0 \
    /etc/apt/keyrings/openresty-mirror.asc \
    /srv/repo/openresty-mirror.asc

find /srv/repo -type d -exec chmod 0755 {} +
find /srv/repo -type f -exec chmod 0644 {} +
