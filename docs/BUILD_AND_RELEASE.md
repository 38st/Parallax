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
./script/build_and_run.sh install
./script/build_and_run.sh run
```

`build` publishes `dist/Parallax.app` for inspection and marks `dist/` as
Spotlight-excluded. `install` atomically replaces the canonical
`/Applications/Parallax.app`; `run` installs that same canonical copy and opens
it. These modes use a debug build and an ad-hoc signature. They are local
development artifacts, not signed distribution releases.

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
Gatekeeper is expected to reject it. Use this mode for development or
controlled internal inspection, not customer delivery.

The unsigned archive ZIP is the canonical reproducible source candidate.
Packaging derives
`SOURCE_DATE_EPOCH` from the source commit unless it is supplied explicitly,
normalizes the staged app, sorts ZIP entries, removes ZIP extra metadata, and
records the epoch in provenance. Two builds from the same source, toolchain,
architecture, and epoch must produce the same ZIP hash. Final Developer ID
release ZIPs continue to use Apple-metadata-preserving `ditto` and are verified
after extraction because signing/notarization timestamps are intentionally not
reproducible. Apple’s DMG filesystem container may also differ byte-for-byte,
so signed outputs are verified through their app payload, ticket, and
provenance hash instead.

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
or shell history. Prefer an interactive credential setup or a protected
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

Release mode also requires a committed, completely clean Git working tree,
including no untracked files. Internal `archive` builds may still record and
package a dirty tree for investigation, but `release` refuses it before staging
or credential use because a signed artifact must be tied to a reviewable source
revision.

`SIGN_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`,
`MIN_SYSTEM_VERSION`, `DIST_DIR`, `INSTALL_DIR`, and `SOURCE_DATE_EPOCH` can also
be supplied through the environment. Explicit command options are easier to
audit in a release log, provided they do not contain secrets.

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

### What verification enforces

Verification is fail-closed and ordered from the outside in: the container
bytes, then the archive listing, then the extracted or mounted application.
Each stage refuses the artifact before the tools of the next stage read it.
Every check below applies to production and to verification of an existing
artifact, so a rejected artifact is never extracted, mounted, or published.

#### Canonical bundle permissions

Packaging normalizes the staged bundle immediately after signing to 0755
directories, 0644 files, and a 0755 main executable, so the published bytes do
not depend on the producing machine's umask or on the modes SwiftPM happened to
leave on build products. Those exact modes are then a verification
requirement. A bundle root, directory, file, or main executable carrying any
other mode is refused.

#### Closed application inventory

The bundle must be a closed, canonical tree. No symbolic links, no
multiply-linked files, and no special files. No hidden Apple or editor residue
such as `.DS_Store`. A bounded entry count and path length, and no control
character in any path.

Membership is exact rather than prefixed: every published directory admits only
its own declared children, and every declared path admits only its own kind.
`Contents` holds `Info.plist`, `MacOS`, `Resources`, and `_CodeSignature`.
`Contents/MacOS` holds only the main executable. `Contents/_CodeSignature`
holds only `CodeResources`. `Contents/Resources` holds only the application
icon, the packaging provenance plist, and the SwiftPM runtime resource bundle.
The runtime bundle is generated rather than hand-written, so it is closed by
shape: its own `Info.plist`, the processed icon representations, and one
`*.lproj` directory per language holding nothing but `Localizable.strings` and
`Localizable.stringsdict`. An extra resource, a stray signature record, a
nested localization, or a directory standing in for a file is refused.

Membership closure is asserted where the bundle is produced and for local and
unsigned expectations. It is relaxed for a signed expectation, because a
stapled release bundle carries an extra notarization record.

#### Bounded archive input

A verifiable `.zip` or `.dmg` is a regular non-symbolic-link file with exactly
one hard link, a control-character-free path, a non-zero size, and a size
within 512 MiB. Its device, inode, size, and SHA-256 are captured before
inspection and rechecked before use, so an archive whose bytes change between
inspection and extraction or mounting is refused rather than trusted.

#### Canonical ZIP container

The container bytes are parsed directly before any listing or extraction tool
runs, because `zipinfo`, `unzip`, and `ditto` can agree on a listing that does
not describe the bytes an extractor actually walks.

The archive must be single-disk with agreeing entry counts. Its
end-of-central-directory record must be the exact 22-byte tail, with no archive
comment, no trailing payload, no prefixed stub, and no second self-consistent
end record. Its central directory must end exactly where that record begins,
and no ZIP64 locator or ZIP64 sentinel field may appear. Every central header
must declare a bounded extra field, no entry comment, a supported compression
method, and no encrypted, strongly encrypted, or patched entry. Every local
header must agree with its central header byte for byte, including the entry
name; a streamed entry must carry placeholder local sizes and a trailing data
descriptor that matches the central directory. Local entries must tile the
payload region contiguously from offset zero to the start of the central
directory, so no unlisted bytes can hide between payloads.

#### ZIP entry names and kinds

Entry names must be valid UTF-8 within a bounded path length, free of control
characters and of ambiguous separators or listed representations. No absolute,
traversing, or non-canonical path. No duplicate entry under case folding and
Unicode normalization, and no case-equivalent or Unicode-equivalent collision
with the application root. Every entry must be a plain directory or file whose
declared type agrees with its path, the application root must be an explicit
directory entry, and the application payload may not be a symbolic link. The
only permitted top-level payload is `Parallax.app`.

Bounded inventory limits are applied before any name is read: a maximum entry
count, a maximum listing size, a maximum declared size per entry and in total,
and a maximum declared compression ratio per entry.

#### AppleDouble exclusion

An unsigned archive is this project's own published format, produced by a
deterministic `zip` run that never sequesters resource forks, so any `__MACOSX`
entry or `._`-prefixed sidecar in one is smuggled metadata and is refused
outright. A signed release archive is produced with `ditto --sequesterRsrc`
from a stapled bundle, and a local expectation is the compatibility path for a
bundle archived by other Apple tooling. Both of those permit metadata records
and instead require every record to describe payload the same archive carries:
an unpaired `._` record, or any non-metadata payload under `__MACOSX`, is
refused.

#### ZIP payload integrity

Stored payload is checksum-verified and checked for local-header disagreement
and for encryption before extraction, because `ditto` reports none of those
conditions through its exit status.

#### DMG image structure

`hdiutil attach` hands the image to the kernel's disk-image and filesystem
parsers, so the container is described first and only the exact structure this
project publishes is accepted: a single-segment, checksummed, unencrypted,
zlib-compressed UDIF image with a GUID partition scheme, no software license
agreement, and a bounded declared size. An encrypted or otherwise unreadable
container fails closed here, because `hdiutil` cannot describe it without a
credential. The image checksum is then verified, the image is attached
read-only with bad checksums refused, and the mounted volume must carry exactly
`Parallax.app` and an `Applications` alias resolving to `/Applications`.

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

Do not publish an unsigned archive as a customer release. Do not attach
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

Before using real `/Applications`, rehearse the candidate against a known prior
artifact in an isolated temporary Applications directory:

```bash
./script/rehearse_install_upgrade_rollback.sh \
  --previous /path/to/Parallax-0.9.0-90.zip \
  --candidate dist/Parallax-1.0.0-100.zip
```

The rehearsal does not change either input or `/Applications`. It verifies
strict code-signature structure and packaged-resource startup with a fresh home
for clean install, prior install, upgrade, and rollback, then proves rollback
restores the byte-identical prior app. Repeat this with final signed artifacts
on a clean macOS account before public distribution.

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

## Credentials

There is no hosted CI. Signed and notarized releases are produced on a
maintainer's Mac with the `release` command above. The Developer ID
certificate lives in that Mac's keychain and the notary credentials live in a
`notarytool` keychain profile; neither is stored in the repository or passed
through an automated pipeline. `SIGN_IDENTITY` may be supplied as an
environment variable instead of `--sign`. The identity must be present in the
active keychain, or the release fails before any artifact is mutated.
