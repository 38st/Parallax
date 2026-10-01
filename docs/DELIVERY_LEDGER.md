# Delivery ledger

This ledger is the current delivery snapshot for Parallax. Historical issue,
branch, and CI narratives were removed because they described superseded work
and made the active release state hard to identify.

Last verified: September 28, 2026, at source commit `8c88e71` (clean tree).

## Current product state

October 1 implementation: Claude **Shared Conversations** adds a central
revision library, explicit account-history bindings, managed account switching,
per-conversation review and non-destructive migration from legacy groups. The
implementation and synthetic test map are in [Shared history](SHARED_HISTORY.md).
The September measurements below are historical and do not verify this change.
Fresh gate evidence must identify this implementation's source commit. Native
cross-account acceptance and installation remain separately authorized manual
steps; a successful tracked launch does not establish either provider login or
successful resume.

September 28 addition: local Claude Code conversation copying is an
owner-authorized preview with local history-format validation instead of an
exact Desktop version requirement. Its
implementation and synthetic regression coverage are described in
[conversation copying](CLAUDE_CONVERSATION_COPY.md). The gate results below
include its synthetic tests; native cross-account continuation still requires
manual verification.

September 28 addition: optional [shared local Code history](SHARED_HISTORY.md)
links selected Claude/Codex spaces and synchronizes before launch. The
`SharedHistoryTests`, `SharedHistoryCodexTests`, `SharedHistoryStoreTests` and
`SharedHistoryLibraryTests` cover synthetic round trips and failure recovery.
The gate results below include these synthetic tests; native signed-in
Desktop acceptance remains unverified.

| Area | Status | Evidence |
| --- | --- | --- |
| Workspace navigation | Verified | Control Center and Local Spaces use one persistent `NavigationSplitView` sidebar. Sidebar selection and the two detail tabs stay synchronized. |
| Claude desktop spaces | Verified | Every Claude space receives a distinct managed `--user-data-dir` and `CLAUDE_CONFIG_DIR`; Launch Services is asked for a new application instance. Existing and newly created managed directories are forced to owner-only `0700` before launch. The `CLAUDE_CONFIG_DIR` folder is part of launch health, collision checks, and import review: two Claude spaces that share one folder cannot run at the same time, and Duplicate gives the copy its own folder (`ClaudeIsolationFollowupAuditRegressionTests.testClaudePeerCollisionUsesExpandedPathAndCannotBeOverridden`, `ClaudeIsolationFollowupAuditRegressionTests.testClaudeDuplicateDropsAllExplicitConfigEntriesAndKeepsOtherText`). |
| Claude account tracking | Verified preview | Each tracked Claude account receives an owner-only account-specific `CLAUDE_CONFIG_DIR`; sign-in, status, and parsed live `/usage` operations are scoped independently to that account. A sign-in the provider confirms stays connected when the follow-up `/usage` read fails, and accounts are rechecked about every 5 minutes (`ProviderAccountAuditRegressionTests.testConfirmedClaudeAuthenticationSurvivesEveryUsageFailure`, `AccountsAuditRegressionTests.testHealthyAccountIsDueAtFiveMinutes`). |
| Codex account tracking | Verified preview | Each tracked record uses a provider/account-specific `CODEX_HOME` and the official local app-server status flow. Codex sign-ins run one at a time (`AccountsAuditRegressionTests.testCodexSignInsSerializeButRefreshesRemainIndependent`). |
| Localization | Verified | Census at `8c88e71`: 1,303 source keys from 1,499 literals; 1,310 English and 1,310 Spanish entries, zero debt, zero new issues. The extractor covers initializer arguments, ternaries, and returned keys (`LocalizationAuditRegressionTests.test_initializer_memberwise_ternary_and_returned_keys`), and the Spanish catalog is checked for the formal register (`IntegrationCatalogAuditRegressionTests.testMergedCatalogsHaveUniqueKeysNoBlankLinesAndNoRetiredKeys`). |
| Quality gates | Verified locally | Local scripts enforce warning-clean tests, localization, coverage, secret scanning, ASan, TSan, production Keychain characterization, local artifact packaging, and clean-artifact inspection. `script/run_quality_gates.sh` runs them in order. Coverage and packaging pin SwiftPM's native build system, the whitespace gate also checks commits that have not been pushed, and release compiles a committed `git archive` snapshot (`GateAuditRegressionTests`). The coverage floor is 51,137 / 75,458 (67.77%, measured at 84b67f7). There is no hosted CI. Signed/notarized release remains a manual credentialed procedure. |

## Verification evidence

All 14 local gates passed via `./script/run_quality_gates.sh --full` at
`8c88e71` (clean tree), recorded September 28, 2026. The
[release gate](production-readiness/release-gate.md) lists the command for each
row.

| Gate | Result |
| --- | --- |
| Release build with warnings as errors | PASS |
| Full Swift test suite with warnings as errors | 2,121 tests, 0 failures, 2 skipped |
| Fresh isolated product line coverage | 58,587 / 84,463 product lines (69.36%); floor 51,137 / 75,458 (67.77%, measured at 84b67f7) |
| Localization checker | 1,303 source keys from 1,499 literals; 1,310 English and 1,310 Spanish entries, zero debt, zero new issues |
| Localization checker contracts | PASS |
| Evidence hygiene contracts | PASS |
| Coverage gate contracts | PASS |
| Warning gate contract | PASS |
| Packaging contracts | PASS |
| Native artifact integration | PASS, 12/12: reproducible ZIP, DMG, install/upgrade/rollback, provenance, collision verification |
| Secret scan | PASS |
| Thread Sanitizer lane | PASS |
| Address Sanitizer lane | PASS |
| Patch whitespace | PASS |

The two skips were
`NSWorkspaceApplicationLauncherIntegrationTests.testWorkspaceControllerActivatesOnlyTheExactTrackedInstance`
(documented capability skip) and
`ReadmeScreenshotRenderingTests.testRenderReadmeScreenshots` (opt-in README
screenshot renderer). Neither verifies the skipped behavior. Artifacts were
ad-hoc signed only; Developer ID signing and notarization were not done.

## Changes in this update

Behavior changes since the previous snapshot at `3fc2988`. The commits up to
`e6123cf` only added the gate runner, updated documentation, and split source
files; the changes below come from the bug-audit fixes in `edfa888` through
`a85f70e`, with September 28 follow-ups noted below. The
[gap register](production-readiness/gap-register.md) (PRX-021 to PRX-039)
records the audit findings and their resolution.

### Library and recovery

- Opening a new window while another Parallax window or process is working no
  longer runs recovery. The window opens read-only and retries on its own, and
  spaces that an unfinished operation involves stay closed until recovery
  finishes.
- Storage relocation, profile data changes, and application removal can no
  longer be undone or damaged by recovery running in another window.
- Large Clear, Duplicate, Archive, Delete, and relocation operations no longer
  put the library into recovery on later launches.
- A Remove and Delete Data, application removal, or relocation interrupted by
  quitting, a crash, or power loss now finishes or rolls back the next time the
  library opens.
- Parallax prunes old operation records and removes leftover temporary files
  each time it loads the library.
- If recovery is waiting for a stuck launch record, the message names the
  space, and Clear Stuck Launch Record is available for it.
- When `library.json` is missing but operations still need recovery, the
  recovery screen offers Restore Latest Verified Backup. Start Over is not
  offered.
- A failed legacy-library migration no longer blocks later attempts. The
  recovery screen names what is blocking migration and where.
- Backups are ordered by when they were published, so a clock change cannot
  prune the newest backup.
- The selected application and space stay selected while they exist.
  Otherwise nothing is selected; Parallax no longer jumps to the first item.

### Space data

- Remove, Clear, and Duplicate work for spaces that have never been opened.
  Remove Space Only works again.
- While a data operation runs, its spaces cannot be opened from any window.
  The expert override for a destructive action on a running space does not
  bypass another data operation.
- Clear and Duplicate undo their changes immediately if they fail, and the
  reported result matches what happened.
- Clear, Duplicate, and Remove report an external `CLAUDE_CONFIG_DIR` as
  external data that stays in place.
- Keychain items stay in place while any saved space or unsaved draft still
  uses them.
- Reveal User Data and Reveal Codex Home open the managed folder for default
  spaces.

### Application removal

- Removal stops with a clear message when the storage volume is disconnected.
- A removal attempt that is refused no longer creates a backup.
- The list of external paths now includes an external `CLAUDE_CONFIG_DIR` and
  leaves out paths inside managed storage.
- Spaces containing stale Chromium Singleton links, or other unsupported
  items, are refused before any change. The message names the space and the
  item.
- When recovery cannot continue safely, Keep Files and Continue stops recovery
  for that removal and leaves every file in place. The saved locations appear
  under Preserved Files. After you close the window or restart Parallax,
  Review Application Removal… on the recovery screen returns to these choices.
- A newly added application selects its new space.

### Storage relocation

- The preview is prepared in the background, shows progress, and can be
  cancelled.
- The preview names each blocker, such as settings it cannot parse, explicit
  paths inside the storage, or other applications that use it.
- Relocation is refused when the destination lacks POSIX file permissions or
  sits inside another application's storage, and while an earlier relocation
  of the same application is unfinished.
- “Change…” is disabled while a relocation runs.
- The destination is flushed to disk before the original is deleted. Original
  data that cannot be removed safely is left in place, and Parallax shows its
  location once in each window until you dismiss the notice.
- Relocation keeps other environment variables in CRLF text and copies
  read-only files correctly.

### Launching and isolation

- `f248871` adds Open Terminal in This Space and confirmed `parallax://open`
  links. `75d4a3e` adds Firefox and VS Code-family presets, capability
  summaries, and heuristic primary-folder activity notices. See
  [Isolation and data ownership](ISOLATION_AND_DATA.md) for their limits.
- `75d4a3e` preserves the complete launch source when rebuilding confirmation
  and recovery fingerprints, fixing rejected confirmed Claude launches
  (PRX-039).
- Arguments made only of dashes no longer crash Parallax.
- `--user-data-dir <path>` now opens the space's own folder.
- A `--user-data-dir` or `CODEX_HOME` typed in the editor is used at launch.
- For Claude spaces, the `CLAUDE_CONFIG_DIR` folder is now checked for health
  and collisions and shown in import review. Two Claude spaces that share a
  configuration folder cannot run at the same time, and duplicating a Claude
  space gives the copy its own folder.
- More secrets are detected and redacted, for example credential URLs, bare
  names such as `API_KEY`, and lines joined by a trailing backslash.
- Line separators such as U+2028 in environment text block launch.
- Imported Claude spaces approved by an earlier build may ask for review once
  more.
- A crash during a launch-record write no longer locks the library. A damaged
  launch record blocks only its own space.
- Spaces blocked by an old launch record can be freed with Clear Stuck Launch
  Record, which asks for confirmation.
- If an app declines Quit, its space returns to running. A crash right after
  launch now counts as unexpected.
- After an open error with an unknown result, later opens of the same app wait
  and name the space whose record is stuck. Clearing that record, after every
  instance of the app has quit, lets them continue, and Recent Activity shows
  the cleared open as “Open cancelled”.

### Managed storage

- An operation stops, instead of entering it, when another volume is mounted
  inside managed storage.
- Parallax's own storage folders must belong to you. Group or world write
  access is removed from them, and folders owned by others or carrying
  access-control entries are refused.
- `d09732e` adds UUID-bound root recovery across drive replugs, advisory
  enrollment for missing roots outside `/Volumes`, and Forget This Drive.
  Recovery validates only roots needed by its branch (PRX-034). See
  [Migration and recovery](MIGRATION_AND_RECOVERY.md#external-storage-drives).

### Settings and templates

- Export Preserved Copy no longer crashes.
- An oversized value is rejected on its own instead of putting Settings into
  recovery.
- Other Parallax writes no longer force Settings into recovery.
- Text fields save 400 ms after you stop typing.
- Saving no longer leaves hidden copies of old settings behind.
- Spanish default templates saved by earlier builds keep their names. Reset
  to Defaults applies the corrected names; it replaces every template, and
  Undo Reset is available. Builds `84b67f7` to `d203594` changed these names
  automatically; this build keeps whatever name is saved.

### Editor, import, and export

- Discard Changes restores the saved version, and Open launches it.
- “Choose an App” works on the Control Center tab.
- “Open Parallax” in the menu bar reuses the existing window.
- “Use Imported” keeps an existing application's storage location.
- An import that times out while publishing its backup no longer treats
  another window's newer save as damage.
- Exporting library metadata is refused, and its menu item is disabled, until
  the library has loaded.

### Accounts (preview)

- A sign-in the provider confirms stays connected when the follow-up usage
  read fails.
- Accounts are rechecked about every 5 minutes.
- Codex sign-ins run one at a time.
- Quitting Parallax stops provider sign-in processes and their child
  processes.

### Translations

- The missing Spanish recovery and relocation strings were added,
  mistranslations were fixed, and the formal register is used throughout.
- File system errors now have localized messages.

### For people building from source

- Packaging and coverage pin SwiftPM's native build system.
- Releases build from a committed snapshot.
- The whitespace gate also checks commits that have not been pushed.
- The coverage floor is raised to 51,137 / 75,458 (67.7688%, measured at 84b67f7).

### Known limitations

- Missing-root detection outside `/Volumes` depends on usable volume
  enrollment. Legacy transaction records retain device-number checks
  (PRX-034).
- Relocation to a Mac OS Extended (HFS+) volume fails, without losing data,
  when file names contain composed accented characters (PRX-035).
- `d09732e` retires completed transaction records and writes cancelled history
  compatibly. Unfinished newer records and deferred cleanup can still block
  older builds; v2 application-removal phases deliberately fail closed on
  downgrade. Keep the backup made before updating (PRX-036).
- Presentation-logic tests now cover “Choose an App” and repeated launch
  warnings (PRX-038); native UI checks remain manual. The
  [manual UI checklist](BUILD_AND_RELEASE.md#manual-ui-checks) is pending.

## Repository state

Recorded September 10, 2026 after the branch, worktree, and tracker cleanup.
Mobile branch disposition updated September 28, 2026.

| Item | Disposition |
| --- | --- |
| Hosted CI | Removed in `afb6981`. GitHub Actions was already disabled for the repository and had not run on `master` since August 6, 2026. Quality gates are the local scripts listed in the release gate. |
| `wip/parallax-mobile-prototype-20260729` | Deleted locally and remotely on September 28, 2026 at the maintainer's direction. Its single unique commit, `feb7daaf`, was not merged into `master`. See the [mobile history](MOBILE_STATUS.md). |
| `wip/parallel-development-20260728` | Superseded. Its single commit `1d7c7b9` is byte-identical to the former `AF-009` stash and its behavior was integrated into `master` in `be1bc11` and later refactors. The stash was dropped, the `Parallax-dev` worktree was removed, and the branch was deleted on September 10, 2026 at the maintainer's direction. |
| `codex/reconcile-product-20260816`, `wip/parallax-product-run-20260729` | Triaged and closed out; see the [branch triage](production-readiness/branch-triage.md). The product-run branch has no unique commits. Of the 68 commits on the codex branch, 33 were already in `master`, 9 were obsolete or superseded, 20 were not applicable (hosted CI lanes or removed product-run bookkeeping), and 4 were ported with contract tests in `a423f9a` and `9f5476e`. Two stay open by choice: frozen release metadata binding needs tracked changelog and release-notes documents plus a new mode, and a test-harness cleanup allowlist is unsafe under the system bash. Their worktrees were removed and both branches were deleted on September 10, 2026 at the maintainer's direction; the triage document is the record. |
| `relay/*` branches, `.relay/` state, `wip/parallax-integrated-rc-20260729` | Removed. Their content was already in `master` (the Relay subsystem itself was removed in `3ba1298`). |
| Issues #14 to #21 (Relay program) | Closed as describing a removed component. |
| Issue #1 (ShellWordsParser adapter tests) | Closed; the tests have been on `master` since `50cc2d1`. |

## External release boundary

The source and unsigned/ad-hoc artifact lanes are locally verified. Public
binary distribution is not authorized by this ledger. A final release still
requires all of the following external inputs:

- an approved version and build number;
- a Developer ID Application identity;
- an authorized Apple notary profile;
- successful signing, notarization, stapling, and Gatekeeper checks;
- clean-account install, upgrade, and rollback verification of the exact signed
  artifacts; and
- explicit publication approval.

Use [Build and release](BUILD_AND_RELEASE.md) and the
[release gate](production-readiness/release-gate.md) for the operational
commands and decision boundary.
