import Foundation

struct LaunchWarningListItem: Identifiable, Equatable {
    let id: Int
    let message: String

    static func rows(_ warnings: [String]) -> [Self] {
        warnings.enumerated().map { Self(id: $0.offset, message: $0.element) }
    }
}
