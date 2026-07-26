import Darwin
import Foundation

protocol PathWriteAccessChecking: Sendable {
    func isWritable(at url: URL) -> Bool
}

struct POSIXPathWriteAccessChecker: PathWriteAccessChecking {
    func isWritable(at url: URL) -> Bool {
        access(url.path, W_OK) == 0
    }
}

/// Produces read-only launch and profile-storage health reports.
///
/// Inputs intentionally contain already-classified isolation paths. The launch
/// configuration compiler can supply those paths later without duplicating
/// argument or environment parsing in health checks.
struct LaunchHealthService: Sendable {
    private struct InspectedPath {
        let report: ProfileHealthPathReport
        let issue: LaunchHealthIssue?
    }

    private struct CollisionCandidate {
        let reportIndex: Int
        let profileID: UUID
        let path: ProfileHealthPathReport
    }

    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    private let writeAccess: any PathWriteAccessChecking
    private let activityProvider: any ProfileHealthActivityProviding

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        writeAccess: any PathWriteAccessChecking = POSIXPathWriteAccessChecker(),
        activityProvider: any ProfileHealthActivityProviding =
            NoProfileHealthActivityProvider()
    ) {
        self.fileSystem = fileSystem
        pathResolver = ManagedPathResolver(fileSystem: fileSystem)
        self.writeAccess = writeAccess
        self.activityProvider = activityProvider
    }

    func inspectApplication(
        _ input: ApplicationHealthInput
    ) -> ApplicationHealthReport {
        let requested = input.applicationURL
        var issues: [LaunchHealthIssue] = []
        var canonicalURL: URL?
        var bundleIdentifier: String?
        var executableURL: URL?

        guard
            requested.isFileURL,
            requested.path.hasPrefix("/")
        else {
            return applicationReport(
                input,
                canonicalURL: nil,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: [
                    LaunchHealthIssue(
                        .applicationPathNotAbsolute,
                        path: requested.path
                    )
                ]
            )
        }
        guard requested.pathExtension.lowercased() == "app" else {
            return applicationReport(
                input,
                canonicalURL: nil,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: [
                    LaunchHealthIssue(
                        .applicationNotAppBundle,
                        path: requested.path
                    )
                ]
            )
        }
        guard fileSystem.fileExists(at: requested) else {
            return applicationReport(
                input,
                canonicalURL: nil,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: [
                    LaunchHealthIssue(.applicationMissing, path: requested.path)
                ]
            )
        }

        do {
            let attributes = try fileSystem.attributesOfItem(at: requested)
            guard attributes.kind == .directory else {
                return applicationReport(
                    input,
                    canonicalURL: nil,
                    bundleIdentifier: nil,
                    executableURL: nil,
                    issues: [
                        LaunchHealthIssue(
                            .applicationNotDirectory,
                            path: requested.path
                        )
                    ]
                )
            }
            canonicalURL = try fileSystem.canonicalURL(for: requested)
            guard
                let canonicalURL,
                canonicalURL.pathExtension.lowercased() == "app",
                try fileSystem.attributesOfItem(at: canonicalURL).kind
                    == .directory
            else {
                issues.append(
                    LaunchHealthIssue(
                        .applicationNotAppBundle,
                        path: canonicalURL?.path ?? requested.path
                    )
                )
                return applicationReport(
                    input,
                    canonicalURL: canonicalURL,
                    bundleIdentifier: nil,
                    executableURL: nil,
                    issues: issues
                )
            }
        } catch {
            issues.append(
                LaunchHealthIssue(
                    .applicationCanonicalizationFailed,
                    path: requested.path
                )
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: issues
            )
        }

        guard let canonicalURL else {
            return applicationReport(
                input,
                canonicalURL: nil,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: issues
            )
        }
        let infoPlistURL = canonicalURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard fileSystem.fileExists(at: infoPlistURL) else {
            issues.append(
                LaunchHealthIssue(.missingInfoPlist, path: infoPlistURL.path)
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: issues
            )
        }

        let plist: [String: Any]
        do {
            guard
                try fileSystem.attributesOfItem(at: infoPlistURL).kind
                    == .regularFile,
                let object = try PropertyListSerialization.propertyList(
                    from: fileSystem.readData(at: infoPlistURL),
                    options: [],
                    format: nil
                ) as? [String: Any]
            else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            plist = object
        } catch {
            issues.append(
                LaunchHealthIssue(.invalidInfoPlist, path: infoPlistURL.path)
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: nil,
                executableURL: nil,
                issues: issues
            )
        }

        if let identifier = plist["CFBundleIdentifier"] as? String,
           !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            bundleIdentifier = identifier
            if let expected = input.expectedBundleIdentifier,
               expected != identifier
            {
                issues.append(
                    LaunchHealthIssue(
                        .bundleIdentifierMismatch,
                        path: canonicalURL.path
                    )
                )
            }
        } else {
            issues.append(
                LaunchHealthIssue(
                    .missingBundleIdentifier,
                    path: infoPlistURL.path
                )
            )
        }

        guard let executableName = plist["CFBundleExecutable"] as? String else {
            issues.append(
                LaunchHealthIssue(
                    .missingExecutableName,
                    path: infoPlistURL.path
                )
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: bundleIdentifier,
                executableURL: nil,
                issues: issues
            )
        }
        guard isValidExecutableName(executableName) else {
            issues.append(
                LaunchHealthIssue(
                    .invalidExecutableName,
                    path: executableName
                )
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: bundleIdentifier,
                executableURL: nil,
                issues: issues
            )
        }

        let candidateExecutable = canonicalURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        executableURL = candidateExecutable
        guard fileSystem.fileExists(at: candidateExecutable) else {
            issues.append(
                LaunchHealthIssue(
                    .executableMissing,
                    path: candidateExecutable.path
                )
            )
            return applicationReport(
                input,
                canonicalURL: canonicalURL,
                bundleIdentifier: bundleIdentifier,
                executableURL: executableURL,
                issues: issues
            )
        }
        do {
            let attributes = try fileSystem.attributesOfItem(
                at: candidateExecutable
            )
            if attributes.kind != .regularFile {
                issues.append(
                    LaunchHealthIssue(
                        .executableNotRegularFile,
                        path: candidateExecutable.path
                    )
                )
            } else if !isExecutable(attributes) {
                issues.append(
                    LaunchHealthIssue(
                        .executableNotRunnable,
                        path: candidateExecutable.path
                    )
                )
            }
        } catch {
            issues.append(
                LaunchHealthIssue(
                    .executableMissing,
                    path: candidateExecutable.path
                )
            )
        }

        return applicationReport(
            input,
            canonicalURL: canonicalURL,
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL,
            issues: issues
        )
    }

    func inspectProfiles(
        _ inputs: [ProfileHealthInput]
    ) -> [ProfileHealthReport] {
        var reports = inputs.map(inspectProfile)
        addCollisions(to: &reports)
        return reports
    }

    private func inspectProfile(
        _ input: ProfileHealthInput
    ) -> ProfileHealthReport {
        let active = activityProvider.isStorageActive(
            applicationStorageID: input.applicationStorageID,
            profileStorageID: input.profileStorageID
        )
        var issues: [LaunchHealthIssue] = active
            ? [LaunchHealthIssue(.profileActive)]
            : []
        var paths: [ProfileHealthPathReport] = []

        let managed: ResolvedProfilePaths?
        do {
            managed = try pathResolver.resolve(
                configuredBaseRoot: input.configuredBaseRoot,
                applicationStorageID: input.applicationStorageID,
                profileStorageID: input.profileStorageID
            )
        } catch {
            issues.append(
                LaunchHealthIssue(
                    .managedPathInvalid,
                    path: input.configuredBaseRoot
                )
            )
            managed = nil
        }

        if let managed {
            append(
                inspectPath(
                    managed.profileRoot.url,
                    role: .managedProfileRoot
                ),
                to: &paths,
                issues: &issues
            )
        }
        for isolation in input.isolationPaths {
            switch isolation.source {
            case .managedUserData:
                if let managed {
                    append(
                        inspectPath(
                            managed.userData.url,
                            role: isolation.role
                        ),
                        to: &paths,
                        issues: &issues
                    )
                }
            case .managedCodexHome:
                if let managed {
                    append(
                        inspectPath(
                            managed.codexHome.url,
                            role: isolation.role
                        ),
                        to: &paths,
                        issues: &issues
                    )
                }
            case .external(let configured):
                do {
                    let path = try pathResolver.resolveExternalPath(configured)
                    append(
                        inspectPath(path.url, role: isolation.role),
                        to: &paths,
                        issues: &issues
                    )
                } catch {
                    issues.append(
                        LaunchHealthIssue(
                            .externalPathInvalid,
                            path: configured
                        )
                    )
                }
            }
        }

        return ProfileHealthReport(
            applicationID: input.applicationID,
            profileID: input.profileID,
            applicationStorageID: input.applicationStorageID,
            profileStorageID: input.profileStorageID,
            isActive: active,
            paths: paths,
            issues: issues
        )
    }

    private func inspectPath(
        _ requested: URL,
        role: ProfileHealthPathRole
    ) -> InspectedPath {
        if fileSystem.fileExists(at: requested) {
            do {
                let canonical = try fileSystem.canonicalURL(for: requested)
                let attributes = try fileSystem.attributesOfItem(at: canonical)
                guard attributes.kind == .directory else {
                    return InspectedPath(
                        report: ProfileHealthPathReport(
                            role: role,
                            requestedURL: requested,
                            canonicalURL: canonical,
                            state: .invalid,
                            identity: attributes.identity,
                            writableURL: nil
                        ),
                        issue: LaunchHealthIssue(
                            .targetNotDirectory,
                            path: requested.path
                        )
                    )
                }
                let writable = writeAccess.isWritable(at: canonical)
                return InspectedPath(
                    report: ProfileHealthPathReport(
                        role: role,
                        requestedURL: requested,
                        canonicalURL: canonical,
                        state: writable ? .existingDirectory : .invalid,
                        identity: attributes.identity,
                        writableURL: writable ? canonical : nil
                    ),
                    issue: writable
                        ? nil
                        : LaunchHealthIssue(
                            .targetNotWritable,
                            path: canonical.path
                        )
                )
            } catch {
                return InspectedPath(
                    report: ProfileHealthPathReport(
                        role: role,
                        requestedURL: requested,
                        canonicalURL: nil,
                        state: .invalid,
                        identity: nil,
                        writableURL: nil
                    ),
                    issue: LaunchHealthIssue(
                        .targetNotDirectory,
                        path: requested.path
                    )
                )
            }
        }

        do {
            let missing = try nearestExistingAncestor(for: requested)
            let writable = writeAccess.isWritable(at: missing.ancestor)
            return InspectedPath(
                report: ProfileHealthPathReport(
                    role: role,
                    requestedURL: requested,
                    canonicalURL: missing.canonicalTarget,
                    state: writable ? .missingCreatable : .missingUnwritable,
                    identity: nil,
                    writableURL: writable ? missing.ancestor : nil
                ),
                issue: writable
                    ? nil
                    : LaunchHealthIssue(
                        .noWritableAncestor,
                        path: missing.ancestor.path
                    )
            )
        } catch {
            return InspectedPath(
                report: ProfileHealthPathReport(
                    role: role,
                    requestedURL: requested,
                    canonicalURL: nil,
                    state: .invalid,
                    identity: nil,
                    writableURL: nil
                ),
                issue: LaunchHealthIssue(
                    .noWritableAncestor,
                    path: requested.path
                )
            )
        }
    }

    private func nearestExistingAncestor(
        for requested: URL
    ) throws -> (ancestor: URL, canonicalTarget: URL) {
        var cursor = requested.standardizedFileURL
        var missingComponents: [String] = []
        while !fileSystem.fileExists(at: cursor) {
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            missingComponents.insert(cursor.lastPathComponent, at: 0)
            cursor = parent
        }
        let canonicalAncestor = try fileSystem.canonicalURL(for: cursor)
        guard
            try fileSystem.attributesOfItem(at: canonicalAncestor).kind
                == .directory
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let canonicalTarget = missingComponents.reduce(canonicalAncestor) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return (canonicalAncestor, canonicalTarget)
    }

    private func append(
        _ inspected: InspectedPath,
        to paths: inout [ProfileHealthPathReport],
        issues: inout [LaunchHealthIssue]
    ) {
        paths.append(inspected.report)
        if let issue = inspected.issue {
            issues.append(issue)
        }
    }

    private func addCollisions(
        to reports: inout [ProfileHealthReport]
    ) {
        let candidates = reports.enumerated().flatMap { index, report in
            report.paths.map {
                CollisionCandidate(
                    reportIndex: index,
                    profileID: report.profileID,
                    path: $0
                )
            }
        }
        let byCanonicalPath = Dictionary(
            grouping: candidates.compactMap { candidate in
                candidate.path.canonicalURL.map {
                    ($0.standardizedFileURL.path, candidate)
                }
            },
            by: \.0
        )
        for (path, grouped) in byCanonicalPath {
            let members = grouped.map(\.1)
            addCollision(
                members,
                code: .canonicalPathCollision,
                path: path,
                reports: &reports
            )
        }

        let byIdentity = Dictionary(
            grouping: candidates.compactMap { candidate in
                candidate.path.identity.map { ($0, candidate) }
            },
            by: \.0
        )
        for (_, grouped) in byIdentity {
            let members = grouped.map(\.1)
            let canonicalPaths = Set(
                members.compactMap {
                    $0.path.canonicalURL?.standardizedFileURL.path
                }
            )
            guard canonicalPaths.count > 1 else { continue }
            addCollision(
                members,
                code: .fileIdentityCollision,
                path: nil,
                reports: &reports
            )
        }
    }

    private func addCollision(
        _ candidates: [CollisionCandidate],
        code: LaunchHealthIssueCode,
        path: String?,
        reports: inout [ProfileHealthReport]
    ) {
        let profileIDs = Set(candidates.map(\.profileID))
        guard profileIDs.count > 1 else { return }
        for candidate in candidates {
            let related = profileIDs.subtracting([candidate.profileID])
            guard !related.isEmpty else { continue }
            let issue = LaunchHealthIssue(
                code,
                path: path ?? candidate.path.canonicalURL?.path,
                relatedProfileIDs: related
            )
            if !reports[candidate.reportIndex].issues.contains(issue) {
                reports[candidate.reportIndex].issues.append(issue)
            }
        }
    }

    private func applicationReport(
        _ input: ApplicationHealthInput,
        canonicalURL: URL?,
        bundleIdentifier: String?,
        executableURL: URL?,
        issues: [LaunchHealthIssue]
    ) -> ApplicationHealthReport {
        ApplicationHealthReport(
            applicationID: input.applicationID,
            requestedApplicationURL: input.applicationURL,
            canonicalApplicationURL: canonicalURL,
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL,
            issues: issues
        )
    }

    private func isValidExecutableName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    private func isExecutable(_ attributes: FileSystemItemAttributes) -> Bool {
        guard let permissions = attributes.posixPermissions else {
            return false
        }
        return permissions & 0o111 != 0
    }
}
