# TODO: Align README with implementation

## Verify before rewriting
- [ ] Confirm `scripts/prepare-keys.sh` writes `openresty-keys.clearsigned.asc` and the `.asc` files to the paths the workflow uploads.
- [ ] Confirm `scripts/publish-release.sh` ships `.tar.zst`, `.sha256`, and `.sha256.asc` and does not ship the `.tar` files.
- [ ] Confirm `docker/Dockerfile` matches the stage order described in the workflow (`repo-builder` → `artifact-builder` → `artifact` → `final`).
- [ ] Check the mirror's `Packages` indexes with the `Filename:`/`Architecture:` grep against a built snapshot.

## Security
- [ ] Move the signing key out of job outputs: generate and sign in one job, or store it as a secret and pass only what each job needs.
- [ ] Decide whether the README's "ephemeral key" claim still holds after that change.

## Repository hygiene
- [ ] Extend `.gitignore` with release artifacts (`*.tar`, `*.tar.zst`, `*.sha256`, `*.sha256.asc`, `*.url`) and key patterns (`*.key`, `*.sec`, `*.gpg`).
- [ ] Confirm where the clearsigned bundle is written, since the `docker/` pattern won't match if it lands in the repo root.

## Mirror metadata
- [ ] Decide whether to add `Valid-Until` to the `Release` file or document that snapshots have no freshness guarantee.
- [ ] Decide whether `.sha256` and `.url` files under `pool/` should be published or removed after verification.

## README rewrite
- [ ] Document the bookworm → trixie relabeling.
- [ ] State that the upstream key is fetched per run without a pinned fingerprint.
- [ ] State that the mirror is served over plain HTTP.
- [ ] Correct "rejecting" CR/NUL to "stripping" `\r`.
- [ ] Document the two-stage build (`artifact` target, then `Dockerfile.from-artifact`).
- [ ] Note that only `amd64` is runtime-tested.
