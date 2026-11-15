#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

OUT_DIR="$(mktemp -d "${RUNNER_TEMP}/keys.XXXXXX")"
echo "out_dir=${OUT_DIR}" >> "${GITHUB_OUTPUT}"

# Expiration set to '0' (never expires) so archived releases remain valid in the future
gpg --batch --passphrase '' \
  --quick-generate-key "OpenResty Mirror (${RELEASE_TAG}) <admin@openresty.com>" \
  rsa3072 sign 0

# 1. Raw armored mirror public key (directly usable in APT Signed-By:)
gpg --batch --armor --export > "${OUT_DIR}/openresty-mirror.asc"

# 2. Fetch the current upstream OpenResty public key
BASE_URL='https://openresty.org'
KEY_PATH='/package/pubkey.gpg'
curl -fsSL "${BASE_URL}${KEY_PATH}" -o "${OUT_DIR}/openresty-upstream.asc"
test -s "${OUT_DIR}/openresty-upstream.asc"

# 3. Combine both armored public key blocks and clearsign with our mirror key
{
  printf '# OpenResty Mirror Public Key (%s)\n' "${RELEASE_TAG}"
  cat "${OUT_DIR}/openresty-mirror.asc"
  printf '\n# Upstream OpenResty Public Key\n'
  cat "${OUT_DIR}/openresty-upstream.asc"
} > "${WORK_DIR}/combined-keys.txt"

gpg --batch --yes --clearsign \
  -o "${OUT_DIR}/openresty-keys.clearsigned.asc" \
  "${WORK_DIR}/combined-keys.txt"

{
  echo "private_key<<EOF_GPG_PRIV"
  gpg --batch --armor --export-secret-keys
  echo "EOF_GPG_PRIV"

  echo "mirror_pub<<EOF_GPG_MIRROR"
  cat "${OUT_DIR}/openresty-mirror.asc"
  echo "EOF_GPG_MIRROR"

  echo "upstream_pub<<EOF_GPG_UPSTREAM"
  cat "${OUT_DIR}/openresty-upstream.asc"
  echo "EOF_GPG_UPSTREAM"
} >> "${GITHUB_OUTPUT}"
