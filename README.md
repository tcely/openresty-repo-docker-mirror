# openresty-repo-docker-mirror

Weekly signed snapshots of the official OpenResty APT repository for Debian Trixie, `amd64` and `arm64`, packaged as `python:3.15-slim-trixie` Docker images.

---

## What This Repository Produces

Every Tuesday at 18:03 UTC, a workflow fetches the upstream OpenResty repository, verifies it, re-indexes it under the `trixie` suite, and signs the index with a freshly generated RSA 3072 key. It then publishes a GitHub Release tagged `vYYYY.MM.DD`. Each release contains a Docker image archive that serves the signed repository over HTTP, along with the public keys and checksums needed to verify and restore it.

**Each release is signed by a different key.** A new signing key is generated on every workflow run, so clients must install the `openresty-mirror.asc` from the same release they are installing packages from. A key from an earlier release will not validate later snapshots.

### Release Assets

The image archive is published as `openresty-trixie-repo-<arch>-<tag>.tar.zst`, compressed with `zstd -11`. Its checksum and signature files are `.tar.zst.sha256` and `.tar.zst.sha256.asc`.

The release also includes `openresty-trixie-repo-<arch>-<tag>.tar.sha256` and `.tar.sha256.asc`, which cover the uncompressed `.tar`. **The `.tar.sha256` and `.tar.sha256.asc` files are published without their `.tar` files.** The `.tar` is deleted after compression, so you must decompress the `.tar.zst` to recreate it before checking the `.tar.sha256` file.

The public keys `openresty-mirror.asc` (the signing key), `openresty-upstream.asc` (OpenResty's key), and `openresty-keys.clearsigned.asc` (a clearsigned bundle containing both) are attached to each release. The mirror public key and the upstream public key are also embedded in the image.

Releases are immutable. Once published, their assets cannot be changed.

---

## Build Pipeline

The workflow `.github/workflows/weekly-release.yml` runs on a weekly cron (`3 18 * * 2`) and executes three jobs in order.

1. **`prepare-key`** runs `scripts/prepare-keys.sh` on `ubuntu-slim`. It generates an RSA 3072 sign-only key with no expiration in a temporary `GNUPGHOME`, fetches the upstream key from `https://openresty.org/package/pubkey.gpg`, and creates the clearsigned bundle `openresty-keys.clearsigned.asc`. It exports the private key, mirror public key, and upstream public key as job outputs, which are passed to later jobs. The three key files are also uploaded as a workflow artifact.
2. **`build`** calls the reusable `docker/github-builder` workflow with `target: 'artifact'`, `output: local`, and `platforms: linux/amd64,linux/arm64`. The private signing key is passed to the build as the `apt_signing_key` BuildKit secret.
3. **`publish-release`** runs `scripts/publish-release.sh` on `ubuntu-latest`. It builds the release images, runs the smoke test, compresses and checksums the archives, signs them, and verifies them. It then creates a draft release, uploads the assets, and publishes the release, which makes it immutable.

### Build Paths

Both Dockerfile targets produce the same final image. The release workflow uses the `artifact` path because the reusable Docker builder workflow requires an artifact archive for Debian images.

The `artifact` target of `docker/Dockerfile` contains only `/repo-artifact.tar`, a tarball of `etc/apt` and `srv` produced by the `artifact-builder` stage. `scripts/publish-release.sh` copies that tarball into `docker/` and builds the release image with `docker/Dockerfile.from-artifact`. This is the path used for every published release.

The `final` target of `docker/Dockerfile` builds directly from `repo-builder` without the tarball. It is the direct path to the same image and is used for local builds.

Both images run as `65534:65534`, expose port 8080, declare `VOLUME ["/srv/repo"]`, and start with `ENTRYPOINT ["python3", "-m", "http.server", "--directory", "/srv/repo"]`.

### Smoke Test

Before a release is created, `publish-release.sh` loads the `amd64` image and runs it on port 8090 using `python:3.15-slim-trixie`. The smoke test runs `apt-get update` against the repository configuration in the image, which confirms that the signed index, the keys, and the source configuration work together. Only `amd64` is tested.

---

## Repository Mirror Details

### Upstream Fetch and Verification

`docker/build.sh` imports the `apt_signing_key` secret and fetches the **`bookworm`** repository from `openresty.org` for both architectures. It verifies upstream `Release.gpg` against the upstream key, then writes the output under **`trixie`**, setting `Suites: trixie` and `Codename: trixie` in the new `Release` file. **The packages are built for bookworm and served as trixie. This relabeling is the only change the mirror makes to the upstream packages.**

The upstream key is **trust-on-first-use**. It is fetched from `openresty.org` on each workflow run, and the build verifies against that copy with no pinned fingerprint.

The `Packages` metadata is cleaned to **strip `\r` (carriage return) characters**. **NUL bytes are not handled.** The indexes are generated per architecture with `apt-ftparchive --arch`, so the `amd64` and `arm64` indexes do not include each other's packages.

### Files Shipped in the Pool

Each `.deb` in `/srv/repo/pool` has two companion files. A `.sha256` file contains the expected checksum, and a `.url` file records the upstream source URL. The `.sha256` files use absolute build-container paths (`/srv/repo/pool/...`), so they will only pass `sha256sum -c` after the paths are adjusted or the pool is restored to that location.

### Signing and Freshness

`Release` is signed with a detached armored signature in `Release.gpg`, and `InRelease` is clearsigned with the mirror key. **The `Release` file has no `Valid-Until` field.** APT will not reject the snapshot as expired, so each snapshot is fixed and carries no freshness guarantee.

### HTTP Service

**The mirror is served over plain HTTP** by Python's `http.server`. Integrity depends on the APT signature check, not on transport security, so the signing key must be installed from a trusted copy, such as the release assets or the copy embedded in the image.

---

## Verifying a Release

Download the `.tar.zst` archive, its `.sha256` and `.sha256.asc` files, and the three key files into one directory. The example below uses the `amd64` archive from a release tagged `v2026.11.14`.

```sh
set -euo pipefail

TAG=v2026.11.14
BASE="openresty-trixie-repo-amd64-${TAG}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
export GNUPGHOME="${WORK_DIR}/gnupg"
mkdir -m 0700 "${GNUPGHOME}"

gpg --batch --import openresty-mirror.asc
gpg --batch --verify openresty-keys.clearsigned.asc

gpg --batch --verify "${BASE}.tar.zst.sha256.asc" "${BASE}.tar.zst.sha256"
sha256sum -c "${BASE}.tar.zst.sha256"

zstd -d -c "${BASE}.tar.zst" > "${BASE}.tar"
gpg --batch --verify "${BASE}.tar.sha256.asc" "${BASE}.tar.sha256"
sha256sum -c "${BASE}.tar.sha256"

docker load -i "${BASE}.tar"
rm -f "${BASE}.tar"
```

After loading, the image is named `openresty-trixie-repo-amd64:v2026.11.14`.

---

## Running the Container

The container runs as `65534:65534`. Its default command binds to `0.0.0.0` on port 8080.

```sh
docker run -d \
  --name openresty-repo \
  -p 8080:8080 \
  openresty-trixie-repo-amd64:v2026.11.14
```

To bind to a different address or port, pass the arguments directly, since they replace the default `CMD`:

```sh
docker run -d \
  --name openresty-repo \
  --network host \
  openresty-trixie-repo-amd64:v2026.11.14 --bind 127.0.0.1 9000
```

The repository is served from the root (`dists/trixie/...` and `pool/openresty/...`). The public keys are available at `/openresty-mirror.asc` and `/openresty-upstream.asc`, and they are installed in `/etc/apt/keyrings` inside the image.

---

## Configuring a Debian Trixie Client

Install the mirror key from the same release as the packages you are installing, into `/etc/apt/keyrings`, and add a DEB822 source file that points to the running container:

```sh
install -d -m 0755 -o 0 -g 0 /etc/apt/keyrings
install -m 0644 -o 0 -g 0 openresty-mirror.asc /etc/apt/keyrings/openresty-mirror.asc

cat <<'EOF' > /etc/apt/sources.list.d/openresty.sources
Types: deb
URIs: http://<host>:8080
Suites: trixie
Components: openresty
Signed-By: /etc/apt/keyrings/openresty-mirror.asc
EOF
chmod 0644 /etc/apt/sources.list.d/openresty.sources

apt-get update
apt-get install -y --no-install-recommends openresty
```

Replace `<host>` with the address of the machine running the container.

---

## Building Locally

To build the `final` target directly, provide the three secrets that the release workflow uses:

```sh
docker buildx build \
  --target final \
  --secret id=apt_signing_key,src=mirror-private.asc \
  --secret id=openresty_mirror_pub,src=openresty-mirror.asc \
  --secret id=openresty_upstream_pub,src=openresty-upstream.asc \
  -t openresty-trixie-repo-local \
  ./docker
```

A local build creates its own signing key, so its `Release` signatures will not match a published release.

---

## Known Limitations

- **Only `amd64` is runtime-tested.** The smoke test loads and runs only the `amd64` image. The `arm64` image is built but not run.
- **The mirror is served over HTTP**, so the APT signature check is the only integrity guarantee.
- **The upstream key is trust-on-first-use.** It is fetched on each workflow run without a pinned fingerprint.
- **Each release has a new signing key.** Clients must use the key from the same release.
- **The `Release` file has no `Valid-Until`**, so snapshots never expire.
- **NUL bytes in upstream `Packages` metadata are not handled.** Only `\r` is stripped.
- **Bookworm packages are served as trixie.** The packages are not rebuilt, so compatibility depends on the upstream packages.
