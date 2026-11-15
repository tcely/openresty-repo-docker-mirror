# TODO

## Pending

- [ ] **Fix `publish-release.sh` clearsigned bundle check.** Replace `gpg --decrypt` with `gpg --verify` for `openresty-keys.clearsigned.asc`. The README already documents `--verify`.
- [ ] **Extend `.gitignore`.** Add `*.tar`, `*.tar.zst`, `*.sha256`, `*.sha256.asc`, `*.url`, `*.key`, `*.sec`, `*.gpg`, `/dists/`, `/pool/`, and `/gnupg/`. Keep the existing `docker/openresty-*.asc` and `docker/*.tar` entries.
- [ ] **Fix absolute paths in pool checksums.** `build.sh` writes `.sha256` files with absolute build-container paths (`/srv/repo/pool/...`). Rewrite them as relative paths so they verify from the pool directory. Update the README's "Files Shipped in the Pool" section when this is done.
- [ ] **Move the signing key out of GitHub job outputs.** The private key currently passes from `prepare-key` to `build` (as the `apt_signing_key` secret) and to `publish-release` (as the `GPG_PRIVATE_KEY` environment variable). Generate and use it in a single job, or store it as a secure secret. Update the README's "Build Pipeline" section when this is done.

