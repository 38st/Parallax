# Parallax agent instructions

## Keep it small

Parallax does three things: usage tracking, per-account app spaces, and continuing chats across accounts. Version 1 grew to 85,000 lines of transactional storage, custom parsers, migration frameworks, and process documents around those three jobs. Version 2 replaced it with a few thousand lines. Keep it that way.

- Before adding code, name which of the three jobs needs it.
- Use Foundation and AppKit instead of building infrastructure: atomic `Data.write`, `JSONDecoder`, `FileManager`, `NSWorkspace`.
- Don't add journals, recovery state machines, custom file-system layers, release gates, ledgers, or planning documents unless the owner asks for them.
- A rare failure that leaves a stray file or asks the user to retry is acceptable. Losing the user's chats or sign-ins is not.

## Git

- Work directly on `master`. Commit and push each finished unit of work.
- Never force-push or rewrite published history.
- Commit messages describe the change only. No attribution or co-author lines.

## Before pushing code

```bash
swift build -c release
swift test
```

## Tests

- Use temporary directories and synthetic data only.
- Never read or write `~/Library/Application Support/Parallax`, `~/.claude`, `~/.codex`, or the Keychain, and never start a real sign-in.

## Running the app

- Don't install to `/Applications` or launch the app unless the owner asks.
- For a development run, set `PARALLAX_SUPPORT_DIR` to a scratch folder.

## Data safety

- Never write to the 1.x files: `library.json`, `shared-history.json`, and the `corporate.workspace.v1` preference.
- Never move or rename a space's data folder; it holds that account's sign-in.
- Chat copies: quit Claude in both spaces first, and back up anything that would be replaced.
- Treat paths, arguments, and environment values from saved state as untrusted input.
