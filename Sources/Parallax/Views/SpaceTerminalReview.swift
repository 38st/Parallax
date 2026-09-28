import SwiftUI

@MainActor
@Observable
final class SpaceTerminalReviewCoordinator {
    private(set) var review: ImportedLaunchReview?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request(_ review: ImportedLaunchReview) async -> Bool {
        guard continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.review = review
        }
    }

    func finish(approved: Bool) {
        let continuation = continuation
        self.continuation = nil
        review = nil
        continuation?.resume(returning: approved)
    }
}

struct SpaceTerminalReviewPresentation: ViewModifier {
    let coordinator: SpaceTerminalReviewCoordinator

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { coordinator.review != nil },
            set: { if !$0 { coordinator.finish(approved: false) } }
        )) {
            if let review = coordinator.review {
                ImportedLaunchReviewView(review: review,
                    onCancel: { coordinator.finish(approved: false) },
                    onApprove: { coordinator.finish(approved: true) })
            }
        }
        .onDisappear { coordinator.finish(approved: false) }
    }
}
