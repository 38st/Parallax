import Foundation

struct ApplicationRemovalProfileActivity: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case inactive
        case active
        case ambiguous
    }

    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let state: State
}

struct ApplicationRemovalActivitySnapshot: Equatable, Sendable {
    let profiles: [ApplicationRemovalProfileActivity]

    init(profiles: [ApplicationRemovalProfileActivity]) {
        self.profiles = profiles.sorted {
            if $0.profileStorageID != $1.profileStorageID {
                return $0.profileStorageID.uuidString
                    < $1.profileStorageID.uuidString
            }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
    }
}
