import SwiftUI

/// Present the same operation state inside modal panels as on the app page.
/// A sheet must never hide a failed open behind a stale progress message.
struct SpaceOperationStatusView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        if let message = store.errorMessage ?? store.conversationSwitchMessage {
            Label(message, systemImage: store.errorMessage != nil || store.conversationSwitchFailed
                ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(store.errorMessage != nil || store.conversationSwitchFailed ? Color.red : Color.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("conversation-library.progress")
        }
    }
}
