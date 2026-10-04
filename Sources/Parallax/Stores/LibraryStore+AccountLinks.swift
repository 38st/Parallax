import Foundation

extension LibraryStore {
    /// Metadata-only update with optimistic concurrency. Never changes paths,
    /// authentication, history membership, or imported launch approval.
    @discardableResult
    func saveAccountLink(_ link: SpaceAccountLink, applicationID: UUID, profileID: UUID,
                         expected: SpaceAccountLink?) -> Bool {
        guard canMutateLibrary() else { return false }
        guard let appIndex = applications.firstIndex(where: { $0.id == applicationID }),
              let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profileID }),
              applications[appIndex].profiles[profileIndex].accountLink == expected else {
            errorMessage = String(localized: "This account link changed. Close this panel and review the latest details.")
            return false
        }
        guard requireCommittedProfileDraft(application: applications[appIndex], profile: applications[appIndex].profiles[profileIndex]) else { return false }
        let savedLink: SpaceAccountLink? = link.isEmpty ? nil : link
        guard applications[appIndex].profiles[profileIndex].accountLink != savedLink else { return true }
        var candidate = applications
        candidate[appIndex].profiles[profileIndex].accountLink = savedLink
        return commit(candidate, selectedApplicationID: selectedApplicationID, selectedProfileID: selectedProfileID)
    }
}
