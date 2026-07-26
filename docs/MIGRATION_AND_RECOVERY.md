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

## Crash recovery and idempotence

Migration and ordinary profile-data operations use durable journals and
ownership records. On the next load, Parallax examines incomplete work and
either resumes, rolls back, or reports that recovery is required. Re-running a
completed or interrupted migration with the same valid state is idempotent:
already published content must match its recorded manifest. Conflicting content
causes a stop rather than an overwrite.

Profile-data transaction control records are stored under:

```text
~/Library/Application Support/Parallax/ProfileTransactions/
```

Managed data staging is under the configured base root’s:

```text
<base>/.parallax/Transactions/
```

Application removal and storage relocation have their own durable transaction
receipts and recovery checks. A receipt proves what Parallax planned and
published; it is not permission to remove an unrecognized path.

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
mislabelled as last-known-good backups.

When the library cannot be loaded, the recovery screen can:

- **Restore Latest Verified Backup**: verify the backup, preserve the current
  primary as another backup or quarantine artifact, then replace the primary.
- **Export Recovery Copy**: write verified recovery bytes to a user-selected
  file without modifying the primary.
- **Show Recovery Files**: reveal the recovery directory for inspection.
- **Start Over**: quarantine the original bytes before publishing an empty v2
  library. This is destructive to current metadata and requires confirmation.

A library backup does not contain managed profile payloads, external data,
application binaries, settings/templates, or Keychain secret values. See
[Isolation and data ownership](ISOLATION_AND_DATA.md#export-is-not-backup) for
a complete manual-backup checklist.

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
  retrying an operation.
- If recovery reports ambiguous or conflicting ownership, preserve the entire
  Parallax support directory and every relevant base root before investigating.
- A newer unsupported library version opens read-only/recovery behavior; use a
  compatible Parallax build instead of downgrading the file format manually.
