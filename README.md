# Parallax

[![CI](https://github.com/38st/Parallax/actions/workflows/ci.yml/badge.svg)](https://github.com/38st/Parallax/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Parallax is a macOS control center for corporate AI access. It helps an
organization see how its Claude and Codex seats are being used, identify idle
capacity, and rebalance internal allocations toward people who are approaching
a limit. The original local launcher remains available for keeping separate
launch configurations for Chromium-based browsers and the OpenAI Codex desktop
app.

Parallax never shares credentials or claims to override a provider's own usage
limits. Provider-side enforcement requires an eligible enterprise plan and a
supported provider connection; the built-in control center currently models
and persists the organization's internal allocation decisions locally.

> [!NOTE]
> The corporate control center is an early local preview. Member, seat, and
> transfer data starts with fictional demo values and is not synchronized with
> provider admin consoles. Account status is read through locally installed
> Codex or Claude command-line tools after you complete the provider's normal
> sign-in flow.

## Project status

Parallax is under active development and is being shared as a source preview.
There is no supported binary release yet, and the corporate workspace should
not be used as the system of record for billing, access control, or compliance
decisions. For evaluation, build the app locally and use fictional or
non-sensitive workspace data.

Parallax provides **best-effort configuration isolation**, not an operating
system security boundary. A launched application can ignore an isolation
option, connect to an existing singleton process, or continue to use resources
shared by the current macOS account. See
[Isolation and data ownership](docs/ISOLATION_AND_DATA.md) before relying on a
profile for sensitive separation.

## Features

- Local account inventory with isolated Codex ChatGPT logins, live Codex
  rate-limit and token-activity refreshes, Claude Code authentication status,
  reset dates, plan details, and last-checked timestamps.
- Corporate overview for purchased, assigned, and reserve Claude and Codex
  seats.
- Member-level utilization, at-risk detection, and reclaimable-capacity
  recommendations.
- Admin-approved capacity transfers with safety buffers and a persistent audit
  trail.
- Searchable people and provider views plus reviewable automatic
  recommendations.
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

## Build and run

Clone the repository on a Mac with the requirements above, run the tests, and
launch an ad-hoc-signed local build:

```bash
git clone https://github.com/38st/Parallax.git
cd Parallax
swift build
swift test
./script/build_and_run.sh run
```

For a quick tour:

1. Open **Control Center → Accounts** to add or refresh a locally authenticated
   Codex or Claude account.
2. Review the fictional workspace under **Overview**, **People**, and
   **Providers**, then try a capacity transfer to see the local audit trail.
3. Open **Local Spaces** to create isolated launch configurations for supported
   browsers or the Codex desktop app.

Removing an account from Control Center removes only Parallax's local tracking
record. It does not sign out, cancel a subscription, or change anything in the
provider's admin system.

The local build is ad-hoc signed and is not intended for redistribution. It
does not update itself; pull the latest source and rebuild when evaluating a
new revision.

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
