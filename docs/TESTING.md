# Behavior tests

Parallax's tests use synthetic apps, provider responses, and disposable storage.
They must never touch real provider credentials or the user's history. Coverage
numbers measure executed code; they do not prove live provider acceptance.

Every behavior change needs a test for the user-visible result and relevant
failure paths. Tests must assert preserved data and released operation state
where interruption or failure is possible. A happy-path test alone is not
sufficient for storage, launch, import, account switching, or recovery changes.

## Workflow checks

| Workflow | Automated test entry points |
| --- | --- |
| Startup, shared settings, failed bootstrap | `ParallaxAppCompositionTests`, `SettingsRuntimeTests`, `AppSettingsPersistenceTests` |
| Launch, quit, uncertain outcomes, singleton reuse | `WorkspaceApplicationLauncherTerminationTests`, `WorkspaceApplicationLauncherUnknownOutcomeTests`, `SingletonLaunchPolicyTests` |
| Claude shared history, conflicts, missing chats, restart recovery | `ConversationLibraryTests`, `ConversationLibraryIntegrationTests`, `AllAccountHistoryTests` |
| Codex main history and account-space metadata | `MainHistoryActivationTests`, `CodexSharedWorkspaceTests`, `CodexAccountSpaceSynchronizationTests` |
| Provider account status and errors | `AIAccountConnectionServiceTests`, `ProviderAccountAuditRegressionTests`, `AccountsAuditRegressionTests` |
| Imported launch configuration and library replacement | `ImportedLaunchTrustTests`, `LibraryImportReplacementCoordinatorTests`, `FileImporterFailureTests` |
| Removal, relocation, and durable rollback | `ApplicationRemovalTransactionCoordinatorTests`, `StorageRelocationDurabilityAuditRegressionTests`, `ProfileDataTransactionCoordinatorTests` |
| English text, plural counts, unsupported language fallback | `LocalizationTests`, `GateLocalizationAuditRegressionTests`, `RuntimeResourceSmokeTests`, `script/test_localization_completeness.py` |
| App bundles, ZIP/DMG, install/upgrade/rollback, artifact ownership | `script/test_build_and_run.sh`, `script/tests/GateAuditRegressionTests.py`, `script/tests/GateReviewAuditRegressionTests.py` |

The October 6 tests explicitly cover every persisted Claude handoff phase
(waiting, capturing, preparing, ready, opening), recovery through a new store,
retry after recovery, remount/reconnect without restoring deleted chats,
opening an unlinked space without enrollment, each count helper at zero/one/two
under five locales, every required runtime resource missing or empty, and
rejection of additional language catalogs in source, runtime, and packaging.

## Running checks

`./script/run_quality_gates.sh --full` runs the release build, full test suite,
English catalog contracts and census, script contracts, secret scan, diff
checks, coverage threshold, Address Sanitizer, Thread Sanitizer, and isolated
native packaging rehearsal. See `script/run_quality_gates.sh --help` for log
locations and exact commands. This is a local command, not hosted CI.

The packaging language probe runs under multiple preferred languages and
requires the packaged app to resolve English. Changing supported language
resources also changes the packaging cache namespace so obsolete resources
cannot silently carry over from older cached builds.

## Boundaries

Synthetic tests do not prove that Claude accepts a native import, opens the
requested conversation, or has the intended account signed in. These require
explicitly authorized live verification. UI screenshots and operating-system
capability tests may have documented skips; report them, do not call them
passes. The workflow table is a map into the suite, not a claim that every
possible state or all product code is covered.
