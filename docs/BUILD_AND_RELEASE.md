# Build and release

Parallax has three distinct packaging levels. Choose the mode by intended
audience; an ad-hoc signature is not a substitute for a Developer ID release.

| Mode | Intended use | Configuration and architecture | Trust |
| --- | --- | --- | --- |
| `build` / `run` | Development on the current Mac | Debug, native architecture by default | Ad-hoc signed with hardened runtime |
| `archive` | Local/internal optimized artifact | Release, universal `arm64` + `x86_64` by default | Ad-hoc signed; expected to be rejected by Gatekeeper |
| `release` | Customer distribution | Release, universal `arm64` + `x86_64` by default | Developer ID signed, notarized, and stapled |

The minimum supported system is macOS 14.0. Building requires a Swift 6
toolchain and Apple’s command-line developer tools. Universal packaging builds
both architecture slices and requires a toolchain/SDK capable of targeting both
`arm64` and `x86_64`.

## Source build and tests

```bash
swift build
swift test
```

Those commands build and test the Swift Package. To assemble a local native
`.app`, use:

```bash
./script/build_and_run.sh build
./script/build_and_run.sh run
```

`build` publishes `dist/Parallax.app`; `run` publishes and opens it. Both use a
debug build and an ad-hoc signature. They are local development artifacts, not
signed distribution releases.

The script also provides `debug`, `logs`, and `telemetry` modes. Run
`./script/build_and_run.sh --help` for their options.

## Unsigned local archive

No Apple Developer credentials are required to create an optimized universal
archive:

```bash
./script/build_and_run.sh archive \
  --version 1.0.0 \
  --build 100 \
  --zip \
  --dmg
```

This publishes versioned ZIP and DMG artifacts plus a provenance plist under
`dist/`. “Unsigned” here means not Developer ID signed: the contained app has an
ad-hoc signature and hardened runtime so its structure can be verified.
Gatekeeper is expected to reject it. Use this mode for development, CI, or
controlled internal inspection, not customer delivery.

Archive and release default to universal `arm64` + `x86_64`. A local diagnostic
build can select `--architecture native`; single-architecture distribution
artifacts must be labelled and verified with the same explicit architecture.

## Signed and notarized release

Before release, install a valid **Developer ID Application** certificate in the
active keychain and create a `notarytool` keychain profile. For example:

```bash
xcrun notarytool store-credentials parallax-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

Do not put the password, certificate, or exported private key in the repository
or shell history. Prefer an interactive credential setup or a protected CI
secret mechanism.

Build the distribution artifacts with the exact installed identity:

```bash
./script/build_and_run.sh release \
  --version 1.0.0 \
  --build 100 \
  --sign "Developer ID Application: Example, Inc. (TEAMID1234)" \
  --notary-profile parallax-notary \
  --zip \
  --dmg
```

Release mode always requires notarization and stapling. It submits and staples
the application before creating the ZIP. When `--dmg` is requested, it also
signs, notarizes, and staples the final DMG container. A release without an
available signing identity or valid notary profile fails during preflight,
before staging or replacing release artifacts.

`SIGN_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`,
`MIN_SYSTEM_VERSION`, and `DIST_DIR` can also be supplied through the
environment. Explicit command options are easier to audit in a release log,
provided they do not contain secrets.

## Artifact names and provenance

For version `1.0.0` and build `100`, the optional distribution outputs are:

```text
dist/Parallax-1.0.0-100.zip
dist/Parallax-1.0.0-100.dmg
dist/Parallax-1.0.0-100.provenance.plist
```

The app also contains `Contents/Resources/PackagingProvenance.plist`. Embedded
provenance records the version/build, bundle ID, Git revision and dirty state,
Swift toolchain, SDK, minimum system version, executable architectures,
pre-sign executable hash, and signing identity. The sidecar records the final
packaged executable hash after signing and adds hashes for the ZIP and DMG that
were published. The final hash cannot be added inside the app after signing
without invalidating that signature.

Packaging uses a per-destination lock and a unique staging directory. Artifacts
are verified before publication. An existing version/build filename is a
collision and is not overwritten; increment the build number or deliberately
move the known artifact elsewhere after verifying why the collision occurred.

The app contains the SwiftPM runtime resource bundle under
`Contents/Resources`, along with its icon. `Info.plist` is constructed with
`plutil`, and the bundle ID, semantic version, positive build number, and
minimum-system value are validated before packaging.

## Verify an existing artifact

Verification is read-only with respect to the selected artifact. It does not
rebuild, replace, launch, or publish the artifact.

Local debug app:

```bash
./script/build_and_run.sh verify \
  --artifact dist/Parallax.app \
  --expect local \
  --architecture native
```

Unsigned universal ZIP:

```bash
./script/build_and_run.sh verify \
  --artifact dist/Parallax-1.0.0-100.zip \
  --expect unsigned \
  --architecture universal
```

Signed, notarized universal DMG:

```bash
./script/build_and_run.sh verify \
  --artifact dist/Parallax-1.0.0-100.dmg \
  --expect signed \
  --architecture universal \
  --bundle-id com.parallax.Parallax \
  --team-id TEAMID1234 \
  --notarized
```

The verifier accepts an existing `.app`, `.zip`, or `.dmg`. It checks the plist,
bundle identity, executable, exact declared architectures, agreement between
the plist and Mach-O deployment target, runtime resources, strict code
signature, hardened runtime, and the expected signing/Team ID state. It uses
Gatekeeper for unsigned/signed expectations and validates stapling when
requested. ZIPs are extracted into a temporary clean directory and checked for
unsafe paths. DMGs are mounted read-only and must contain `Parallax.app` plus an
`Applications` alias; a signed notarized DMG’s container signature and ticket
are also checked.

Verification defaults to the current machine architecture for a local
expectation and to universal `arm64` + `x86_64` for signed or unsigned
expectations. Pass `--architecture` explicitly when checking an intentionally
single-architecture artifact.

## Public release checklist

Before publishing a GitHub release:

1. Confirm the intended version and positive build number are unique.
2. Confirm the default branch is clean and up to date.
3. Run `swift build`, `swift test`, and
   `./script/test_build_and_run.sh`.
4. Run the signed and notarized `release` command from a clean commit.
5. Verify the final DMG independently with `--expect signed`, the expected
   bundle ID and Team ID, `--architecture universal`, and `--notarized`.
6. Compare the final artifact hashes with the sidecar provenance plist.
7. Tag the exact packaged commit with an annotated version tag, such as
   `v1.0.0`, and push the tag without rewriting it.
8. Create a GitHub release for that tag, attach the DMG and provenance plist,
   and describe user-visible changes, data migrations, known limitations, and
   the minimum macOS version.
9. Download the published assets into a clean directory, verify them again,
   and perform a launch smoke test from `/Applications`.

Do not publish the unsigned CI archive as a customer release. Do not attach
signing certificates, notary credentials, private logs, user libraries, or
profile data to a release.

## Install from DMG

For a signed/notarized customer DMG:

1. Open the DMG.
2. Drag `Parallax.app` onto the `Applications` alias.
3. Wait for the copy to finish, then eject the Parallax volume.
4. Launch Parallax from `/Applications`, not from the mounted image.

The unsigned archive DMG has the same layout but is intentionally not accepted
as a customer distribution artifact.

## Manual updates and rollback

Parallax does not currently include an automatic updater or update feed.

To update manually:

1. Verify the downloaded signed/notarized DMG.
2. Quit every Parallax window. If taking a profile-data backup, also quit the
   affected profile applications; do not perform migration or storage operations
   during an update.
3. Keep a coherent backup as described in
   [Isolation and data ownership](ISOLATION_AND_DATA.md#export-is-not-backup).
4. Drag the new app to `Applications` and confirm replacement of the old app.
5. Open the new version and verify the library and representative profiles.

Replacing `/Applications/Parallax.app` does not intentionally remove
`~/Library/Application Support/Parallax` or configured profile storage.
However, an application rollback is not a data-format rollback: after a library
migration, an older Parallax build may not understand the newer library. Keep a
known-good application artifact and the pre-migration support/base-root backup;
do not force an older build to rewrite a newer library.

## CI and credentials

The macOS CI workflow builds and tests the package, runs packaging contract
tests, creates and verifies an unsigned universal ZIP and DMG, checks both
Mach-O slices and packaged resources, and reinspects downloaded artifacts in a
clean job.

Signed/notarized verification is credential-gated and runs only when the
workflow is manually dispatched with all protected secrets configured:

- `SIGNING_CERTIFICATE_P12_BASE64`
- `SIGNING_CERTIFICATE_PASSWORD`
- `SIGN_IDENTITY`
- `APPLE_NOTARY_APPLE_ID`
- `APPLE_NOTARY_TEAM_ID`
- `APPLE_NOTARY_PASSWORD`

The workflow imports the certificate into an ephemeral keychain, creates a
temporary `notarytool` profile, verifies the signed app/ZIP/DMG, and removes the
temporary credential material. Ordinary pull requests and pushes do not require
or receive signing credentials.
