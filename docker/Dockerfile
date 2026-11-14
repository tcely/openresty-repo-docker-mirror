# syntax=docker/dockerfile:1

FROM python:3.15-slim-trixie AS repo-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        ca-certificates \
        gnupg \
        gpgv \
        wget && \
    rm -rf /var/lib/apt/lists/*

# Copy both public keys from the default build context
COPY --chown=0:0 --chmod=0644 openresty-upstream.asc /etc/apt/keyrings/openresty-upstream.asc
COPY --chown=0:0 --chmod=0644 openresty-mirror.asc /etc/apt/keyrings/openresty-mirror.asc

RUN --mount=type=secret,id=apt_signing_key,required=true \
    set -eux; \
    WORK_DIR="$(mktemp -d)"; \
    trap 'rm -rf "${WORK_DIR}"' EXIT; \
    \
    export GNUPGHOME="${WORK_DIR}/gnupg"; \
    mkdir -m 0700 "${GNUPGHOME}"; \
    \
    gpg --batch --import /run/secrets/apt_signing_key; \
    FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"; \
    \
    # Sanity-check that /etc/apt/keyrings/openresty-mirror.asc matches the imported secret key
    CONTEXT_FPR="$(gpg --batch --with-colons --import-options show-only --import /etc/apt/keyrings/openresty-mirror.asc | awk -F: '/^fpr:/ {print $10; exit}')"; \
    test "${FPR}" = "${CONTEXT_FPR}"; \
    \
    BASE_URL='https://openresty.org'; \
    mkdir -p /srv/repo/pool/openresty; \
    cd /srv/repo; \
    \
    for arch in amd64 arm64; do \
        case "${arch}" in \
            amd64) REPO_PATH='/package/debian' ;; \
            arm64) REPO_PATH='/package/arm64/debian' ;; \
        esac; \
        UPSTREAM="${BASE_URL}${REPO_PATH}"; \
        \
        ARCH_TMP="$(mktemp -d "${WORK_DIR}/upstream-${arch}.XXXXXX")"; \
        wget -q -O "${ARCH_TMP}/Release" "${UPSTREAM}/dists/bookworm/Release"; \
        wget -q -O "${ARCH_TMP}/Release.gpg" "${UPSTREAM}/dists/bookworm/Release.gpg"; \
        \
        # 1. Verify upstream Release signature directly against /etc/apt/keyrings/openresty-upstream.asc
        gpgv --keyring /etc/apt/keyrings/openresty-upstream.asc \
            "${ARCH_TMP}/Release.gpg" "${ARCH_TMP}/Release"; \
        \
        # 2. Extract expected SHA-256 of openresty/binary-${arch}/Packages.gz from signed Release
        PKG_REL="openresty/binary-${arch}/Packages.gz"; \
        EXPECTED_PKG_SHA256="$(awk -v target="${PKG_REL}" '
            /^SHA256:/ { in_sha=1; next }
            /^[^ ]/ { in_sha=0 }
            in_sha && $3 == target { print $1; exit }
        ' "${ARCH_TMP}/Release")"; \
        test -n "${EXPECTED_PKG_SHA256}"; \
        \
        wget -q -O "${ARCH_TMP}/Packages.gz" "${UPSTREAM}/dists/bookworm/${PKG_REL}"; \
        printf '%s  %s\n' "${EXPECTED_PKG_SHA256}" "${ARCH_TMP}/Packages.gz" | sha256sum -c -; \
        \
        # 3. Extract every .deb Filename and SHA256 from verified Packages.gz, download, and verify
        gunzip -c "${ARCH_TMP}/Packages.gz" | awk '
            /^Filename:/ { f=$2 }
            /^SHA256:/   { s=$2 }
            /^$/         { if (f && s) print s, f; f=""; s="" }
            END          { if (f && s) print s, f }
        ' > "${ARCH_TMP}/debs.sha256"; \
        test -s "${ARCH_TMP}/debs.sha256"; \
        \
        while read -r expected_sha relpath; do \
            mkdir -p "/srv/repo/$(dirname "${relpath}")"; \
            wget -q -O "/srv/repo/${relpath}" "${UPSTREAM}/${relpath}"; \
            printf '%s  /srv/repo/%s\n' "${expected_sha}" "${relpath}" | sha256sum -c -; \
        done < "${ARCH_TMP}/debs.sha256"; \
        \
        rm -rf "${ARCH_TMP}"; \
        \
        # 4. Generate Trixie Packages index for this architecture
        mkdir -p "dists/trixie/openresty/binary-${arch}"; \
        apt-ftparchive --arch "${arch}" packages pool \
            > "dists/trixie/openresty/binary-${arch}/Packages"; \
        gzip -9c "dists/trixie/openresty/binary-${arch}/Packages" \
            > "dists/trixie/openresty/binary-${arch}/Packages.gz"; \
    done; \
    \
    # 5. Generate and sign Trixie Release / InRelease with ephemeral RSA 3072 key
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="OpenResty-Snapshot" \
        -o APT::FTPArchive::Release::Label="OpenResty-Trixie-Snapshot" \
        -o APT::FTPArchive::Release::Suite="trixie" \
        -o APT::FTPArchive::Release::Codename="trixie" \
        -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
        -o APT::FTPArchive::Release::Components="openresty" \
        release dists/trixie > dists/trixie/Release; \
    \
    gpg --batch --yes --default-key "${FPR}" \
        --detach-sign --armor -o dists/trixie/Release.gpg dists/trixie/Release; \
    gpg --batch --yes --default-key "${FPR}" \
        --clearsign -o dists/trixie/InRelease dists/trixie/Release


FROM python:3.15-slim-trixie

# Keep both public keys in /etc/apt/keyrings/ and also serve them from /srv/repo/ over HTTP
COPY --chown=0:0 --chmod=0644 openresty-upstream.asc /etc/apt/keyrings/openresty-upstream.asc
COPY --chown=0:0 --chmod=0644 openresty-mirror.asc /etc/apt/keyrings/openresty-mirror.asc
COPY --chown=0:0 --chmod=0644 openresty-upstream.asc /srv/repo/openresty-upstream.asc
COPY --chown=0:0 --chmod=0644 openresty-mirror.asc /srv/repo/openresty-mirror.asc

COPY --from=repo-builder --chown=0:0 --chmod=0644 /srv/repo /srv/repo
RUN find /srv/repo -type d -exec chmod 0755 {} +

VOLUME ["/srv/repo"]

USER 65534:65534
EXPOSE 8080

ENTRYPOINT ["python3", "-m", "http.server", "--directory", "/srv/repo"]
CMD ["--bind", "0.0.0.0", "8080"]
