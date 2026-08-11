import SwiftUI

struct RelayIntakeView: View {
    @Binding var draft: RelayIntakeDraft
    let repositoryValidationMessage: String?
    let isSubmitting: Bool
    let chooseRepository: () -> Void
    let cancel: () -> Void
    let start: (RelayIntakeDraft) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Relay")
                        .font(.title2.bold())
                    Text(
                        "Define one outcome and the evidence required to accept it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Task") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier(
                            RelayAccessibilityIdentifier.intakeTitle
                        )

                    HStack {
                        TextField(
                            "Repository",
                            text: $draft.repositoryPath
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(
                            RelayAccessibilityIdentifier.intakeRepository
                        )

                        Button("Choose…", action: chooseRepository)
                            .accessibilityIdentifier(
                                RelayAccessibilityIdentifier
                                    .intakeChooseRepository
                            )
                    }

                    if let repositoryValidationMessage {
                        Label(
                            repositoryValidationMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    TextField(
                        "Objective",
                        text: $draft.objective,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .accessibilityHint(
                        Text("Describe the outcome, not the implementation steps")
                    )
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.intakeObjective
                    )

                    TextField(
                        "Acceptance criteria, one per line",
                        text: $draft.acceptanceCriteriaText,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.intakeCriteria
                    )
                }

                Section("Production Change Relay") {
                    LabeledContent("Stages") {
                        Text(RelayIntakePresentation.stages)
                    }
                    LabeledContent("Workspace") {
                        Text("Isolated Git worktree")
                    }
                    LabeledContent("Approval") {
                        Text("Required for destructive or external actions")
                    }
                    LabeledContent("Result") {
                        Text(RelayIntakePresentation.result)
                    }
                }

                if !draft.validationIssues.isEmpty {
                    Section("Required Before Starting") {
                        ForEach(
                            Array(draft.validationIssues.enumerated()),
                            id: \.offset
                        ) { _, issue in
                            Label(issue.message, systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(
                    RelayIntakePresentation.schedulingDisclosure
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", role: .cancel, action: cancel)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.intakeCancel
                    )

                Button("Start Relay") {
                    start(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !draft.canStart
                        || repositoryValidationMessage != nil
                        || isSubmitting
                )
                .accessibilityHint(
                    Text(
                        startAccessibilityHint
                    )
                )
                .accessibilityIdentifier(
                    RelayAccessibilityIdentifier.intakeStart
                )
            }
            .padding(20)
        }
        .frame(width: 680, height: 660)
        .accessibilityIdentifier(RelayAccessibilityIdentifier.intake)
    }

    private var startAccessibilityHint: String {
        if let issue = draft.validationIssues.first {
            return issue.message
        }
        if let repositoryValidationMessage {
            return repositoryValidationMessage
        }
        if isSubmitting {
            return String(localized: "Saving the relay before scheduling it")
        }
        return String(localized: "Save and schedule this relay")
    }
}
