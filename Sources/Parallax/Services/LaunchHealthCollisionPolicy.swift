import Foundation

enum LaunchHealthCollisionPolicy {
    private struct CollisionCandidate {
        let reportIndex: Int
        let profileID: UUID
        let path: ProfileHealthPathReport
    }

    static func addCollisions(
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

    private static func addCollision(
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
}
