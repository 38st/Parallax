# Delivery ledger

This ledger is the current delivery snapshot for Parallax. Historical issue,
branch, and CI narratives were removed because they described superseded work
and made the active release state hard to identify.

Last verified: August 21, 2026.

## Current product state

| Area | Status | Evidence |
| --- | --- | --- |
| Workspace navigation | Verified | Control Center and Local Spaces use one persistent `NavigationSplitView` sidebar. Sidebar selection and the two detail tabs stay synchronized. |
| Claude desktop spaces | Verified | Every Claude space receives a distinct managed `--user-data-dir` and `CLAUDE_CONFIG_DIR`; Launch Services is asked for a new application instance. Existing and newly created managed directories are forced to owner-only `0700` before launch. |
| Claude account tracking | Verified preview | Control Center follows the current macOS user's default Claude Code sign-in, exposes at most one Claude identity, serializes Claude operations provider-wide, and reports only parsed live `/usage` windows. Legacy duplicate rows are collapsed without deleting their old local directories. |
| Codex account tracking | Verified preview | Each tracked record uses a provider/account-specific `CODEX_HOME` and the official local app-server status flow. |
| Localization | Verified | The census covers 953 source keys and 1,086 literals. English and Spanish each contain 953 keys; dynamic keys, unknown interpolations, new debt, and allowlisted debt are all zero. |
| CI | Verified locally | `.github/workflows/ci.yml` enforces warning-clean tests, localization, coverage, secret scanning, ASan, TSan, production Keychain characterization, unsigned universal packaging, and clean-artifact inspection. Signed/notarized release remains a manual credentialed job. |

## Verification evidence

| Gate | Result |
| --- | --- |
| Release build with warnings as errors | PASS |
| Full Swift test suite with warnings as errors | PASS — 1,207 tests, 0 failures, 1 foreground-activation capability skip |
| Fresh isolated coverage suite | PASS — 1,207 tests, 0 failures, 1 capability skip |
| Product line coverage | PASS — 45,250 / 69,737 lines (64.8866%); floor 30,029 / 56,525 (53.1252%) |
| Localization checker | PASS — 953/953 keys in English and Spanish, zero debt |
| Localization checker contracts | PASS — 14/14 |
| CI evidence hygiene | PASS — 10/10 |
| Coverage gate contracts | PASS — 3/3 |
| Warning gate contract | PASS — 1/1 |
| Packaging contracts | PASS — 6/6 |
| Native artifact integration | PASS — local app, reproducible ZIP, DMG, install/upgrade/rollback, provenance, and collision checks |
| Secret scan | PASS — gitleaks 8.30.1, zero findings |

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
