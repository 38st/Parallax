# Contributing to Parallax

Bug reports, fixes, and small improvements are welcome.

- Remove account emails, file paths, environment values, and other personal data from issues, logs, and screenshots.
- Build with `swift build`, test with `swift test`, and make an app bundle with `./script/build_app.sh`.
- Keep changes small and focused on the three things Parallax does: usage tracking, per-account spaces, and continuing chats. See [AGENTS.md](AGENTS.md) for the project's conventions.
- Add a test for behavior changes. Tests use temporary folders, never your real Parallax data.
