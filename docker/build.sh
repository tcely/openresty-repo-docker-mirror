#!/usr/bin/env bash

set -eux

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"

mkdir -m 0700 "${GNUPGHOME}"

gpg --batch --import /run/secrets/apt_signing_key

FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
CONTEXT_FPR="$(gpg --batch --with-colons --import-options show-only --import \
    /etc/apt/keyrings/openresty-mirror.asc | awk -F: '/^fpr:/ {print $10; exit}')"
test "${FPR}" = "${CONTEXT_FPR}"

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

    mkdir "${ARCH_TMP}"
    wget -q -O "${ARCH_TMP}/Release" "${UPSTREAM}/dists/bookworm/Release" &
    dl=$!
    wget -q -O "${ARCH_TMP}/Release.gpg" "${UPSTREAM}/dists/bookworm/Release.gpg"
    
    wait "${dl}"
    gpgv --keyring /etc/apt/keyrings/openresty-upstream.asc \
        "${ARCH_TMP}/Release.gpg" "${ARCH_TMP}/Release"

    PKG_REL="openresty/binary-${arch}/Packages.gz"

    wget -q -O "${ARCH_TMP}/Packages.gz" "${UPSTREAM}/dists/bookworm/${PKG_REL}" &
    dl=$!
    _awk_prog='
        /^SHA256:/ { in_sha=1; next; }
        /^[^ ]/    { in_sha=0; }
        in_sha && $3 == target { print $1; exit; }
        '
    EXPECTED_PKG_SHA256="$(awk -v target="${PKG_REL}" "${_awk_prog}" "${ARCH_TMP}/Release")"
    test -n "${EXPECTED_PKG_SHA256}"

    wait "${dl}"
    printf '%s *%s\n' "${EXPECTED_PKG_SHA256}" "${ARCH_TMP}/Packages.gz" | sha256sum -c -

    _awk_prog='
        /^Filename:/ { f=$2; }
        /^SHA256:/   { s=$2; }
        /^$/         { if (f && s) print s, f; f=""; s=""; }
        END          { if (f && s) print s, f; }
        '
    gzip -cd "${ARCH_TMP}/Packages.gz" | awk "${_awk_prog}" > "${ARCH_TMP}/debs.sha256"
    test -s "${ARCH_TMP}/debs.sha256"

    while read -r expected_sha relpath
    do
        mkdir -p "/srv/repo/$(dirname "${relpath}")"
        printf '%s */srv/repo/%s\n' "${expected_sha}" "${relpath}"  >| "/srv/repo/${relpath}.sha256"
        printf '%s/%s\n' "${UPSTREAM}" "${relpath}" >| "/srv/repo/${relpath}.url"
        wget -q -O "/srv/repo/${relpath}" "${UPSTREAM}/${relpath}" &
    done < "${ARCH_TMP}/debs.sha256"

    wait
    find /srv/repo -name '*.sha256' -exec cat '{}' + | sha256sum -c -w --strict
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
    release dists/trixie > dists/trixie/Release

gpg --batch --yes --default-key "${FPR}" \
    --detach-sign --armor -o dists/trixie/Release.gpg dists/trixie/Release
gpg --batch --yes --default-key "${FPR}" \
    --clearsign -o dists/trixie/InRelease dists/trixie/Release

install -m 0644 -o 0 -g 0 /etc/apt/keyrings/openresty-upstream.asc /srv/repo/openresty-upstream.asc
install -m 0644 -o 0 -g 0 /etc/apt/keyrings/openresty-mirror.asc /srv/repo/openresty-mirror.asc

find /srv/repo -type d -exec chmod 0755 {} +
find /srv/repo -type f -exec chmod 0644 {} +
