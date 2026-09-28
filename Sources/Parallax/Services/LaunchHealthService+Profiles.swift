import Foundation

extension LaunchHealthService {
    func inspectProfiles(
        _ inputs: [ProfileHealthInput], refreshActivity: Bool = true
    ) -> [ProfileHealthReport] {
        let verified = !refreshActivity || activityProvider.refreshForHealthInspection()
        var reports = inputs.map { inspectProfile($0, activityVerified: verified) }
        LaunchHealthCollisionPolicy.addCollisions(to: &reports)
        annotateClaudeConfigCollisions(in: &reports)
        return reports
    }

    private func annotateClaudeConfigCollisions(in reports: inout [ProfileHealthReport]) {
        var claudeReports = reports.map { report in
            var claudeReport = report
            claudeReport.paths = report.paths.filter {
                $0.role == .managedClaudeConfig || $0.role == .externalClaudeConfig
            }
            claudeReport.issues = []
            return claudeReport
        }
        guard claudeReports.filter({ !$0.paths.isEmpty }).count > 1 else { return }
        // Reuse the collision policy so aliases and volume case rules match
        // the launch blocker. Only Claude-to-Claude collisions get this remedy.
        LaunchHealthCollisionPolicy.addCollisions(to: &claudeReports)
        for index in reports.indices {
            for collision in claudeReports[index].issues {
                for issueIndex in reports[index].issues.indices {
                    let issue = reports[index].issues[issueIndex]
                    if issue.code == collision.code && issue.path == collision.path {
                        reports[index].issues[issueIndex].claudeConfigCollisionProfileIDs
                            .formUnion(collision.relatedProfileIDs)
                    }
                }
            }
        }
    }

    private func inspectProfile(
        _ input: ProfileHealthInput, activityVerified: Bool
    ) -> ProfileHealthReport {
        let active = activityProvider.isStorageActive(
            applicationStorageID: input.applicationStorageID,
            profileStorageID: input.profileStorageID
        )
        let reserved =
            !activityVerified
            || activityProvider.isStorageReserved(
                applicationStorageID: input.applicationStorageID,
                profileStorageID: input.profileStorageID)
        var issues: [LaunchHealthIssue] =
            reserved
            ? [LaunchHealthIssue(.storageReservedForDataOperation)]
            : (active ? [LaunchHealthIssue(.profileActive)] : [])
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
            case .managedClaudeConfig:
                if let managed {
                    append(
                        inspectPath(
                            managed.claudeConfig.url,
                            role: isolation.role
                        ),
                        to: &paths,
                        issues: &issues
                    )
                }
            case .managedPresetFolder(let folder):
                if let managed {
                    let target = folder.managedPath(in: managed)
                    do {
                        _ = try pathResolver.revalidateForMutation(target)
                        append(inspectPath(target.url, role: isolation.role),
                               to: &paths, issues: &issues)
                    } catch {
                        issues.append(LaunchHealthIssue(.managedPathInvalid, path: target.url.path))
                    }
                }
            case .external(let configured):
                do {
                    let path = try pathResolver.resolveExternalPath(configured)
                    let role: ProfileHealthPathRole =
                        isolation.role == .externalClaudeConfig
                        && path.requestedURL.path == managed?.claudeConfig.url.standardizedFileURL.path
                        ? .managedClaudeConfig : isolation.role
                    append(
                        inspectPath(path.url, role: role),
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
}
