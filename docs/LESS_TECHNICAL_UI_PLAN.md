# Less-Technical User Experience Plan

## Goal

Make Parallax understandable and useful to someone who knows they want separate
app spaces but does not know what bundle identifiers, launch arguments,
environment variables, storage roots, or user-data directories are.

The default experience should answer three questions:

1. Which app am I opening?
2. Which separate space am I opening it in?
3. What should I click to open it?

Advanced configuration must remain available without dominating the default
workflow.

## Definition of success

A new user should be able to:

1. Add an app.
2. Create a separate space with a recognizable name such as "Work."
3. Understand, at a high level, what will be kept separate.
4. Open that space.

They should be able to complete this flow without seeing or understanding raw
paths, bundle IDs, launch arguments, environment syntax, inheritance policy, or
storage implementation details.

Existing advanced users must retain access to all current configuration,
security, import, recovery, and data-management capabilities.

## Product framing

Present Parallax as a launcher for separate **spaces**, not primarily as a
launch-configuration editor.

Use "Space" in user-facing copy where the interface currently says "Profile."
Keep the existing `LaunchProfile` model and profile-oriented internal APIs. This
is a presentation change, not a persistence or schema migration.

Suggested core language:

| Current term | Preferred user-facing term |
| --- | --- |
| Application | App |
| Profile | Space |
| Add Application | Choose an App |
| Add Profile | New Space |
| Launch / Launch Profile | Open / Open Space |
| Preset | App Type |
| Profile Data | Browsing and App Data |
| Launch Arguments | Launch Arguments (Advanced) |
| Environment | Environment Variables (Advanced) |

Use the original technical term where precision is required in recovery,
security, import-review, or diagnostic content.

## UX principles

- Lead with the primary action: open a space.
- Use progressive disclosure instead of removing advanced capabilities.
- Prefer plain-language outcomes over implementation details.
- Keep warnings next to the action they affect.
- Never weaken security, destructive-action, or imported-configuration review
  safeguards for the sake of simplicity.
- Avoid multiple equally prominent ways to perform the same primary action.
- Preserve native macOS interaction patterns, accessibility, keyboard
  navigation, and localization.

## Current issues

### App metadata dominates the selected-app view

`ApplicationHeaderView` permanently shows the app name, bundle ID, path, preset,
storage path, and Apply/Revert controls. This puts maintenance and
implementation details above the user's spaces.

Relevant code:

- `Sources/Parallax/Views/ApplicationHeaderView.swift`
- `Sources/Parallax/Views/DetailView.swift`

### The space editor begins with raw configuration

`ProfileEditorView` puts launch arguments, environment syntax, inheritance,
Keychain references, data paths, health details, and launch preview in the main
form. A user must move through advanced concepts before reaching the primary
open action.

Relevant code:

- `Sources/Parallax/Views/ProfileEditorView.swift`

### Save and open are disconnected

Editing creates a draft, disables launching, and requires the user to discover
and press Apply before launching. "Apply" and "Revert" also sound like settings
utility terminology rather than a document or launcher workflow.

Relevant code:

- `Sources/Parallax/Views/ProfileEditorView.swift`
- `Sources/Parallax/Views/ApplicationHeaderView.swift`
- `Sources/Parallax/Views/DetailView.swift`

### Space rows emphasize technical metadata

Rows show argument counts and technical badges such as "Data Dir." The open
button is an icon-only control. Duplicate and remove are partly hidden in
context menus.

Relevant code:

- `Sources/Parallax/Views/ProfileListView.swift`

### Empty states describe the implementation

The first-run copy asks users to create "isolated launch profiles" and mentions
"profile-specific arguments and environment" before explaining the practical
benefit.

Relevant code:

- `Sources/Parallax/Views/EmptyStates.swift`

## Target default experience

The selected-app screen should be organized around spaces:

```text
Chrome                                             App Settings…

Your Spaces
┌────────────────────────────────────────────────────────────┐
│ Work       Accounts, history, and settings kept separate  Open │
│ Personal   Running now                                    Open │
│ Testing    Last opened yesterday                          Open │
└────────────────────────────────────────────────────────────┘

                         New Space
```

Selecting a space should show a simple editor:

```text
Work

Name                 Work
Separation           Uses its own app data
Notes                [optional notes]

Advanced Settings    >

Discard Changes                         Save / Save & Open
```

The exact visual treatment can follow native SwiftUI/macOS conventions. The
information hierarchy and progressive disclosure are the requirements.

## Work plan

### Phase 1: Simplify the main information hierarchy

#### Task 1.1: Replace the permanent app configuration card

Create a compact selected-app header containing:

- App icon
- App display name
- A secondary "App Settings…" button

Move the editable name, bundle ID, app path, app type/preset, storage path,
relink action, and associated Apply/Revert controls into a dedicated app
settings sheet or inspector.

Suggested implementation:

- Keep `ApplicationHeaderView` as the compact header.
- Extract the current form into a new `ApplicationSettingsView`.
- Present it from `DetailView` or `ApplicationHeaderView`.
- Rename "Apply" to "Save" and "Revert" to "Discard Changes."

Acceptance criteria:

- Bundle ID, raw path, and storage path are not visible in the default
  selected-app view.
- App settings remain reachable in one click.
- Relinking, preset-change preview, and storage-relocation behavior are
  unchanged.
- Unsaved app-setting edits are not silently discarded when dismissing the
  sheet. Prevent dismissal, prompt, or explicitly discard according to native
  macOS behavior.
- Existing conflict handling remains intact.

#### Task 1.2: Make the space list the visual focus

Update `DetailView` so the space list and selected-space content are the primary
content beneath the compact app header.

Acceptance criteria:

- A user can identify the selected app and its available spaces without
  scanning configuration metadata.
- Narrow and wide layouts remain usable.
- The minimum supported window size remains visually coherent.

### Phase 2: Add progressive disclosure to the space editor

#### Task 2.1: Create a simple default section

At the top of `ProfileEditorView`, show:

- Space name
- A short separation summary
- Notes
- Any compatibility, imported-configuration, parsing, or security warning that
  blocks or materially changes opening the space
- Primary save/open controls

Suggested summary copy:

- Chromium preset: "Uses separate browsing data for this space."
- Codex preset: "Uses separate Codex settings and data for this space."
- Custom or incomplete configuration: "Review Advanced Settings to confirm
  what this space keeps separate."

Do not claim that Parallax provides a security sandbox.

Acceptance criteria:

- A valid default or template-created space can be named, saved, and opened
  without expanding Advanced Settings.
- Important warnings are never hidden solely inside a collapsed disclosure.
- The summary is derived from the effective draft, not only the persisted
  profile.

#### Task 2.2: Move technical controls under Advanced Settings

Place these existing sections inside a collapsed-by-default "Advanced
Settings" disclosure:

- Launch arguments
- Environment variables
- Sensitive-value controls
- Keychain secret management
- Environment inheritance
- Browsing and app data paths/actions
- Detailed health checks
- Launch preview

The disclosure may automatically expand when:

- The configuration has parsing errors.
- An imported configuration requires review.
- A warning directly references an advanced field.

Acceptance criteria:

- All existing advanced fields and actions remain available.
- Draft state, staged Keychain handling, conflict detection, redaction, and
  cleanup behavior are preserved.
- Imported launch review cannot be bypassed.
- Parsing diagnostics remain associated with the relevant editor.

#### Task 2.3: Clarify save and open behavior

Replace the current footer with context-aware actions:

- Clean draft: "Open Space"
- Dirty valid draft: "Save" and "Save & Open"
- Dirty invalid draft: show the relevant error and disable "Save & Open"
- Secondary action: "Discard Changes"

Prefer this explicit workflow over introducing autosave in this project. The
current optimistic edit and conflict model is safety-sensitive, and autosave
would materially change its semantics.

Implementation note:

Refactor the existing draft-apply operation so the UI can determine whether a
save succeeded before opening. "Save & Open" must never open the stale
persisted profile after a failed save or edit conflict.

Acceptance criteria:

- Editing no longer leads to a disabled open button with no direct recovery
  action.
- "Save & Open" opens only after the exact draft is successfully persisted.
- A conflict or validation failure keeps the editor open and does not launch.
- Keychain references are committed or discarded exactly as they are today.

### Phase 3: Make the space list understandable

#### Task 3.1: Replace technical row summaries

Replace argument count as the primary secondary label with user-oriented
status:

- "Running now"
- "Last opened [relative date/time]"
- "Never opened"

Where reliable, add a short separation label such as:

- "Separate browsing data"
- "Separate Codex data"
- "Custom setup"

Do not infer separation more strongly than the effective configuration
supports.

Acceptance criteria:

- Argument counts are no longer prominent in the default list.
- Running state and last-opened state are accurate and accessible.
- Technical details remain available in Advanced Settings.

#### Task 3.2: Make the primary row action explicit

Use a visible "Open" button where layout permits instead of relying only on a
play icon. Keep an accessible compact treatment for narrow layouts.

Replace the icon-only footer with:

- A labeled "New Space" primary action
- A secondary template menu when templates exist
- Duplicate and remove in a discoverable selected-space action menu; context
  menus may remain as shortcuts

Acceptance criteria:

- The add and open actions are understandable without tooltips.
- Every icon-only fallback has an accessibility label and hint.
- Keyboard and VoiceOver traversal remain logical.
- Destructive actions retain confirmation.

### Phase 4: Improve onboarding and empty states

#### Task 4.1: Rewrite empty-state copy

Suggested first-run state:

- Title: "Choose an App"
- Description: "Add an app to create separate spaces for work, personal use,
  testing, or anything else."
- Primary action: "Choose an App…"

Suggested app-without-spaces state:

- Title: "Create Your First Space"
- Description: "A space can keep this app's accounts, history, and settings
  separate."
- Primary action: "New Space"
- Secondary action, when templates exist: "Start From a Template…"

Acceptance criteria:

- Empty states describe benefits before technical implementation.
- Copy does not overpromise isolation or security.
- Actions use the same terminology as the populated interface.

#### Task 4.2: Add a guided New Space sheet

Replace immediate creation with a short sheet:

1. Name the space.
2. Choose a purpose/template: Work, Personal, Testing, Blank, or a configured
   template.
3. Show a one-sentence separation summary.
4. Create, with an optional "Create & Open" primary action.

Reuse the current templates and preset recommendation logic. Do not add a new
persistence format for the wizard.

Acceptance criteria:

- A user can create a recommended valid space without editing raw
  configuration.
- "Blank" remains available for advanced/custom use.
- Template names remain user-editable in Settings.
- Creation errors leave the user's entered name and choice intact.

### Phase 5: Terminology and feedback pass

#### Task 5.1: Apply user-facing "Space" terminology

Update visible strings, accessibility labels, help text, alerts, menus, and
localized count formatting. Keep internal identifiers and model names stable.

Search at minimum:

```sh
rg -n '"[^"]*(Profile|profile|Launch|launch)[^"]*"' Sources/Parallax
```

Do not mechanically replace:

- Security or diagnostic terms where "launch configuration" is the precise
  concept
- File names, type names, test fixture keys, JSON fields, or migration content
- Imported data terminology that must match its format

Acceptance criteria:

- The primary workflow consistently uses App, Space, New Space, and Open.
- Accessibility output uses the same mental model.
- Localization tests pass.
- Technical text remains technically correct.

#### Task 5.2: Improve launch feedback

After a successful request, show a brief status such as:

- "Opened Work in Chrome."
- "Chrome is already using this space." when that condition can be determined
  reliably

Keep failure messages actionable and in plain language, with technical detail
available when useful.

Acceptance criteria:

- Users receive immediate feedback after choosing Open.
- Success and failure states are distinguishable without relying on color.
- Existing launch lifecycle and confirmation behavior remain correct.

## Guardrails and non-goals

This work must not:

- Change the library JSON schema or stored profile identity.
- Weaken launch trust review, Keychain handling, path validation, redaction,
  backup, migration, recovery, or destructive-action safeguards.
- Claim operating-system-level isolation or sandboxing.
- Remove raw configuration support.
- Change ownership rules for managed or external data.
- Redesign import conflict resolution or library recovery beyond terminology
  consistency.
- Add automatic discovery of installed apps as part of this effort. It can be a
  later enhancement; the existing app picker is sufficient for the scoped
  onboarding flow.

## Likely files

Primary:

- `Sources/Parallax/Views/ApplicationHeaderView.swift`
- `Sources/Parallax/Views/DetailView.swift`
- `Sources/Parallax/Views/ProfileEditorView.swift`
- `Sources/Parallax/Views/ProfileListView.swift`
- `Sources/Parallax/Views/EmptyStates.swift`

Supporting:

- `Sources/Parallax/Stores/LibraryStore.swift`
- `Sources/Parallax/Models/LaunchProfile.swift`
- `Sources/Parallax/Models/AppPreset.swift`
- `Sources/Parallax/Support/LocalizedCount.swift`
- `Sources/Parallax/Resources/*/Localizable.stringsdict`
- `Sources/Parallax/Views/SettingsView.swift`

Tests likely to update or extend:

- `Tests/ParallaxTests/ProfileListPresentationTests.swift`
- `Tests/ParallaxTests/LocalizationTests.swift`
- `Tests/ParallaxTests/LibraryPresentationStateTests.swift`
- `Tests/ParallaxTests/ProfileEditorSecurityPresentationTests.swift`
- `Tests/ParallaxTests/LaunchLifecycleTests.swift`
- `Tests/ParallaxTests/MultiWindowStoreIntegrationTests.swift`

## Implementation strategy

Prefer extracting presentation values and action-state decisions into small,
testable value types rather than embedding all copy and branching directly in
SwiftUI views. Examples:

- `SpaceSeparationSummary`
- `SpaceEditorPrimaryAction`
- `SpaceListItemPresentation`
- `NewSpaceDraft`

Reuse existing store operations. Add new store methods only where an atomic
save-then-open result or guided-creation operation is required.

Keep phases independently reviewable. A sensible pull-request sequence is:

1. Compact app header and app settings sheet.
2. Simple/advanced space editor and Save & Open.
3. Space-list rows and explicit actions.
4. Guided creation and empty states.
5. Terminology, accessibility, launch feedback, and final polish.

## Verification

Run:

```sh
swift test
./script/build_and_run.sh run
```

Manually verify:

1. Empty library → choose an app.
2. App with no spaces → create a default space.
3. Create from each built-in template.
4. Save a renamed space.
5. Save & Open a dirty valid space.
6. Attempt Save & Open with parsing errors.
7. Trigger an optimistic-edit conflict from two windows.
8. Add, replace, and remove a staged Keychain secret.
9. Review and approve an imported configuration.
10. Change app preset and review the preview.
11. Relink an app and relocate storage.
12. Remove a space while keeping, archiving, and deleting data.
13. Use the app at minimum window size and in both light and dark appearance.
14. Navigate the main workflow using only the keyboard.
15. Review VoiceOver labels and order for app selection, space selection, New
    Space, Open, Save & Open, Advanced Settings, and destructive actions.

## Completion criteria

This effort is complete when:

- The default selected-app view no longer displays raw app metadata.
- A new space can be created and opened without exposing advanced fields.
- Advanced users can still reach every existing configuration and data action.
- Dirty edits offer an explicit Save & Open path.
- The primary workflow consistently uses plain-language App/Space/Open terms.
- All automated tests pass.
- The packaged app builds and the manual critical-path checks above pass.
