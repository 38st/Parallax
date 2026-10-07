# Parallax

A small macOS app for people who use more than one Claude or Codex account.

- **Usage.** See how much of each account's limits you've used (current session and week), refreshed every 5 minutes.
- **Spaces.** Open separate copies of Claude, Codex (ChatGPT), Chrome-family browsers, VS Code-family editors, or Firefox at the same time, one per account. Each space keeps its own sign-in and data.
- **Chats.** When one Claude account runs out, continue the same Claude Code chat in another account. For Codex, turn on **One chat history for all Codex accounts** and switch accounts inside Codex.

## Requirements

- macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later) to build.
- For usage tracking, the `claude` and/or `codex` command-line tools, installed with Homebrew, npm, or the native installer (`~/.local/bin`).

## Build and install

```bash
./script/build_app.sh             # builds dist/Parallax.app
./script/build_app.sh --install   # also copies it to /Applications (quit Parallax first)
swift test
```

`PARALLAX_SUPPORT_DIR=/some/scratch/folder` makes a development run use that folder instead of your real data.

## How it works

- **Usage** runs `claude auth status`, `claude -p /usage`, and `codex app-server` against a private login folder per account in `~/Library/Application Support/Parallax/AccountSessions/`. Adding an account signs in through the provider's own login.
- **Spaces** open the app with its own data folder: `--user-data-dir` for Chromium and Electron apps, plus `CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex, `--extensions-dir` for VS Code, and `-profile` for Firefox. Space folders live under `~/Library/Application Support/Parallax/Profiles/`.
- **Chats** copies a Claude Code chat's record and transcript into the other account's chat folder and opens Claude there. Claude is quit in both spaces first, and a copy that would be replaced is saved to `ChatBackups/`.

Everything Parallax keeps is in `~/Library/Application Support/Parallax/state.json`.

## Limits

- Only Claude **Code** chats can be continued in another account. Regular Claude chats are stored on Anthropic's servers under each account.
- claude.ai artifacts, sign-ins, and permissions stay with the account that created them.
- Usage numbers come from the providers' command-line tools. If a tool changes its output, usage shows as unavailable until Parallax is updated.
- Spaces are separate data folders, not a security boundary between accounts.

## Upgrading from Parallax 1.x

On first launch, Parallax 2 reads the 1.x library, usage accounts, and Codex history setting, and keeps using the same space folders, so sign-ins and chats carry over. It never changes the 1.x files. The 1.x source is in the git history up to commit `569ed34`.

## License

[MIT](LICENSE)
