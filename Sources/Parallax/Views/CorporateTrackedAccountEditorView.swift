import SwiftUI

struct CorporateTrackedAccountEditorContent: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CorporateUsageStore
    let context: CorporateAccountEditorContext

    @State private var provider: AIProvider
    @State private var label: String
    @State private var email: String
    @State private var planName: String
    @State private var usagePercent: Int
    @State private var resetsAt: Date

    init(store: CorporateUsageStore, context: CorporateAccountEditorContext) {
        self.store = store
        self.context = context
        let draft = TrackedAccountEditorDraft(account: context.account)
        _provider = State(initialValue: draft.provider)
        _label = State(initialValue: draft.label)
        _email = State(initialValue: draft.email)
        _planName = State(initialValue: draft.planName)
        _usagePercent = State(initialValue: draft.usagePercent)
        _resetsAt = State(initialValue: draft.resetsAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.account == nil ? "Add account" : "Update account")
                    .font(.title2.weight(.semibold))
                Text("Keep a local record of this subscription's current usage.")
                    .foregroundStyle(.secondary)
            }
            .padding(22)

            Divider()

            Form {
                Section("Account") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .disabled(context.account != nil)
                    TextField("Label", text: $label)
                    TextField("Email", text: $email)
                    TextField("Plan", text: $planName)
                }

                Section("Fallback usage") {
                    Stepper(value: $usagePercent, in: 0...100, step: 5) {
                        HStack {
                            Text("Used")
                            Spacer()
                            Text("\(usagePercent)%")
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                    ProgressView(value: Double(usagePercent), total: 100)
                        .tint(usagePercent >= 85 ? .orange : .accentColor)
                    DatePicker(
                        "Usage resets",
                        selection: $resetsAt,
                        displayedComponents: [.date]
                    )
                }

                Section {
                    Label(
                        "Provider refreshes replace this fallback percentage when live usage is available.",
                        systemImage: "lock.macwindow"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save account") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 520, height: 590)
    }

    private func save() {
        var draft = TrackedAccountEditorDraft(account: context.account)
        draft.provider = provider
        draft.label = label
        draft.email = email
        draft.planName = planName
        draft.usagePercent = usagePercent
        draft.resetsAt = resetsAt
        if context.account != nil {
            guard let current = store.trackedAccounts.first(where: {
                $0.id == context.id
            }) else {
                dismiss()
                return
            }
            store.saveTrackedAccount(draft.merging(into: current))
        } else {
            store.saveTrackedAccount(draft.account(id: context.id))
        }
        dismiss()
    }
}
