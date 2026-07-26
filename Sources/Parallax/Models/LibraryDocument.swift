import Foundation

struct LibraryDocument: Codable {
    static let currentVersion = 2

    let version: Int
    var applications: [ManagedApplication]

    init(applications: [ManagedApplication]) {
        version = Self.currentVersion
        self.applications = applications
    }
}
