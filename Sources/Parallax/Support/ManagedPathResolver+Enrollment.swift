import Foundation

extension ManagedPathResolver {
    func enroll(_ paths: ResolvedProfilePaths, applicationStorageID: UUID) throws {
        let context = paths.profileRoot.validationContext
        _ = try revalidateForMutation(paths.profileRoot)
        guard fileSystem.fileExists(at: context.canonicalBaseRootURL) else { return }
        try enrollmentStore?.enroll(applicationStorageID: applicationStorageID,
            configuredBaseRoot: context.configuredBaseRootURL, canonicalBaseRoot: context.canonicalBaseRootURL)
    }

    func applicationStorageID(for path: any ManagedMutationPath) -> UUID? {
        let root = path.validationContext.canonicalBaseRootURL.pathComponents
        let components = path.url.pathComponents
        guard components.starts(with: root) else { return nil }
        let relative = Array(components.dropFirst(root.count))
        guard relative.count >= 3, relative[0] == ".parallax",
            relative[1] == "Applications" || relative[1] == "Archives" else { return nil }
        return UUID(uuidString: relative[2])
    }
}
