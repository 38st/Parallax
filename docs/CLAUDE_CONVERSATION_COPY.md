# Copy a Claude Code conversation between spaces

This is a local preview for Claude Desktop. It copies one saved
conversation from the **Code** tab into another Parallax Claude space so it
can be continued with the login already present there. It does not transfer
usage quota, merge accounts, or copy Chat-tab history.

## Use the preview

1. Sign in to Claude in the destination space and create a local Code
   conversation there once. This establishes its account history directory.
2. Quit all Claude instances.
3. In Parallax, select the source Claude space. Open **Space Actions → Copy
   Claude Conversation…**, or use the space's context menu.
4. Select a conversation and the destination space, then **Review Copy**.
   Review which account will receive the messages and tool results, then
   choose **Copy Conversation**.
5. Choose **Open Destination Space**. Find the conversation with **(copy)**
   appended to its title in Claude's Code tab. Its original activity date is
   preserved, so it may appear farther down the list. Complete Claude's own
   import review before continuing.

The source conversation stays unchanged. Both conversations reference the
same project directory; edits made by either affect those project files.
Messages and tool results may contain private information, including secrets
that were pasted into a chat. Continuing uses the destination account to
process that context. Parallax does not read or copy login credentials,
cookies, Keychain entries, desktop settings, or saved permission approvals.

## Artifacts

Claude hosts claude.ai artifacts under the account that created them. Their
contents are not part of the local transcript and cannot be copied by Parallax;
the links will show as unavailable when opened under another account.
Review Copy warns with the number of referenced artifacts and lists their URLs.
When a transcript unambiguously associates an artifact with an original local
file, the list shows its path and whether it still exists on this Mac.
**Copy Republish Prompt** copies a prompt listing only those files still present,
so you can ask Claude in the destination space to publish new artifacts. It is
disabled when no original files are available. Parallax does not read these
files or republish anything itself. The warning does not block copying or alter
the transcript's artifact references.

## Compatibility boundary

The adapter targets the local import boundary inspected in Claude Desktop
2.9939.2 and 2.9939.4. This is a private provider format, not a published
cross-account migration API. The app version does not determine admission:
compatible local history can be copied after a Desktop update without adding
that version to an allowlist. Session identifiers, required record fields,
account directory structure, transcript JSONL, working directories and session
bindings are checked before writing. Unrecognized or incomplete records are
not offered for copying; unsupported transcripts are refused.
The source and destination must use their generated Parallax user-data and
Claude configuration paths. External paths, missing or ambiguous transcripts,
multiple destination account/organization directories, and remote sessions
are refused. A provider restart or sign-in is never performed automatically.

The September 28 compatibility check compared the installed 2.9939.4 app
with the previously inspected 2.9939.2 code. `getStorageDir`,
`loadSessionRecords`, `registerExternalSession`, `finishRegisterExternalSession`
and `confirmImportedSessionResume` matched byte for byte. The session-directory
and import-type constants also matched. These inspected builds establish the
adapter's starting format, not a required version list. Format validation cannot
prove that a future provider import implementation will accept a copied chat.
Failed sharing keeps the selected spaces checked so the user can retry without
selecting them again.

Synthetic tests validate Parallax's copy, failure, and storage behavior.
They do **not** establish successful provider-side continuation. Manual
verification still requires opening the chosen copied conversation in the
destination Code tab and continuing with that account. No real login or
provider request belongs in automated tests.

## Storage and failure recovery

Only a selected desktop session record and its managed JSONL transcript are
read. The adapter emits a minimal new imported-session record with a distinct
session identifier. It drops the transcript's previous session binding and
subagent result linkage using the provider's import rules. It does not copy
the source record's permissions, hooks, scheduling, or provider configuration.

Reads use pinned descriptors with no-follow semantics and private disk-backed
snapshots. Conversation count and byte size have no fixed product cap; JSONL
normalization processes one record at a time instead of accumulating the full
transcript in memory.
Symlinks, hard links, unsupported objects, source changes after review, and
destination directory replacement stop the operation. Parallax reserves both
spaces while copying and requires Claude to be stopped. As elsewhere in Local
Spaces, this is not an OS boundary; an external application can still access
the same files or start independently of Parallax.

The transcript and a private session record are written exclusively and
synchronized before a single exclusive rename publishes the session record.
An interrupted attempt can leave private staging files. Retrying the same
unchanged source reuses matching prepared bytes and can finish publication;
an already published identical copy is recognized. Conflicting or damaged
staging files are preserved and refused, not overwritten or silently removed.
After Claude consumes or changes the imported record, another identical copy
attempt may be refused instead of duplicating or overwriting that conversation.

Implementation: `ClaudeConversationCopyService`,
`LibraryStore+ClaudeConversations`, and `ClaudeConversationCopyView`.
Regression evidence: `ClaudeConversationCopyTests`,
`ClaudeConversationCopySecurityTests`, and `ClaudeConversationCopyStoreTests`.
The store tests copy compatible fixtures across known, unknown and missing
Desktop versions and verify incompatible transcripts leave destinations unchanged.
Run these with `swift test --jobs 4 -Xswiftc -warnings-as-errors --filter ClaudeConversation`.
