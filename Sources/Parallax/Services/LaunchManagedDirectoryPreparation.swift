import Foundation

struct LaunchManagedDirectoryPreparer {
    let pathResolver: ManagedPathResolver

    func prepare(
        for isolation: LaunchIsolationAnalysis,
        managedPaths: ResolvedProfilePaths
    ) throws {
        var managedTargets: [any ManagedMutationPath] = []
        if isolation.userData?.isManaged == true {
            managedTargets.append(managedPaths.userData)
        }
        if isolation.codexHome?.isManaged == true {
            managedTargets.append(managedPaths.codexHome)
        }
        guard !managedTargets.isEmpty else { return }

        let context = managedPaths.profileRoot.validationContext
        let canonicalRoot = context.canonicalBaseRootURL
        let anchorComponents =
            context.identityAnchorURL.standardizedFileURL.pathComponents
        let rootComponents =
            canonicalRoot.standardizedFileURL.pathComponents
        guard
            rootComponents.count >= anchorComponents.count,
            Array(rootComponents.prefix(anchorComponents.count))
                == anchorComponents
        else {
            throw ManagedPathError(
                .outsideManagedRoot,
                path: canonicalRoot.path
            )
        }
        let missingRootComponents = Array(
            rootComponents.dropFirst(anchorComponents.count)
        )
        let secureFileSystem: SecureManagedFileSystem
        if missingRootComponents.isEmpty {
            secureFileSystem = try SecureManagedFileSystem(
                rootURL: canonicalRoot
            )
        } else {
            secureFileSystem = try SecureManagedFileSystem(
                anchorURL: context.identityAnchorURL,
                rootComponents: missingRootComponents,
                createIfMissing: true
            )
        }
        for target in managedTargets {
            try Task.checkCancellation()
            _ = try pathResolver.revalidateForMutation(target)
            let relative = try securePath(
                target.url,
                relativeTo: canonicalRoot
            )
            switch try secureFileSystem.itemState(at: relative) {
            case .missing:
                try secureFileSystem.createDirectory(at: relative)
            case .present(let identity):
                guard identity.kind == .directory else {
                    throw SecureManagedFileSystemError.unsupportedItem
                }
            }
            _ = try pathResolver.revalidateForMutation(target)
        }
    }

    private func securePath(
        _ url: URL,
        relativeTo root: URL
    ) throws -> SecureManagedPath {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard
            targetComponents.count > rootComponents.count,
            Array(targetComponents.prefix(rootComponents.count))
                == rootComponents
        else {
            throw ManagedPathError(.outsideManagedRoot, path: url.path)
        }
        return try SecureManagedPath(
            Array(targetComponents.dropFirst(rootComponents.count))
        )
    }
}
