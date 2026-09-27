import Foundation

extension LaunchHealthService {
    func inspectProfiles(
        _ inputs: [ProfileHealthInput], refreshActivity: Bool = true
    ) -> [ProfileHealthReport] {
        let verified = !refreshActivity || activityProvider.refreshForHealthInspection()
        var reports = inputs.map { inspectProfile($0, activityVerified: verified) }
        LaunchHealthCollisionPolicy.addCollisions(to: &reports)
        return reports
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
}
