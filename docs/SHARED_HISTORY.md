# Optional shared local Code history

Shared History is an owner-requested preview for switching between accounts
while continuing saved local Code chats. Separate histories remain the default.
Linking spaces does not sign in, transfer credits, merge provider accounts, or
change a subscription. Each linked space uses its existing login.

## Use it

1. Sign in to each account in its own Parallax space. For Claude, open Code at
   least once so Desktop creates the account's local history directory.
2. Quit every instance of the provider app, including its background windows.
3. Select a space and choose **Space Actions → Shared History…** (also in the
   space's context menu). Select the other spaces. For Claude, click
   **Review Sharing** to check for artifact references, then **Share History**.
   For Codex, click **Share History** directly.
4. Open the desired account's space normally. Before opening it, Parallax
   synchronizes active local conversations across the group. Quit the provider
   before opening another linked account.
5. **Turn Off Sharing** returns the group to separate histories. It keeps
   already copied chats; it does not delete messages or restore old versions.

Two to eight spaces in the same application can form a group. A space can
belong to one group. Conversations and tool output become visible to every
linked account. Both accounts still refer to the same project files on this
Mac. Sharing history does not copy a repository, worktree, or external file.

## Provider boundaries

**Claude Desktop:** uses the local Code import format inspected in 2.9939.2 and
2.9939.4, with stable session and CLI IDs and the original title. Only the native import
allowlist is published to the destination account directory. Claude can ask
for import review again when a newer transcript arrives. Login data, cookies,
permission approvals, spawn configuration, and MCP settings are not copied.
Each space must have one unambiguous account/organization history and separate
managed `UserData` and `ClaudeConfig` paths. Chat-tab and remote sessions are
outside this adapter. The app version is not an admission gate. Session records,
transcripts and account-directory structure are validated before publication;
an unsupported record or transcript stops synchronization before any history
is written. These checks cannot guarantee future provider acceptance. Native
Desktop acceptance with real signed-in accounts remains a manual validation boundary;
synthetic tests do not establish it.

**Codex:** copies local active rollout JSONL files with stable thread IDs,
then asks the installed trusted `codex app-server` to refresh its local list
using `thread/list` with `useStateDbOnly: false`. No login, resume, turn, or
model call is sent by this refresh. Each account keeps its own `CODEX_HOME`,
authentication and SQLite databases. Existing cached messages can remain in
the UI until the native chat resumes. The adapter currently accepts local CLI
and VS Code rollout metadata from **0.153.2** and **0.158.0-alpha.2.1**; unknown
versions or remote/subagent session metadata stop sharing. An installed Codex
CLI is required for indexing. Native desktop account switching remains a
preview; cloud chats and ChatGPT chat history are not included. Sidebar
organization, pins and database-only title edits are not synchronized.

The Codex adapter accepts generated managed homes and the exact Parallax-owned
`AccountSessions/<UUID>/CodexHome` namespace used by Control Center account
spaces. Other explicit external homes and explicit `CODEX_SQLITE_HOME`
overrides are refused. It never shares a whole home or SQLite directory.

## Artifacts

Claude hosts claude.ai artifacts under the account that created them. Their
contents are not part of local transcripts, cannot be copied by Parallax, and
will show as unavailable under another account. **Review Sharing** counts unique
artifact URLs in the selected spaces' active Claude transcripts and warns before
sharing. This is an advisory snapshot; later conversations can add references.
Sharing does not republish artifacts or change their links.

For a list of original local files and a republish prompt, use **Copy Claude
Conversation → Review Copy** for the relevant conversation. Where the transcript
identifies original files, Parallax shows whether they still exist on this Mac
and can copy a prompt listing only those still present. Paste it into Claude in
the destination space to request new artifacts. Shared History itself shows only
the count warning and does not publish artifacts.

## Conflicts and recovery

Only linear additions to the same saved conversation are reconciled. A saved
prefix length and digest prevent a truncated or rewritten previous history
from being silently restored. All
histories are checked before publication. If two transcripts diverge, sharing
stops and both versions remain available. A missing or archived conversation
from the last completed synchronization also stops sharing rather than
resurrecting a deletion. Archives and deletions are not propagated. Transcript
rewrites or compaction that changes the earlier record sequence can require
turning sharing off and reviewing the accounts separately.

Synchronization scans one conversation at a time and retains only paths,
record identities, byte counts and hashes across the group. Prefix comparisons
map at most the two conversations being compared, and publication revalidates
the source and destination before each write. Persisted baselines use the same
streaming scan. The former 256 MiB aggregate in-memory limit no longer blocks
large linked histories. Transcript and session-record reads stream into private,
immediately unlinked scratch files and return private mappings. JSONL
normalization processes one record at a time into the same disk-backed storage;
it does not build a whole-transcript string or normalized in-memory buffer.
Conversation sizes, JSON-line sizes, counts, and required receipt sizes have no
fixed product cap. Available disk space and memory for an individual JSON record
remain practical constraints. File identity, link, format, and conflict checks
still apply. Scratch mappings release their storage when no longer referenced.

For Claude, receipts also retain the hashes of previously validated session
records and transcripts. Every launch still enumerates the current history and
reads and hashes every file; unchanged bytes reuse their validated normalized
digest instead of reparsing and rewriting every JSON line. Changed records or
transcripts receive full validation and the same prefix/conflict checks. Older
receipts receive the cache after their next full synchronization. A completed
no-change synchronization does not rewrite the receipt. The optional validation
cache can be dropped to keep receipts smaller without dropping required
conversation IDs or baselines.

Claude staged transcripts use `<revision>/<cliSessionId>.jsonl`: Desktop's
reader resolves the directory from the import record and derives that exact
filename. A content digest belongs in the parent directory. Older copies that
put the digest in the filename are repaired on synchronization, including when
the linked transcripts have identical contents.

Each file replacement stages durable new bytes and atomically exchanges the
file, retaining the previous version under `.parallax-history-recovery` in
that same managed history root. Claude stages the new transcript before
publishing its native import record; the original CLI transcript remains until
Claude confirms the import. Recovery files may contain private conversation
data and remain until explicitly cleaned up. No automatic cleanup runs.
Publication across several chats/spaces is not one filesystem transaction:
an interruption can leave some chats updated, with the remaining updates
completed on retry. Stable IDs and content comparisons prevent retry copies.

Local opt-in receipts live in Parallax's private `shared-history.json`, with
locked compare-and-replace writes. Receipts bind stable space identities to
their verified roots, so retargeting storage requires fresh opt-in. They are excluded from portable library
exports/imports. Corrupt or future receipts fail closed. Clear, duplicate,
remove and relocate operations require disconnecting the affected group first.
Quit checks, inactive-profile reservations, no-follow snapshot reads and source
revalidation reduce races. They are not an OS security boundary and cannot
prevent an independently launched process from changing files.

## Evidence

`SharedHistoryTests` exercises Claude round trips, stable IDs, credential and
permission exclusions, divergent edits, deletion/archive refusal, interrupted
publication and file-identity changes. `SharedHistoryCodexTests` covers local
rollout round trips, auth/database preservation, unsafe paths, duplicate IDs
and unsupported formats. `SharedHistoryStoreTests` and
`SharedHistoryLibraryTests` cover opt-in persistence, stale writers, corrupt
receipts, launch preparation, running apps, data-operation protection and
index-failure recovery. Claude store tests use compatible histories with unknown
or missing app versions and reject incompatible records/transcripts without
changing history. All automated fixtures use disposable synthetic roots.

Separate manual characterization used disposable homes, no credentials and a
loopback mock model with Codex 0.153.2 and bundled 0.158.0-alpha.2.1. Both
resumed the same ID through A → B → A with both messages present, and an
unlinked third home stayed empty. This establishes local rollout behavior,
not live-account or desktop UI acceptance.

Required local gates remain those in [the release gate](production-readiness/release-gate.md).
Historical counts elsewhere in the repository are not evidence for this change.
