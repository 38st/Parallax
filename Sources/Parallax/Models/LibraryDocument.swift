import Foundation

struct LibraryDocument: Codable {
    static let currentVersion = 1

    var version: Int
    var applications: [ManagedApplication]

    init(version: Int = Self.currentVersion, applications: [ManagedApplication]) {
        self.version = version
        self.applications = applications
    }
}
