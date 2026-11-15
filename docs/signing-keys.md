## Proposal: Monthly `age` rotation and encrypted signing-key handoff

**Keep this as planned work in `TODO.md`; don’t describe it in `README.md` until it is implemented.** The age pair protects the *transport* of the OpenResty signing key between jobs. It does not replace the OpenResty signing key or change what the release signatures mean.

The planned values are:

- `AGE_ROTATION_PAT`: fine-grained PAT stored as a repository Actions secret; used only by the rotation workflow.
- `AGE_IDENTITY`: current age private identity, stored as a repository Actions secret; used by `build` and `publish-release` to decrypt.
- `AGE_RECIPIENT`: matching age public recipient, stored as a repository Actions variable; used by `prepare-key` to encrypt.

An age recipient is the public value used to encrypt; the matching private identity decrypts the result. <citation src="16"></citation>

---

## 1. Configure the repository credentials

Create a **fine-grained PAT** restricted to this repository, with **Secrets: write** and **Variables: write** repository permissions. GitHub names the latter permission `actions_variables`; the secrets API specifically requires `Secrets: write`. Give the PAT an expiration and account for organization approval or policy requirements. <citation src="2,4"></citation>

Add the PAT as the repository Actions secret `AGE_ROTATION_PAT`. The rotation workflow will use it to update `AGE_IDENTITY` and `AGE_RECIPIENT`. Keep the PAT out of the weekly release workflow; a compromised workflow that can use this token could replace the age credentials. GitHub recommends limiting credential permissions and repository access. <citation src="5"></citation>

---

## 2. Monthly rotation workflow

Add a scheduled workflow, for example `.github/workflows/rotate-age-key.yml`, with both `schedule` and `workflow_dispatch` triggers. Schedule it away from the weekly release run. Scheduled workflows run from the default branch and can be delayed or dropped during high load, so keep manual dispatch available and don’t make a release depend on rotation running at an exact time. <citation src="7"></citation>

The rotation steps should:

1. Generate an age identity in a temporary file with restrictive permissions.
2. Derive its public recipient.
3. Test encryption and decryption locally before changing repository values.
4. Update the secret and variable using the PAT.
5. Remove temporary files and fail visibly if either update fails.

The essential commands are:

```bash
set -euo pipefail
umask 077

identity="$RUNNER_TEMP/age-identity"
recipient="$RUNNER_TEMP/age-recipient"

age-keygen -o "$identity"
age-keygen -y "$identity" > "$recipient"

printf 'age-key-rotation-test\n' > "$RUNNER_TEMP/plaintext"
age -r "$(cat "$recipient")" \
  -o "$RUNNER_TEMP/test.age" \
  "$RUNNER_TEMP/plaintext"
age -d -i "$identity" \
  -o "$RUNNER_TEMP/decrypted" \
  "$RUNNER_TEMP/test.age"
cmp "$RUNNER_TEMP/plaintext" "$RUNNER_TEMP/decrypted"

gh secret set AGE_IDENTITY --repo "$GITHUB_REPOSITORY" < "$identity"
gh variable set AGE_RECIPIENT --repo "$GITHUB_REPOSITORY" < "$recipient"

rm -f "$identity" "$recipient" \
  "$RUNNER_TEMP/plaintext" "$RUNNER_TEMP/test.age" "$RUNNER_TEMP/decrypted"
```

Expose the PAT to only the step that needs it, for example through `GH_TOKEN: ${{ secrets.AGE_ROTATION_PAT }}`. GitHub CLI supports setting a repository secret from a file on standard input and setting a variable from standard input. <citation src="1,21"></citation>

The secret and variable updates are separate operations, not an atomic pair. For the first version, run rotation only when no weekly release is in progress, and add a recovery procedure for a partial update. A stronger later design could use versioned identity/recipient names and advance a “current key version” only after both new values are stored. Monthly rotation also means you should decide how long to retain an old identity for reruns that reuse an older encrypted key.

---

## 3. Encrypt in `prepare-key`; decrypt in both consumer jobs

In `prepare-key`, generate or retrieve the OpenResty signing key as today, then encrypt it to the current `AGE_RECIPIENT`. Pass only the **encrypted ciphertext**, encoded as a single-line output, to the downstream jobs:

```bash
set -euo pipefail
umask 077

age -r "$AGE_RECIPIENT" \
  -o "$RUNNER_TEMP/signing-key.age" \
  "$SIGNING_KEY_FILE"

bundle="$(base64 -w0 "$RUNNER_TEMP/signing-key.age")"
printf 'signing_key_bundle=%s\n' "$bundle" >> "$GITHUB_OUTPUT"
```

Map that step output to a `prepare-key` job output and make both `build` and `publish-release` depend on `prepare-key`. Job outputs are a supported way to pass data to dependent jobs. <citation src="13"></citation>

In each consumer job, make the bundle an environment variable and decrypt it using `AGE_IDENTITY`:

```bash
set -euo pipefail
umask 077

identity="$RUNNER_TEMP/age-identity"
encrypted="$RUNNER_TEMP/signing-key.age"
signing_key="$RUNNER_TEMP/signing-key.pem"

printf '%s' "$AGE_IDENTITY" > "$identity"
printf '%s' "$SIGNING_KEY_BUNDLE" | base64 --decode > "$encrypted"
age -d -i "$identity" -o "$signing_key" "$encrypted"

# Use "$signing_key" for the job's existing signing operation.
```

Inject `AGE_IDENTITY` and `SIGNING_KEY_BUNDLE` through step or job `env`; don’t interpolate secret values directly into shell script text. Don’t enable shell tracing, print the identity or decrypted key, or pass the plaintext key through `GITHUB_OUTPUT`. GitHub may redact outputs it recognizes as secrets, so test that the encrypted bundle is actually delivered; if output redaction interferes, use an encrypted artifact as the transport instead. <citation src="11"></citation>

Base64 here is only to make the ciphertext convenient to pass as a single-line output; **age encryption is what protects the key**. The receiving jobs should be limited to trusted release workflow code because age encryption does not establish who produced a ciphertext.

---

## 4. Future externally supplied signing keys

This design can keep the consumer jobs unchanged if the key is generated outside `prepare-key` later. The producer or import step must encrypt the key to the current public `AGE_RECIPIENT` before handing it to the workflow. Only the encrypted bundle should cross the job boundary.

---

## Suggested pending TODO entry

1. Add a monthly age-key rotation workflow that updates the repository’s `AGE_IDENTITY` secret and `AGE_RECIPIENT` variable using a narrowly scoped fine-grained PAT.
2. Encrypt the signing key in `prepare-key` to `AGE_RECIPIENT`; pass only the encrypted bundle to `build` and `publish-release`.
3. Decrypt the bundle in both consumer jobs using `AGE_IDENTITY`; keep plaintext key material out of outputs and logs.
4. Add rotation validation, overlap prevention, partial-update recovery, and a policy for reruns that need the previous age identity.
