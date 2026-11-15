#!/usr/bin/env bash

set -euo pipefail

: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${AGE_KEY_MONTH:?AGE_KEY_MONTH is required}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"

if [[ ! "${AGE_KEY_MONTH}" =~ ^(0[1-9]|1[0-2])$ ]]; then
    echo '::error::AGE_KEY_MONTH must be a month from 01 through 12.'
    exit 1
fi

command -v age >/dev/null
command -v gpg >/dev/null

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

OUT_DIR="$(mktemp -d "${RUNNER_TEMP}/keys.XXXXXX")"
echo "out_dir=${OUT_DIR}" >> "${GITHUB_OUTPUT}"

# The signing key is ephemeral for this workflow run.
gpg --batch --passphrase '' \
    --quick-generate-key \
    "OpenResty Mirror (${RELEASE_TAG}) <admin@openresty.com>" \
    rsa3072 sign 0

FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')"
test -n "${FPR}"

# Export only the public mirror key for publication.
gpg --batch --armor --export "${FPR}" > "${OUT_DIR}/openresty-mirror.asc"

# Fetch the current upstream OpenResty public key.
BASE_URL='https://openresty.org'
KEY_PATH='/package/pubkey.gpg'
curl --retry -fsSL "${BASE_URL}${KEY_PATH}" -o "${OUT_DIR}/openresty-upstream.asc"
test -s "${OUT_DIR}/openresty-upstream.asc"

# Combine the public keys and clearsign the bundle with the mirror key.
{
    printf '# OpenResty Mirror Public Key (%s)\n' "${RELEASE_TAG}"
    cat "${OUT_DIR}/openresty-mirror.asc"
    printf '\n# Upstream OpenResty Public Key\n'
    cat "${OUT_DIR}/openresty-upstream.asc"
} > "${WORK_DIR}/combined-keys.txt"

gpg --batch --yes --clearsign \
  --local-user "${FPR}" \
  --output "${OUT_DIR}/openresty-keys.clearsigned.asc" \
  "${WORK_DIR}/combined-keys.txt"

# Export the private signing key to a temporary file, then encrypt it.
gpg --batch --armor --export-secret-keys "${FPR}" > "${WORK_DIR}/apt-signing-key.asc"
age -r "${AGE_RECIPIENT}" \
    -o "${WORK_DIR}/apt-signing-key.age" \
    "${WORK_DIR}/apt-signing-key.asc"
rm -f "${WORK_DIR}/apt-signing-key.asc"

# Emit a collision-resistant multiline output delimiter.
emit_output() {
    local name="$1"
    local file="$2"
    local delimiter
    delimiter="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

    {
        printf '%s<<%s\n' "${name}" "${delimiter}"
        cat "${file}"
        printf '%s\n' "${delimiter}"
    } >> "${GITHUB_OUTPUT}"
}

emit_output age_encrypted_private_key "${WORK_DIR}/apt-signing-key.age"
emit_output gpg_mirror_pub "${OUT_DIR}/openresty-mirror.asc"
emit_output gpg_upstream_pub "${OUT_DIR}/openresty-upstream.asc"
echo "age_key_month=${AGE_KEY_MONTH}" >> "${GITHUB_OUTPUT}"
