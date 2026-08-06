# Release gate

## Decision

**NO-GO for public distribution from the current directory.**

**Locally verified source release candidate** once the exact intended changes
are reviewed. No locally actionable P0/P1/P2 macOS release-candidate defect
remains open in the gap register. Public release remains blocked by a
deliberately dirty, user-owned working tree plus Developer ID/notarization
authority that was not granted.

## Exact local results

All commands ran from a local macOS checkout on July 28, 2026.

| Gate | Command | Result |
| --- | --- | --- |
| Debug build | `swift build` | PASS |
| Complete test suite | `swift test` | PASS — 616 tests, 0 failures, 16.410s test time |
| Packaging contracts | `./script/test_build_and_run.sh` | PASS — 4/4 |
| Artifact integration | `PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native ./script/test_build_and_run.sh` | PASS — 5/5 |
| Candidate formats | Integration output | PASS — local `.app`, ZIP, DMG |
| Artifact verification | Integration output | PASS — code signature validity/designated requirement, ZIP/DMG re-extraction, hashes/provenance, collision policy |
| Reproducible archive | Integration output | PASS — repeated canonical ZIP from identical source epoch is byte-identical |
| Install lifecycle rehearsal | `rehearse_install_upgrade_rollback.sh` via integration | PASS — isolated clean install, upgrade, launch smoke, and byte-identical rollback |
| Secret scan | `gitleaks 8.30.1 dir . --redact` | PASS — 0 findings |
| Patch whitespace | `git diff --check` | PASS |
| Mobile prototype | simulator build/test audit | PASS — 2 tests; excluded from RC |

The packaging integration used isolated temporary output and removed it after
verification. No artifact was published, deployed, signed with release
credentials, or notarized.

## Release criteria

### Code and product

- [x] All locally actionable P0/P1 findings fixed and regression-tested.
- [x] Exact-profile isolation survives concurrent Parallax processes.
- [x] Unexpected exit is visible and recoverable.
- [x] Automatic retry requires strong crash evidence and is bounded per profile.
- [x] Workaround verification is durable, profile-scoped, and truthful.
- [x] Dirty editor state cannot be silently lost or launched stale.
- [x] Argument-secret leakage is blocked/redacted.
- [x] P2 findings are documented with rationale.
- [x] Locally actionable macOS P2 findings are fixed and regression-tested.

### Data and security

- [x] Versioned library uses compare-and-swap and recovery evidence.
- [x] Managed mutations are transactionally recoverable and descriptor-safe.
- [x] Sensitive metadata/journals are hardened to `0700`/`0600`.
- [x] Keychain references remain opaque outside launch preparation.
- [x] Redacted repository scan reports no committed/worktree secret finding.
- [ ] Clean reviewed commit identified.
- [ ] Signed/notarized artifact tested on a clean macOS account.

### Build and operations

- [x] Debug and production compilation.
- [x] Complete unit/integration suite.
- [x] Local app/ZIP/DMG packaging and independent verification.
- [x] Unsigned canonical source-candidate ZIP is byte-reproducible for the same
  source epoch.
- [x] Unsigned clean-install, upgrade, and rollback rehearsal is automated.
- [x] Release mode refuses dirty or uncommitted source.
- [x] Missing credentials fail before artifact mutation.
- [ ] Developer ID signature.
- [ ] Apple notarization and stapling.
- [ ] Gatekeeper assessment of final artifact.
- [x] Clean install, supported upgrade, and rollback rehearsal using local
  ad-hoc artifacts.
- [ ] Repeat clean install, upgrade, and rollback using the final signed
  artifact on a clean macOS account.
- [ ] Final version/build number approved.
- [ ] Publication/deployment explicitly authorized.

## Required maintainer handoff

1. Review the existing user-owned changes together with this hardening work;
   choose the exact source intended for release.
2. Commit it on a clean branch. Release mode will refuse anything else.
3. Re-run `swift test` and both packaging suites from that commit.
4. With authorized credentials, run the documented `release` mode in
   [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md).
5. Independently verify `codesign`, Gatekeeper, notarization/stapling,
   ZIP/DMG hashes and provenance.
6. Repeat the automated install/upgrade/rollback rehearsal with the final
   signed artifacts on a clean macOS account, then exercise
   add/open/quit/crash/manual recovery/import/migration.
7. Change this decision to GO only if every unchecked gate passes.

## Remaining accepted risks

- Mobile is a separate prototype and remains excluded (PRX-017).
- The unsigned source-candidate ZIP is byte-reproducible. Developer ID
  ZIP/DMG bytes include Apple metadata/timestamps and are verified by ticket,
  signed payload, and provenance instead.
- A native host-driven visual/XCUITest suite would add polish coverage, but the
  stable accessibility contract and critical state transitions are automated.

None of these risks authorizes bypassing the clean-tree, review,
signing/notarization, or final clean-account gates.
