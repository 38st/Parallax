import Foundation

/// Pure collision analysis over filesystem evidence captured by migration inventory.
///
/// This type never resolves or probes a path. Callers must supply canonical paths and
/// stable identities obtained by the coordinator's filesystem authority.
enum LibraryMigrationInventoryAnalysis {
  struct ApplicationRoot: Sendable {
    let applicationOccurrence: Int
    let canonicalURL: URL
  }

  struct ExistingSource: Sendable {
    let profileOccurrence: Int
    let sourceURL: URL
    let canonicalSourceURL: URL
    let sourceIdentity: FileSystemObjectIdentity?
  }

  static func collisionBlockers(
    applicationRoots: [ApplicationRoot],
    existingSources: [ExistingSource]
  ) -> [LibraryMigrationBlocker] {
    var blockers: [LibraryMigrationBlocker] = []

    let applicationRootGroups = Dictionary(grouping: applicationRoots) {
      compatibilityKey($0.canonicalURL.path)
    }
    for (key, group) in applicationRootGroups
    where Set(group.map(\.applicationOccurrence)).count > 1 {
      blockers.append(
        LibraryMigrationBlocker(
          kind: .sharedApplicationRoot,
          recordOccurrences: group.map(\.applicationOccurrence).sorted(),
          canonicalPaths: [key]
        )
      )
    }

    let exactGroups = Dictionary(grouping: existingSources) {
      $0.canonicalSourceURL.standardizedFileURL.path
    }
    for (path, group) in exactGroups where group.count > 1 {
      blockers.append(
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: group.map(\.profileOccurrence).sorted(),
          canonicalPaths: [path]
        )
      )
    }

    let identityGroups = Dictionary(
      grouping: existingSources.compactMap {
        source in source.sourceIdentity.map { ($0, source) }
      }, by: \.0)
    for (_, identified) in identityGroups where identified.count > 1 {
      let group = identified.map(\.1)
      blockers.append(
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: group.map(\.profileOccurrence).sorted(),
          canonicalPaths: Set(group.map(\.canonicalSourceURL.path)).sorted()
        )
      )
    }

    let compatibilityGroups = Dictionary(grouping: existingSources) {
      compatibilityKey($0.sourceURL.standardizedFileURL.path)
    }
    for (_, group) in compatibilityGroups where group.count > 1 {
      let exactPaths = Set(group.map { $0.sourceURL.standardizedFileURL.path })
      if exactPaths.count > 1 {
        blockers.append(
          LibraryMigrationBlocker(
            kind: .caseInsensitiveSourceCollision,
            recordOccurrences: group.map(\.profileOccurrence).sorted(),
            canonicalPaths: exactPaths.sorted()
          )
        )
      }
    }

    for leftIndex in existingSources.indices {
      for rightIndex in existingSources.indices where rightIndex > leftIndex {
        let left = existingSources[leftIndex]
        let right = existingSources[rightIndex]
        if contains(left.canonicalSourceURL, within: right.canonicalSourceURL)
          || contains(right.canonicalSourceURL, within: left.canonicalSourceURL)
        {
          blockers.append(
            LibraryMigrationBlocker(
              kind: .canonicalSourceCollision,
              recordOccurrences: [
                left.profileOccurrence,
                right.profileOccurrence,
              ].sorted(),
              canonicalPaths: [
                left.canonicalSourceURL.path,
                right.canonicalSourceURL.path,
              ].sorted()
            )
          )
        }
      }
    }

    return blockers
  }

  static func orderedUniqueBlockers(
    _ blockers: [LibraryMigrationBlocker]
  ) -> [LibraryMigrationBlocker] {
    Array(Set(blockers)).sorted {
      if $0.kind.rawValue == $1.kind.rawValue {
        return $0.recordOccurrences.lexicographicallyPrecedes(
          $1.recordOccurrences
        )
      }
      return $0.kind.rawValue < $1.kind.rawValue
    }
  }

  private static func compatibilityKey(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased()
  }

  private static func contains(_ target: URL, within root: URL) -> Bool {
    let rootComponents = root.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard targetComponents.count >= rootComponents.count else { return false }
    return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
  }
}
