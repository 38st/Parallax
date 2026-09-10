# Branch triage: unmerged release-hardening work

Scope: every commit on `codex/reconcile-product-20260816` that is not on
`master`, classified against the current `master` scripts and sources.

## Branch relationship

`wip/parallax-product-run-20260729` contributes **zero unique commits**. Its 63
commits are all reachable from `codex/reconcile-product-20260816`, which is 68
commits ahead of `master`. The five commits the codex branch adds on top of the
product-run series are `65b69d0`, `c8c9564`, `e11dc3d`, `d698687`, `df5eb1b`.
Triaging the codex branch therefore triages both branches; the product-run
branch can be retired on the same disposition.

`65b69d0` is a merge of master's `54d2adf` into the side branch. Its resolution
kept only `script/build_and_run.sh`, `script/test_build_and_run.sh`,
`script/verify_zip_structure.pl`, and `docs/BUILD_AND_RELEASE.md` from the
branch; every branch-side `Sources/` and `docs/` change was already resolved in
master's favour at that merge. That is why the Swift-side series below is
almost entirely already present.

## Counts

| Classification | Commits |
| --- | --- |
| ALREADY PRESENT in master | 33 |
| STILL VALUABLE AND APPLICABLE, ported in this pass | 4 |
| STILL VALUABLE AND APPLICABLE, not ported | 1 |
| OBSOLETE / SUPERSEDED | 8 |
| NOT APPLICABLE | 22 |
| **Total** | **68** |

Ported in this pass: `bd098db`, `e11dc3d`, `df5eb1b`, `f90ada7` (the last in
reduced form). Not ported: `a8879bf`. One commit counted as ALREADY PRESENT,
`cad9194`, has a residual not-ported part that is called out in its row.
Several ALREADY PRESENT packaging commits were additionally *strengthened* by
the ports; the column below says which master function carries each.

## Theme: ZIP structural preflight (REL-003C, REL-003D)

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| accfb78 | REL-003C: harden ZIP structural preflight | ALREADY PRESENT | `script/lib/build_and_run/artifact_verification.sh`: `safe_zip_entries`, `verify_zip_entry_names`, `verify_zip_entry_kinds` (bounded inventory, entry-name safety, kind/path agreement, duplicate and case/Unicode folding, top-level closure) |
| 67c8203 | Verify ZIP payload integrity before extraction | ALREADY PRESENT | `artifact_verification.sh`: `verify_zip_payload_integrity` (`unzip -qq -t`, which covers stored-CRC failure, local/central header disagreement, and encryption). The branch's streaming inflate implementation in `script/verify_zip_structure.pl` is superseded by that call |
| f90ada7 | Harden ZIP structure preflight | STILL VALUABLE, PORTED (reduced) | Ported as `artifact_verification.sh`: `verify_zip_container_structure`, called from `verify_zip` before any listing tool. Covers the container layer of the branch's `verify_zip_structure.pl`: single-disk, exact 22-byte tail end record, no archive comment or trailing payload, no second self-consistent end record, central directory ending exactly at that record, no ZIP64 locator or sentinel, per-entry flag/method/comment/extra bounds, byte-for-byte local/central agreement including the entry name, data-descriptor validation, and contiguous local coverage from offset zero. Deliberately omitted: the branch's inflate-in-Perl CRC walk (covered by `unzip -t`), its 0600 snapshot-copy input contract (master uses `require_bounded_archive_input` plus `require_unchanged_archive`), and its exact producer-tuple extra-field allowlist (pinned to two producer profiles and brittle across tool versions) |
| de59d38 | Bind REL-003D byte-faithful ZIP preflight scope | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only; that tree does not exist in master |
| 3a5030c | Correct REL-003D reachable metadata bound | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |
| a5fb50b | Align REL-003D metadata bound with producer tuples | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |
| 488d2d5 | Clarify REL-003D descriptor ambiguity evidence | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |
| 3fbde86 | Clarify REL-003D extra-field limit evidence | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |
| 0579089 | Bind streaming ZIP payload preflight | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only; release-evidence bookkeeping for `67c8203` |

## Theme: ZIP application inventory and permissions

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| f3a5935 | Close local ZIP application inventory | ALREADY PRESENT | `artifact_verification.sh`: `verify_application_inventory` (closed membership, asserted post-extraction by `verify_zip`), strengthened to exact closure by the `df5eb1b` port |
| 91ba638 | Bind local ZIP application inventory | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |
| de524c1 | Normalize local application permissions | ALREADY PRESENT | `script/lib/build_and_run/app_assembly.sh`: `normalize_application_permissions` (0755 directories, 0644 files, 0755 main executable), called from `script/build_and_run.sh` after `sign_app`; enforced by `verify_application_inventory` |
| 426efae | Bind deterministic application permissions | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |

## Theme: DMG structural verification

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| bda2bea | Harden DMG structural verification | ALREADY PRESENT | `artifact_verification.sh`: `verify_dmg_image_structure`, `dmg_image_property`, `require_dmg_image_property`, `verify_dmg_top_level_inventory`, and the read-only `-noignorebadchecksums` attach in `verify_dmg` |
| 2938b0b | Bind hostile DMG structural preflight | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only |

## Theme: application artifact inventory (the branch's last wave)

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| bd098db | Harden application artifact inventory verification | STILL VALUABLE, PORTED (in two parts) | AppleDouble rejection ported as `artifact_verification.sh`: `verify_zip_metadata_exclusion`, called from `safe_zip_entries` for the unsigned expectation. Exact inventory closure and per-path kind binding ported into `verify_application_inventory` plus the new `verify_resource_bundle_member`. Not ported: the branch's `capture_application_inventory` / `scan_application_children` / `revalidate_application_inventory` re-enumeration harness, which depends on its `run_bounded_command`, `create_owned_evidence_file`, `create_owned_temp_dir`, and `verifier_test_barrier` infrastructure that master deliberately does not carry |
| e11dc3d | Update AppleDouble rejection contract | STILL VALUABLE, PORTED | `verify_zip_metadata_exclusion` produces the branch's diagnostic, `ZIP contains forbidden AppleDouble metadata`. Scoped to the unsigned expectation rather than unconditionally, because master's integration contract requires a real `ditto --sequesterRsrc` archive of a local build to verify as `--expect-local`, and release archives are produced by `ditto --sequesterRsrc` from a stapled bundle. Contract test 6 and contract test 8 in `script/test_build_and_run.sh` cover both sides |
| df5eb1b | Activate direct application inventory contracts | STILL VALUABLE, PORTED (in substance) | Exact-closure and kind binding in `verify_application_inventory` and `verify_resource_bundle_member`: `Contents`, `Contents/MacOS`, `Contents/_CodeSignature`, `Contents/Resources`, and the SwiftPM runtime bundle each admit only their own declared children, and each declared path admits only its own kind. The runtime bundle is closed by shape rather than by the branch's enumerated 30-path table, so adding a localization does not break packaging. The branch's `PARALLAX_PACKAGING_FOCUS` selective runner is not applicable: master's suite has no focus modes |
| c8c9564 | Align aggregate ZIP fixture with closed inventory | ALREADY PRESENT (equivalent) | Fixture realignment for the branch's raw-ZIP generator, which master does not have. The equivalent work in master is `create_resource_inventory_fixture` in `script/test_build_and_run.sh`, added with the `df5eb1b` port so the closure contract is proved against the complete published resource layout |
| d698687 | Align DMG inventory rejection contracts | OBSOLETE / SUPERSEDED | Realigns diagnostics to `application inventory has an unexpected path or type`, which only becomes reachable because the branch moved inventory capture ahead of the plist and executable completeness check. Master keeps `application bundle is incomplete` as the first gate, so the realignment has no target |

## Theme: frozen release metadata (REL-002A)

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| a8879bf | Bind frozen release metadata | STILL VALUABLE, NOT PORTED | Adds a `check-release-metadata` mode and a `--release-metadata PATH` manifest binding version, build, intended tag, source revision, and two document hashes, revalidated immediately before publication and cross-checked against embedded provenance. Blocked on three things, none of which are in this task's remit: (1) the manifest contract requires two tracked repository documents, a changelog and release notes, and master has neither, so the document half cannot be exercised or tested; (2) creating those documents and extending `write_provenance` with the metadata fields is outside the file ownership for this pass; (3) the branch's implementation is entangled with its `verifier_test_barrier` and producer-test-authority harness, which master does not carry, so the ordering guarantees it asserts have no test surface here. Recommend re-opening once the changelog and release-notes documents exist and a new CLI mode is approved |
| c9e13bf | Record REL-002A completion evidence | NOT APPLICABLE | `docs/product-run/TASK_LEDGER.md` only; release-evidence bookkeeping for `a8879bf` |

## Theme: verifier cleanup and test-harness safety (REL-003A, REL-003B)

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| 6fba0e6 | REL-003B: make verifier cleanup fail-safe | ALREADY PRESENT | `artifact_verification.sh`: the `verify_zip` and `verify_dmg` subshells with `cleanup_verification_zip` and `cleanup_verification_dmg` traps, `detach_verification_dmg` with a forced fallback and a hard failure if the mount survives, plus `assert_no_verifier_dmg_mounts` and `assert_no_verifier_temp_dirs` in `script/test_build_and_run.sh`. Not ported: the branch's bounded-command timeout and child-survivor harness, which requires its verifier test-authority infrastructure |
| cad9194 | REL-003A: make dirty release fixture self-contained | ALREADY PRESENT (part) / STILL VALUABLE, NOT PORTED (part) | The self-contained fixture is present: `test_dirty_release_is_rejected_before_staging` in `script/test_build_and_run.sh` builds its own throwaway Git repository under a temporary directory. Not ported: the hardened `cleanup` that confines removal to allowlisted parents and fails loudly on an unexpected path. Master's `cleanup` already gates on the `parallax-package-test.*` basename pattern, so the residual gain is a loud failure instead of a silent skip; the branch's version requires converting `TEMPORARY_DIRS` to an array across every test, and `"${array[@]}"` under `set -u` on the system bash 3.2 is unbound when the array is empty, which is reachable if an early test fails before any temporary directory exists |

## Theme: settings persistence chain (MAC-005) - all already in master

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| a320af3 | MAC-005A: add bounded settings document codec | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsDocumentCodec.swift`, `Sources/Parallax/Models/SettingsDocument.swift`; tests in `Tests/ParallaxTests/SettingsDocumentCodecTests.swift` |
| 0692d72 | MAC-005B: inspect settings snapshots securely | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsPrimaryFileAccess.swift`; `Tests/ParallaxTests/SettingsRepositoryTests.swift` |
| a52ab6e | MAC-005C0: add secure settings mutation lock | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsPrimaryMutationLock.swift` (contracts split into `Sources/Parallax/Stores/SettingsPrimaryMutationContracts.swift` by master `66da3bc`) |
| 5ab732c | MAC-005C1A: add locked settings inspection authority | ALREADY PRESENT | same lock file; `Tests/ParallaxTests/SettingsPrimaryLockedInspectionTests.swift` |
| d75752e | MAC-005C1B: add durable settings CAS publication | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsPrimaryPublication.swift`; `Tests/ParallaxTests/SettingsRepositoryMutationTests.swift` |
| ecb129e | MAC-005C2A: add restart-safe residual inventory | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsPublicationResidualInventory.swift` |
| fa2a0b9 | MAC-005D0: add read-only legacy settings snapshot | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsLegacySnapshot.swift`, later extended by master `be461cd` |
| 65cb38e | MAC-005D1A: extract strict JSON preflight | ALREADY PRESENT | `Sources/Parallax/Stores/StrictJSONPreflight.swift` with master's `StrictJSONLexical.swift` and `SettingsStrictJSONParser.swift` |
| cbde6aa | MAC-005D1B: decode bounded legacy settings wire | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsLegacySnapshotDecoder.swift`, `Sources/Parallax/Models/SettingsLegacySnapshotWireModels.swift` |
| 3912d1b | MAC-005D2A: assess legacy settings compatibility | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsLegacyMigrationAssessment.swift` |
| dd007e3 | Assess current settings presence | ALREADY PRESENT | `Sources/Parallax/Stores/SettingsCurrentMigrationAssessment.swift`; `Tests/ParallaxTests/SettingsCurrentMigrationAssessmentTests.swift` |
| 8bb1e5c | Bind MAC-005C2A residual inventory scope | NOT APPLICABLE | bookkeeping for `ecb129e` |
| 9730dbe | Bind MAC-005D0 legacy snapshot scope | NOT APPLICABLE | bookkeeping for `fa2a0b9` |
| 9c16176 | Bind MAC-005D1A strict JSON preflight scope | NOT APPLICABLE | bookkeeping for `65cb38e` |
| b2a8ffb | Bind MAC-005D1B legacy wire decoder scope | NOT APPLICABLE | bookkeeping for `cbde6aa` |
| e5ace93 | Bind MAC-005D2A compatibility assessment scope | NOT APPLICABLE | bookkeeping for `3912d1b` |
| ffb617e | Bind current settings presence assessment | NOT APPLICABLE | bookkeeping for `dd007e3` |

## Theme: display-name validation (MAC-003) - all already in master

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| c7b248c | MAC-003A0: add canonical display name validation | ALREADY PRESENT | `Sources/Parallax/Support/DisplayNameValidator.swift` (master's version is a strict superset, master `515755d`) |
| 8eeaa34 | MAC-003A1: validate app editor names | ALREADY PRESENT | `Sources/Parallax/Views/ApplicationHeaderView.swift`, `nameValidationMessage` |
| 2645593 | MAC-003A2: validate template mutation names | ALREADY PRESENT | `Sources/Parallax/Models/AppSettings.swift`; `Tests/ParallaxTests/DisplayNameMutationBoundaryTests.swift` |
| 2b87492 | MAC-003A3: validate space edit names | ALREADY PRESENT | `Sources/Parallax/Stores/LibraryStore+Editing.swift` |
| ee3a3e3 | MAC-003A4: add inline Space name validation | ALREADY PRESENT | `Sources/Parallax/Models/SpacePresentation.swift` (master moved the file from `Views/`) |

## Theme: launch provenance and process termination (MAC-002A, MAC-009A)

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| ad75bb4 | MAC-009A0: classify launch process provenance | ALREADY PRESENT | `Sources/Parallax/Services/LaunchProcessProvenanceClassifier.swift`, `Sources/Parallax/Services/WorkspaceProcessIdentity.swift` (master renamed the cases and added `LaunchProcessProvenanceIndeterminacy`, master `7a6e43c`) |
| 26afd40 | MAC-009A1: capture exact pre-open process snapshots | ALREADY PRESENT | `Sources/Parallax/Services/WorkspaceProcessSnapshotter.swift`, `Sources/Parallax/Services/WorkspaceRunningProcessListing.swift` |
| 0d0cff2 | MAC-009A2: bind returned launch provenance | ALREADY PRESENT | `Sources/Parallax/Stores/ProfileActivityRegistry.swift` `recordRunningProcess`, `Sources/Parallax/Stores/ProfileActivityContracts.swift`. The branch's two localized strings are superseded: master ships different wording in `Sources/Parallax/Resources/en.lproj/Localizable.strings` |
| cb4b749 | MAC-002A0: harden process termination observation | ALREADY PRESENT | `Sources/Parallax/Services/NSWorkspaceApplicationOpening.swift`, `NSWorkspaceTerminationObservation` |
| 1964259 | MAC-009A3: verify real workspace created launches | ALREADY PRESENT | `Tests/ParallaxTests/NSWorkspaceApplicationLauncherIntegrationTests.swift`, `Tests/ParallaxTests/ProductionLaunchApplicationFixture.swift` (master's fixture is a superset, master `6605def`) |
| b5ccb53 | MAC-009A4: verify real workspace self-exit | ALREADY PRESENT | `Tests/ParallaxTests/NSWorkspaceApplicationLauncherIntegrationTests.swift` |
| d0c5e30 | MAC-009A5: verify exact cooperative termination | ALREADY PRESENT | `Sources/Parallax/Services/ApplicationInstanceController.swift`, `Sources/Parallax/Services/TrackedLaunchSession.swift` (master `c038c1e`, `21c64b4`) |
| a81b97e | MAC-009A6: harden exact activation authority | ALREADY PRESENT | `Sources/Parallax/Services/NSWorkspaceApplicationProcessRuntime.swift`, `NSWorkspaceApplicationProcessProvider.swift` |
| db1d1f4 | DOC: record MAC-009A2 verification evidence | NOT APPLICABLE | bookkeeping for `0d0cff2` |

## Theme: parser regression and Keychain characterization

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| 86a9839 | MAC-001: add parser result regression tests | ALREADY PRESENT | `Tests/ParallaxTests/ShellWordsParserTests.swift`, the same four `testParseResult...` cases |
| 983a7c0 | MAC-009K0: characterize real Keychain CRUD | OBSOLETE / SUPERSEDED | Superseded by master `cb4a040`: `Tests/ParallaxTests/ProductionKeychainCRUDCharacterizationTests.swift` and `Tests/ParallaxTests/ProductionKeychainTestSupport.swift`. Master deliberately keeps isolation test-side and does not add the production `init(testService:)` seam this commit puts in `Sources/Parallax/Services/SecretConfiguration.swift` |
| 2a0cced | MAC-001B: record verified clean baseline evidence | NOT APPLICABLE | bookkeeping for `86a9839` |

## Theme: CI quality gates (MAC-012) - master has no hosted CI

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| 92b255c | MAC-012A: enforce warnings as errors in CI | NOT APPLICABLE | `.github/workflows/ci.yml` only; master carries no workflow files. The local equivalent is `script/test_warning_gate.sh` |
| 5bdde2b | MAC-012B: enforce CI coverage floors | OBSOLETE / SUPERSEDED | CI lane not applicable, and its small `script/check_coverage.sh` is superseded by master's `script/check_coverage.sh`, `script/coverage-baseline.env`, and `script/test_coverage_gate.sh` (master `f0496e5`) |
| 9a77806 | MAC-012C: gate localization catalog parity | OBSOLETE / SUPERSEDED | Superseded by `script/check_localization_completeness.py` and `script/localization_completeness_baseline.json`, which emit `catalog-key-missing-en` and `catalog-key-missing-es` |
| 3f789f9 | MAC-012D: add pinned secret scanning | OBSOLETE / SUPERSEDED | Its `script/check_secrets.sh` is superseded by `script/run_secret_scan.sh` and `script/gitleaks.toml` |
| 631813a | MAC-012E: add AddressSanitizer CI coverage | NOT APPLICABLE | `.github/workflows/ci.yml` only; covered locally by `script/run_sanitizer_tests.sh address` |
| 8b566c8 | MAC-012F: add ThreadSanitizer CI lane | NOT APPLICABLE | `.github/workflows/ci.yml` only; covered locally by `script/run_sanitizer_tests.sh thread` |

## Theme: product-run planning documents and the reconcile merge

| SHA | Subject | Classification | Carried by / reason |
| --- | --- | --- | --- |
| c0a9c68 | DOC-001: add continuous product run plan | OBSOLETE / SUPERSEDED | Creates the `docs/product-run/` tree; superseded by `docs/production-readiness/release-gate.md`, `docs/production-readiness/gap-register.md`, and `docs/DELIVERY_LEDGER.md` |
| f9e6828 | DOC-002: correct full-product dependency gates | OBSOLETE / SUPERSEDED | Same tree, same successors |
| 73df7d6 | DOC: preserve decomposition wave boundary | NOT APPLICABLE | `docs/product-run/DECISIONS.md` only; master's decomposition landed differently (`66da3bc`, `77ebe51`, `0fd0a91`, `f923db1`) |
| 65b69d0 | Reconcile product release hardening with master | OBSOLETE / SUPERSEDED (documentation ported) | The merge itself is superseded: its script side is the monolithic `script/build_and_run.sh` that master has since split into `script/lib/build_and_run/*.sh`, and its `Sources/` and `docs/` side was already resolved in master's favour inside the merge. Its `docs/BUILD_AND_RELEASE.md` half was worth porting and is now carried by the `What verification enforces` section of `docs/BUILD_AND_RELEASE.md`, rewritten to describe what master actually enforces |

## Ports landed in this pass

| Slice | Files | Behaviour |
| --- | --- | --- |
| 2 | `script/lib/build_and_run/artifact_verification.sh`, `script/test_build_and_run.sh` | `verify_zip_metadata_exclusion`, called from `safe_zip_entries` for the unsigned expectation: `__MACOSX` at any depth and any `._`-prefixed basename are refused before extraction. Contract tests 6 and 8 assert the ban for `--expect-unsigned` and preserve the existing metadata-target rules for `--expect-local` |
| 3 | `script/lib/build_and_run/artifact_verification.sh`, `script/test_build_and_run.sh` | Exact closed inventory: `verify_application_inventory` closes `Contents`, `Contents/MacOS`, `Contents/Resources`, and `Contents/_CodeSignature` to their declared children and binds each declared path to its kind; `verify_resource_bundle_member` closes the SwiftPM runtime bundle by shape. Contract test 9 adds `create_resource_inventory_fixture` plus rejection cases for a stray resource, a stray signature record, a stray bundle payload, a stray localization file, a nested localization, and a directory or file standing in for the other kind |
| 4 | `script/lib/build_and_run/artifact_verification.sh`, `script/test_build_and_run.sh` | `verify_zip_container_structure`, called from `verify_zip` before any listing tool: a byte-faithful container contract. New contract test 10, `test_verifier_rejects_noncanonical_zip_containers`, covers a canonical producer control plus trailing payload, archive comment, concatenation, prefixed stub, encrypted entry, and local/central name disagreement |

Also updated: `docs/BUILD_AND_RELEASE.md` gained a `What verification enforces`
section covering all of the above plus the already-committed slice-1 behaviour;
`script/build_and_run.sh --help` gained a `verification contract` block; and the
Evidence or Resolution paragraphs of PRX-004, PRX-007, and PRX-018 in
`docs/production-readiness/gap-register.md` were updated.
