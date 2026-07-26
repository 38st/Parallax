# Parallax Remediation Plan

This document converts the repository-wide bug, implementation-gap, security,
test, and distribution audit into an executable engineering backlog.

It is intentionally self-contained so a new Codex task can implement the work
without access to the audit conversation.

## Copy/paste kickoff prompt for a new Codex task

> Read `AGENTS.md` and `PARALLAX_REMEDIATION_PLAN.md` completely. Implement the
> remediation dependency graph in reviewable waves, starting with Phase 0.
> Task-level dependency fields are authoritative when section order differs.
> Treat every task's
> acceptance criteria and tests as required. Do not skip or weaken the v2
> library migration, canonical path containment, transaction, recovery, or
> concurrency requirements. Keep each phase reviewable, run `swift build` and
> `swift test` before closing each implementation slice, preserve user data,
> and follow the repository's default commit/push instructions. Update the
> status checkboxes and task notes in `PARALLAX_REMEDIATION_PLAN.md` as work is
> completed. Stop and report before any migration or recovery design choice
> that could discard existing user data.

## Objective

Make Parallax safe and predictable enough to manage persistent Chromium and
Codex profile data without cross-profile aliasing, path escape, silent metadata
loss, stale-writer overwrites, live-data mutation, ambiguous confirmations, or
unverifiable release artifacts.

## Non-negotiable rules

- Existing user profile data must not be silently deleted, abandoned, or
  redirected during migration.
- Every destructive filesystem target must be canonicalized and proven to be
  inside an approved managed root immediately before mutation.
- User-visible names must never be filesystem identity.
- Imported identifiers and path components are untrusted input.
- Filesystem changes and library metadata changes must commit or roll back as
  one logical operation.
- Load or decode failure must never leave a writable empty store that can
  overwrite the failed source file.
- A failed archive, delete, duplicate, move, or save must not be reported as
  success.
- Profile data must not be mutated while a tracked application instance is
  using it without an explicit expert override.
- Window-local selection, drafts, dialogs, and pending actions must not be
  stored as global application state.
- Do not weaken the existing selection convention: `nil` means no selection;
  model accessors must not silently fall back to the first item.
- Avoid force unwraps and continue using `String(localized:)` for user-facing
  strings constructed in code.

## Current baseline

- SwiftPM macOS 14+ executable with Swift 6 strict concurrency.
- Current library document version: `1`.
- Current test count: 33, all passing at audit time.
- Approximate audit-time line coverage:
  - `LibraryStore`: 68.6%
  - `WorkspaceApplicationLauncher`: 44.3%
  - `LibraryPersistence`: 74.5%
  - SwiftUI/App scenes: 0%
- The existing tests cover many successful profile, migration, archive, parser,
  and confirmation flows, but not the main failure and concurrency paths in
  this plan.

## Severity and status

- **P0:** destructive or security-sensitive defect; fix before normal use.
- **P1:** high data-integrity, isolation, recovery, or release risk.
- **P2:** significant correctness, privacy, usability, or maintainability gap.
- **P3:** polish, documentation, or lower-risk hardening.

Task status uses:

- `[ ]` not started
- `[-]` in progress
- `[x]` complete and verified

## Delivery strategy

Do not implement this plan as one large unreviewable change.

The numbered phases below are workstreams. Task-level `Dependencies` define the
actual execution order. Use these recommended implementation waves:

1. Land BASE-001 and BASE-002 plus failing P0 regression tests.
2. Implement STOR-001 through STOR-004 and the v2 migration contract.
3. Implement FS-001 through FS-004, STOR-005, and PERS-001 through PERS-004.
4. Implement LAUNCH-005 through LAUNCH-010 and SEC-001/SEC-002 so import
   validation can reuse one launch-configuration model.
5. Implement IMP-001 through IMP-005 and PERS-005.
6. Implement LAUNCH-001 through LAUNCH-004 and WIN-001 through WIN-003.
7. Implement APP-001 through APP-005 and UI-001 through UI-008.
8. Finish packaging, documentation, the full regression suite, and CI.

Every phase must:

- add regression tests that fail before the fix;
- preserve or explicitly migrate existing data;
- run `swift build`;
- run `swift test`;
- leave the Git worktree clean after its commit;
- update this plan's task status.

# Phase 0 — Test seams and behavioral fixtures

## BASE-001 — Add injectable filesystem and persistence failure seams

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]
- **Affected areas:** `LibraryStore`, `LibraryPersistence`, profile data helpers,
  tests

### Scope

- Introduce a small filesystem protocol covering existence, attributes,
  canonicalization, directory creation, copy, move, removal, listing, and
  atomic replacement operations used by the store.
- Inject it into `LibraryStore` and the profile-data transaction layer.
- Make persistence writes throw to the caller rather than swallowing errors at
  the lowest layer.
- Provide deterministic test doubles for permission failure, disk-full style
  failure, copy interruption, save failure, and delayed operations.

### Acceptance criteria

- Production behavior still uses `FileManager`.
- Tests can fail each filesystem or persistence step independently.
- No production helper converts a failed data mutation into a success-only
  `Void` result.
- Existing tests continue to pass.

### Required tests

- Archive move failure.
- Delete failure.
- Directory creation failure.
- Copy failure after partial destination creation.
- Persistence save failure before and after a filesystem mutation.

## BASE-002 — Add stable fixtures for legacy, malformed, and hostile libraries

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]
- **Affected areas:** `Tests/ParallaxTests`, test resources

### Scope

Create checked-in fixtures for:

- a valid v1 library;
- the legacy raw application array;
- corrupt/truncated JSON;
- unsupported future version;
- negative and zero versions;
- duplicate application IDs;
- duplicate profile IDs;
- duplicate, empty, `Archives`, case-variant, slash-containing, and traversing
  `storageName` values;
- conflicting import profiles;
- a moved application record;
- custom external `CODEX_HOME` and user-data paths.

### Acceptance criteria

- Fixtures contain no real user paths or secrets.
- Every migration/import/recovery test names the exact fixture it uses.
- Future schema changes can run all old fixtures through a repeatable migration
  matrix.

# Phase 1 — Stable storage identity and library v2

## STOR-001 — Define immutable application and profile storage identities

- **Priority:** P0
- **Dependencies:** BASE-001, BASE-002
- **Status:** [ ]
- **Affected areas:** `ManagedApplication`, `LaunchProfile`,
  `LibraryDocument`, `LibraryStore`

### Scope

- Add an immutable persisted storage identity for every application and
  profile. Use opaque UUID-backed components rather than display names.
- Keep user-facing application/profile names separate from disk identity.
- Prevent edits to these identifiers through normal UI bindings.
- Decide and document whether the existing `storageName` becomes a migration
  source only or remains a display/debug field.
- Bump `LibraryDocument.currentVersion` to `2`.

### Acceptance criteria

- Two same-named applications and profiles always resolve to distinct physical
  directories.
- Renaming an application or profile never changes its storage identity.
- Case and Unicode normalization differences cannot alias storage.
- Encoded v2 documents contain stable unique storage identities.
- No generated storage component contains a separator or reserved path token.

### Required tests

- Same app display name, different application IDs.
- `Work` and `work` profiles on a case-insensitive test volume when available.
- Unicode normalization variants.
- Application and profile rename stability.
- Duplicate imported UUID/storage identity rejection or repair.

## STOR-002 — Implement a lossless v1-to-v2 migration

- **Priority:** P0
- **Dependencies:** STOR-001
- **Status:** [ ]
- **Affected areas:** `LibraryPersistence`, migration code, filesystem
  transaction layer

### Scope

- Decode v1 without trusting its path components.
- Inventory each legacy managed path before changing metadata.
- Allocate safe v2 storage identities.
- Detect legacy collisions, reserved names, traversal, missing paths, multiple
  records pointing to one canonical directory, and external paths.
- Produce a migration plan before moving data.
- Move/copy data transactionally and write v2 metadata only after success.
- On ambiguous collisions, preserve all source data and require user
  resolution; never choose a destructive winner.
- Preserve a backup of the original v1 library and a migration receipt.

### Acceptance criteria

- Successful migration is idempotent.
- Failure leaves the v1 library and data usable and unchanged.
- Unsupported newer libraries remain untouched.
- A migration receipt records old and new canonical locations without secrets.
- Existing valid profiles retain their account data after migration.
- Ambiguous/colliding legacy profiles are quarantined or paused, not merged.

### Required tests

- Clean v1 migration.
- Missing legacy folder.
- `Archives` legacy profile.
- Case-colliding profiles.
- Same-name applications sharing a legacy folder.
- Traversing/empty imported `storageName`.
- Failure at each move and save step with rollback verification.
- Re-running an interrupted migration.

## STOR-003 — Centralize canonical managed path resolution

- **Priority:** P0
- **Dependencies:** STOR-001
- **Status:** [ ]
- **Affected areas:** new path resolver, `LibraryStore`,
  `ApplicationLauncher`

### Scope

- Replace ad hoc string concatenation with URL-based path construction.
- Define an explicit v2 layout, for example:
  - `<base>/Applications/<applicationStorageID>/Profiles/<profileStorageID>`
  - `<base>/Archives/<applicationStorageID>/<profileStorageID>/<timestamp>`
- Require configured base roots to be absolute directory URLs.
- Standardize and resolve the nearest existing ancestor.
- Reject `.`/`..`, separators, relative paths, non-directory roots, unsafe
  symlink ancestors, and targets outside the approved root.
- Expose typed paths for managed profile root, user-data directory, Codex home,
  archive root, and temporary transaction staging.

### Acceptance criteria

- No destructive store method accepts a raw string path.
- Every destructive operation performs a final canonical containment check.
- Relative base paths are rejected with a localized actionable error.
- Symlinked ancestors outside the approved root are rejected.
- Path preview and launch use the same resolved URL.

### Required tests

- Empty, relative, absolute, traversal, separator, symlink, file-instead-of-
  directory, and disconnected-volume cases.
- Canonical containment on existing and partially nonexistent paths.

## STOR-004 — Reserve internal namespaces and validate identifiers

- **Priority:** P0
- **Dependencies:** STOR-003
- **Status:** [ ]

### Scope

- Reserve internal directory names, including archive and transaction staging
  namespaces, case-insensitively and normalization-insensitively.
- Validate imported and persisted identifiers before any path use.
- Never derive internal identity directly from a template or visible profile
  name.

### Acceptance criteria

- A visible profile may be named `Archives` without using the archive directory.
- Imported invalid components are rejected or repaired before entering the
  active library.
- Internal namespaces cannot collide with user data.

### Required tests

- `Archives`, `archives`, normalization variants, `.`, `..`, empty string, and
  transaction staging names.

## STOR-005 — Add an explicit, transactional storage relocation workflow

- **Priority:** P1
- **Dependencies:** STOR-002, STOR-003, FS-001
- **Status:** [ ]
- **Affected areas:** application editor, settings, store, data transaction UI

### Scope

- Stop treating application name or storage text edits as implicit relocation.
- Add an explicit Change Storage Location action.
- Preview old/new canonical paths, disk-space estimate, conflicts, and running
  profile blockers.
- Move data transactionally with progress and rollback.
- Preserve explicit external `CODEX_HOME` and user-data values unless the user
  separately chooses to rewrite them.

### Acceptance criteria

- Editing display name or preset never moves or rewrites profile paths.
- Storage relocation cannot run while affected profiles are active.
- Cancel and failure leave both metadata and data at the old location.
- Successful relocation updates generated isolation paths exactly once.

# Phase 2 — Transactional profile data operations

## FS-001 — Create a profile data transaction coordinator

- **Priority:** P1
- **Dependencies:** BASE-001, STOR-003
- **Status:** [ ]

### Scope

- Model archive, clear, delete, duplicate, and relocate as explicit
  transactions.
- Stage copies/moves in unique sibling temporary directories.
- Validate source/destination identity, free space where practical, and
  containment before mutation.
- Commit filesystem state and metadata in a defined order.
- Roll back or provide a recovery receipt when rollback cannot complete.

### Acceptance criteria

- No operation reports success until data and metadata both commit.
- Partial transaction state is detectable and recoverable after restart.
- Transactions never overwrite an unexpected destination.

## FS-002 — Fix remove/archive/delete failure semantics

- **Priority:** P0
- **Dependencies:** FS-001
- **Status:** [ ]

### Scope

- Propagate archive/delete errors to the caller.
- Keep profile metadata and selection unchanged after failure.
- Offer “Remove Entry Anyway” only as a separate, explicit recovery action that
  shows the canonical remaining data path.

### Acceptance criteria

- Failed archive/delete cannot remove the profile record.
- Successful data mutation followed by failed metadata persistence rolls back
  or records a recoverable transaction.
- Error and status messages identify the exact operation that failed.

## FS-003 — Make duplicate non-destructive and atomic

- **Priority:** P0
- **Dependencies:** FS-001
- **Status:** [ ]

### Scope

- Include existing on-disk destinations when allocating new profile storage.
- Never delete an existing destination as part of ordinary duplication.
- Copy to a unique temporary directory, validate, then atomically publish.
- Persist the duplicate profile only after the copy commits.
- Define external-path duplication semantics:
  - either copy every configured external data root safely; or
  - explicitly label the action “Duplicate Configuration” and do not claim data
    was copied.

### Acceptance criteria

- Remove-only followed by re-duplicate preserves the kept folder.
- Source and destination can never canonicalize to the same path.
- Copy failure leaves no active duplicate metadata and no partial published
  destination.
- Success wording accurately describes what was copied.

## FS-004 — Correct clear and reveal semantics

- **Priority:** P2
- **Dependencies:** FS-001
- **Status:** [ ]

### Scope

- Distinguish “archive and clear existing data” from “create an empty folder.”
- Make Reveal read-only; do not create the target as a side effect.
- When the target is missing, reveal the nearest existing parent or offer a
  separate Create action.

### Acceptance criteria

- Reveal never changes health state or creates data.
- Clear reports whether anything was archived.
- External configured paths are clearly distinguished from the managed profile
  root.

# Phase 3 — Persistence recovery and concurrency

## PERS-001 — Add explicit loaded, recovery, and read-only store states

- **Priority:** P0
- **Dependencies:** BASE-001, BASE-002
- **Status:** [ ]

### Scope

- Represent load state explicitly: loading, loaded, recovery-required,
  unsupported-newer-version, and unrecoverable.
- Disable mutating commands until a valid library is loaded or the user
  explicitly starts over.
- Preserve the original bytes and error details.

### Acceptance criteria

- Corrupt or unsupported libraries cannot be overwritten by later mutations.
- Starting over requires a destructive confirmation and preserves/quarantines
  the original file.
- UI clearly distinguishes empty library from failed library.

## PERS-002 — Add backup, quarantine, and recovery support

- **Priority:** P1
- **Dependencies:** PERS-001
- **Status:** [ ]

### Scope

- Keep bounded last-known-good backups before migrations, replace imports, and
  destructive document rewrites.
- Quarantine corrupt files with timestamps rather than deleting them.
- Add restore and inspect/export recovery actions.

### Acceptance criteria

- Primary corruption can recover from a verified backup.
- Replace import can be undone from a backup.
- Backups have bounded retention and atomic publication.
- Backup files do not contain more secret data than the primary library.

## PERS-003 — Make save failures visible and rollback-safe

- **Priority:** P1
- **Dependencies:** BASE-001, FS-001
- **Status:** [ ]

### Scope

- Stop swallowing save errors in `LibraryStore.save()`.
- Define mutation APIs that either persist successfully or restore the prior
  in-memory state.
- Do not emit success status after failed persistence.

### Acceptance criteria

- Add, update, remove, import, duplicate, and relocation restore consistent
  state on save failure.
- A later successful save cannot accidentally commit a collection of previously
  failed hidden mutations.

## PERS-004 — Prevent stale multi-process writers

- **Priority:** P1
- **Dependencies:** PERS-003
- **Status:** [ ]

### Scope

- Add a document generation/revision and filesystem coordination or locking.
- Detect when the on-disk library changed since load.
- Reject or explicitly merge stale writes.
- Decide whether Parallax should be single-process for library editing; if so,
  enforce it and still retain revision checking for abnormal cases.

### Acceptance criteria

- Two stores cannot silently overwrite one another.
- Stale writers receive an actionable conflict.
- Lock crash recovery is defined and tested.

## PERS-005 — Harden `AppSettings` persistence

- **Priority:** P2
- **Dependencies:** BASE-002
- **Status:** [ ]

### Scope

- Surface corrupt template data instead of silently replacing it.
- Preserve or quarantine bad settings before writing defaults.
- Prevent two processes from rewriting unrelated settings with stale snapshots.
- Define intentional empty-template behavior.

### Acceptance criteria

- Corrupt templates are recoverable.
- An intentionally empty template list remains empty or is explicitly
  prohibited; UI and store agree.
- Updating one setting cannot revert a concurrently changed unrelated setting.

# Phase 4 — Import/export trust and validation

## IMP-001 — Add complete structural import validation

- **Priority:** P0
- **Dependencies:** STOR-001, STOR-003, BASE-002
- **Status:** [ ]

### Scope

Validate before merge/replace:

- supported document version;
- unique application IDs;
- unique profile IDs;
- valid immutable storage identities;
- bounded counts and string sizes;
- canonical application paths;
- duplicate/colliding names and storage;
- reserved or traversing path components;
- valid preset values and required fields.

### Acceptance criteria

- Invalid imports never enter the active store.
- Validation returns all actionable issues, not only the first decoder error.
- Hostile path components cannot reach filesystem helpers.
- Large imports are size-limited before full decode when practical.

## IMP-002 — Treat imported launch configuration as untrusted

- **Priority:** P1
- **Dependencies:** IMP-001, LAUNCH-005, LAUNCH-007
- **Status:** [ ]

### Scope

- Mark imported or externally modified profiles as requiring review.
- Verify target `.app` structure, bundle ID, and executable before first launch.
- Show application, canonical path, arguments, environment keys, isolation
  directories, and security-sensitive variables in a detailed first-launch
  confirmation.
- Flag loader/debug variables and other dangerous imported environment values.

### Acceptance criteria

- Import alone never launches an application or creates profile directories.
- First launch of untrusted imported configuration always requires review,
  regardless of the global confirmation preference.
- Trust is invalidated when relevant imported launch configuration changes.

## IMP-003 — Replace name-only merge with an explicit conflict engine

- **Priority:** P1
- **Dependencies:** IMP-001
- **Status:** [ ]

### Scope

- Match using validated stable identity plus clear relocation rules.
- Detect same-name/different-content conflicts.
- Update the comparison set as profiles are merged.
- Present keep existing, use imported, keep both with rename, and skip choices.
- Do not silently discard application-level fields such as path, preset, or
  base storage root.

### Acceptance criteria

- Merge never silently drops differing configuration.
- Duplicate names in one imported batch cannot bypass conflict handling.
- Same bundle ID at different paths is treated as a relocation/conflict, not
  automatically conflated.

## IMP-004 — Make replace import recoverable

- **Priority:** P1
- **Dependencies:** PERS-002, IMP-001
- **Status:** [ ]

### Scope

- Preview application/profile counts and validation warnings.
- Back up the active library before replacement.
- Preserve existing profile data unless the user explicitly chooses a separate
  cleanup operation.

### Acceptance criteria

- Replace can be undone.
- A failed replacement leaves the active library unchanged.
- Success status is emitted only after persistence completes.

## IMP-005 — Define a truthful export and backup contract

- **Priority:** P2
- **Dependencies:** SEC-002, PERS-002
- **Status:** [ ]

### Scope

- Distinguish:
  - library metadata export;
  - settings/template export;
  - full backup including profile data.
- Decide whether settings/templates are included in a portable configuration.
- Warn that application paths may require relocation on another Mac.

### Acceptance criteria

- UI and documentation state exactly what is included.
- Secrets follow the redaction/omission policy.
- Round-trip tests cover every supported export type.

# Phase 5 — Launch lifecycle and configuration correctness

## LAUNCH-001 — Track launched application lifetime per profile

- **Priority:** P1
- **Dependencies:** BASE-001
- **Status:** [ ]

### Scope

- Return and retain `NSRunningApplication` or a production abstraction.
- Track launching, running, terminating, terminated, and failed states by
  application/profile/request ID.
- Observe termination and clear leases.
- Do not equate an accepted open request with durable process health.

### Acceptance criteria

- Status can distinguish requested, running, exited, and failed.
- Immediate crash/exit is not reported as a durable successful launch.
- Removed profiles do not receive stale launch status updates.

## LAUNCH-002 — Prevent concurrent use and live-data mutation

- **Priority:** P0
- **Dependencies:** LAUNCH-001, FS-001
- **Status:** [ ]

### Scope

- Block a second launch of the same canonical profile storage by default.
- Disable archive, clear, delete, duplicate, and relocate while the profile is
  active.
- Add an expert override with clear corruption risk wording.
- Optionally inspect known Chromium lock files as an additional warning, not
  the sole authority.

### Acceptance criteria

- Two windows cannot launch the same profile concurrently without override.
- Destructive actions cannot run against tracked live data.
- State clears after process termination.

## LAUNCH-003 — Make confirmation requests immutable and window-scoped

- **Priority:** P1
- **Dependencies:** WIN-001
- **Status:** [ ]

### Scope

- Store application ID, profile ID, configuration revision/snapshot, request
  ID, and originating scene.
- Reject, queue, or separately present new requests while one is pending.
- Invalidate and re-confirm if arguments/environment/path changed.
- Show both application and profile names.

### Acceptance criteria

- Confirming A can never launch B.
- Edits after prompting cannot alter the approved launch silently.
- Removed targets produce an actionable error rather than a no-op.

## LAUNCH-004 — Make launch status request-scoped

- **Priority:** P2
- **Dependencies:** LAUNCH-001
- **Status:** [ ]

### Scope

- Track status and errors per launch request/profile.
- Prevent older completions from overwriting newer status.
- Clear stale success when a new attempt begins or fails.

### Acceptance criteria

- Reverse-order completions display correctly.
- A status message never appears under an unrelated selected profile.

## LAUNCH-005 — Add diagnostic argument parsing

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Return parsed arguments plus line/range diagnostics.
- Detect unmatched quotes, trailing escapes, and unsupported grammar.
- Either implement documented shell-like double-quote behavior or explicitly
  define the custom grammar.
- Quote generated paths using the same parser/serializer rather than direct
  string interpolation.

### Acceptance criteria

- Malformed arguments cannot launch without an explicit override.
- Paths containing spaces, quotes, and backslashes round-trip.
- Generated default profiles are valid for every accepted base path.

## LAUNCH-006 — Centralize singleton option resolution

- **Priority:** P2
- **Dependencies:** LAUNCH-005
- **Status:** [ ]

### Scope

- Parse `--user-data-dir=value` consistently.
- Decide and document whether split form `--user-data-dir value` is supported.
- Reject duplicate singleton switches or resolve them using a documented policy
  matching supported applications.
- Use the same result for launch, directory creation, preview, reveal, warning,
  and health checks.

### Acceptance criteria

- Parallax never creates/reveals one directory while launching another.
- Duplicate/blank/mixed forms produce diagnostics.

## LAUNCH-007 — Add validated environment parsing

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Preserve ordered source entries and line diagnostics.
- Validate environment variable names.
- Warn on duplicates and malformed lines.
- Define empty-value and explicit-unset semantics.
- Do not silently trim meaningful value whitespace.

### Acceptance criteria

- Invalid lines are visible and block or require override.
- Preview exactly matches the environment sent to the application.

## LAUNCH-008 — Restrict environment inheritance and tilde expansion

- **Priority:** P1
- **Dependencies:** LAUNCH-007, SEC-001
- **Status:** [ ]

### Scope

- Stop blindly forwarding the complete Parallax process environment.
- Define a safe base environment and explicit inheritance preference.
- Scrub profile-affecting and sensitive development variables unless explicitly
  configured.
- Expand `~` only for documented path-valued settings, not every environment
  value.

### Acceptance criteria

- An unrelated app does not receive shell-inherited secrets by default.
- An inherited hidden `CODEX_HOME` cannot bypass the profile preview.
- Literal non-path values beginning with `~` remain unchanged.

## LAUNCH-009 — Strengthen application and profile health checks

- **Priority:** P2
- **Dependencies:** STOR-003, LAUNCH-006, LAUNCH-007
- **Status:** [ ]

### Scope

- Validate target `.app` directory, bundle structure, executable, bundle ID,
  and canonical path.
- Validate profile paths are directories, writable where needed, contained,
  non-colliding, and not active.
- Detect multiple profiles resolving to the same canonical data root.

### Acceptance criteria

- A regular file cannot pass a folder health check.
- Shared/symlink-aliased paths are reported.
- Health wording reflects what is actually verified.

## LAUNCH-010 — Remove main-actor blocking filesystem preparation

- **Priority:** P2
- **Dependencies:** BASE-001
- **Status:** [ ]

### Scope

- Perform slow canonicalization, network-volume checks, and directory
  preparation off the main actor.
- Return to the main actor only for observable state and required AppKit calls.

### Acceptance criteria

- Slow/disconnected profile storage does not freeze the UI.
- Swift 6 concurrency checks remain clean.

# Phase 6 — Application and multi-window state

## WIN-001 — Introduce a per-scene coordinator

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Keep the shared library repository/model separate from window-local:
  - application selection;
  - profile selection;
  - drafts;
  - importer presentation;
  - alerts/dialogs;
  - pending launch/import/destructive requests;
  - transient status.
- Route commands using focused scene values.

### Acceptance criteria

- Two windows can select and edit different items independently.
- Only the focused/originating window presents an importer or dialog.
- Shared library changes propagate without overwriting window-local state.

## WIN-002 — Capture immutable destructive-action targets

- **Priority:** P0
- **Dependencies:** WIN-001, FS-001
- **Status:** [ ]

### Scope

- Replace boolean-only confirmation state with typed pending actions containing
  immutable application/profile IDs, canonical path snapshot, operation, and
  originating scene.
- Revalidate identity and path immediately before execution.

### Acceptance criteria

- A selection or draft change cannot retarget an open Clear/Remove dialog.
- Confirmation shows the exact current canonical target.
- Stale requests are invalidated safely.

## WIN-003 — Replace whole-value keystroke saves with edit sessions

- **Priority:** P1
- **Dependencies:** WIN-001, PERS-003
- **Status:** [ ]

### Scope

- Stop saving the complete application/profile on every character.
- Use field-granular mutations, debounced commits, or explicit Apply/Cancel edit
  sessions.
- Detect concurrent editor conflicts instead of last-write-win resets.
- Keep the existing guarded draft synchronization behavior where local drafts
  remain.

### Acceptance criteria

- Two windows cannot silently clobber each other's edits.
- Cursor position is stable during external model updates.
- Failed persistence is visible and recoverable.

# Phase 7 — Application library UX

## APP-001 — Define application-to-profile selection behavior

- **Priority:** P2
- **Dependencies:** WIN-001
- **Status:** [ ]

### Scope

- When an application is selected, restore that window's last selected profile
  for the application or explicitly clear selection.
- Do not leave a stale profile ID from another application.
- Distinguish no profiles from no profile selected.

### Acceptance criteria

- Selecting an app with profiles never shows a false “create a profile” state.
- Selection remains `nil` when intentionally cleared; model accessors do not
  silently default.

## APP-002 — Add application relink/relocate support

- **Priority:** P1
- **Dependencies:** LAUNCH-009
- **Status:** [ ]

### Scope

- Detect missing stored application paths.
- Offer Locate Application.
- Verify bundle identity and show conflicts when the bundle ID matches another
  stored app or the path contains a different app.
- When re-adding a matching bundle whose old path is missing, offer to update
  the existing record.

### Acceptance criteria

- Moved apps can be repaired without deleting their profiles.
- Different installations sharing a bundle ID are not silently conflated.

## APP-003 — Make application removal confirmable and recoverable

- **Priority:** P1
- **Dependencies:** FS-001, PERS-002
- **Status:** [ ]

### Scope

- Mark the action destructive.
- Confirm the exact application and profile count.
- Offer keep, archive, or delete managed data with truthful external-data
  caveats.
- Preserve a library backup or undo record.

### Acceptance criteria

- One context-menu click cannot irreversibly remove all configuration.
- Cancel leaves library and selection unchanged.
- Data action failure preserves the application record.

## APP-004 — Correct automatic preset detection

- **Priority:** P2
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Remove the broad “any bundle containing microsoft is Edge” rule.
- Match known Edge bundle identifiers specifically.
- Add representative Word, Teams, Outlook, Edge stable/beta/dev, Chromium,
  Electron, and Codex fixtures.
- Ensure changing to Custom does not silently retain unwanted generated
  settings without explaining them.

### Acceptance criteria

- Non-Edge Microsoft applications are not classified as Edge.
- Detection remains overrideable and transparent.

## APP-005 — Separate metadata edits, preset changes, and reapply actions

- **Priority:** P1
- **Dependencies:** STOR-005, WIN-003
- **Status:** [ ]

### Scope

- Editing name must affect display metadata only.
- Changing preset must preview which generated values would be added, changed,
  retained, or removed.
- “Apply Recommended Settings” must not overwrite explicit values without
  confirmation.

### Acceptance criteria

- Custom `CODEX_HOME` and user-data values survive ordinary metadata edits.
- Generated values can be intentionally refreshed through a dedicated action.

# Phase 8 — Templates, UI, accessibility, and localization

## UI-001 — Address templates by ID, not name

- **Priority:** P2
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Menu items use template UUIDs.
- Profile creation accepts a template ID or complete template value.
- Duplicate display names are either prohibited after normalized comparison or
  remain distinguishable while selecting the correct template.

### Acceptance criteria

- Two same-named templates cannot both resolve to the first one.
- SwiftUI menu IDs are unique.

## UI-002 — Define empty-template and reset semantics

- **Priority:** P2
- **Dependencies:** PERS-005
- **Status:** [ ]

### Scope

- Make Settings and the profile menu agree when no templates exist.
- Add confirmation/undo for Reset to Defaults.
- Add a discoverable delete control usable by keyboard and VoiceOver.

## UI-003 — Surface file importer failures

- **Priority:** P2
- **Dependencies:** WIN-001
- **Status:** [ ]

### Scope

- Handle `.failure` for application and Codex-home importers.
- Ignore only genuine user cancellation.
- Route provider, permission, and malformed selection errors to the originating
  window.

## UI-004 — Split empty and unselected states

- **Priority:** P2
- **Dependencies:** APP-001
- **Status:** [ ]

### Scope

Provide separate views for:

- empty application library;
- applications exist but none selected;
- selected application has zero profiles;
- profiles exist but none selected;
- failed/recovery-required library.

## UI-005 — Fix SwiftUI identity and accessibility semantics

- **Priority:** P2
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Enumerate repeated launch arguments instead of using string identity.
- Keep the Launch button as a separate accessibility element from the profile
  row.
- Add programmatic labels and identifiers to text editors and critical actions.
- Verify keyboard traversal, VoiceOver names, roles, and destructive controls.

### Acceptance criteria

- Repeated arguments render without duplicate-ID warnings.
- VoiceOver exposes both row selection and launch actions.

## UI-006 — Apply appearance consistently to every scene

- **Priority:** P3
- **Dependencies:** WIN-001
- **Status:** [ ]

### Scope

- Apply system/light/dark preference to main and Settings scenes.
- Add a runtime or snapshot test where practical.

## UI-007 — Make status and error presentation operation-scoped

- **Priority:** P2
- **Dependencies:** LAUNCH-004, WIN-001
- **Status:** [ ]

### Scope

- Stop showing one global launch status beneath every profile.
- Present global library errors separately from profile/request status.
- Ensure old success is cleared when a new operation fails.

## UI-008 — Complete localization coverage

- **Priority:** P3
- **Dependencies:** behavioral strings stabilized
- **Status:** [ ]

### Scope

- Localize code-built summaries, generated names, default template content,
  badges, dynamic dialog strings, and pluralization.
- Add a String Catalog if appropriate.
- Test a non-English locale and plural cases.

# Phase 9 — Secret handling and privacy

## SEC-001 — Define a safe child-environment policy

- **Priority:** P1
- **Dependencies:** LAUNCH-007
- **Status:** [ ]

### Scope

- Inventory environment variables required for normal GUI launches.
- Default to a safe base rather than the complete Parallax environment.
- Add explicit opt-in inheritance for advanced use.
- Redact sensitive values from logs and previews.

### Acceptance criteria

- Shell-inherited API keys are not forwarded by default.
- Required macOS launch behavior remains functional.
- Logs never include full environment values.

## SEC-002 — Add secret-aware profile configuration

- **Priority:** P2
- **Dependencies:** LAUNCH-007
- **Status:** [ ]

### Scope

- Warn that ordinary environment values are stored in plaintext.
- Redact values in launch preview by default with a Reveal control.
- Allow export to omit/redact sensitive entries.
- Evaluate Keychain-backed secret references without embedding secrets in JSON
  or UserDefaults.

### Acceptance criteria

- A user cannot accidentally export a secret without a clear warning.
- Secret references resolve only at launch and are never logged.

# Phase 10 — Packaging and release engineering

## PKG-001 — Split local, unsigned archive, and signed release modes

- **Priority:** P1
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Make the documented command behavior truthful:
  - local debug build/run;
  - unsigned local release archive, if supported;
  - signed/notarized distribution release.
- Validate signing identity and notary profile before deleting/rebuilding an
  existing release artifact.
- Do not make a doomed release overwrite the previous good artifact.

### Acceptance criteria

- The README command works in its documented environment.
- Missing credentials fail during preflight before artifact mutation.

## PKG-002 — Add real artifact verification

- **Priority:** P1
- **Dependencies:** PKG-001
- **Status:** [ ]

### Scope

- Make verification operate on a specified existing artifact rather than
  rebuilding it as debug.
- Verify:
  - `plutil`;
  - strict `codesign`;
  - `spctl`;
  - hardened runtime;
  - Team ID/identifier;
  - notarization/stapling where applicable;
  - executable architectures;
  - deployment target;
  - resource presence;
  - ZIP extraction and DMG contents.

### Acceptance criteria

- Verification never deletes/replaces the artifact being checked.
- Debug and release verification have clearly different expectations.

## PKG-003 — Produce declared architecture support

- **Priority:** P1
- **Dependencies:** PKG-001
- **Status:** [ ]

### Scope

- Either build a universal `arm64` + `x86_64` release or explicitly declare
  Apple Silicon-only support everywhere.
- Ensure dependencies and resource bundles match each architecture.

### Acceptance criteria

- Release architecture matches README/system requirements.
- CI validates the final binary with `lipo`.

## PKG-004 — Package SwiftPM runtime resources correctly

- **Priority:** P2
- **Dependencies:** none
- **Status:** [ ]

### Scope

- Copy the generated SwiftPM resource bundle into the application bundle at the
  location expected by `Bundle.module`, or remove the unnecessary SwiftPM
  resource declaration and manage resources through the app bundle.
- Add a runtime resource smoke test.

### Acceptance criteria

- A customer-machine build can load a packaged resource without a developer
  `.build` path.

## PKG-005 — Generate and validate `Info.plist` safely

- **Priority:** P2
- **Dependencies:** PKG-001
- **Status:** [ ]

### Scope

- Use `plutil`/structured generation rather than raw XML interpolation.
- Validate bundle ID, semantic version, build number, and minimum OS.
- Ensure plist minimum OS matches the Mach-O deployment target.
- Add common distribution metadata.

## PKG-006 — Publish artifacts atomically with provenance

- **Priority:** P2
- **Dependencies:** PKG-001, PKG-002
- **Status:** [ ]

### Scope

- Build into a unique temporary staging directory.
- Lock or separate concurrent invocations.
- Atomically publish only verified artifacts.
- Prevent version/build collisions.
- Record Git revision, dirty state, toolchain, SDK, hashes, architecture, and
  signing identity in a manifest.

## PKG-007 — Improve DMG and update delivery

- **Priority:** P3
- **Dependencies:** PKG-002
- **Status:** [ ]

### Scope

- Add an Applications alias and clear installation affordance.
- Decide whether to sign/notarize/staple the final DMG container.
- Document manual update behavior or add an updater/feed with integrity and
  rollback support.

# Phase 11 — Product truth and documentation

## DOC-001 — Correct isolation guarantees

- **Priority:** P1
- **Dependencies:** LAUNCH-001, LAUNCH-009
- **Status:** [ ]

### Scope

- Explain that `createsNewApplicationInstance`, `--user-data-dir`, and
  `CODEX_HOME` are best-effort application configuration, not a macOS sandbox.
- Document shared Keychain, app groups, containers, helpers, singleton IPC, and
  application-specific storage limitations.
- Distinguish “launch request accepted” from “application running.”

## DOC-002 — Document managed versus external profile data

- **Priority:** P2
- **Dependencies:** FS-003, IMP-005
- **Status:** [ ]

### Scope

- State which folders Clear, Duplicate, Archive, Remove, and Export affect.
- Explain external `CODEX_HOME` and user-data behavior.
- Clearly label metadata export versus complete backup.

## DOC-003 — Add recovery and migration documentation

- **Priority:** P2
- **Dependencies:** STOR-002, PERS-002, PERS-004
- **Status:** [ ]

### Scope

- Document v2 migration, backup locations, conflict recovery, stale-writer
  behavior, moved-app relinking, and transaction recovery receipts.

# Phase 12 — Regression, UI, and release CI

## TEST-001 — Add P0/P1 data-integrity regression coverage

- **Priority:** P0
- **Dependencies:** BASE-001, BASE-002
- **Status:** [ ]

### Required tests

- `Archives` profile cannot collide with archive storage.
- Traversing/empty/reserved imported identity is rejected.
- Failed archive/delete keeps metadata.
- Remove-only then re-duplicate preserves existing data.
- Same-name apps have distinct storage.
- Case/Unicode-equivalent profiles have distinct storage.
- App rename keeps storage identity and explicit isolation configuration.
- Every transaction failure point rolls back.
- Corrupt/newer library remains unchanged and read-only.
- Two writers cannot lose updates.

## TEST-002 — Add launch lifecycle and parser coverage

- **Priority:** P1
- **Dependencies:** LAUNCH-001 through LAUNCH-009
- **Status:** [ ]

### Required tests

- Second launch and live-data actions are blocked.
- Running state clears on termination.
- Immediate process exit is reported.
- Confirmation target/configuration remains immutable.
- Concurrent completions arriving out of order.
- Missing/malformed/replaced app bundle.
- Quotes, backslashes, malformed arguments, malformed environment, duplicates,
  unset semantics, relative paths, and singleton option handling.
- Parent environment secrets are not inherited by default.

## TEST-003 — Add import/persistence recovery coverage

- **Priority:** P1
- **Dependencies:** IMP-001 through IMP-005, PERS-001 through PERS-005
- **Status:** [ ]

### Required tests

- Merge conflict choices.
- Duplicate IDs and storage identities.
- Replace backup and restore.
- Size/count limits.
- Settings corruption and intentional empty templates.
- Save rollback and stale-writer conflicts.
- Export round trips and secret policy.

## TEST-004 — Add SwiftUI and multi-window tests

- **Priority:** P1
- **Dependencies:** WIN-001 through UI-007
- **Status:** [ ]

### Required tests

- Independent selection in two windows.
- App switch selects/restores a valid profile without fallback semantics.
- Launch confirmation and destructive dialog cannot retarget.
- Importer failure presentation.
- Application removal cancellation.
- Duplicate template identity.
- Duplicate launch argument rendering.
- Empty/recovery states.
- Appearance in main and Settings scenes.
- VoiceOver labels/roles and keyboard navigation.

## TEST-005 — Add packaging CI

- **Priority:** P1
- **Dependencies:** PKG-001 through PKG-006
- **Status:** [ ]

### Scope

- Add CI jobs for build/test, release assembly, resource loading, plist
  validation, architecture, deployment target, and unsigned artifact structure.
- Add credential-gated signed/notarized release verification.
- Extract and inspect ZIP/DMG artifacts in a clean environment.

# Finding-to-task coverage matrix

This matrix prevents audit findings from being lost during implementation.

| Audit finding | Primary tasks |
|---|---|
| `Archives` profile deletes/corrupts archive namespace | STOR-003, STOR-004, STOR-005, FS-002, TEST-001 |
| Imported `storageName` traversal/empty component | STOR-002, STOR-003, IMP-001, TEST-001 |
| Symlink ancestor and TOCTOU path redirection | STOR-003, FS-001, FS-002 |
| Failed archive/delete still removes metadata | BASE-001, FS-002, PERS-003, TEST-001 |
| Duplicate deletes a preserved destination | FS-001, FS-003, TEST-001 |
| Duplicate metadata saved before copy completes | FS-001, FS-003, PERS-003 |
| External-path duplicate does not copy real data | FS-003, DOC-002 |
| Application edits overwrite custom isolation | STOR-005, APP-005, WIN-003, TEST-001 |
| Application rename/base-root edit orphans data | STOR-001, STOR-005, APP-005 |
| Same-name applications share storage | STOR-001, STOR-002, TEST-001 |
| Case/Unicode-equivalent profiles share storage | STOR-001, STOR-004, TEST-001 |
| Relative/non-directory base storage paths | STOR-003, STOR-005 |
| Corrupt/newer library can be overwritten | PERS-001, PERS-002, TEST-001 |
| No backup/quarantine/recovery | PERS-002, DOC-003 |
| Save failure leaves divergent in-memory state | PERS-003, FS-001, TEST-003 |
| Filesystem and metadata are non-transactional | FS-001, PERS-003, TEST-001 |
| Multiple processes lose library/settings updates | PERS-004, PERS-005, TEST-001 |
| Imported duplicate IDs break selection/mutation | STOR-002, IMP-001, TEST-003 |
| Import merge drops or duplicates profiles | IMP-003, TEST-003 |
| Bundle-ID-first merge conflates installs | IMP-003, APP-002 |
| Replace import is irreversible | PERS-002, IMP-004 |
| Import is unbounded | IMP-001 |
| Import becomes trusted app launch configuration | IMP-002, LAUNCH-009 |
| Export omits settings/data and may include secrets | IMP-005, SEC-002, DOC-002 |
| AppSettings corruption silently resets templates | PERS-005, TEST-003 |
| Same profile can launch twice | LAUNCH-001, LAUNCH-002, TEST-002 |
| Live profile can be clear/delete/duplicate/relocate | LAUNCH-002, FS-001 |
| Launch confirmation can be replaced/retargeted | WIN-001, LAUNCH-003, TEST-004 |
| Confirmation approves mutable configuration | LAUNCH-003 |
| Accepted open request reported as running success | LAUNCH-001, LAUNCH-004, DOC-001 |
| Out-of-order completions overwrite global status | LAUNCH-004, UI-007 |
| `--user-data-dir` forms/duplicates disagree | LAUNCH-005, LAUNCH-006 |
| Relative isolation paths resolve differently | STOR-003, LAUNCH-006 |
| Shell parser accepts malformed input | LAUNCH-005, TEST-002 |
| Environment parser drops/alters invalid input | LAUNCH-007, TEST-002 |
| All environment values receive tilde expansion | LAUNCH-008 |
| Complete parent environment leaks to children | SEC-001, LAUNCH-008 |
| Profile secrets stored/displayed/exported | SEC-002, IMP-005 |
| Health checks only test existence | LAUNCH-009 |
| Generic profile folder/health semantics unclear | LAUNCH-009, DOC-002 |
| Launch preparation can block main actor | LAUNCH-010 |
| Application selection leaves stale profile ID | WIN-001, APP-001, TEST-004 |
| Shared multi-window state and dialogs | WIN-001, WIN-002, WIN-003 |
| Destructive dialogs reference mutable drafts | WIN-002, TEST-004 |
| Global status appears under wrong profile | LAUNCH-004, UI-007 |
| Moved app cannot be relinked | APP-002 |
| Application removal is immediate/unrecoverable | APP-003 |
| Any Microsoft bundle detected as Edge | APP-004 |
| Duplicate template names are unreachable | UI-001 |
| Empty templates disagree with fallback defaults | PERS-005, UI-002 |
| Importer failures are ignored | UI-003 |
| Empty and unselected states are conflated | APP-001, UI-004 |
| Launch button accessibility is collapsed into row | UI-005 |
| Duplicate argument strings have duplicate SwiftUI IDs | UI-005 |
| Appearance does not apply to Settings | UI-006 |
| Reveal creates directories | FS-004 |
| Clear reports archive when nothing existed | FS-004 |
| Localization gaps | UI-008 |
| Documented release command fails without hidden signing setup | PKG-001 |
| Debug app described as signed/distributable | PKG-001, PKG-002, DOC-001 |
| `verify` rebuilds/replaces a debug artifact | PKG-002 |
| Host-architecture-only release | PKG-003 |
| Plist minimum OS can disagree with Mach-O | PKG-002, PKG-005 |
| Raw XML metadata interpolation | PKG-005 |
| SwiftPM resource bundle omitted | PKG-004 |
| Release publication is non-atomic/racy | PKG-006 |
| Version/build artifact collisions and no provenance | PKG-006 |
| DMG installation/notarization/update gaps | PKG-007 |
| README overstates isolation guarantees | DOC-001 |
| No UI/multi-window/accessibility tests | TEST-004 |
| No packaging/signing/release CI | TEST-005 |

# Completion gate

The remediation program is complete only when:

- every P0 and P1 task is `[x]`;
- every P2 task is implemented or explicitly accepted as deferred with a
  documented rationale;
- v1 fixtures migrate losslessly to v2;
- hostile imports cannot escape managed roots or create duplicate identity;
- every destructive operation is transactional and rollback-tested;
- corrupt/newer libraries cannot be overwritten;
- two processes cannot silently lose updates;
- active profile data cannot be mutated accidentally;
- multi-window confirmations cannot change targets;
- child applications do not inherit unrelated secrets by default;
- signed release artifacts pass strict verification on declared architectures;
- `swift build` and `swift test` pass;
- packaging CI passes;
- README behavior and guarantees match the implementation.
