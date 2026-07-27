# Parallax

[![CI](https://github.com/38st/Parallax/actions/workflows/ci.yml/badge.svg)](https://github.com/38st/Parallax/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Parallax is a macOS launcher for keeping multiple launch configurations for
Chromium-based browsers and the OpenAI Codex desktop app. Each profile can use a
different Chromium user-data directory, `CODEX_HOME`, argument list, and
environment.

Parallax provides **best-effort configuration isolation**, not an operating
system security boundary. A launched application can ignore an isolation
option, connect to an existing singleton process, or continue to use resources
shared by the current macOS account. See
[Isolation and data ownership](docs/ISOLATION_AND_DATA.md) before relying on a
profile for sensitive separation.

## Features

- Stable per-application and per-profile storage identities that do not change
  when visible names change.
- Recommended Chromium and Codex isolation settings with explicit overrides.
- Launch lifecycle tracking from request through confirmed process termination.
- Transactional clear, duplicate, remove, archive, delete, and storage
  relocation operations for Parallax-managed data.
- Metadata import review and conflict resolution, including explicit approval
  before an imported launch configuration can run.
- Versioned library persistence, stale-writer rejection, migration receipts,
  verified recovery backups, and crash recovery.
- Multiple windows with field-level edit merging and visible conflict handling.
- Portable exports for library metadata, settings/templates, or both.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Swift 6.0 toolchain to build from source

Parallax launches other applications already installed on the Mac. Compatibility
with a profile’s arguments and environment ultimately depends on the launched
application.

## Install

Download the signed and notarized DMG from the
[latest GitHub release](https://github.com/38st/Parallax/releases/latest), open
it, and drag Parallax into `Applications`. CI artifacts and locally created
`archive` builds are ad-hoc signed and are not intended for end-user
distribution.

Parallax does not currently update itself. Review release notes and keep a
coherent backup of important profile data before updating.

## Build from source

```bash
swift build
swift test
./script/build_and_run.sh run
```

The packaging script supports local app bundles, release artifacts, and
verification. Release modes, credentials, architecture checks, DMG installation,
and the manual update procedure are documented in
[Build and release](docs/BUILD_AND_RELEASE.md).

## Data at a glance

The v2 library metadata file is:

```text
~/Library/Application Support/Parallax/library.json
```

The default managed base storage root is:

```text
~/Library/Application Support/Parallax/Profiles
```

Within a configured base root, Parallax owns only its UUID-based namespace:

```text
<base>/.parallax/
├── Applications/<application-storage-id>/Profiles/<profile-storage-id>/
│   ├── UserData/
│   └── CodexHome/
├── Archives/<application-storage-id>/<profile-storage-id>/
└── Transactions/
```

An application can use a different base root. Explicit absolute user-data and
`CODEX_HOME` paths are external data: Parallax passes them to the application
but does not copy, relocate, archive, clear, or delete them.

Read [Isolation and data ownership](docs/ISOLATION_AND_DATA.md) for the exact
effect of every data action and export. Read
[Library migration and recovery](docs/MIGRATION_AND_RECOVERY.md) before moving
an existing library, restoring a backup, or troubleshooting a migration.

## Project layout

```text
Sources/Parallax/
├── App/            SwiftUI scenes, commands, and app lifecycle
├── Models/         Versioned library, applications, profiles, and settings
├── Services/       Launch compilation, import validation, relinking, exports
├── Stores/         Library coordination, transactions, recovery, persistence
├── Support/        Filesystem, path containment, logging, parsing, hashing
├── Resources/      Swift Package resources included in app artifacts
└── Views/          Multi-window SwiftUI interface
Tests/ParallaxTests/
├── Fixtures/       Migration, import, and compatibility fixtures
└── *.swift         Unit, integration, failure-injection, and UI-model tests
```

## Contributing and support

Bug reports and feature requests are welcome through
[GitHub Issues](https://github.com/38st/Parallax/issues). See
[CONTRIBUTING.md](CONTRIBUTING.md) for development setup and project
conventions, and review the project [Code of conduct](CODE_OF_CONDUCT.md).

Do not report vulnerabilities or sensitive user data in a public issue. Follow
the private reporting process in [SECURITY.md](SECURITY.md).

## License

Parallax is available under the [MIT License](LICENSE).

Parallax is an independent project and is not affiliated with or endorsed by
OpenAI, Apple, Google, or other browser vendors.
