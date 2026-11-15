# TODO

## Pending

- [ ] **Fix `publish-release.sh` clearsigned bundle check.** Replace `gpg --decrypt` with `gpg --verify` for `openresty-keys.clearsigned.asc`.
  - Suggested fix: replace the three lines `gpg --batch --decrypt -o .output ...`, `cat -v .output`, and `rm -f .output` with `gpg --batch --verify openresty-keys.clearsigned.asc`. `--verify` fails with a non-zero exit code on a bad signature, so `set -e` stops the release. The README already documents `--verify`.

- [ ] **Extend `.gitignore`.** Add `*.tar`, `*.tar.zst`, `*.sha256`, `*.sha256.asc`, `*.url`, `*.key`, `*.sec`, `*.gpg`, `/dists/`, `/pool/`, and `/gnupg/`. Keep the existing `docker/openresty-*.asc` and `docker/*.tar` entries.
  - Suggested fix: after editing, run `git ls-files -ci --exclude-standard` to list any tracked file the new patterns now match. Keep the public keys tracked, and confirm that no `.sha256` or `.gpg` file you intend to commit is excluded.

- [ ] **Fix absolute paths in pool checksums.** `build.sh` writes `.sha256` files with absolute build-container paths (`/srv/repo/pool/...`). Rewrite them as relative paths so they verify from the pool directory. Update the README's "Files Shipped in the Pool" section when this is done.
  - Suggested fix: in `build.sh`, generate each checksum from inside the file's own directory, for example `(cd "$(dirname "${deb}")" && sha256sum "$(basename "${deb}")") > "${deb}.sha256"`. Then verify with `cd pool/openresty/<dir> && sha256sum -c <name>.deb.sha256`. The file format changes for anyone who already parses these files, so mention it in the release notes.

- [ ] **Move the signing key out of GitHub job outputs.** The private key currently passes from `prepare-key` to `build` (as the `apt_signing_key` secret) and to `publish-release` (as the `GPG_PRIVATE_KEY` environment variable). Generate and use it in a single job, or store it as a secure secret. Update the README's "Build Pipeline" section when this is done.
  - Suggested fix: the key is needed in two places, the `build` job (to sign `Release` and `InRelease` inside the Docker build) and `publish-release` (to sign the checksums). Keep the key inside one job by moving the checksum signing into the build step, so the private key never leaves that job. The `publish-release` job then only needs the public key and the signed artifacts. If that isn't practical, store the key as an environment-scoped secret with restricted access, and drop the job output. A `gpg-private-key` output is not masked by GitHub, so it stays visible in run data.

- [ ] **Decide the signing-key design.** Choose between generating and using the key in a single job or storing it as a secure secret. The key-handling fix depends on this choice.
  - Suggested fix: recommend the single-job approach above. It removes the key from job outputs and needs no long-lived secret. Record the decision here before implementing the job-output change.

- [ ] **Add prerequisites to the README verification section.** The verification script needs `gpg`, `zstd`, `sha256sum`, and `docker` on the host. List them before the script.
  - Suggested fix: add a short bulleted list above the verification block, such as "You need `gpg`, `zstd`, `sha256sum` (coreutils), and `docker` installed."

- [ ] **Trim duplicated limitations in the README.** HTTP, trust-on-first-use, per-release keys, `Valid-Until`, NUL bytes, and the bookworm-to-trixie relabel are described in both the body and "Known Limitations". Keep one.
  - Suggested fix: keep the full explanation in the body sections, and make "Known Limitations" a one-line bullet for each item that links to its section. Or keep the bullets and remove the duplicate sentences from the body. Pick one approach and apply it to all six items.

- [ ] **Clarify the `Valid-Until` wording in the README.** Say that APT has no expiry to enforce, so a stale mirror is never flagged, rather than only that APT won't reject it.
  - Suggested fix: replace the current sentence with "Because `Release` has no `Valid-Until`, APT has no expiry to enforce. A stale mirror is never flagged as expired, so the snapshot's age is the only freshness signal."

- [ ] **Note `--network host` is Linux-only in the README.** The `docker run` example that uses `--network host` should say it applies only to Linux hosts.
  - Suggested fix: add a sentence before the example, such as "`--network host` works only on Linux. Docker Desktop on macOS and Windows doesn't support it, so use the `-p` form there."

## Done

- [x] **Confirm the `prepare-key` artifact contains no private key.** The upload lists three explicit files. `openresty-mirror.asc` is written with `gpg --armor --export`, which exports public keys only, and the clearsigned bundle is built from public key blocks. The private key leaves the job only as the `gpg-private-key` output, which is covered separately.

## Won't Do

- **Pin the upstream OpenResty key fingerprint.** Trust-on-first-use is intentional. The README documents the trade-off.
