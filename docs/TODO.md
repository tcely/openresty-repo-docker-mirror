# TODO

## Pending

- [ ] **Fix `publish-release.sh` clearsigned bundle check.** The current check uses `gpg --decrypt`, which does not verify the signature.
  1. Replace the three lines that run `gpg --batch --decrypt -o .output`, `cat -v .output`, and `rm -f .output` with `gpg --batch --verify openresty-keys.clearsigned.asc`.
  2. Rely on `set -e` so that a bad signature exits non-zero and stops the release.

- [ ] **Extend `.gitignore`.** Several generated files are not ignored yet.
  1. Add `*.tar`, `*.tar.zst`, `*.sha256`, `*.sha256.asc`, `*.url`, `*.key`, `*.sec`, `*.gpg`, `/dists/`, `/pool/`, and `/gnupg/`.
  2. Keep the existing `docker/openresty-*.asc` and `docker/*.tar` entries, and keep the public keys tracked.
  3. Run `git ls-files -ci --exclude-standard` after the change to list any tracked file the new patterns now match.

- [ ] **Fix absolute paths in pool checksums.** `build.sh` writes `.sha256` files with absolute build-container paths (`/srv/repo/pool/...`).
  1. Generate each checksum from inside the file's own directory, for example `(cd "$(dirname "$deb")" && sha256sum "$(basename "$deb")") > "${deb}.sha256"`.
  2. Verify from the pool directory with `cd pool/openresty/<dir> && sha256sum -c <name>.deb.sha256`.
  3. Note the change in the file format in the release notes, since anyone parsing these files will be affected.

- [ ] **Move the signing key out of GitHub job outputs.** The private key currently passes from `prepare-key` to `build` as the `apt_signing_key` secret, and to `publish-release` as the `GPG_PRIVATE_KEY` environment variable. It is also exported as a job output. The decision is to sign APT metadata in `build` and the release tar checksums in `publish-release`, because `docker save` runs in that job. Both jobs therefore need the key.
  1. Remove the private key from the `prepare-key` job outputs.
  2. Store the private key as an environment-scoped secret, restricted to the release workflow.
  3. Give each job that needs the key access to that secret directly, so the key never appears in run data.
  4. Update the README's Build Pipeline and Known Limitations sections when this is done.

## Done

- [x] **Add README verification prerequisites.** The README lists the tools needed for verification.
  - Implemented: the README's Verifying a Release section lists `gpg`, `zstd`, `sha256sum`, and `docker`.

- [x] **Trim duplicate README limitations.** HTTP, trust-on-first-use, per-release keys, `Valid-Until`, NUL bytes, and the bookworm-to-trixie relabel are each explained once in the body. Known Limitations has one short bullet per item that points to its section.
  - Implemented: the README's Known Limitations section contains one bullet per item.

- [x] **Clarify the `Valid-Until` wording in the README.** The README says the `Release` file has no `Valid-Until` and that APT therefore has no expiry to enforce.
  - Implemented: the Signing and Freshness section states this.

- [x] **Note that `--network host` is Linux-only.** The README says this before the example and recommends the `-p` form on Docker Desktop.
  - Implemented: the Running the Container section includes this note.

- [x] **Confirm the `prepare-key` artifact contains no private key.** The artifact uploads three explicit files. The public key is written with `gpg --armor --export`, and the clearsigned bundle is built from public key blocks only. The private key leaves the job only as a job output.
  - Implemented: the upload step lists these three files explicitly.

## Won't Do

- **Pin the upstream OpenResty key fingerprint.** Trust-on-first-use is intentional. The README documents the trade-off.
- **Create the release in a single step.** The script creates a draft and publishes it only after all assets are uploaded and verified. This is intentional because releases are immutable. A failed run leaves a draft that a maintainer deletes manually.
- **Add TLS or authentication to the mirror.** Serving over plain HTTP with `http.server` is intentional. Integrity comes from APT signature checks, as the README's HTTP Service section explains.
- **Align the smoke-test port with the default port 8080.** The smoke test deliberately runs on 8090 to confirm that the image still accepts a different port.
