# Delivery ledger

This ledger is the current delivery snapshot for Parallax. Historical issue,
branch, and CI narratives were removed because they described superseded work
and made the active release state hard to identify.

Last verified: September 10, 2026, at source commit `3fc2988`.

## Current product state

| Area | Status | Evidence |
| --- | --- | --- |
| Workspace navigation | Verified | Control Center and Local Spaces use one persistent `NavigationSplitView` sidebar. Sidebar selection and the two detail tabs stay synchronized. |
| Claude desktop spaces | Verified | Every Claude space receives a distinct managed `--user-data-dir` and `CLAUDE_CONFIG_DIR`; Launch Services is asked for a new application instance. Existing and newly created managed directories are forced to owner-only `0700` before launch. |
| Claude account tracking | Verified preview | Each tracked Claude account receives an owner-only account-specific `CLAUDE_CONFIG_DIR`; sign-in, status, and parsed live `/usage` operations are scoped independently to that account. |
| Codex account tracking | Verified preview | Each tracked record uses a provider/account-specific `CODEX_HOME` and the official local app-server status flow. |
| Localization | Verified | The census covers 1,025 source keys and 1,168 literals. English and Spanish each contain 1,035 catalog entries; dynamic keys, unknown interpolations, new debt, and allowlisted debt are all zero. |
| Quality gates | Verified locally | Local scripts enforce warning-clean tests, localization, coverage, secret scanning, ASan, TSan, production Keychain characterization, unsigned universal packaging, and clean-artifact inspection. `script/run_quality_gates.sh` runs them in order. There is no hosted CI. Signed/notarized release remains a manual credentialed procedure. |

## Verification evidence

| Gate | Result |
| --- | --- |
| Release build with warnings as errors | PASS |
| Full Swift test suite with warnings as errors | PASS — 1,264 tests, 0 failures, 1 foreground-activation capability skip |
| Fresh isolated coverage suite | PASS — 1,264 tests, 0 failures, 1 capability skip |
| Product line coverage | PASS — 46,413 / 71,430 lines (64.9769%); floor 30,029 / 56,525 (53.1252%) |
| Localization checker | PASS — 1,025 source keys, 1,035 English and Spanish catalog entries, zero debt |
| Localization checker contracts | PASS — 15/15 |
| Evidence hygiene contracts | PASS — 9/9 |
| Coverage gate contracts | PASS — 3/3 |
| Warning gate contract | PASS — 1/1 |
| Packaging contracts | PASS — 11/11 |
| Native artifact integration | PASS — 12/12: local app, reproducible ZIP, DMG, install/upgrade/rollback, provenance, and collision checks |
| Secret scan | PASS — gitleaks 8.30.1, zero findings |
| Thread Sanitizer lane | PASS — 1,264 tests, zero diagnostics |
| Address Sanitizer lane | PASS — 1,264 tests, zero diagnostics |

## Repository state

Recorded September 10, 2026 after the branch, worktree, and tracker cleanup.

| Item | Disposition |
| --- | --- |
| Hosted CI | Removed in `afb6981`. GitHub Actions was already disabled for the repository and had not run on `master` since August 6, 2026. Quality gates are the local scripts listed in the release gate. |
| `wip/parallax-mobile-prototype-20260729` | Archival. Checkpoint `feb7daaf` is preserved on `origin/wip/parallax-mobile-prototype-20260729` and locally. |
| `wip/parallel-development-20260728` | Superseded. Its single commit `1d7c7b9` is byte-identical to the former `AF-009` stash and its behavior was integrated into `master` in `be1bc11` and later refactors. The branch is kept as history; the stash was dropped and the `Parallax-dev` worktree removed. |
| `codex/reconcile-product-20260816`, `wip/parallax-product-run-20260729` | Triaged and closed out; see the [branch triage](production-readiness/branch-triage.md). The product-run branch has no unique commits. Of the 68 commits on the codex branch, 33 were already in `master`, 9 were obsolete or superseded, 20 were not applicable (hosted CI lanes or removed product-run bookkeeping), and 4 were ported with contract tests in `a423f9a` and `9f5476e`. Two stay open by choice: frozen release metadata binding needs tracked changelog and release-notes documents plus a new mode, and a test-harness cleanup allowlist is unsafe under the system bash. Both branches are kept as history; their worktrees were removed. |
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
