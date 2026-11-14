#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORK_DIR}"
  docker rm -f openresty-repo-test >/dev/null 2>&1 || true
  docker network rm openresty-test-net >/dev/null 2>&1 || true
}
trap cleanup EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

printf '%s\n' "${GPG_PRIVATE_KEY}" | gpg --batch --import
FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"

# 1. Package each architecture rootfs into a Docker tar archive, checksum (--tag), compress, and sign
for arch in amd64 arm64; do
  SRC_DIR="${ROOTFS_DIR}/linux_${arch}"
  if [ ! -d "${SRC_DIR}" ]; then
    SRC_DIR="${ROOTFS_DIR}"
  fi
  test -d "${SRC_DIR}/srv/repo"

  IMAGE_REF="openresty-trixie-repo-${arch}:${RELEASE_TAG}"
  TAR_NAME="openresty-trixie-repo-${arch}-${RELEASE_TAG}.tar"

  tar -C "${SRC_DIR}" -cf - . | docker import \
    --platform "linux/${arch}" \
    --change 'USER 65534:65534' \
    --change 'EXPOSE 8080' \
    --change 'VOLUME ["/srv/repo"]' \
    --change 'ENTRYPOINT ["python3", "-m", "http.server", "--directory", "/srv/repo"]' \
    --change 'CMD ["--bind", "0.0.0.0", "8080"]' \
    - "${IMAGE_REF}"

  docker save -o "${ASSETS_DIR}/${TAR_NAME}" "${IMAGE_REF}"
  docker rmi "${IMAGE_REF}" >/dev/null

  (
    cd "${ASSETS_DIR}"

    sha256sum --tag "${TAR_NAME}" > "${TAR_NAME}.sha256"
    gpg --batch --yes --default-key "${FPR}" \
      --detach-sign --armor -o "${TAR_NAME}.sha256.asc" "${TAR_NAME}.sha256"

    zstd -T0 -19 --rm "${TAR_NAME}"

    ZST_NAME="${TAR_NAME}.zst"
    sha256sum --tag "${ZST_NAME}" > "${ZST_NAME}.sha256"
    gpg --batch --yes --default-key "${FPR}" \
      --detach-sign --armor -o "${ZST_NAME}.sha256.asc" "${ZST_NAME}.sha256"
  )
done

# 2. Verify all signatures, checksums, and round-trip .tar.zst load + live Trixie APT client test
(
  cd "${ASSETS_DIR}"
  gpg --batch --decrypt openresty-keys.clearsigned.asc >/dev/null

  for arch in amd64 arm64; do
    TAR_NAME="openresty-trixie-repo-${arch}-${RELEASE_TAG}.tar"
    ZST_NAME="${TAR_NAME}.zst"

    gpg --batch --verify "${ZST_NAME}.sha256.asc" "${ZST_NAME}.sha256"
    sha256sum -c "${ZST_NAME}.sha256"

    gpg --batch --verify "${TAR_NAME}.sha256.asc" "${TAR_NAME}.sha256"
    zstd -d -c "${ZST_NAME}" > "${WORK_DIR}/${TAR_NAME}"
    (
      cd "${WORK_DIR}"
      sha256sum -c "${ASSETS_DIR}/${TAR_NAME}.sha256"
    )
    rm -f "${WORK_DIR}/${TAR_NAME}"
  done
)

zstd -d -c "${ASSETS_DIR}/openresty-trixie-repo-amd64-${RELEASE_TAG}.tar.zst" | docker load

docker network create openresty-test-net >/dev/null
docker run -d \
  --name openresty-repo-test \
  --network openresty-test-net \
  "openresty-trixie-repo-amd64:${RELEASE_TAG}" --bind 0.0.0.0 8090 >/dev/null

docker run --rm \
  --network openresty-test-net \
  -v "${ASSETS_DIR}/openresty-mirror.asc:/etc/apt/keyrings/openresty-mirror.asc:ro" \
  python:3.15-slim-trixie \
  sh -euxc '
    cat <<EOF > /etc/apt/sources.list.d/openresty.sources
Types: deb
URIs: http://openresty-repo-test:8090
Suites: trixie
Components: openresty
Signed-By: /etc/apt/keyrings/openresty-mirror.asc
EOF
    apt-get update
    apt-cache policy openresty | grep -q "http://openresty-repo-test:8090 trixie/openresty"
  '

# 3. Create draft release and publish as immutable
NOTES=$(cat <<'EOF'
Self-contained OpenResty APT repository images for Debian Trixie (`amd64` and `arm64`) compressed with `zstd`, alongside:
- `openresty-mirror.asc` — Ephemeral RSA 3072 public signing key for APT `Signed-By:`
- `openresty-upstream.asc` — Upstream OpenResty public key used to verify origin packages at build time
- `openresty-keys.clearsigned.asc` — Clearsigned bundle containing both the mirror and upstream armored public key blocks
- Tagged SHA-256 checksums (`*.sha256`) and detached GPG signatures (`*.sha256.asc`) for both the `.tar` and `.tar.zst` image archives
EOF
)

gh release create "${RELEASE_TAG}" \
  "${ASSETS_DIR}"/* \
  --draft \
  --target "${GITHUB_SHA}" \
  --title "OpenResty Trixie Snapshot (${RELEASE_TAG})" \
  --notes "${NOTES}"

gh release edit "${RELEASE_TAG}" --draft=false
