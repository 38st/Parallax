# Workspace simplification

The October 4 redesign keeps the existing local storage and launch safeguards
while reducing the number of places needed for everyday work.

## Everyday workflow

1. Choose an app in the sidebar. Each saved space has an **Open** action;
   a verified running instance offers **Show** instead.
2. For Claude or Codex, use **Account & Usage** in the space's actions to record
   the expected Desktop email. A dated confirmation records what the user
   checked inside the native app; it is never a live identity assertion.
3. Optionally link an existing usage tracking record. Its CLI authentication is
   separate from Desktop authentication. Missing or stale usage is explicitly
   unavailable, with any retained measurement labeled as historical.
4. For Claude sharing, select a space and open **History**. Review the chosen
   histories once. Only those selected spaces become members. Opening a new
   space, even with a legacy all-account preference, cannot enroll it.
5. Search shared conversations by title or project. Opening an account does not
   require selecting a conversation. Conflicts expose dated saved revisions and
   a message preview; recovery retains the original histories and saved versions.

Home offers direct access to saved and recently opened spaces. Activity contains
launch and provider-check records. Settings collects preferences, usage
connections, configuration import/export, and storage guidance. Menu-bar opens
route through the main window so required launch reviews remain visible.

When main Codex history is enabled, the app page presents one destination.
Choose its launch configuration explicitly once if an older receipt has no
saved selection. Change the provider account inside Codex itself. Other local
histories are retained.

## Compatibility and evidence

| Requirement | Implementation and automated evidence |
| --- | --- |
| Immediate switch errors and owned cleanup | `SpaceOperationStatusView`, `LibraryStore+LaunchLifecycle`; `ConversationLibraryIntegrationTests` exercises failed preparation, duplicate scheduling, competing reservations, and retry with uncertain launch storage. |
| Explicit identity and account links | `SpaceAccountLink`, `LibraryStore+AccountLinks`; `SpaceAccountLinkTests` covers old JSON, restart, stale edits, identity changes, import and duplication. |
| One primary Open after setup | `ProfileListView`, `SpaceOpenButton`; existing launch lifecycle and review tests continue to exercise the shared launch entry point. Native sign-in remains a manual check. |
| Reviewed membership only | `ConversationAccountPicker`, `ConversationLibraryView`, `LibraryStore+AllAccountHistory`; `AllAccountHistoryTests` covers new spaces remaining separate and interrupted membership publication. |
| Search without implicit selection | `ConversationSearchTests` covers title/project tokens, activity ordering, and archived conversations. |
| One main Codex destination | `CodexSharedWorkspaceTests` covers explicit launch selection, receipt reload, root identity, invalid selection and stale edits. |
| Main-window menu routing | `MenuBarOpenRoutingTests` covers queued opens, retained launch confirmation, explicit navigation and removed targets. |
| Existing spaces and histories retained | Optional account metadata and an optional Codex launch-profile ID are additive. Existing storage IDs, managed paths, settings, history bindings and revision files are not moved by this redesign. Existing persistence, rename, import and history suites remain required. |

`ReadmeScreenshotRenderingTests` renders Home, app pages, Account & Usage,
History, and Settings using disposable stores and synthetic accounts. It does not launch a provider. Synthetic previews are available for
[Account & Usage](images/parallax-account-details.png),
[first-time History review](images/parallax-history-review.png),
[shared History](images/parallax-history.png),
[a visible switch error](images/parallax-history-error.png), and
[Settings](images/parallax-settings.png). The current gate
results and source SHA are recorded in [the delivery ledger](DELIVERY_LEDGER.md).

Automated coverage does not establish a live Desktop account's identity or
successful native conversation continuation. Those acceptance checks require
opening the native apps with the owner's real accounts separately. This change
does not install a new app bundle or perform that live acceptance flow.
