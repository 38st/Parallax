import SwiftUI

struct NewSpaceView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var store: LibraryStore
    let application: ManagedApplication
    var openCreatedSpace: ((LaunchProfile) -> Void)?

    @State private var draft: NewSpaceDraft
    @State private var creationError: String?
    @State private var expectedEmail = ""

    var choices: [NewSpaceChoice] {
        NewSpaceChoice.available(templates: store.profileTemplates)
    }

    init(
        store: LibraryStore,
        application: ManagedApplication,
        preferredTemplateID: ProfileTemplate.ID? = nil,
        openCreatedSpace: ((LaunchProfile) -> Void)? = nil
    ) {
        self.store = store
        self.application = application
        self.openCreatedSpace = openCreatedSpace
        let choices = NewSpaceChoice.available(
            templates: store.profileTemplates
        )
        _draft = State(
            initialValue: NewSpaceDraft(
                choices: choices,
                preferredTemplateID: preferredTemplateID
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Space")
                .font(.title2.bold())

            Form {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $draft.name)
                        .accessibilityHint(
                            Text(draft.nameValidationMessage ?? "")
                        )
                        .accessibilityIdentifier(
                            UIAutomationContract.newSpaceName
                        )
                    if let message = draft.nameValidationMessage {
                        Label(
                            message,
                            systemImage: "xmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "new-space.name.validation-error"
                        )
                    }
                }

                if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                    TextField("Expected email", text: $expectedEmail)
                    Text("Create the space, sign in inside the Desktop app, then confirm the email in Account & Usage. History stays separate until you review sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Picker("Purpose", selection: choiceBinding) {
                    ForEach(choices) { choice in
                        Text(choice.title)
                            .tag(choice)
                    }
                }
                .accessibilityHint(
                    Text(
                        "Choose a starting point; you can change all settings later"
                    )
                )
                .accessibilityIdentifier(
                    UIAutomationContract.newSpacePurpose
                )

                LabeledContent("Separation") {
                    Text(
                        draft.separationSummary(
                            for: application
                        )
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)

            if let creationError {
                Label(
                    creationError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(
                    UIAutomationContract.newSpaceError
                )
            }

            SpaceOperationStatusView(store: store)
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    create(openAfterCreation: false)
                }
                .disabled(!draft.canCreate)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier(
                    UIAutomationContract.newSpaceCreate
                )

                Button("Create & Open") {
                    create(openAfterCreation: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canCreate)
                .accessibilityIdentifier(
                    UIAutomationContract.newSpaceCreateAndOpen
                )
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: choices) { _, updated in
            draft.synchronizeChoices(updated)
        }
    }

    private var choiceBinding: Binding<NewSpaceChoice> {
        Binding(
            get: { draft.choice },
            set: { draft.select($0) }
        )
    }

    private func create(openAfterCreation: Bool) {
        creationError = nil
        guard
            let created = store.createSpace(
                named: draft.name,
                templateID: draft.choice.templateID,
                applicationID: application.id,
                accountLink: expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : SpaceAccountLink(expectedEmail: expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        else {
            creationError = store.errorMessage
                ?? String(
                    localized:
                        "This space could not be created. Review the details and try again."
                )
            store.errorMessage = nil
            return
        }
        dismiss()
        if openAfterCreation {
            if let openCreatedSpace { openCreatedSpace(created) } else { store.launch(created) }
        }
    }
}
