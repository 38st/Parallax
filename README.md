# Parallax

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

## Build and test

```bash
swift build
swift test
```

The packaging script also supports local app bundles, release artifacts, and
verification. The release modes, credentials, architecture checks, DMG
installation, and manual update procedure are documented in
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

## License

See [LICENSE](LICENSE).
