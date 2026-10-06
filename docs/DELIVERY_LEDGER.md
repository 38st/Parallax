# Delivery ledger

Language policy changed October 6, 2026: the product is now English-only.
References to translated catalogs in dated validation records below describe
those historical trees, not the current supported languages.

This ledger is the current delivery snapshot for Parallax. Historical issue,
branch, and CI narratives were removed because they described superseded work
and made the active release state hard to identify.

Verification is bound to each dated entry's source commit. Earlier test counts,
coverage measurements, installations, and screenshots do not verify newer code.

## Current product state

The October 4 workspace implementation consolidates everyday actions into
Home, app pages, Activity, and Settings. The acceptance map and data-compatibility
rules are in [Workspace simplification](WORKSPACE_SIMPLIFICATION.md).

| Area | Implemented behavior | Evidence locations |
| --- | --- | --- |
| Switching | Failed preparation replaces progress immediately. Retry and cancellation respect the owning request and require inactive storage before recovery. | `SpaceOperationStatusView`, `LibraryStore+LaunchLifecycle`, `LibraryStore+ConversationLibrary`, `ConversationLibraryIntegrationTests` |
| Account presentation | Expected Desktop email, dated user confirmation, and an optional usage-record link are separate from live provider identity. Stale usage stays labeled historical. | `SpaceAccountLink`, `SpaceAccountDetailsView`, `SpaceAccountLinkTests` |
| Everyday navigation | One sidebar, direct Open/Show actions, editable space sheets, and recent spaces on Home and in the menu bar. Required menu-bar launch reviews route to the main window. | `CorporateControlCenterView`, `AllSpacesView`, `ProfileListView`, `MenuBarOpenRoutingTests`, `ReadmeScreenshotRenderingTests` |
| History | One History control, explicit membership review, title/project search, and contextual revision recovery. Future spaces remain separate until reviewed. Existing libraries, bindings and revisions remain saved. | `ConversationLibraryView`, `ConversationSearchTests`, `AllAccountHistoryTests`, `ConversationLibraryIntegrationTests` |
| Main Codex workspace | One destination with explicitly selected launch settings. The native app manages account changes. Separate histories remain retained. | `CodexMainOpenView`, `CodexSharedWorkspaceTests` |
| Supporting flows | Settings groups usage connections, configuration import/export and per-app storage settings; Activity groups launch and provider records. English catalogs accompany the changes. | `WorkspaceSettingsView`, `CorporateAccountTrackerView`, localization scripts |

These are local source-preview capabilities. No provider identity is inferred
from a name, namespace, CLI connection, or saved user confirmation. Native
login and successful conversation continuation remain separate manual acceptance
checks. The October 4 redesign does not install or launch a new app bundle.

## Verification evidence

### October 4: workspace simplification and owned switch recovery

Implementation and test source: `94df9758ceed9ca6b1b0051ade3216d6c3a38713`,
clean tree. No source edits occurred during these final verification runs.
Earlier runs were superseded by localization corrections and a deterministic
recovery-test fixture. A prior packaging attempt failed while detaching a
test disk image; the final native rehearsal ran separately and completed.

Commands completed successfully:

```bash
./script/run_quality_gates.sh --output-dir .build/workspace-redesign-final
./script/check_coverage.sh --output-dir .build/workspace-redesign-coverage-final
PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh
git diff --check
```

All ten fast gates passed: release compilation and the full suite with warnings
as errors, localization, warning/evidence/coverage/packaging contracts, pinned
secret scanning, and whitespace checks. The full suite ran 2,241 tests with
three skips and zero failures (769.491 seconds). The separate isolated coverage
suite ran the same 2,241 tests with three skips and zero failures (741.290
seconds). Product coverage passed at 61,392 / 89,223 lines (68.8074%), above the
51,137 / 75,458 baseline (67.7688%). Localization reported 1,413 source keys
from 1,651 literals, 1,442 entries in each language, and zero debt or new issues.

Native packaging integration passed all 12 checks, including local bundle,
ZIP and DMG verification, resource smoke checks, upgrade/rollback in disposable
directories, provenance, collision refusal, and a byte-identical ZIP rebuilt
from an empty cache. Sanitizer lanes were not rerun for this change.

Coverage provenance is bound to source-input SHA-256
`7d2aadb7ecab5e9db5b1d8e593c1f056d9669fc42c046cfd0cc402c698c4ca14`.
Fast-gate and coverage outputs are under `.build/workspace-redesign-final/`
and `.build/workspace-redesign-coverage-final/`. The native packaging log is
`/tmp/parallax-workspace-packaging-serial.log`.

The two opt-in screenshot tests passed using the UI source subsequently
committed unchanged in `c07d7c4ae4df9e2074cca4742a60061bec1e0381`:

```bash
PARALLAX_README_SCREENSHOT_DIR="$PWD/.build/redesign-final-screenshots" swift test --jobs 4 -Xswiftc -warnings-as-errors --filter ReadmeScreenshotRenderingTests
```

The seven captures were visually reviewed and saved under `docs/images/`;
the rendering log is `/tmp/parallax-redesign-final-render.log`. Subsequent
commits changed Spanish copy and recovery-test setup, not the captured English
views. Rendering used synthetic accounts and test-owned windows. No installed
app bundle was replaced, and no real provider sign-in, account switch, or
conversation continuation was performed. Those remain separate manual
acceptance checks.

### October 2: one main Codex workspace across accounts

Implementation source: `a579dc8165d9f2b2ff5a3ff2211d907382d44731`, clean tree.
The final required checks below ran against that source without edits.
Earlier runs were superseded after catalog formatting/Spanish corrections
and the launch-preview/folder-action follow-up; they are not completion evidence.

Commands completed successfully:

```bash
./script/run_quality_gates.sh --output-dir .build/codex-main-history-gates-final
./script/check_coverage.sh --output-dir .build/codex-main-history-coverage-final
PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh
./script/build_and_run.sh install --architecture native
./script/build_and_run.sh verify --artifact /Applications/Parallax.app --expect-local --architecture native
git diff --check
```

All ten fast gates passed: release compilation and the full suite with warnings
as errors, localization, warning/evidence/coverage/packaging contracts, pinned
secret scanning, and whitespace checks. The full suite ran 2,185 tests with two
skips and zero failures (503.767 seconds). The separate isolated coverage suite
ran the same 2,185 tests with two skips and zero failures (487.052 seconds).
Product coverage passed at 60,568 / 87,946 lines (68.8695%), above the
51,137 / 75,458 baseline (67.7688%). Localization reported 1,365 source keys
from 1,569 literals, 1,372 entries in each language, and zero debt or new issues.
Native packaging integration passed all 12 checks. Sanitizer lanes were not
rerun for this change.

Coverage provenance is bound to source-input SHA-256
`71578995723b1c9df0e5d0448999ecd9b4ab9cb3e0c98eb8f908a010b529f0a1`.
Gate and coverage outputs are under `.build/codex-main-history-gates-final/`
and `.build/codex-main-history-coverage-final/`. Packaging, installation and
installed-artifact verification logs are `/tmp/parallax-codex-main-packaging-final.log`,
`/tmp/parallax-codex-main-install.log`, and
`/tmp/parallax-codex-main-installed-verification.log`.

The installed native arm64 app records the same clean source `a579dc8` in
`/Applications/Parallax.app/Contents/Resources/PackagingProvenance.plist`.
Its executable SHA-256 is
`8da83e8802f2d6c9aa6772358349959c6ea3a70c6f7a017a47fc4e1705ce64b7`.

The owner-authorized installed UI's `codex-shared-workspace.all-accounts`
checkbox was enabled. Read-only verification confirmed receipt schema 4 with
one pinned main Codex workspace, the original directory identity, retained
source-account thread IDs, unchanged profile metadata, unchanged Claude
group/policy, and a byte-identical 78-conversation Claude catalog. The previous
receipt was retained as a schema-3 backup. The original Codex process remained
alive. The UI showed the enabled setting, main folder and shared separation
label on the requested account's space. Local proof is in
`/tmp/parallax-codex-main-enabled-verification.json` and
`/tmp/parallax-codex-main-enabled.png`.

This validates the preference and local launch routing. No live sign-out,
account switch, model turn, or cross-account resume was performed. Codex uses
its native sign-in within one workspace; other isolated histories were not
merged or deleted. Automated tests used disposable synthetic storage.

### October 2: persistent history for all Claude accounts

Implementation source: `1dad2ae46af2927f69d6c43edfd104529f3a24c1`, clean tree.
No source changes occurred during these final verification runs.

Commands completed successfully:

```bash
swift test --jobs 4 -Xswiftc -warnings-as-errors --filter 'AllAccountHistory|ConversationLibrary|SharedHistoryStore|LaunchPreparationIntegration|LibraryLaunchAuditRegression'
./script/run_quality_gates.sh --output-dir .build/all-account-gates-verified
COVERAGE_OUTPUT_DIR="$PWD/.build/all-account-coverage-verified" ./script/check_coverage.sh
PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh
./script/build_and_run.sh install --architecture native
./script/build_and_run.sh verify --artifact /Applications/Parallax.app --expect-local --architecture native
git diff --check
```

The focused run passed 69 tests. All ten fast gates passed, including release
compilation and the full suite with warnings as errors, localization,
warning/evidence/coverage/packaging contracts, pinned secret scanning, and
whitespace checks. The full suite and separate coverage suite each ran 2,171
tests, with two skips and zero failures. Localization reported 1,357 source
keys, 1,364 entries in each language, and zero debt or new issues. Fresh
isolated coverage passed at 60,371 / 87,654 product lines (68.8742%), above the
51,137 / 75,458 baseline (67.7688%). Native packaging integration passed all
12 checks. Sanitizer lanes were not rerun for this change.

Fast-gate logs are in `.build/all-account-gates-verified/`; coverage results
and provenance are in `.build/all-account-coverage-verified/`, bound to source
input SHA-256 `53ed463eaf9a512c631444e192aa3dde61756620dfe72e9a1c2eccb1530586e9`.
Focused and packaging logs are `/tmp/parallax-all-account-verified-focused.log`
and `/tmp/parallax-all-account-packaging-verified.log`.

The owner-authorized installation records the same clean source `1dad2ae` in
`/Applications/Parallax.app/Contents/Resources/PackagingProvenance.plist`.
The executable SHA-256 is
`4723c644f7f928b3589b8ed1976282230714d6d33c67fc490e8a34f84336dc28`.
Installation and verification logs are
`/tmp/parallax-all-account-install-verified.log` and
`/tmp/parallax-all-account-installed-verified.log`.

The installed UI's `conversation-library.all-accounts` checkbox was enabled
while an existing linked Claude instance remained running. Read-only
verification found the persisted schema-v3 policy, the same library identity
and bindings, and byte-identical canonical catalog contents across the setting
change. This checks the local preference only; it does not establish provider
identity, native import acceptance, or cross-account resume. Automated tests
use disposable synthetic histories and no real provider logins.

### October 2: All Spaces overview

Implementation source: `6f956f5a5ed7d708622268606bd4e6f415478dc5`.
The fast gate run began with these exact source files uncommitted over
`9b2459a`, then they were committed unchanged during the release build; its
header therefore records that earlier SHA and a dirty tree. Coverage,
packaging integration, and the local bundle build ran at `6f956f5` with a
clean tree. No source edits occurred during verification.

Commands completed successfully:

```bash
./script/run_quality_gates.sh --output-dir .build/all-spaces-gates
COVERAGE_OUTPUT_DIR="$PWD/.build/all-spaces-coverage" ./script/check_coverage.sh
PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh
./script/build_and_run.sh build --architecture native
```

All ten fast gates passed, including release compilation and the full Swift
suite with warnings as errors, localization, warning/evidence/coverage/packaging
contracts, secret scanning, and whitespace checks. The suite ran 2,155 tests
with zero failures and two skips. Localization reported 1,352 source keys,
1,359 English and Spanish entries each, and zero debt or new issues.
Fresh isolated coverage passed at 59,956 / 87,168 lines (68.7821%), above the
51,137 / 75,458 baseline (67.7688%). Native packaging integration passed
12/12 checks. The ad-hoc local bundle was built and verified at
`dist/Parallax.app`; it was not installed or launched. Sanitizer lanes were
not rerun for this view-only change.

Local fast-gate logs are under `.build/all-spaces-gates/`; coverage results
and provenance are under `.build/all-spaces-coverage/`, bound to source-input
SHA-256 `6ca802c6dbc018550ed67425ac37d0ef5af7e0feb74ea3a9f9c7a71d0ad2fb45`.
The packaging and bundle logs are `/tmp/parallax-all-spaces-packaging.log`
and `/tmp/parallax-all-spaces-build.log`. These checks use synthetic fixtures;
they do not establish the integrity of any user's provider history or native
cross-account continuation.

After explicit owner approval on October 2, installation and verification
completed successfully:

```bash
./script/build_and_run.sh install --architecture native
./script/build_and_run.sh verify --artifact /Applications/Parallax.app --expect-local --architecture native
```

The installed package records clean source revision `2e6a0e9`, whose product,
test, script, and package files are identical to verified implementation
`6f956f5`; the intervening commit only records verification evidence. The
installer replaced and registered the canonical app without opening it.
Logs are `/tmp/parallax-all-spaces-install.log` and
`/tmp/parallax-all-spaces-installed-verification.log`.

### October 1: shared Claude conversation library

Implementation source: `60b66730501ab9588295c3bd3a9dbc3593487af1`, clean tree.
This includes the initial implementation in `4e59489` and explicit recovery
from an unreadable source in `60b6673`. These measurements apply to that exact
implementation, not to later product changes.

Commands completed successfully:

```bash
./script/run_quality_gates.sh --full --output-dir .build/conversation-library-final-gates
./script/build_and_run.sh build --architecture native
```

| Gate | Result at `60b6673` |
| --- | --- |
| Release build with warnings as errors | PASS |
| Full Swift suite with warnings as errors | 2,155 tests, 0 failures, 2 skips |
| Localization checker and contracts | PASS; 1,352 source keys, 1,359 English and 1,359 Spanish entries; zero debt and zero new issues |
| Warning, evidence-hygiene, coverage and packaging contracts | PASS |
| Pinned secret scan and patch whitespace | PASS |
| Fresh isolated product coverage | 59,961 / 86,804 lines (69.0763%); floor 51,137 / 75,458 (67.7688%) |
| Address Sanitizer | PASS; no detected sanitizer diagnostic |
| Thread Sanitizer | PASS; no detected sanitizer diagnostic |
| Native packaging integration | PASS, 12/12; local artifact, reproducible ZIP, DMG, isolated install/upgrade/rollback, provenance and collision verification |
| Local native app build | PASS; `dist/Parallax.app`, ad-hoc signature verified, not installed or launched |

The two skips were the existing foreground-activation capability check
(`NSWorkspaceApplicationLauncherIntegrationTests.testWorkspaceControllerActivatesOnlyTheExactTrackedInstance`)
and the opt-in README renderer (`ReadmeScreenshotRenderingTests.testRenderReadmeScreenshots`).
Neither skipped behavior is verified by this run. Developer ID signing,
notarization, public distribution and live Claude account acceptance were not
performed.

Local logs are under `.build/conversation-library-final-gates/`. The coverage
provenance pins source-input SHA-256
`ce1cdfd309d5abfc4cb59db160875a6fba656b67ac645584dd8545e3656399da`
and report SHA-256
`511985b564f7b444a5e67ca7ba9a47fb7405c5a398aac3322dde9476e4545c52`.
The new suites contain 22 synthetic conversation-library tests, plus a launch
adapter regression for delivering the exact continuation URL with the target
profile configuration. All are included in the full suite above.

The [native acceptance checklist](SHARED_HISTORY.md#evidence) remains a manual
boundary. Claude's feature-gated continuation route and import-review behavior
cannot be established by synthetic tests. Real histories were not migrated as
part of this implementation and verification run.

### September 28: historical release-gate snapshot

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

## Historical implementation notes (before October 4)

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
