# Isolation and data ownership

Parallax isolates launch **configuration and selected storage locations**. It
does not create a macOS sandbox, a separate login session, a VM, or a separate
Keychain. Treat profiles as a convenient way to ask a compatible application to
use different data, not as a boundary against a malicious or incompatible
application.

## What a profile changes

For a profile using generated paths, Parallax can pass:

- `--user-data-dir=<managed profile>/UserData` to compatible Chromium-based
  applications.
- `-profile <managed profile>/FirefoxProfile` and `-no-remote` to Firefox.
- `--user-data-dir=<managed profile>/UserData` and
  `--extensions-dir=<managed profile>/Extensions` to VS Code-family editors
  (VS Code, Insiders, VSCodium, Cursor, and Windsurf).
- `CODEX_HOME=<managed profile>/CodexHome` to Codex.
- For Claude Desktop, both
  `--user-data-dir=<managed profile>/UserData` and
  `CLAUDE_CONFIG_DIR=<managed profile>/UserData/ClaudeConfig`. This configures
  its web app data and Claude Code state to use the same space-specific
  locations when Claude honors those values.
- The profile’s additional arguments and environment entries.

The application decides whether to honor those values. It may ignore an
argument, reuse a singleton process through IPC, start helpers that use shared
locations, or write elsewhere.

Firefox and VS Code generated arguments are saved when creating a space with
recommended settings, applying recommended settings through the preview, or
duplicating a space. An upgrade or newly detected preset does not silently add
them to existing spaces. Recommended settings preserve explicit paths and
Firefox selections such as `-P`, `-ProfileManager`, `-CreateProfile`, or
`XRE_PROFILE_PATH`. Both `-profile` and `--profile` accept a folder path; a
generated folder combined with another Firefox selection blocks launch until
the conflict is removed. Duplicate replaces these selections with fresh
generated paths and leaves the original external data untouched.

Capability summaries shown when adding an application and in its header
describe the preset's requested data separation and the app's
`LSMultipleInstancesProhibited` policy. An unreadable policy is unverified;
absence of a prohibition does not guarantee independent processes. These
summaries do not certify account, Keychain, helper-process, or system-resource
isolation.

Parallax offers a preview with history-format validation to copy a selected local **Code**
conversation between managed Claude spaces. It creates a separate imported
conversation and keeps the source unchanged. It does not merge histories or
copy Chat-tab conversations. See [Claude conversation copying](CLAUDE_CONVERSATION_COPY.md).

The **History…** preview links explicitly selected Claude histories to a
revision library while preserving separate authentication. Conflicting and
missing conversations require individual review; saved versions remain in the
library. New spaces never join on opening. Older Codex copy groups synchronize
active local Code chats before launch and refuse divergent or missing shared
chats. Those groups also accept the exact Parallax-owned account-session home
namespace after opt-in; arbitrary external homes remain excluded. Codex's main
workspace mode instead reuses its native home without copying histories. See
[Shared history](SHARED_HISTORY.md).

Claude Code binds
its login to the `CLAUDE_CONFIG_DIR` it was started with (its Keychain item is
scoped per configuration directory), so each Claude configuration directory
holds its own independent login. Parallax never copies credentials between
directories; pointing a space or a tracked account at a different configuration
directory requires signing in again there. Whether Claude Desktop honors a
configured storage path for its web-app data remains the application's
decision. Switching accounts may therefore make an earlier chat unavailable in
the new account. The copy workflow carries over the selected conversation's
messages and tool results for use with the destination login, after explicit
review. Both conversations still refer to the same project files.

These Local Space paths are separate from usage-connection account boundaries.
Each tracked Claude Code account receives its own
`~/Library/Application Support/Parallax/AccountSessions/<account-id>/ClaudeConfig`
directory, which the usage tracker supplies as `CLAUDE_CONFIG_DIR` for sign-in,
status, and usage operations.

### Refresh policy for tracked accounts

A refresh failure never disconnects a tracked account. The account keeps its
connected state and its last known values, and the failure is shown alongside
them. “Sign-in required” is shown only when the provider tool explicitly
reports that the account’s configuration directory has no login; a timeout, a
missing tool, or an incomplete response is reported as that failure, not as a
sign-out. Only removing the record, or a record that has never signed in, is
“not connected”. Once the provider has reported a missing login, the record
remembers it: a later timeout or an abandoned browser sign-in does not turn the
card back into a plain refresh, and only a successful refresh or sign-in clears
it. Tracked accounts are re-checked automatically about every 5 minutes and
again after the Mac wakes from sleep, so an account that was signed in outside
Parallax, or whose sign-in expired, updates without a manual refresh. An
account whose checks keep failing is retried less often each time, up to once
an hour, until a check succeeds. While a check is running, the previous values
stay on screen and the account reads “Refreshing” rather than failed.

Immediately before a managed Claude launch, Parallax revalidates both paths and
forces the managed user-data and Claude configuration directories to owner-only
`0700`, including directories created by an older build.

Likewise, `NSWorkspace.OpenConfiguration.createsNewApplicationInstance` is a
request to Launch Services, not a guarantee that the target application will
create and retain an independent process.

Profiles launched under the same macOS account can still share:

- login Keychain items and credentials;
- application-group and container data;
- system and application preferences, caches, logs, and temporary locations;
- helper processes, extensions, agents, shared services, and singleton IPC;
- files reachable through the user account’s normal permissions.

Use separate macOS accounts or a stronger OS/virtualization boundary when those
resources must be isolated.

## Launch status

“Launch requested” or “request accepted” means macOS accepted the open request.
It does **not** prove that a new process is running or that the application used
the requested profile.

Parallax reports a profile as running only after `NSWorkspace` returns a
specific running application and Parallax has installed termination tracking.
An application that immediately exits is not treated as durably running.
Parallax follows the lifecycle through requested, launching, running,
terminating, terminated, failed, or cancelled states. Cancelled is used only
for an open that Clear Stuck Launch Record released.

By default, Parallax prevents a second concurrent launch of the same profile
storage and blocks clear, remove, relocation, and similar mutations while that
storage is active. The expert override is intentionally explicit because two
processes using or modifying the same storage can corrupt it.

While Clear, Duplicate, a removal that archives or deletes data, or a
relocation runs, Parallax reserves the spaces involved. No Parallax window can
open them until the operation finishes (“This space is busy with a data
operation…”), and the reservation cannot be overridden: the expert override
for a destructive action on a running space never passes another data
operation. If such an operation was interrupted and its recovery has to wait,
for example because one of its spaces is still open, Parallax keeps those
spaces closed until recovery finishes (“Wait for storage recovery to finish
before opening …”).

For Claude spaces, two spaces that use the same `CLAUDE_CONFIG_DIR` folder
cannot run at the same time. The message names the other space. This rule
cannot be overridden either, and it does not apply to other presets.

Ambiguous durable launch receipts also keep storage blocked. A space's context
menu can offer **Clear Stuck Launch Record…** only when the cached snapshot has
an opening-state launch receipt for that space, or an open from this session
whose outcome is unknown and whose space still points at the application
bundle that was opened. There must be no global ambiguity and no other
in-process request for the same identity. The library and settings must be
available, with no profile-data operation running; while a library operation
is in progress, the action is offered only for spaces that a waiting startup
recovery involves. The action validates the exact receipt and requires all
matching application instances to be stopped; unavailable process evidence
prevents clearing. Confirmation names the space and warns that an unrecognized
process could still be using its data. Receipt and process checks run again
under the activity lock. Clearing retires only confirmed launch records and
does not delete space data or dismiss other blockers. See
[stuck launch recovery](MIGRATION_AND_RECOVERY.md#stuck-launch-records).

If an app reports an error while opening and Parallax cannot tell whether it
started, managed-data actions for that space and further opens of that app
stay blocked. The error message asks you to quit every instance of the app,
restart Parallax, and then use Clear Stuck Launch Record for that space.
Opens of the same app that were already requested wait, and their status
names the space whose record is stuck; once every instance of the app has
quit, clearing that record lets them continue without a restart. The cleared
open is recorded in Recent Activity as “Open cancelled”.

If `library.json` is missing while journals require recovery, the recovery
screen can restore a verified metadata backup after rechecking absence under
the library lock. Start Over is unavailable in this state. Restoring metadata
retries journal recovery; it does not restore profile payloads or guarantee that
conflicting operations can recover. See
[verified library backups](MIGRATION_AND_RECOVERY.md#verified-library-backups).

### Post-launch isolation checks

After a tracked launch becomes running, Parallax checks for modification times
newer than its launch baseline in the managed primary data folder: Firefox's
profile folder, or the managed user-data folder for other presets. It checks
after about 30 seconds and, if needed, once more about 30 seconds later.
External folders, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and the extensions folder
are not separately checked.

The bounded scan reads filesystem metadata, not file contents, and does not
follow symbolic links or enter mounted volumes. If a complete scan finds no
activity, a temporary notice says the app has not written to the folder yet
and may be ignoring the isolation option. An incomplete scan is inconclusive.
The notice clears when the check ends or the tracked launch ends.

An idle app may not write anything, and another process can update a folder.
Neither activity nor the absence of a notice proves which process used the
folder, that every requested option was honored, or that other resources are
isolated. The check does not change the running state or block the app.

## Terminal and space links

For Codex and Claude presets, **Open Terminal in This Space** opens macOS
Terminal and exports the space's resolved `CODEX_HOME` or `CLAUDE_CONFIG_DIR`.
A private, self-deleting command file changes to the macOS user's home
directory, prints a banner, and starts that user's login shell. It does not
start the provider tool or apply the profile's other arguments and environment
entries. Login startup files may override the exported value.

The action can run while the space's app is running, but is refused while a
data operation reserves its storage. Other configuration and storage checks
still apply; unsaved edits must be saved or discarded, imported configurations
require review, and a tool-directory value stored in Keychain or marked
sensitive is refused. Parallax releases its reservation after handing the
command to Terminal and does not track the open shell or commands run there.
Close tools using the space before changing its data.

**Copy Link to Space** copies `parallax://open?space=<space UUID>`. The link
contains only the space identity, not launch arguments or credentials. Opening
it always asks for confirmation naming the application and space, with Cancel
as the default action. Unknown spaces and other URL actions are refused;
confirmation still applies imported-configuration review and normal launch
checks. The window-routing and keyboard behavior require the
[pending manual checks](BUILD_AND_RELEASE.md#manual-ui-checks).

## Environment and secret handling

The normal launch environment is built from a small trusted baseline, including
identity, locale, temporary-directory, and fixed system path values. Parallax
does not copy the full parent environment by default. In particular, arbitrary
parent secrets, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, SSH agent values, and
dynamic-loader variables are not inherited unless an advanced configuration
explicitly opts into broader inheritance.

Secret environment values can be stored as opaque Keychain references. Parallax
resolves a reference only while preparing the final launch environment.
Portable exports never contain the referenced Keychain value. The Keychain
itself remains shared at the macOS-account level, so a profile-specific
reference is not a separate Keychain security boundary.

Imported launch configurations remain pending review until the user inspects
and approves the exact current configuration. Editing an approved imported
configuration invalidates that approval. Importing metadata never imports
Keychain secret values.

An update can ask you to review an imported space again when approval starts
to cover more settings. For example, imported Claude spaces approved by an
earlier build may ask once more, because approval now includes the Claude
configuration folder.

## Managed and external paths

Each application and profile has an immutable storage UUID. Display-name changes
therefore do not rename or move its storage directory.

Parallax-managed profile data is under:

```text
<configured-base>/.parallax/Applications/<application-storage-id>/Profiles/<profile-storage-id>/
```

Archives are under:

```text
<configured-base>/.parallax/Archives/<application-storage-id>/<profile-storage-id>/
```

The default configured base is:

```text
~/Library/Application Support/Parallax/Profiles
```

Before a managed mutation, Parallax canonicalizes the base, verifies directory
identity, and verifies that the target remains within the `.parallax`
namespace. Changed roots, symbolic links, hard-linked folders, another volume
mounted inside managed storage, unsafe names, and unexpected files stop the
operation. Parallax's own folders under `.parallax` must belong to you and
must not carry access-control entries; if they are group- or world-writable,
Parallax removes that write access.

A missing storage root is reported as unavailable when its enrolled volume
UUID is not mounted, including outside `/Volumes`. This requires a readable
enrollment record and mounted-volume inventory; without them, the older path
checks apply. See
[external storage drives](MIGRATION_AND_RECOVERY.md#external-storage-drives)
for replug recovery, enrollment limits, and **Forget This Drive**.

An explicitly configured absolute user-data, Firefox profile, or extensions
directory, `CODEX_HOME`, or `CLAUDE_CONFIG_DIR` outside the generated path is
**external**. It is configuration-only from Parallax’s point of view. External
data remains owned and backed up by the user or by the external application.

## Exact data-operation behavior

| Operation | Managed profile data | Explicit external data | Library metadata |
| --- | --- | --- | --- |
| Launch | Application receives generated paths | Application receives configured paths | Last-launch/lifecycle state may update |
| Reveal | Opens an existing selected directory; does not create one | Opens an existing selected directory; does not create one | Unchanged |
| Clear Data | Moves the managed profile root to a new archive entry; no-op if no managed data exists | Never touched | Profile remains |
| Duplicate | Copies the managed profile root when it exists | Never copied; the duplicate receives fresh generated recommended isolation paths for supported presets | Adds a profile with new immutable IDs |
| Remove Profile Only | Left in place | Left in place | Removes the profile entry |
| Remove and Archive Data | Moves the managed profile root to an archive entry | Left in place | Removes the profile entry |
| Remove and Delete Data | Deletes the managed profile root through a recoverable transaction; an interrupted delete finishes the next time the library opens | Left in place | Removes the profile entry |
| Relocate Storage | Moves Parallax-managed application/profile data and archives transactionally. Refused while an explicit path or another application points inside the storage being moved, while the destination lacks POSIX permissions or lies inside another application's storage, or while an earlier relocation of the application is unfinished. Original data that cannot be removed safely is left in place, and Parallax shows its location until you dismiss the notice | Not moved or rewritten | Updates the managed base after publication succeeds |
| Remove Application / Keep in Place | All managed profile roots are left in place | Left in place | Removes the application and its profile entries |
| Remove Application / Archive | Managed profile roots are moved to their archive locations. Stops if the storage volume is disconnected. Refused while copies kept by an earlier Keep Files and Continue remain | Left in place | Removes the application and its profile entries |
| Remove Application / Delete Permanently | Managed profile roots are deleted through a recoverable transaction; an interrupted delete finishes the next time the library opens. Stops if the storage volume is disconnected. Refused while copies kept by an earlier Keep Files and Continue remain | Left in place | Removes the application and its profile entries |

“Remove Profile Only” and application removal with “Keep in Place” intentionally
leave orphaned managed data. Parallax does not later infer ownership from a
visible name. Record the displayed paths if you plan to reclaim those
directories manually.

Clear, duplicate, profile removal, application removal, and relocation stage
their filesystem and metadata work as coordinated transactions. A failed
operation is rolled back when that can be proved safe; otherwise Parallax stops
in recovery instead of guessing. A metadata backup is required before
destructive application removal, and it is taken only after the removal passes
its checks, so a refused removal does not create one.

Directory copies preserve extended attributes and non-protected user flags,
including Finder metadata and the hidden flag, through pinned descriptors.
Immutable, append-only and system flags are never copied; protected sources
are refused. Symlinks remain refused.

If an application removal can neither finish nor roll back safely, the removal
window shows Application Removal Recovery. Retry Recovery tries again. Keep
Files and Continue stops recovery for that removal only: it leaves every file
where it is, keeps the current application list, and lists the locations
under Preserved Files the next time you open Remove Application. After you
close the window or restart Parallax, the library recovery screen offers
Review Application Removal… to return to these choices; Start Over is not
offered while a removal needs recovery.

## Export is not backup

The File menu provides three portable JSON exports:

| Export | Includes | Excludes |
| --- | --- | --- |
| Library Metadata | Applications, profiles, launch configuration, storage IDs, and related metadata | Settings/templates, managed data payloads, external data, app binaries, Keychain secret values |
| Settings and Templates | Parallax settings and profile templates | Library metadata, managed data payloads, external data, app binaries, Keychain secret values |
| Portable Configuration | Library metadata plus settings/templates | Managed data payloads, external data, app binaries, Keychain secret values |

If a launch configuration contains a plaintext value that appears sensitive,
Parallax asks whether to omit, redact, or explicitly include it. Keychain
reference tokens may be present so the relationship can be reconstructed, but
the secret values they reference are never exported.

An import changes metadata only. It is size-, structure-, and schema-validated;
conflicts require an explicit decision, and imported launch configurations must
be reviewed before launch. Existing profile data is not replaced by an import.

Recovery backups are also metadata backups: they preserve exact verified
`library.json` bytes, not profile payloads.

Parallax does not currently offer a one-click complete data backup. For a
coherent manual backup:

1. Quit applications launched from every affected profile, then quit every
   Parallax window.
2. Copy `~/Library/Application Support/Parallax` to backup storage.
3. For each custom base root, copy its `.parallax` directory.
4. Back up every explicitly configured external user-data, Firefox profile,
   extensions, `CODEX_HOME`, or `CLAUDE_CONFIG_DIR` directory separately,
   following the owning application's guidance.
5. Export Settings and Templates if those settings must be portable.
6. Back up required credentials using an appropriate Keychain-aware process;
   neither filesystem copies nor Parallax exports contain Keychain secret
   values.

Do not assemble a backup while affected applications or Parallax are writing
those locations. A filesystem snapshot or backup tool capable of taking a
consistent snapshot is preferable for large profiles.
