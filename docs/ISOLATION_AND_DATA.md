# Isolation and data ownership

Parallax isolates launch **configuration and selected storage locations**. It
does not create a macOS sandbox, a separate login session, a VM, or a separate
Keychain. Treat profiles as a convenient way to ask a compatible application to
use different data, not as a boundary against a malicious or incompatible
application.

## What a profile changes

For a profile using generated paths, Parallax can pass:

- `--user-data-dir=<managed profile>/UserData` to compatible Chromium-based
  applications.
- `CODEX_HOME=<managed profile>/CodexHome` to Codex.
- For Claude Desktop, both
  `--user-data-dir=<managed profile>/UserData` and
  `CLAUDE_CONFIG_DIR=<managed profile>/UserData/ClaudeConfig`. This configures
  its web app data and Claude Code state to use the same space-specific
  locations when Claude honors those values.
- The profile’s additional arguments and environment entries.

The application decides whether to honor those values. It may ignore an
argument, reuse a singleton process through IPC, start helpers that use shared
locations, or write elsewhere.

Parallax does not copy or merge Claude chats between spaces. Claude Code binds
its login to the `CLAUDE_CONFIG_DIR` it was started with (its Keychain item is
scoped per configuration directory), so each Claude configuration directory
holds its own independent login. Parallax never copies credentials between
directories; pointing a space or a tracked account at a different configuration
directory requires signing in again there. Whether Claude Desktop honors a
configured storage path for its web-app data remains the application's
decision. Switching accounts may therefore make an earlier chat unavailable in
the new account. To continue that work, return to the original account or
carry over only the context you choose to share.

These Local Space paths are separate from Control Center account boundaries.
Each tracked Claude Code account receives its own
`~/Library/Application Support/Parallax/AccountSessions/<account-id>/ClaudeConfig`
directory, which Control Center supplies as `CLAUDE_CONFIG_DIR` for sign-in,
status, and usage operations.

### Refresh policy for tracked accounts

A refresh failure never disconnects a tracked account. The account keeps its
connected state and its last known values, and the failure is shown alongside
them. “Sign-in required” is shown only when the provider tool explicitly
reports that the account’s configuration directory has no login; a timeout, a
missing tool, or an incomplete response is reported as that failure, not as a
sign-out. Only removing the record, or a record that has never signed in, is
“not connected”. Once the provider has reported a missing login, the record
remembers it: a later timeout or an abandoned browser sign-in does not turn the
card back into a plain refresh, and only a successful refresh or sign-in clears
it. Tracked accounts are re-checked automatically about every 5 minutes and
again after the Mac wakes from sleep, so an account that was signed in outside
Parallax, or whose sign-in expired, updates without a manual refresh. An
account whose checks keep failing is retried less often each time, up to once
an hour, until a check succeeds. While a check is running, the previous values
stay on screen and the account reads “Refreshing” rather than failed.

Immediately before a managed Claude launch, Parallax revalidates both paths and
forces the managed user-data and Claude configuration directories to owner-only
`0700`, including directories created by an older build.

Likewise, `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` is a
request to Launch Services, not a guarantee that the target application will
create and retain an independent process.

Profiles launched under the same macOS account can still share:

- login Keychain items and credentials;
- application-group and container data;
- system and application preferences, caches, logs, and temporary locations;
- helper processes, extensions, agents, shared services, and singleton IPC;
- files reachable through the user account’s normal permissions.

Use separate macOS accounts or a stronger OS/virtualization boundary when those
resources must be isolated.

## Launch status

“Launch requested” or “request accepted” means macOS accepted the open request.
It does **not** prove that a new process is running or that the application used
the requested profile.

Parallax reports a profile as running only after `NSWorkspace` returns a
specific running application and Parallax has installed termination tracking.
An application that immediately exits is not treated as durably running.
Parallax follows the lifecycle through requested, launching, running,
terminating, terminated, or failed states.

By default, Parallax prevents a second concurrent launch of the same profile
storage and blocks clear, remove, relocation, and similar mutations while that
storage is active. The expert override is intentionally explicit because two
processes using or modifying the same storage can corrupt it.

## Environment and secret handling

The normal launch environment is built from a small trusted baseline, including
identity, locale, temporary-directory, and fixed system path values. Parallax
does not copy the full parent environment by default. In particular, arbitrary
parent secrets, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, SSH agent values, and
dynamic-loader variables are not inherited unless an advanced configuration
explicitly opts into broader inheritance.

Secret environment values can be stored as opaque Keychain references. Parallax
resolves a reference only while preparing the final launch environment.
Portable exports never contain the referenced Keychain value. The Keychain
itself remains shared at the macOS-account level, so a profile-specific
reference is not a separate Keychain security boundary.

Imported launch configurations remain pending review until the user inspects
and approves the exact current configuration. Editing an approved imported
configuration invalidates that approval. Importing metadata never imports
Keychain secret values.

## Managed and external paths

Each application and profile has an immutable storage UUID. Display-name changes
therefore do not rename or move its storage directory.

Parallax-managed profile data is under:

```text
<configured-base>/.parallax/Applications/<application-storage-id>/Profiles/<profile-storage-id>/
```

Archives are under:

```text
<configured-base>/.parallax/Archives/<application-storage-id>/<profile-storage-id>/
```

The default configured base is:

```text
~/Library/Application Support/Parallax/Profiles
```

Before a managed mutation, Parallax canonicalizes the base, verifies directory
identity, and verifies that the target remains within the `.parallax`
namespace. Missing storage volumes, changed roots, symlink escapes, unsafe
components, and unexpected files stop the operation.

An explicitly configured absolute Chromium user-data directory, `CODEX_HOME`,
or `CLAUDE_CONFIG_DIR` outside the generated path is **external**. It is
configuration-only from Parallax’s point of view. External data remains owned
and backed up by the user or by the external application.

## Exact data-operation behavior

| Operation | Managed profile data | Explicit external data | Library metadata |
| --- | --- | --- | --- |
| Launch | Application receives generated paths | Application receives configured paths | Last-launch/lifecycle state may update |
| Reveal | Opens an existing selected directory; does not create one | Opens an existing selected directory; does not create one | Unchanged |
| Clear Data | Moves the managed profile root to a new archive entry; no-op if no managed data exists | Never touched | Profile remains |
| Duplicate | Copies the managed profile root when it exists | Never copied; the duplicate receives fresh generated recommended isolation paths for supported presets | Adds a profile with new immutable IDs |
| Remove Profile Only | Left in place | Left in place | Removes the profile entry |
| Remove and Archive Data | Moves the managed profile root to an archive entry | Left in place | Removes the profile entry |
| Remove and Delete Data | Deletes the managed profile root through a recoverable transaction | Left in place | Removes the profile entry |
| Relocate Storage | Moves Parallax-managed application/profile data and archives transactionally | Not moved or rewritten | Updates the managed base after publication succeeds |
| Remove Application / Keep in Place | All managed profile roots are left in place | Left in place | Removes the application and its profile entries |
| Remove Application / Archive | Managed profile roots are moved to their archive locations | Left in place | Removes the application and its profile entries |
| Remove Application / Delete Permanently | Managed profile roots are deleted through a recoverable transaction | Left in place | Removes the application and its profile entries |

“Remove Profile Only” and application removal with “Keep in Place” intentionally
leave orphaned managed data. Parallax does not later infer ownership from a
visible name. Record the displayed paths if you plan to reclaim those
directories manually.

Clear, duplicate, profile removal, application removal, and relocation stage
their filesystem and metadata work as coordinated transactions. A failed
operation is rolled back when that can be proved safe; otherwise Parallax stops
in recovery instead of guessing. A metadata backup is required before
destructive application removal.

## Export is not backup

The File menu provides three portable JSON exports:

| Export | Includes | Excludes |
| --- | --- | --- |
| Library Metadata | Applications, profiles, launch configuration, storage IDs, and related metadata | Settings/templates, managed data payloads, external data, app binaries, Keychain secret values |
| Settings and Templates | Parallax settings and profile templates | Library metadata, managed data payloads, external data, app binaries, Keychain secret values |
| Portable Configuration | Library metadata plus settings/templates | Managed data payloads, external data, app binaries, Keychain secret values |

If a launch configuration contains a plaintext value that appears sensitive,
Parallax asks whether to omit, redact, or explicitly include it. Keychain
reference tokens may be present so the relationship can be reconstructed, but
the secret values they reference are never exported.

An import changes metadata only. It is size-, structure-, and schema-validated;
conflicts require an explicit decision, and imported launch configurations must
be reviewed before launch. Existing profile data is not replaced by an import.

Recovery backups are also metadata backups: they preserve exact verified
`library.json` bytes, not profile payloads.

Parallax does not currently offer a one-click complete data backup. For a
coherent manual backup:

1. Quit applications launched from every affected profile, then quit every
   Parallax window.
2. Copy `~/Library/Application Support/Parallax` to backup storage.
3. For each custom base root, copy its `.parallax` directory.
4. Back up every explicitly configured external user-data, `CODEX_HOME`, or
   `CLAUDE_CONFIG_DIR` directory separately, following the owning application's
   guidance.
5. Export Settings and Templates if those settings must be portable.
6. Back up required credentials using an appropriate Keychain-aware process;
   neither filesystem copies nor Parallax exports contain Keychain secret
   values.

Do not assemble a backup while affected applications or Parallax are writing
those locations. A filesystem snapshot or backup tool capable of taking a
consistent snapshot is preferable for large profiles.
