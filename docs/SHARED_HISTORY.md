# Optional shared local Code history

Shared History is an owner-requested preview for switching between accounts
while continuing saved local Code chats. Separate histories remain the default.
Linking spaces does not sign in, transfer credits, merge provider accounts, or
change a subscription. Claude and the older Codex copy groups use each space's
existing login. Codex's main-workspace mode uses its native signed-in account.

## Use it

### Claude: Shared Conversations

For one library across every current and future Claude space, enable **Use one
chat history for all Claude accounts** above the space list. If every current
space is already linked to the same library, enabling the policy does not
require quitting Claude. Otherwise finish active work and quit Claude before
enabling it so enrollment can safely capture local histories. Existing linked chats and retained
revisions stay in the same library. Ready accounts are included immediately;
the setting also works before any accounts or histories exist.

For a new space, sign in and open Code once, quit Claude, then open the space
through Parallax again. It joins the same library automatically on that open,
including opens from links and the menu bar. A unique populated local history
takes precedence over empty/scheduling-only directories. If several histories
contain chats (or several empty histories exist), choose the intended one in
**Shared Conversations… → Reconnect Accounts…**. Already linked accounts remain
usable while an unrelated new account awaits that choice. Existing bindings
are never changed automatically. Parallax does not authenticate the login from
directory names; confirm the intended signed-in account in Claude.

Turning this setting off stops future automatic inclusion but retains the
current links. **Use Separate Histories** disconnects the group and disables
automatic inclusion, retaining all saved chats. Multiple existing groups must
be explicitly disconnected/reviewed into one library before enabling the
setting; it does not silently merge separate groups.

For manual selection of only particular accounts:

1. Confirm the intended signed-in account in each managed Claude space, open
   Code at least once, finish active work and quit Claude.
2. Select a space and choose **Shared Conversations…**. The existing **Shared
   History…** action also opens this setup. Select the account/organization
   history for each participating space using its chat count and directory
   identifiers. Manual setup does not implicitly select a history. At least
   two spaces join manual setup; the all-accounts setting can start with one.
   A space can belong to one group; canonical libraries have no eight-space cap.
3. Confirm the mappings, choose **Review Shared Conversations**, review the
   artifact warning, then **Create Shared Library**. Existing shared-history
   groups migrate through the same explicit review. No native records are
   rewritten during enrollment.
4. Select a conversation and destination in the library sheet and choose
   **Switch Account**. Subsequent switches use the compact account picker and
   retain that conversation selection. **Open without selecting a conversation**
   opens the destination's Code history without selecting an arbitrary chat.
   Parallax requests a graceful quit of actionable managed instances, captures
   saved messages, prepares the destination and opens it. Finish active work
   first: there is no reliable active-turn detection, and Claude may require
   an import review before continuing. Parallax never submits a message.
5. **Review Versions** previews recent message text and lets you select a saved
   revision. Select an account before restoring a conversation missing or
   archived there. Other saved revisions remain available.
6. **Recover Switch** clears an interrupted handoff after all linked spaces are
   inactive and their data reservations can be acquired. If the macOS open
   outcome is unknown, resolve the existing **Clear Stuck Launch Record…**
   workflow first. **Cancel Switch** cancels a preparation owned by this window
   and waits for its file work to finish; it does not force quit Claude.
7. **Reconnect Accounts…** repeats explicit binding review after storage or
   account-history changes. **Use Separate Histories** disconnects the group
   without deleting the library, native chats or recovery copies. Disconnect
   before removing members or moving storage, then create a reviewed group.
   With the all-accounts setting, reviewed new accounts can join the existing
   library without disconnecting it.

Routine account changes do not require selecting a source account or copying
chats. Parallax's library holds the saved conversation; native account folders
are working copies. Separate login credentials and provider permissions remain
with each space. Both accounts still refer to the same project files on this
Mac. Sharing does not copy repositories, worktrees or external files.

### Codex: one main history for every account

Enable **Use one chat history for all Codex accounts** above the Codex space
list. Current and future spaces then open the existing main Codex workspace
(`~/.codex`), using the app's normal desktop storage. **Open Main History**
opens that workspace; the space label does not switch the signed-in account.
When a subscription runs out, change accounts inside Codex. The same native
history stays in place, including its archives, projects and attachments.

This preference does not move or copy chats, credentials or databases and can
be enabled while Codex is running. Other account homes remain untouched. It
does not merge old isolated histories into the main workspace. Turn it off to
open those separate homes again; the saved space configurations are unchanged.
Claude and Codex retain separate histories, not a cross-provider conversation.

If an older Codex copy group is enabled, turn off that group first. Existing
copies remain. A missing or replaced main folder blocks opening instead of
silently selecting an empty home. Restore the folder, or open Codex normally
and turn the preference off and on to reconnect it. Unreadable preferences
require recovery and cannot be silently reset by the toggle.

The preference is stored locally in receipt schema 4, outside portable library
imports. Migration keeps the previous receipt. Launch approvals include the
selected folder identity, and changing the preference invalidates an older
approval. Terminal exports the same home and clears inherited alternate Codex
database/UI roots; shell startup files can still override exported settings.
Native app reuse remains subject to the Local Spaces best-effort boundary.

When Codex is already running normally, **Open Main History** brings it forward
and reports that activation as complete. Parallax does not claim or supervise
that process or mark the selected space as running. A process claimed,
supervised or durably recorded for a Parallax space is refused with a request
to quit Codex first; unavailable tracking evidence also prevents acceptance.
Isolated-space launches continue to refuse pre-existing processes.

### Older Codex copy groups and legacy Claude operation

The following describes the older optional Codex copy setup. Unmigrated Claude groups
retain their old launch behavior until explicitly enrolled above; opening
their settings now offers migration to Shared Conversations.

1. Sign in to each account in its own Parallax space. For Claude, open Code at
   least once so Desktop creates the account's local history directory.
2. Quit every instance of the provider app, including its background windows.
3. Select a space and choose **Space Actions → Shared History…** (also in the
   space's context menu). Select the other spaces and click **Share History**.
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

**Claude Shared Conversations:** explicit bindings replace the legacy
one-namespace rule. A binding pins the managed root's volume/inode, namespace
identity and account/organization IDs. New or changed local records outside
the binding require review; scheduling-only directories do not. This detects
some stale-account changes but does **not** authenticate the currently signed-in
provider account. Confirm that login in Claude before enrollment/reconnection.
The newest statically inspected desktop build is **2.16120.0**. It still stages
`<cliSessionId>.jsonl` through native import records, and its exact-session
continue URL is behind a provider feature gate. If the URL is ignored, open the
selected chat in Claude's Code list. Import review and native resume acceptance
remain provider-controlled and have not been verified with live accounts for
this implementation.

Native records are rebuilt from the minimal import allowlist. The central
library stores transcript bytes and revision metadata, not raw desktop session
records (which can contain spawn secrets or permission approvals). Transcript
contents can themselves contain private messages, tool results and paths.
Unrelated unreadable records are listed for review and retained in their
original spaces; they no longer prevent opening another valid chat.

**Legacy Claude groups and one-off copying:** use the local Code import format inspected in 2.9939.2 and
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

### Conversation library

The catalog and content-addressed immutable transcript blobs live in
`Parallax/ConversationLibraries/<group-id>/`. The catalog records each native
conversation ID, selected revision, original transcript digest, source space
and account/organization provenance, parent revision, per-account publication
baseline, local removal/archive state, and pending handoff. There is no
automatic garbage collection. These local files are not portable library
metadata exports.

Catalog writes use a private descriptor-backed container, exclusive lock,
generation and durable atomic replacement. Blob reads verify their digests.
Native writes use the existing no-follow managed filesystem and retained
recovery files. Data reservations cover capture/publication and recovery.
Source snapshots are checked again before publication; native destinations are
checked against exact previous record/transcript hashes before replacement.
An independently launched writer can still race these checks; this is not an
operating-system security boundary.

The handoff records `waiting → capturing → preparing → ready → opening` and
the exact launch request/target/selected conversation. Capture commits before
publication, so a target write failure retains newly saved source messages.
Only the matching tracked, actionable process can complete the handoff. This
records an opened configured space, not provider authentication or successful
resume. A recovered/cancelled request cannot publish later. Interrupted partial
publication is reconciled by stable IDs and hashes on a subsequent switch;
copies and saved revisions are retained.

The initial enrollment captures all selected histories. Normal switches scan
the last opened source and requested destination, one conversation at a time;
when no active source is known, they scan all participants. Reads use existing
disk-backed transcript snapshots and rehash unchanged bytes before using the
validation cache. Ordinary app navigation does not rewrite the catalog. Disk
space remains a practical limit because retained originals and revisions grow.

Claude normalization skips unparseable lines, including a truncated final line,
while retaining parsed session and working-directory validation. Original bytes
remain in their separate immutable blob. A later completed tail extends the
previous normalized prefix. Codex normalization is unchanged.

Equal transcripts deduplicate, and linear extensions advance the chosen
revision. A compaction advances automatically only from the tracked active
space when its first normalized record is a `system/compact_boundary` anchored
by `logicalParentUuid` to the prior final main-thread message. Other rewrites,
truncation or concurrent branches require explicit selection. This is a narrow
format check, not general compaction compatibility. Conflicting or unreadable
chats are skipped, while unrelated valid chats remain usable. Choosing an
affected chat requires resolving its problem first. Native deletions and
archives remain local and are restored only by explicit user choice.

For an unreadable source, explicitly selecting a retained revision acknowledges
that exact failed snapshot and allows continuation in a healthy account. A
changed failure fingerprint requires review again. This does not authorize
overwriting an unreadable destination; repair that native history or choose a
healthy destination instead. Original files and all retained revisions remain.

Migration builds the library before publishing its pointer in the sharing
receipt. The previous v1 receipt is retained byte-for-byte as
`shared-history-v1-<digest>.json`. Canonical receipts use schema v2; the
all-accounts policy, single-account libraries or groups exceeding eight members
use schema v3. Older binaries reject unsupported schemas instead of ignoring
the policy or running peer synchronization. Disabling the policy does not
downgrade the receipt. Do not restore an old receipt over newer histories or
downgrade the app against that receipt. Canonical data and native copies stay
saved. Failed enrollment retains original histories and does not
publish a partially built library. IDs previously recorded as shared but now
absent from one account are marked missing there instead of being restored
automatically. A transcript already absent from every account cannot be
reconstructed from its old receipt's digest alone.

Account inclusion publishes the expanded catalog before the membership
receipt. A retry repairs an interrupted membership publication using the same
library and its retained revisions. Automatic publication requires the policy
to still be enabled, and a pending account switch blocks membership changes.
Native records are first prepared during the normal launch handoff, not during
enrollment. `AllAccountHistoryTests` and `SharedHistoryStoreTests` cover policy
persistence, future accounts, namespace ambiguity, interrupted publication,
disconnection, stale writes, unsafe roots and receipt migration with synthetic
histories.

### Legacy peer synchronization

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

Switch progress is owned by the durable request ID. Failed and cancelled
requests replace progress immediately, including inside the History panel and
its version review. Repeated scheduling cannot replace an active task with the
same ID. Cancellation awaits file work and reservation release; recovery is
disabled while that task still owns the operation. A competing request cannot
release another request's waiting handoff. These behaviors are covered by
`ConversationLibraryIntegrationTests`; they do not prove native continuation.

`ConversationLibraryTests` covers canonical round trips, anchored compaction,
conflicts and explicit selection, local deletion/archive restoration,
unreadable-chat isolation, write failures, source/target changes, changed
binding identities, cancelled/stale handoffs, concurrent catalog writers,
integrity checks and bounded message previews. `ConversationLibraryIntegrationTests`
covers migration, legacy receipt retention, repeat enrollment, disconnect,
invalid mappings, launch preparation and exact conversation routing.
`WorkspaceApplicationLauncherAdmissionTests.testContinuationIsDeliveredWithTheExactProfileLaunchConfiguration`
checks URL delivery with the exact destination arguments/environment and
retained unknown-open recovery. These tests use synthetic histories and fake
provider processes; they do not sign in or exercise a real provider account.

Live acceptance still needs the user's explicit authorization and participation:
confirm two logins; continue one supported Code chat through A → B → A with a
distinct user-authored message at each step; confirm Claude shows all messages
once, preserves the selected native ID and uses the chosen login; repeat with
import review and with the continue route unavailable. Check that an unlinked
space stays unchanged. Run this with a disposable conversation before migrating
important histories. A successful local test suite is not evidence of that
provider-controlled behavior.

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
