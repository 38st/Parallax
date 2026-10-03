# Library migration and recovery

Parallax v2 uses stable application/profile identities, a revisioned library,
transaction receipts, and UUID-based storage paths. Existing v1 libraries and
legacy raw application arrays are migrated automatically on load only after a
complete migration plan passes validation.

## v1 to v2 compatibility

The authoritative metadata remains:

```text
~/Library/Application Support/Parallax/library.json
```

For each legacy application and profile, migration:

1. Reads and hashes the exact original library bytes.
2. Validates the legacy library and inventories the canonical legacy source
   directories.
3. Allocates stable v2 application, profile, and storage UUIDs.
4. Stops before publication if data is ambiguous or unsafe.
5. Writes and verifies an exact-byte v1 backup plus a durable journal.
6. Copies each existing legacy source into a staged destination, verifies its
   manifest, and publishes the UUID-based v2 destination.
7. Writes and verifies pending v2 metadata and the migration receipt.
8. Atomically replaces `library.json` only after the data and receipt are
   durable.

Legacy source directories are retained in place. Existing data is copied, not
moved or deleted. Missing legacy directories remain missing rather than being
silently created. Explicit external isolation paths remain external, and
ambiguous legacy path provenance is marked for review instead of being
rewritten speculatively.

The migration control directory is:

```text
~/Library/Application Support/Parallax/Migrations/<migration-id>/
```

It contains the exact `library-v1.backup.json`, journal, pending publication
files, per-profile publication records, and final `receipt.json`. The receipt
records source and target hashes, byte counts, ID/path mappings, timestamps,
and the fact that legacy data was retained.

## When migration stops

Parallax refuses to guess when it encounters conditions such as:

- case-insensitive or canonical source collisions;
- multiple records sharing a legacy application root;
- reserved archive/path ambiguity or unsafe storage names;
- a legacy source outside the expected managed root;
- a non-directory or otherwise unsupported source item;
- an invalid or unavailable base storage root;
- unexpected content already occupying a v2 destination;
- source data that changes during the copy;
- a journal, receipt, backup, or destination that conflicts with the recorded
  hashes and ownership.

The library stays unavailable for mutation until the problem is resolved or a
verified recovery path is chosen. Parallax does not delete the original library
or legacy profile data to “get past” a blocker.

A failed attempt that rolled back no longer blocks later ones. When no copied
destination remains, Parallax retires the old journal, keeping it for
inspection, and plans again with the recorded IDs. Stale temporary files,
abandoned migration folders, Finder `.DS_Store` files, empty applications,
and default storage folders that were never created do not block migration.
The recovery screen names each blocker and its path. Parallax retries only
when you reopen the library.

## Crash recovery and idempotence

Migration and ordinary profile-data operations use durable journals and
ownership records. On the next load, Parallax examines incomplete work and
either resumes, rolls back, or reports that recovery is required. Re-running a
completed or interrupted migration with the same valid state is idempotent:
already published content must match its recorded manifest. Conflicting content
causes a stop rather than an overwrite.

Recovery runs only while Parallax holds the library lock. If another window or
process is working, or a space that an interrupted operation involves is still
open, Parallax keeps the library loaded, reports that another operation is in
progress, and checks again automatically. The spaces the interrupted operation
involves cannot be opened until recovery finishes. If recovery is waiting for
a stuck launch record, the message names the space; see
[stuck launch records](#stuck-launch-records).

Profile-data transaction control records are stored under:

```text
~/Library/Application Support/Parallax/ProfileTransactions/
```

Managed data staging is under the configured base root’s:

```text
<base>/.parallax/Transactions/
```

Records store a digest and a file count instead of the full file list, so
large spaces no longer overflow them, and records from earlier builds still
load. Completed profile-data and relocation control records are retired
immediately; if cleanup fails, maintenance retries on a later locked library
load or operation. An interrupted Remove and Delete Data, application Archive
or Delete, or relocation finishes or rolls back the next time the library opens.
Recovery never deletes data for an application that the current library still
lists. A control file that an interrupted write left empty or truncated is
renamed aside, to a hidden `.parallax-quarantine-…` file, instead of blocking
the library; a complete record that Parallax cannot read still stops recovery.

After a relocation, original data that could not be removed safely stays in
place. Parallax shows its location once in each window until you dismiss the
notice, and dismissing it removes the notice for good. If another operation
holds the library at that moment, the notice stays and you can dismiss it
again later.

Application removal and storage relocation have their own durable transaction
receipts and recovery checks. A receipt proves what Parallax planned and
published; it is not permission to remove an unrecognized path.

## External storage drives

New profile-data and relocation plans bind each root to its recorded path,
inode, and volume UUID when available. Recovery can accept the same volume
after macOS assigns it a different device number; a different available UUID
or changed root inode is refused. Legacy records and roots recorded without a
UUID retain device-number checks. If a UUID was recorded but cannot currently
be read, recovery retains inode and transaction-ownership checks rather than
proving the volume identity.

Recovery validates the roots its particular branch reads or changes. For
example, relocation rollback with no destination data or staging left can
finish without reopening that root. After metadata publication, a verified
destination can complete recovery even if the source is unavailable or
replaced; source cleanup is skipped and its locations are reported as
leftovers. A source needed to verify a published copy before rollback must
still pass identity checks.

An advisory sidecar, separate from `library.json`, remembers each application's
configured base path and volume UUID after verified storage preparation or
transaction completion. If that root is missing and the recorded volume is
not mounted, Parallax reports storage unavailable instead of creating empty
folders on the startup disk. This also covers mount points outside `/Volumes`.
Reconnect the original drive at the recorded canonical path, then retry the
operation or reopen the library for journal recovery.

Enrollment is not transaction authority. Missing or corrupt sidecars, an
unavailable mounted-volume inventory, and enrollment write failures do not
prevent transaction completion or recovery. Without usable enrollment, legacy
availability checks remain: a missing drive under `/Volumes` is recognized,
but a missing folder elsewhere may be recreated. Enrollment checks only a
missing root; it does not certify an existing folder or replace journal
ownership checks.

When an enrolled drive is unavailable, **Forget This Drive** asks to forget
the record for that application. Use it when replacing the drive intentionally:
future operations may recreate the configured path on the currently mounted
disk, subject to the remaining path checks. It clears only that application's
enrollment, without changing library metadata, moving or deleting profile
data, or changing pending transaction identities. It cannot authorize recovery
against a replacement drive. Reconnection or a changed enrollment invalidates
the displayed confirmation.

## Downgrade limits

Completed profile-data and relocation records are retired so older builds do
not normally encounter them. Interrupted work or deferred cleanup can still
leave records an older build cannot read. Current application-removal phases
are encoded as `prepared-v2` and `metadataCommitted-v2`; older decoders reject
them and stop in recovery rather than acting on newer journals. Current builds
still read the earlier phase names.

Recent Activity stores cancelled opens as `closed` with a separate
`wasCancelled` flag. Earlier builds can read them as closed; current builds
retain “Open cancelled” and rewrite older `cancelled` records on load. These
compatibility measures do not make an application rollback a data-format
rollback. Use a compatible build to finish recovery, and retain the backup
made before upgrading. See
[manual updates and rollback](BUILD_AND_RELEASE.md#manual-updates-and-rollback).

## Verified library backups

Parallax creates exact-byte metadata backups before migration, import
replacement, and destructive rewrites. Recovery artifacts live under:

```text
~/Library/Application Support/Parallax/Recovery/
├── Backups/
└── Quarantine/
```

Each artifact is a private bundle containing `library.json` and metadata with
its byte count and SHA-256 hash. Backups are published atomically and verified
before use. Invalid or corrupt primary bytes are quarantined rather than
mislabelled as last-known-good backups. “Latest” means the most recently
published backup, so a clock change cannot make an older backup win or prune
the newest one. Finder metadata inside a backup bundle does not invalidate
it.

When the library cannot be loaded, the recovery screen can:

- **Restore Latest Verified Backup**: verify the backup, preserve the current
  primary when present as another backup or quarantine artifact, then replace
  the primary. If `library.json` is missing and pending operations require
  recovery, this option can restore a verified backup and retry recovery.
  Parallax rechecks the primary under the library lock before publication and
  refuses to overwrite a file that appeared or changed in the meantime.
- **Export Recovery Copy**: write verified recovery bytes to a user-selected
  file without modifying the primary.
- **Show Recovery Files**: reveal the recovery directory for inspection.
- **Start Over**: quarantine the original bytes before publishing an empty v2
  library. This is destructive to current metadata and requires confirmation.

These actions depend on the available recovery evidence. A missing primary
does not authorize Start Over. Restoring metadata also does not guarantee that
pending operations can recover: conflicting journals or data still require
attention.

If the library is intact but an application removal still needs recovery, the
screen says so and offers **Review Application Removal…**; Start Over is not
offered. See
[Isolation and data ownership](ISOLATION_AND_DATA.md#exact-data-operation-behavior)
for Retry Recovery and Keep Files and Continue.

A library backup does not contain managed profile payloads, external data,
application binaries, settings/templates, or Keychain secret values. See
[Isolation and data ownership](ISOLATION_AND_DATA.md#export-is-not-backup) for
a complete manual-backup checklist.

## Stuck launch records

An interrupted older cleanup can leave a launch receipt containing only
`request.json` and `opening.json`. Parallax cannot infer from these files
whether the application opened, so the receipt continues to block that space.
The same happens in the current session when an app reports an error while
opening and Parallax cannot prove that no process started.

The context menu can offer **Clear Stuck Launch Record…** only when the cached
snapshot contains an opening-state launch receipt for that space, or an open
from this session whose outcome is unknown and whose space still points at the
application bundle that was opened. There must be no global ambiguity and no
other in-process request for the same identity. The library and settings must
also be available, with no profile-data operation running. While a library
operation is in progress, the action is offered only for spaces that a waiting
startup recovery involves; the recovery message names such a space. Invoking
it checks the current receipts and processes before showing a confirmation
naming the space. Only an unchanged, valid receipt in the state described
above can be cleared. An older receipt's original owner must no longer be
running; for an open from this session, the owner is the running Parallax
process itself. Parallax conservatively requires all matching instances of the
configured application to be stopped, because the receipt cannot identify
which data paths a process used. Unverifiable process evidence also prevents
clearing.

Clearing an open from this session also releases opens of the same app that
were waiting behind it; they continue without a restart. The cleared open
appears in Recent Activity as “Open cancelled”.

The confirmation warns that an unrecognized process might still be using the
space: clearing the record could allow a duplicate opening and data corruption.
Parallax rechecks the receipt and processes under the interprocess activity
lock before retiring the confirmed record. This removes launch evidence, not
space data or another space's records. Other blockers, including corrupt
receipts, remain in effect and are reported after clearing. This action is not
a way to force past arbitrary recovery failures.

## Stale writers and multiple windows

Each saved library has a monotonic revision and a version token that also binds
the primary file hash. Saves run under an advisory lock and compare the expected
token with the current primary. If another window or process saved first, the
stale writer is rejected; it cannot silently overwrite newer data.

Parallax windows use separate edit sessions. Disjoint field changes can merge
onto the latest application/profile record. If both sessions changed the same
field, or if the target was removed or structurally changed, Parallax presents
the conflict and requires reload/review. Do not work around a stale-writer
message by replacing `library.json` manually.

## Moved or reinstalled applications

The application path is not its storage identity. If the stored `.app` path no
longer exists, choose the moved/reinstalled application through Parallax’s
relink flow.

Relink validates that:

- the stored path is actually unavailable;
- the candidate is a healthy application bundle;
- the bundle identity matches the recorded application;
- the candidate does not collide with another library entry by path or
  installation identity;
- the library has not changed since the relink was reviewed.

A successful relink changes only the application path/installation metadata. It
preserves application IDs, profile IDs, storage IDs, profile configuration, and
managed data. Parallax blocks relinking to a different application or using
relink as an unreviewed path replacement.

## Operational guidance

- Keep migration and recovery directories until the upgraded library and
  profiles have been verified.
- Do not edit journals, receipts, ownership markers, or a v2 `library.json` by
  hand.
- Do not merge two copies of `library.json` with a generic sync tool.
- Reconnect a missing custom storage volume at the same canonical path before
  retrying an operation. New UUID-bound records tolerate a changed device
  number; legacy records retain their earlier checks. See
  [external storage drives](#external-storage-drives).
- If recovery reports ambiguous or conflicting ownership, preserve the entire
  Parallax support directory and every relevant base root before investigating.
- A newer unsupported library version opens read-only/recovery behavior; use a
  compatible Parallax build instead of downgrading the file format manually.
  Going back to a build from before an update has further limits; see
  [Build and release](BUILD_AND_RELEASE.md#manual-updates-and-rollback).

Default templates saved in Spanish by earlier builds keep their names, such as
“Trabajar” or “Tirar a la basura”. To use the corrected names, choose Reset to
Defaults in the Templates settings. This replaces every template, including
ones you added. Undo Reset restores the previous templates until you edit a
template again or quit Parallax.

## Legacy settings and completed saves

When no versioned settings file exists, unreadable legacy template or profile
picture payloads migrate using defaults for only the affected field. A settings
notice identifies the fallback and offers **Export Preserved Copy…** for its
exact original bytes. Migration and later versioned edits never delete or
replace the legacy UserDefaults values. Other valid fields retain their values;
ambiguous identities, incomplete capture and unsafe storage still stop migration.
An existing corrupt or newer versioned settings file never falls back to legacy
settings.

An ordinary settings save that was fully written and verified remains committed
if subsequent lock or descriptor cleanup reports an error. The saved values
stay visible, a separate notice reports the cleanup failure, and further edits
remain available. A write without complete publication proof still requires
recovery.
