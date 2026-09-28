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
in this order and stops at the first failure; without `--full` it runs the
first ten gates only.

All commands ran from the current macOS checkout on September 27, 2026, at source commit
`a85f70e`.

| Gate | Command | Result |
| --- | --- | --- |
| Warning-clean release build | `swift build -c release --jobs 4 -Xswiftc -warnings-as-errors` | PASS |
| Complete warning-clean suite | `swift test --jobs 4 -Xswiftc -warnings-as-errors` | 1,899 tests, 0 failures, 1 documented capability skip |
| Localization contracts | `python3 script/test_localization_completeness.py` | PASS |
| Localization census | `python3 script/check_localization_completeness.py` | 1,203 source keys; 1,206 English and 1,206 Spanish entries, zero debt |
| Warning contract | `./script/test_warning_gate.sh` | PASS |
| Evidence hygiene contracts | `./script/test_ci_evidence_hygiene.sh` | PASS |
| Coverage gate contracts | `./script/test_coverage_gate.sh` | PASS |
| Packaging contracts | `./script/test_build_and_run.sh` | PASS |
| Secret scan | `./script/run_secret_scan.sh` | PASS |
| Patch whitespace | `python3 script/check_git_state.py --diff-check .` | PASS |
| Fresh isolated coverage | `./script/check_coverage.sh` | 55,261 / 79,738 product lines (69.3032%); floor 51,137 / 75,458 (67.7688%, measured at 84b67f7) |
| Address Sanitizer lane | `./script/run_sanitizer_tests.sh address` | PASS |
| Thread Sanitizer lane | `./script/run_sanitizer_tests.sh thread` | PASS |
| Artifact integration | `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh` | PASS |

Skipped tests are counted in the suite's result line. Each skip names the
capability it needs, such as a foreground-capable GUI test host, and a skip is
never reported as proof of that capability. The foreground-activation test
documents its strict required-mode command.

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

## Whitespace and source-state procedure

The manual runner checks whitespace in the committed range from the current
branch's upstream merge base to HEAD, then checks staged and unstaged changes
separately. It fails closed if the upstream merge base cannot be resolved.
Run `python3 script/check_git_state.py --diff-check .` for the same standalone
check. Tree labels account for tracked and non-ignored untracked changes and
index visibility flags through `python3 script/check_git_state.py .`. Ignored
files do not make the tree dirty because release compiles the committed archive
snapshot, which excludes them. These procedures do not update the historical
evidence recorded above.
