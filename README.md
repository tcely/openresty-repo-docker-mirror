# openresty-repo-docker-mirror
Snapshots of the upstream repository signed by an ephemeral key

## OpenResty Debian Trixie Mirror Snapshots

Automated weekly snapshots of the official OpenResty APT repository (`amd64` and `arm64`), cryptographically verified against OpenResty's upstream signing key, re-indexed as a Debian **Trixie** (`Suites: trixie`) repository, and signed with an ephemeral **RSA 3072** OpenPGP key.

Each weekly GitHub Release provides a self-contained, multi-architecture `python:3.15-slim-trixie` Docker image serving the signed repository over HTTP, paired with the exact public signing keys and detached-signed checksums needed to verify and restore the snapshot at any point in the future.

---

### Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── weekly-release.yml   # Weekly build, verification, and immutable release workflow
├── docker/
│   ├── .dockerignore            # Allows only Dockerfile, openresty-mirror.asc, and openresty-upstream.asc
│   └── Dockerfile               # Multi-stage upstream verifier, Trixie indexer, and HTTP server
├── .gitignore                   # Ignores transient docker/*.asc keys during local builds
└── README.md
```

---

### Release Assets

Every weekly release (`vYYYY.MM.DD`) attaches the following immutable assets:

| Asset | Description |
| :--- | :--- |
| `openresty-trixie-repo-*.tar.zst` | Multi-stage `python:3.15-slim-trixie` Docker image archive compressed with `zstd` (`-19`). |
| `openresty-trixie-repo-*.tar.zst.sha256` | Tagged SHA-256 checksum (`SHA256 (...) = ...`) of the `.tar.zst` archive. |
| `openresty-trixie-repo-*.tar.zst.sha256.asc` | Detached ASCII-armored GPG signature of the `.tar.zst.sha256` file. |
| `openresty-trixie-repo-*.tar.sha256` | Tagged SHA-256 checksum of the uncompressed `.tar` image archive. |
| `openresty-trixie-repo-*.tar.sha256.asc` | Detached ASCII-armored GPG signature of the `.tar.sha256` file. |
| `openresty-mirror.asc` | Ephemeral RSA 3072 public key used to sign the Trixie repository (`Signed-By:` compatible). |
| `openresty-upstream.asc` | Upstream OpenResty public key used to verify origin packages at build time. |
| `openresty-keys.clearsigned.asc` | Clearsigned bundle containing both `openresty-mirror.asc` and `openresty-upstream.asc`. |

---

### Restoring and Verifying a Release

#### Verify Checksums and Signatures

Import `openresty-mirror.asc` into an isolated temporary keyring, verify both signed `.sha256` files, and validate the compressed and uncompressed archives:

```sh
set -euo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

# Import the release's mirror public key and verify the clearsigned key bundle
gpg --batch --import openresty-mirror.asc
gpg --batch --decrypt openresty-keys.clearsigned.asc >/dev/null

# Verify and check the compressed .tar.zst archive
gpg --batch --verify openresty-trixie-repo.tar.zst.sha256.asc openresty-trixie-repo.tar.zst.sha256
sha256sum -c openresty-trixie-repo.tar.zst.sha256

# Verify signature on the inner .tar checksum, decompress, check digest, and load into Docker
gpg --batch --verify openresty-trixie-repo.tar.sha256.asc openresty-trixie-repo.tar.sha256
zstd -d -c openresty-trixie-repo.tar.zst > "${WORK_DIR}/openresty-trixie-repo.tar"
(
  cd "${WORK_DIR}"
  sha256sum -c "${OLDPWD}/openresty-trixie-repo.tar.sha256"
)

docker load -i "${WORK_DIR}/openresty-trixie-repo.tar"
```

---

### Running the Repository Container

The container runs as unprivileged user `65534:65534` and uses `python3 -m http.server --directory /srv/repo` as its `ENTRYPOINT`, defaulting to `--bind 0.0.0.0 8080`.

#### Default Bind (`0.0.0.0:8080`)

```sh
docker run -d \
  --name openresty-repo \
  -p 8080:8080 \
  openresty-trixie-repo:v2026.11.14
```

#### Custom Bind Address and Port

Override `CMD` arguments directly to bind to a specific interface or port:

```sh
docker run -d \
  --name openresty-repo \
  --network host \
  openresty-trixie-repo:v2026.11.14 --bind 127.0.0.1 9000
```

#### Exposed Paths & Volume

* **APT Repository Root**: `http://<host>:8080/` (`dists/trixie/...` and `pool/openresty/...`)
* **Mirror Public Key**: `http://<host>:8080/openresty-mirror.asc` (also stored at `/etc/apt/keyrings/openresty-mirror.asc` inside the image)
* **Upstream Public Key**: `http://<host>:8080/openresty-upstream.asc` (also stored at `/etc/apt/keyrings/openresty-upstream.asc` inside the image)
* **Volume**: `/srv/repo` is declared as a `VOLUME` if you want to mount or inspect the repository tree directly.

---

### Configuring a Debian Trixie Client

Install `openresty-mirror.asc` into `/etc/apt/keyrings/` (either from the release artifact or directly from the running container) and add a DEB822 `.sources` file:

```sh
install -d -m 0755 -o 0 -g 0 /etc/apt/keyrings
install -m 0644 -o 0 -g 0 openresty-mirror.asc /etc/apt/keyrings/openresty-mirror.asc

cat <<'EOF' > /etc/apt/sources.list.d/openresty.sources
Types: deb
URIs: http://openresty-repo:8080
Suites: trixie
Components: openresty
Signed-By: /etc/apt/keyrings/openresty-mirror.asc
EOF
chmod 0644 /etc/apt/sources.list.d/openresty.sources

apt-get update
apt-get install -y --no-install-recommends openresty
```

---

### How the Build Pipeline Works

1. **Ephemeral Key Generation (`prepare-key` on `ubuntu-slim`)**: Generates a non-expiring RSA 3072 signing keypair in a temporary `GNUPGHOME`, fetches OpenResty's upstream public key, and creates `openresty-keys.clearsigned.asc`.
2. **Upstream Verification & Multi-Arch Build (`build` via `docker/github-builder`)**:
   * Stages `openresty-mirror.asc` and `openresty-upstream.asc` into the `./docker` build context (filtered via `docker/.dockerignore`) and passes the ephemeral private key via BuildKit `--mount=type=secret` so it is never written to image layers.
   * Verifies upstream `Release` signatures with `gpgv` against `openresty-upstream.asc` and checks every `Packages.gz` and `.deb` SHA-256 digest before indexing `Suites: trixie` (`amd64` + `arm64`) and signing `Release` / `InRelease`.
3. **End-to-End Test & Immutable Release (`publish-release` on `ubuntu-latest`)**:
   * Generates tagged `.sha256` files (`sha256sum --tag`) and detached `.asc` signatures for both `.tar` and `.tar.zst` (`zstd -T0 -19`).
   * Boots the built container and runs `apt-get update` inside a fresh `python:3.15-slim-trixie` container to verify Trixie `sqv` signature acceptance before creating a draft release (`--draft`) and publishing it as immutable (`--draft=false`).

