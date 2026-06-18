# Parallax

Parallax is a macOS utility for managing **isolated launch profiles** for desktop applications, with first-class support for Chromium-based browsers and the OpenAI Codex desktop app.

For each managed `.app`, you can create multiple profiles (e.g. Personal, Work, Testing, Throwaway). Parallax automatically injects `--user-data-dir=<per-profile folder>/UserData` and, for Codex, `CODEX_HOME=<per-profile folder>/CodexHome`, so each launch runs as a **separate application instance** with its own account state, cookies, and storage.

## Features

- **Per-app profile libraries** — manage many isolated profiles per application.
- **Automatic isolation settings** — recommended `--user-data-dir` and `CODEX_HOME` are applied and can be re-applied on demand.
- **Separate application instances** — each profile launches as a new instance via `NSWorkspace` with custom arguments and environment.
- **Health checks** — verify profile folders, user-data directories, and Codex homes exist.
- **Archive & clear data** — move profile data into an `Archives/` folder instead of deleting it outright.
- **Import / export** the library as a versioned JSON document.
- **Settings** — configure default profile templates, base storage path, launch confirmation, and appearance (system/light/dark).

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6.0 toolchain

## Building

Build the executable with Swift Package Manager:

```bash
swift build
```

Run the test suite:

```bash
swift test
```

### Building a `.app` bundle

Use the included build script to assemble a signed, distributable `.app` bundle (and optional `.zip`/`.dmg`):

```bash
./script/build_and_run.sh run                 # build and launch
./script/build_and_run.sh release --zip --dmg # produce dist artifacts
./script/build_and_run.sh --help              # full options
```

Key environment variables: `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`, `SIGN_IDENTITY`, `DIST_DIR`.

## Where data lives

- **Library:** `~/Library/Application Support/Parallax/library.json`
- **Profiles:** `~/Library/Application Support/Parallax/Profiles/<App>/<Profile>/` (configurable per-app via base storage path)

## Project layout

```
Sources/Parallax/
├── App/            Entry point, scenes, AppDelegate
├── Models/         LaunchProfile, ManagedApplication, AppPreset, AppSettings, LibraryDocument
├── Services/       ApplicationLauncher (NSWorkspace integration)
├── Stores/         LibraryStore (view model), LibraryPersistence
├── Support/        ShellWordsParser
└── Views/          SwiftUI views (sidebar, detail, editors, settings, empty states)
Tests/ParallaxTests/ LaunchProfileTests
```

## License

See [LICENSE](./LICENSE).
