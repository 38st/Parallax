import Foundation

/// Produces read-only launch and profile-storage health reports.
///
/// Inputs intentionally contain already-classified isolation paths. The launch
/// configuration compiler can supply those paths later without duplicating
/// argument or environment parsing in health checks.
struct LaunchHealthService: Sendable {
    struct InspectedPath {
        let report: ProfileHealthPathReport
        let issue: LaunchHealthIssue?
    }

    let fileSystem: any FileSystem
    let pathResolver: ManagedPathResolver
    let writeAccess: any PathWriteAccessChecking
    let activityProvider: any ProfileHealthActivityProviding

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
            canonicalURL = try fileSystem.canonicalURL(for: requested)
            let attributes = try fileSystem.attributesOfItem(at: canonicalURL ?? requested)
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
}
