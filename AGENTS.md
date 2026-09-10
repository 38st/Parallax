# Parallax agent instructions

Operating rules for coding agents working in this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) as well; the conventions repeated below are
the ones agents break most often.

## Truthfulness first

- [docs/PRODUCT_CONTRACT.md](docs/PRODUCT_CONTRACT.md) is the ceiling for every
  claim. Documentation, UI copy, tests, and commit messages must not exceed it.
- Local Spaces is the supported macOS surface, local AI account tracking is
  preview, and enterprise seat, member, recommendation, transfer, billing, and
  compliance behavior is deferred. Never imply that local tracking changes
  provider state, or that Parallax provides an operating-system security
  boundary.
- Evidence is bound to a source SHA. Never reuse an earlier test count, gate
  result, or coverage number as proof for a new commit.
- Put file, test, or command evidence next to every status claim. When a
  capability does not exist yet, say so plainly instead of softening it.

## Git workflow

- Work directly on `master` with normal commits. Do not create a feature
  branch unless the user asks for one.
- Push after each cohesive unit of work. Do not end a turn with finished work
  committed locally and unpushed.
- Never force-push and never rewrite published history. If a push is rejected,
  reconcile with a fast-forward pull or a rebase and retry. Stop and ask the
  user if the branches have genuinely diverged.
- Get explicit user approval before any destructive git operation: a forced
  push, `reset --hard` on pushed commits, deleting a ref, worktree, or stash,
  or deleting an unmerged branch.
- `wip/parallax-mobile-prototype-20260729` and its checkpoint commit are
  archival. Do not delete, rebase, or merge them. See
  [docs/MOBILE_STATUS.md](docs/MOBILE_STATUS.md).
- Commit messages describe the change only. Do not add attribution,
  co-author, or generated-by lines.

## Quality gates

There is no hosted CI, and none may be added. The bar is the set of local
scripts recorded in the
[release gate](docs/production-readiness/release-gate.md). Run the checks
proportional to the risk of the change, and the full set before pushing
anything that touches product code or scripts:

```bash
swift build -c release --jobs 4 -Xswiftc -warnings-as-errors
swift test --jobs 4 -Xswiftc -warnings-as-errors
./script/check_coverage.sh
python3 script/check_localization_completeness.py
python3 script/test_localization_completeness.py
./script/test_ci_evidence_hygiene.sh
./script/test_coverage_gate.sh
./script/test_warning_gate.sh
./script/test_build_and_run.sh
PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native \
  ./script/test_build_and_run.sh
./script/run_secret_scan.sh
git diff --check
```

Documentation-only and comment-only changes need no build. Report the exact
commands you ran and their results, and never describe a gate as passing
unless you ran it on the current tree.

## Do not install or launch the app on your own

`./script/build_and_run.sh` defaults to `run` when it is called with no
argument, and the `run`, `install`, `debug`, `logs`, and `telemetry` modes all
replace `/Applications/Parallax.app` and register it with LaunchServices.
`release` signs, notarizes, and staples distribution artifacts. Use any of
those modes only when the user asks for them. The `build` mode stays inside
`dist/` and is the safe default when a local bundle is enough.

## Test hygiene

- Tests use disposable roots under `$TMPDIR` and synthetic fixtures.
- Never read or write `~/Library/Application Support/Parallax`, the login
  Keychain, or a real provider login, and never drive a real Codex or Claude
  sign-in from a test.
- Cover failure paths, not only success paths, for storage, migration,
  import, recovery, launch configuration, and destructive changes.
- Keep tests deterministic: no reliance on wall-clock timing, installed
  provider tools, or the current locale unless the test sets them.

## Code conventions

- A missing application or space selection stays `nil`. Never fall back to the
  first item.
- Application and profile storage identities are stable. Renaming must not
  move an on-disk folder.
- Guard model-to-draft synchronization with an equality check so SwiftUI does
  not feed back or reset the cursor.
- Use `String(localized:)` for user-facing strings built in code.
- Avoid force unwraps.
- Treat imported identifiers, paths, arguments, and environment values as
  untrusted input.
- Persist library data only when a mutation or migration requires it.
- Localization debt stays at zero. Every new user-facing string needs both an
  English and a Spanish entry, verified by the localization scripts above.

## Ask the user first

Ask, and never assume the authority, for: destructive cleanup, creating
external refs, tags, or releases, credential use, publication or any other
release step, protected repository administration, and any change to accepted
product scope.
