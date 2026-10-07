import AppKit
import SwiftUI

struct SpaceEditor: View {
    var model: AppModel
    var appID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Space
    @State private var error: String?

    init(model: AppModel, appID: UUID, space: Space) {
        self.model = model
        self.appID = appID
        _draft = State(initialValue: space)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Space").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name)
                TextField("Account email", text: $draft.email)
                TextField("Extra launch arguments", text: $draft.arguments)
                    .font(.body.monospaced())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra environment (KEY=VALUE per line)")
                    TextEditor(text: $draft.environment)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
                Toggle("Pass Parallax's environment through to the app", isOn: $draft.inheritEnvironment)
                LabeledContent("Data folder") {
                    HStack {
                        Text(draft.folder).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Show") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.folder)])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        do {
            _ = try LaunchText.words(draft.arguments)
        } catch {
            self.error = error.localizedDescription
            return
        }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.email = draft.email.trimmingCharacters(in: .whitespaces)
        model.updateSpace(draft, in: appID)
        dismiss()
    }
}
