# Contributing to Parallax

Thanks for helping improve Parallax. Contributions are welcome as bug reports,
feature proposals, documentation fixes, tests, and code changes.

## Before opening an issue

- Search existing issues to avoid duplicates.
- Remove profile names, filesystem paths, environment values, account details,
  and other personal data from logs and screenshots.

## Development setup

Parallax requires macOS 14 or later, Apple command-line developer tools, and a
Swift 6 toolchain.

```bash
git clone https://github.com/38st/Parallax.git
cd Parallax
swift build
swift test
```

Build and run a local app bundle with:

```bash
./script/build_and_run.sh run
```

This produces an ad-hoc-signed development build. It is not a distributable
release. See [Build and release](docs/BUILD_AND_RELEASE.md) for packaging and
verification details.

Regenerate the README screenshots on macOS with a Retina display and access to the window server:
`PARALLAX_README_SCREENSHOT_DIR="$PWD/docs/images" swift test --filter ReadmeScreenshotRenderingTests`.
This opt-in test briefly shows the real views in a test-owned window over a
neutral backdrop and captures the complete window at 2x in light mode, preserving
transparent corners. It uses synthetic accounts and spaces in disposable
temporary storage, then closes both windows and removes the fixtures; it does
not launch apps or contact providers. Without the environment variable, the test
is skipped.

## Making a change

Maintainers and coding agents working directly in this repository also follow
the operating rules in [AGENTS.md](AGENTS.md); external contributors use the
branch and pull-request flow below.

1. Create a focused branch from the default branch.
2. Add or update tests for behavioral changes.
3. Keep user data compatibility and migration behavior explicit.
4. Run `swift build` and `swift test`.
5. Open a pull request that explains the problem, the approach, and any user
   data or compatibility implications.

Keep pull requests small enough to review. Avoid unrelated formatting changes,
generated build output, credentials, real profile data, and local machine
configuration.

## Project conventions

- A missing application or profile selection stays `nil`; do not silently fall
  back to the first item.
- Profile storage identities are stable. Renaming a profile must not move its
  on-disk folder.
- Guard model-to-draft synchronization with an equality check to avoid SwiftUI
  feedback loops and cursor resets.
- Use `String(localized:)` for user-facing strings constructed in code. SwiftUI
  string literals already use `LocalizedStringKey`.
- Avoid force unwraps.
- Persist library data only when a mutation or migration requires it.
- Treat imported identifiers, paths, arguments, and environment values as
  untrusted input.

Changes involving storage, migration, import, recovery, launch configuration,
or destructive actions should include failure-path tests as well as success
tests.

## Pull request checklist

- [ ] `swift build` succeeds.
- [ ] `swift test` succeeds.
- [ ] User-facing behavior and documentation are updated.
- [ ] New user-facing strings are localizable.
- [ ] No credentials, personal data, generated artifacts, or local paths are
      included.
- [ ] Storage and migration compatibility have been considered.

By contributing, you agree that your contribution will be licensed under the
[MIT License](LICENSE).
