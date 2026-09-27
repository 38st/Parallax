import Foundation

extension LaunchHealthService {
    func inspectPath(
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

    func append(
        _ inspected: InspectedPath,
        to paths: inout [ProfileHealthPathReport],
        issues: inout [LaunchHealthIssue]
    ) {
        paths.append(inspected.report)
        if let issue = inspected.issue {
            issues.append(issue)
        }
    }

    func applicationReport(
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

    func isValidExecutableName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    func isExecutable(_ attributes: FileSystemItemAttributes) -> Bool {
        guard let permissions = attributes.posixPermissions else {
            return false
        }
        return permissions & 0o111 != 0
    }
}
