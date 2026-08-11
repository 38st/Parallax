import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationInventoryAnalysisTests: XCTestCase {
  func testCollisionEvidencePreservesExactIdentityCompatibilityAndNesting() {
    let sharedIdentity = FileSystemObjectIdentity(volumeID: 7, fileID: 11)
    let sources = [
      source(7, configured: "/Configured/Exact-A", canonical: "/Canonical/Same"),
      source(2, configured: "/Configured/Exact-B", canonical: "/Canonical/Same"),
      source(
        9,
        configured: "/Configured/Identity-A",
        canonical: "/Canonical/Identity-A",
        identity: sharedIdentity
      ),
      source(
        4,
        configured: "/Configured/Identity-B",
        canonical: "/Canonical/Identity-B",
        identity: sharedIdentity
      ),
      source(6, configured: "/Configured/Case", canonical: "/Canonical/Case-A"),
      source(1, configured: "/Configured/case", canonical: "/Canonical/Case-B"),
      source(8, configured: "/Configured/Parent", canonical: "/Canonical/Parent"),
      source(
        3,
        configured: "/Configured/Child",
        canonical: "/Canonical/Parent/Child"
      ),
    ]

    let blockers = LibraryMigrationInventoryAnalysis.orderedUniqueBlockers(
      LibraryMigrationInventoryAnalysis.collisionBlockers(
        applicationRoots: [],
        existingSources: sources
      )
    )

    XCTAssertEqual(
      Set(blockers),
      Set([
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: [2, 7],
          canonicalPaths: ["/Canonical/Same"]
        ),
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: [2, 7],
          canonicalPaths: ["/Canonical/Same", "/Canonical/Same"]
        ),
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: [3, 8],
          canonicalPaths: ["/Canonical/Parent", "/Canonical/Parent/Child"]
        ),
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: [4, 9],
          canonicalPaths: ["/Canonical/Identity-A", "/Canonical/Identity-B"]
        ),
        LibraryMigrationBlocker(
          kind: .caseInsensitiveSourceCollision,
          recordOccurrences: [1, 6],
          canonicalPaths: ["/Configured/Case", "/Configured/case"]
        ),
      ])
    )
  }

  func testSharedApplicationRootsUseCompatibilityIdentityAndSortedOccurrences() {
    let roots = [
      applicationRoot(5, "/Managed/Caf\u{00E9}"),
      applicationRoot(1, "/Managed/CAFE\u{0301}"),
      applicationRoot(3, "/Managed/Distinct"),
    ]

    XCTAssertEqual(
      LibraryMigrationInventoryAnalysis.orderedUniqueBlockers(
        LibraryMigrationInventoryAnalysis.collisionBlockers(
          applicationRoots: roots,
          existingSources: []
        )
      ),
      [
        LibraryMigrationBlocker(
          kind: .sharedApplicationRoot,
          recordOccurrences: [1, 5],
          canonicalPaths: ["/managed/café"]
        )
      ]
    )
  }

  func testBlockerOrderingAndDeduplicationRemainStable() {
    let duplicate = LibraryMigrationBlocker(
      kind: .canonicalSourceCollision,
      recordOccurrences: [4, 8],
      canonicalPaths: ["/same"]
    )
    let blockers = [
      LibraryMigrationBlocker(
        kind: .unexpectedDestination,
        recordOccurrences: [2],
        canonicalPaths: ["/destination"]
      ),
      duplicate,
      LibraryMigrationBlocker(
        kind: .canonicalSourceCollision,
        recordOccurrences: [1, 9],
        canonicalPaths: ["/nested"]
      ),
      duplicate,
      LibraryMigrationBlocker(
        kind: .caseInsensitiveSourceCollision,
        recordOccurrences: [3, 7],
        canonicalPaths: ["/A", "/a"]
      ),
    ]

    XCTAssertEqual(
      LibraryMigrationInventoryAnalysis.orderedUniqueBlockers(blockers),
      [
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: [1, 9],
          canonicalPaths: ["/nested"]
        ),
        duplicate,
        LibraryMigrationBlocker(
          kind: .caseInsensitiveSourceCollision,
          recordOccurrences: [3, 7],
          canonicalPaths: ["/A", "/a"]
        ),
        LibraryMigrationBlocker(
          kind: .unexpectedDestination,
          recordOccurrences: [2],
          canonicalPaths: ["/destination"]
        ),
      ]
    )
  }

  private func applicationRoot(
    _ occurrence: Int,
    _ path: String
  ) -> LibraryMigrationInventoryAnalysis.ApplicationRoot {
    .init(
      applicationOccurrence: occurrence,
      canonicalURL: URL(fileURLWithPath: path, isDirectory: true)
    )
  }

  private func source(
    _ occurrence: Int,
    configured: String,
    canonical: String,
    identity: FileSystemObjectIdentity? = nil
  ) -> LibraryMigrationInventoryAnalysis.ExistingSource {
    .init(
      profileOccurrence: occurrence,
      sourceURL: URL(fileURLWithPath: configured, isDirectory: true),
      canonicalSourceURL: URL(fileURLWithPath: canonical, isDirectory: true),
      sourceIdentity: identity
    )
  }
}
