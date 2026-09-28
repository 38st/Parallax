import SwiftUI

@MainActor
@Observable
final class SpaceLinkPromptQueue {
    final class Prompt: Identifiable {
        let id = UUID()
        let spaceID: UUID?
        let request: SpaceLinkRequest?
        let errorMessage: String?
        fileprivate let isOverflow: Bool
        fileprivate var wasPresented = false
        fileprivate var resolved = false

        fileprivate init(spaceID: UUID?, request: SpaceLinkRequest?, errorMessage: String?, isOverflow: Bool = false) {
            self.isOverflow = isOverflow
            self.spaceID = spaceID
            self.request = request
            self.errorMessage = errorMessage
        }
    }

    let capacity: Int
    private(set) var prompts: [Prompt] = []
    private var overflowPending = false

    init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
    }

    var current: Prompt? {
        let prompt = prompts.first
        prompt?.wasPresented = true
        return prompt
    }

    func receive(_ url: URL, load: (URL) throws -> SpaceLinkRequest) {
        let spaceID = try? SpaceLink.profileID(from: url)
        guard !prompts.contains(where: { $0.spaceID == spaceID && !$0.isOverflow }) else { return }
        guard prompts.count < capacity else {
            overflowPending = !prompts.contains(where: \.isOverflow)
            return
        }
        do {
            _ = try SpaceLink.profileID(from: url)
            prompts.append(Prompt(spaceID: spaceID, request: try load(url), errorMessage: nil))
        } catch {
            prompts.append(Prompt(spaceID: spaceID, request: nil, errorMessage: error.localizedDescription))
        }
    }

    func dismiss(_ prompt: Prompt) {
        guard prompts.first?.id == prompt.id else { return }
        prompts.removeFirst()
        if overflowPending {
            overflowPending = false
            if !prompts.contains(where: \.isOverflow) {
                prompts.append(Prompt(spaceID: nil, request: nil,
                    errorMessage: String(localized: "Too many space links are waiting. Additional links were ignored."), isOverflow: true))
            }
        }
    }

    func cancel(_ prompt: Prompt) {
        prompt.resolved = true
        dismiss(prompt)
    }

    func confirm(_ prompt: Prompt, perform: (SpaceLinkRequest) -> Void) {
        guard prompt.wasPresented, !prompt.resolved, let request = prompt.request else { return }
        prompt.resolved = true
        dismiss(prompt)
        // SwiftUI may dismiss the alert binding before invoking its action.
        // The action always owns the exact request that was displayed.
        perform(request)
    }
}

private struct SpaceLinkPresentation: ViewModifier {
    let store: LibraryStore
    @State private var queue = SpaceLinkPromptQueue()

    func body(content: Content) -> some View {
        let prompt = queue.current
        content
            .onOpenURL { url in
                queue.receive(url) { url in
                    store.reloadFromSharedRepository()
                    return try store.spaceLinkRequest(for: url)
                }
            }
            .alert(
                prompt?.request == nil ? String(localized: "Unable to Open Space Link") : String(localized: "Open Linked Space?"),
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { if !$0, let prompt { queue.dismiss(prompt) } }
                ),
                presenting: prompt
            ) { prompt in
                if prompt.request != nil {
                    Button("Cancel", role: .cancel) { queue.cancel(prompt) }
                        .keyboardShortcut(.defaultAction)
                    Button("Open") {
                        queue.confirm(prompt) { request in
                            store.reloadFromSharedRepository()
                            store.confirmSpaceLink(request)
                        }
                    }
                } else {
                    Button("OK", role: .cancel) { queue.cancel(prompt) }
                        .keyboardShortcut(.defaultAction)
                }
            } message: { prompt in
                Text(prompt.request?.message ?? prompt.errorMessage ?? SpaceLinkError.invalid.localizedDescription)
            }
    }
}

extension View {
    func spaceLinkPresentation(store: LibraryStore) -> some View {
        modifier(SpaceLinkPresentation(store: store))
    }
}
