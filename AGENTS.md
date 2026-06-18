# AGENTS.md

Guidance for AI agents (and humans) working on this codebase.

## Project

Parallax is a macOS (SwiftUI, macOS 14+) multi-profile launcher for Chromium-based browsers and the Codex desktop app. It is a Swift Package (`Package.swift`) with an executable target `Parallax` and a test target `ParallaxTests`.

## Build & test commands

- Build: `swift build`
- Test: `swift test`
- Build a distributable `.app`: `./script/build_and_run.sh run` (see `--help` for release/zip/dmg/sign options)

There is no separate lint step; the Swift compiler (strict concurrency, Swift 6) is the primary gate. Run `swift build` and `swift test` before considering work complete.

## Architecture

- `LibraryStore` (`Stores/LibraryStore.swift`) is the `@Observable @MainActor` view model. It owns `applications`, selection state, persistence, profile CRUD, launch orchestration, and health checks. Views hold it via `@Bindable`.
- `LibraryPersistence` reads/writes `~/Library/Application Support/Parallax/library.json` as a versioned `LibraryDocument` (and tolerates a legacy raw `[ManagedApplication]` array).
- `ApplicationLauncher` / `WorkspaceApplicationLauncher` launches a new application instance via `NSWorkspace.openApplication` with custom args/env. `ApplicationLaunching` is the protocol used by tests (`DeferredLauncher`).
- `AppPreset` classifies apps and drives recommended isolation settings. `AppPreset.detected` uses word-boundary matching on the display name plus bundle-id substring matching.
- `ShellWordsParser` tokenizes argument strings and re-quotes them.

## Conventions

- Selection semantics: `selectedApplication` / `selectedProfile` / `selectedApplicationIndex` return `nil` when nothing is selected — do **not** silently fall back to the first item. Mutations must no-op when the target is `nil`.
- Two-way bindings: views keep a local `@State draft` synced to the store via `onChange`. Always guard `if newValue != draft` when copying the model back into the draft to avoid feedback loops and cursor resets.
- User-facing strings built in code (not SwiftUI string literals) must use `String(localized:)`. SwiftUI `Text`/`Label`/`Button`/`Section`/`.help` string literals are already `LocalizedStringKey`.
- Avoid force unwraps. Prefer `if let` / `??`.
- Profile folder names are stable (`storageName`); renaming a profile must not move its on-disk folder.
- `save()` should not run unconditionally on `load()` — only persist when migration actually changed data.

## Library format versioning

`LibraryDocument.currentVersion` is `1`. `LibraryPersistence.decodeApplications` rejects documents with a version greater than `currentVersion` via `LibraryPersistenceError.unsupportedVersion`. When bumping the version, add a migration path there.

## Testing

Tests live in `Tests/ParallaxTests/LaunchProfileTests.swift`. They use a temp directory per test and a `DeferredLauncher` test double to control async launch completion. The test double is `@MainActor`-safe via an `NSLock`.
