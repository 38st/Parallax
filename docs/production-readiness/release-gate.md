# Release gate

## Decision

**GO for source review and unsigned/ad-hoc candidate testing.**

**HOLD for public binary distribution until the external signed-release gates
below are satisfied.**

This distinction is intentional: local code and packaging checks are green,
while Developer ID signing, Apple notarization, final version approval, and
publication require credentials and authority outside the repository.

## Local results

`./script/run_quality_gates.sh --full` runs every command in the table below
in order and stops at the first failure; without `--full` it runs the fast
gates only.

All commands ran from the current macOS checkout on September 10, 2026, at
source commit `3fc2988`.

| Gate | Command | Result |
| --- | --- | --- |
| Warning-clean release build | `swift build -c release --jobs 4 -Xswiftc -warnings-as-errors` | PASS |
| Complete warning-clean suite | `swift test --jobs 4 -Xswiftc -warnings-as-errors` | PASS — 1,264 tests, 0 failures, 1 documented capability skip |
| Fresh isolated coverage | `./script/check_coverage.sh` | PASS — 1,264 tests; 46,413 / 71,430 product lines (64.9769%) |
| Localization census | `python3 script/check_localization_completeness.py` | PASS — 1,025 source keys; 1,035 English and 1,035 Spanish entries, zero debt |
| Localization contracts | `python3 script/test_localization_completeness.py` | PASS — 15/15 |
| Evidence hygiene contracts | `./script/test_ci_evidence_hygiene.sh` | PASS — 9/9 |
| Coverage gate contracts | `./script/test_coverage_gate.sh` | PASS — 3/3 |
| Warning contract | `./script/test_warning_gate.sh` | PASS — 1/1 |
| Packaging contracts | `./script/test_build_and_run.sh` | PASS — 11/11 |
| Artifact integration | `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh` | PASS — 12/12: local app, reproducible ZIP, DMG, install/upgrade/rollback, provenance, and collisions |
| Secret scan | `./script/run_secret_scan.sh` | PASS — gitleaks 8.30.1, zero findings |
| Thread Sanitizer lane | `./script/run_sanitizer_tests.sh thread` | PASS — 1,264 tests, zero diagnostics |
| Address Sanitizer lane | `./script/run_sanitizer_tests.sh address` | PASS — 1,264 tests, zero diagnostics |
| Patch whitespace | `git diff --check` | PASS |

The one skipped test requires a foreground-capable GUI test host. Its strict
required-mode command is documented by the test, and the skip is never
reported as proof of that capability.

## Completed source gates

- [x] Warning-clean production compilation.
- [x] Complete unit and integration suite.
- [x] Fresh isolated coverage exceeds the stored ratchet.
- [x] English and Spanish localization catalogs have complete source coverage
  with no allowlisted debt.
- [x] Account-specific Codex homes and account-specific Claude Code
  configuration directories, kept distinct from Claude Desktop Local Space
  configuration.
- [x] Distinct configured Claude desktop storage paths per space, new-instance
  launch request, and owner-only managed configuration directories.
- [x] One persistent workspace sidebar across Control Center and Local Spaces.
- [x] Local app/ZIP/DMG packaging and independent verification.
- [x] Reproducible unsigned ZIP and isolated install/upgrade/rollback rehearsal.
- [x] Pinned secret scanning and hardened sanitizer lanes as local scripts.
- [x] Release mode rejects dirty source and missing credentials before artifact
  mutation.

## External signed-release gates

- [ ] Final version and build number approved.
- [ ] Exact source commit reviewed and selected for release.
- [ ] Developer ID Application identity available to the release job.
- [ ] Apple notary profile available to the release job.
- [ ] Final app and DMG signed, notarized, and stapled.
- [ ] Gatekeeper validates the exact final artifacts.
- [ ] Final signed artifacts pass clean-account install, supported upgrade, and
  rollback rehearsal.
- [ ] Publication is explicitly authorized.

Run the credentialed command documented in
[BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md). Public release changes from
HOLD to GO only after every external checkbox is backed by evidence from the
exact release commit and artifacts.
