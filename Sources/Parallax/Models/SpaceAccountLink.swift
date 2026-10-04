import Foundation

/// Local intent and user evidence only. Neither a CLI login nor a history
/// namespace proves the account currently signed in to the Desktop app.
struct SpaceAccountLink: Codable, Hashable, Sendable {
    var expectedEmail: String {
        didSet {
            if oldValue != expectedEmail { desktopConfirmation = nil }
        }
    }
    var trackingAccountID: UUID?
    var desktopConfirmation: DesktopIdentityConfirmation?

    init(expectedEmail: String = "", trackingAccountID: UUID? = nil,
         desktopConfirmation: DesktopIdentityConfirmation? = nil) {
        self.expectedEmail = expectedEmail
        self.trackingAccountID = trackingAccountID
        self.desktopConfirmation = desktopConfirmation
    }

    var expectedIdentity: String? {
        let value = expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var isEmpty: Bool { expectedIdentity == nil && trackingAccountID == nil && desktopConfirmation == nil }

    var summary: String {
        guard let expectedIdentity else { return String(localized: "Desktop account unknown") }
        return String(localized: "Expected account: \(expectedIdentity)")
    }

    mutating func confirmDesktopLogin(at date: Date) {
        guard let expectedIdentity else { return }
        desktopConfirmation = DesktopIdentityConfirmation(email: expectedIdentity, confirmedAt: date)
    }
}

struct DesktopIdentityConfirmation: Codable, Hashable, Sendable {
    let email: String
    let confirmedAt: Date
}
