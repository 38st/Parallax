import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileTemplateEditor: View {
    let settings: AppSettings
    @Binding var template: ProfileTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsTextField(
                "Template name", text: field(\.name), settings: settings, validatesName: true
            )
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Arguments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsTextEditor(text: field(\.argumentsText), settings: settings)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Arguments"))
                    .accessibilityIdentifier(
                        "settings.template.arguments.\(template.id.uuidString.lowercased())"
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Environment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsTextEditor(text: field(\.environmentText), settings: settings)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Environment"))
                    .accessibilityIdentifier(
                        "settings.template.environment.\(template.id.uuidString.lowercased())"
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsTextEditor(text: field(\.notes), settings: settings)
                    .frame(minHeight: 50)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Notes"))
                    .accessibilityIdentifier(
                        "settings.template.notes.\(template.id.uuidString.lowercased())"
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private func field(_ keyPath: WritableKeyPath<ProfileTemplate, String>) -> Binding<String> {
        Binding(
            get: { template[keyPath: keyPath] },
            set: { value in
                var updated = template
                updated[keyPath: keyPath] = value
                template = updated
            }
        )
    }

}

struct SettingsIssuePresentation {
    @MainActor
    static func binding(settings: AppSettings, isExporting: @escaping () -> Bool) -> Binding<Bool> {
        Binding(
            get: { !settings.persistenceIssues.isEmpty && !isExporting() },
            set: { _ in }
        )
    }
}

struct SettingsTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let validatesName: Bool
    @State private var draft: SettingsTextDraft
    @FocusState private var isFocused: Bool

    init(_ title: LocalizedStringKey, text: Binding<String>, settings: AppSettings, validatesName: Bool = false) {
        self.title = title
        _text = text
        self.validatesName = validatesName
        _draft = State(initialValue: SettingsTextDraft(
            settings: settings, read: { text.wrappedValue }, write: { text.wrappedValue = $0 },
            normalize: { validatesName ? DisplayNameValidator.normalized($0) : $0 }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: Binding(get: { draft.value }, set: { draft.edit($0) }))
                .focused($isFocused)
                .onSubmit { draft.commit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { draft.commit() }
                }
                .onChange(of: text) { _, _ in draft.synchronize() }
                .onDisappear { draft.commit() }
            if validatesName, let message = DisplayNameValidator.validate(draft.value).issue?.message(for: .template) {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.template.name.validation-error")
            }
        }
    }
}

private struct SettingsTextEditor: View {
    @Binding var text: String
    @State private var draft: SettingsTextDraft
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, settings: AppSettings) {
        _text = text
        _draft = State(initialValue: SettingsTextDraft(
            settings: settings, read: { text.wrappedValue }, write: { text.wrappedValue = $0 }
        ))
    }

    var body: some View {
        TextEditor(text: Binding(get: { draft.value }, set: { draft.edit($0) }))
            .focused($isFocused)
            .onSubmit { draft.commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft.commit() }
            }
            .onChange(of: text) { _, _ in draft.synchronize() }
            .onDisappear { draft.commit() }
    }
}

struct SettingsUndoResetShortcut: NSViewRepresentable {
    let settings: AppSettings

    func makeNSView(context: Context) -> ShortcutView { ShortcutView(settings: settings) }
    func updateNSView(_ nsView: ShortcutView, context: Context) {}

    @MainActor
    static func perform(settings: AppSettings, firstResponder: NSResponder?) -> Bool {
        guard !(firstResponder is NSTextView), !(firstResponder is NSTextField),
              settings.canUndoProfileTemplateReset else { return false }
        return settings.undoProfileTemplateReset()
    }

    final class ShortcutView: NSView {
        private let settings: AppSettings
        private var monitor: Any?

        init(settings: AppSettings) {
            self.settings = settings
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isKeyWindow,
                          event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                          event.charactersIgnoringModifiers == "z"
                    else { return false }
                    return SettingsUndoResetShortcut.perform(settings: self.settings, firstResponder: window.firstResponder)
                }
                return consumed ? nil : event
            }
        }
    }
}
