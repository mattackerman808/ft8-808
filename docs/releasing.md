# Releasing FT8-808

Releases are built by `.github/workflows/release.yml`: a **universal**
(arm64 + x86_64), code-signed, notarized, and stapled **`.pkg`** installer that
drops `ft8term` and `libhamlib.4.dylib` into `/usr/local/bin` (so `ft8term` is on
the user's `PATH` with the bundled Hamlib beside it).

## Cut a release

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow rebuilds Hamlib universal, builds `ft8term` for both arches, signs +
notarizes + staples the `.pkg`, and attaches it to a GitHub Release named after
the tag. To dry-run without releasing, trigger **Actions → release → Run
workflow** (workflow_dispatch) — it builds and uploads the `.pkg` as a workflow
artifact but creates no Release.

## Signing is conditional

The workflow runs **without any secrets**, producing an *unsigned* `.pkg` (fine
for local testing; macOS will warn end users). Add the secrets below and the same
workflow starts signing, notarizing, and stapling — no YAML changes needed.

Add them under **Settings → Secrets and variables → Actions → New repository
secret**:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of a `.p12` containing **both** your *Developer ID Application* and *Developer ID Installer* certificates (with private keys) |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set when exporting the `.p12` |
| `AC_API_KEY_P8` | base64 of your App Store Connect API key file (`AuthKey_XXXXXX.p8`) |
| `AC_API_KEY_ID` | the key's **Key ID** (the `XXXXXX` part) |
| `AC_API_ISSUER_ID` | the **Issuer ID** (UUID) from App Store Connect |

If only the certificate secrets are present, the `.pkg` is signed but not
notarized. Both groups are needed for the full signed + notarized + stapled
artifact.

### Exporting the certificates (`.p12`)

You need two Developer ID certificates (create them at
[developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list)
if you don't have them): **Developer ID Application** (signs the binary/dylib) and
**Developer ID Installer** (signs the `.pkg`).

In **Keychain Access**, select *both* certificates (each shows its private key
underneath), right-click → **Export 2 items…**, save as `certs.p12`, set a
password, then:

```sh
base64 -i certs.p12 | pbcopy   # paste into MACOS_CERTIFICATE_P12
```

### App Store Connect API key (for notarization)

[App Store Connect → Users and Access → Integrations → App Store Connect
API](https://appstoreconnect.apple.com/access/integrations/api) → generate a key
(role *Developer* is enough for notarization). Download the `.p8` **once**, and
note the **Key ID** and **Issuer ID**.

```sh
base64 -i AuthKey_XXXXXX.p8 | pbcopy   # paste into AC_API_KEY_P8
```

## What end users get

Double-click the `.pkg` → it installs to `/usr/local/bin`. Because it's notarized
and stapled, Gatekeeper clears it with no quarantine prompt, even offline. Then:

```sh
ft8term            # configure once in [S]ettings, then just run it
```

## Notes

- The runner is `macos-14` (Apple Silicon); it cross-builds the x86_64 slice.
- `Scripts/ft8term.entitlements` grants the microphone entitlement that live
  capture needs under the hardened runtime; the usage string itself is the
  embedded `Sources/ft8term/Info.plist`.
- Rebuilding Hamlib universal in CI mirrors `ARCHS="arm64 x86_64"
  Scripts/build-hamlib.sh` — the committed `Vendor/Hamlib.xcframework` is arm64
  only and is not modified by a release run.
