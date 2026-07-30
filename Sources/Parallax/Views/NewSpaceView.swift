import SwiftUI

struct NewSpaceView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var store: LibraryStore
    let application: ManagedApplication

    @State private var draft: NewSpaceDraft
    @State private var creationError: String?

    private let choices: [NewSpaceChoice]

    init(
        store: LibraryStore,
        application: ManagedApplication,
        preferredTemplateID: ProfileTemplate.ID? = nil
    ) {
        self.store = store
        self.application = application
        let choices = NewSpaceChoice.available(
            templates: store.profileTemplates
        )
        self.choices = choices
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
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier(
                        UIAutomationContract.newSpaceName
                    )

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
                applicationID: application.id
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
            store.launch(created)
        }
    }
}
