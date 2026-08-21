# Release gate

## Decision

**GO for source review and unsigned/ad-hoc candidate testing.**

**HOLD for public binary distribution until the external signed-release gates
below are satisfied.**

This distinction is intentional: local code and packaging checks are green,
while Developer ID signing, Apple notarization, final version approval, and
publication require credentials and authority outside the repository.

## Local results

All commands ran from the current macOS checkout on August 21, 2026.

| Gate | Command | Result |
| --- | --- | --- |
| Warning-clean release build | `swift build -c release --jobs 4 -Xswiftc -warnings-as-errors` | PASS |
| Complete warning-clean suite | `swift test --jobs 4 -Xswiftc -warnings-as-errors` | PASS — 1,207 tests, 0 failures, 1 documented capability skip |
| Fresh isolated coverage | `./script/check_coverage.sh` | PASS — 1,207 tests; 45,250 / 69,737 product lines (64.8866%) |
| Localization census | `python3 script/check_localization_completeness.py` | PASS — 953/953 English and Spanish keys, zero debt |
| Localization contracts | `python3 script/test_localization_completeness.py` | PASS — 14/14 |
| CI evidence hygiene | `./script/test_ci_evidence_hygiene.sh` | PASS — 10/10 |
| Coverage gate contracts | `./script/test_coverage_gate.sh` | PASS — 3/3 |
| Warning contract | `./script/test_warning_gate.sh` | PASS — 1/1 |
| Packaging contracts | `./script/test_build_and_run.sh` | PASS — 6/6 |
| Artifact integration | `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh` | PASS — local app, reproducible ZIP, DMG, install/upgrade/rollback, provenance, and collisions |
| Secret scan | `./script/run_secret_scan.sh` | PASS — gitleaks 8.30.1, zero findings |
| Patch whitespace | `git diff --check` | PASS |

The one skipped test requires a foreground-capable GUI test host. Its strict
required-mode command is documented by the test and CI does not misreport the
skip as proof of that capability.

## Completed source gates

- [x] Warning-clean production compilation.
- [x] Complete unit and integration suite.
- [x] Fresh isolated coverage exceeds the stored ratchet.
- [x] English and Spanish localization catalogs have complete source coverage
  with no allowlisted debt.
- [x] Account-specific Codex homes and one ambient macOS-user Claude Code
  identity, kept distinct from Claude Desktop Local Space configuration.
- [x] Distinct configured Claude desktop storage paths per space, new-instance
  launch request, and owner-only managed configuration directories.
- [x] One persistent workspace sidebar across Control Center and Local Spaces.
- [x] Local app/ZIP/DMG packaging and independent verification.
- [x] Reproducible unsigned ZIP and isolated install/upgrade/rollback rehearsal.
- [x] Pinned secret scanning and hardened sanitizer lanes in CI.
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
