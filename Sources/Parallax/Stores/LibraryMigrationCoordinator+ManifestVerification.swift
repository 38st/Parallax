import Foundation

extension LibraryMigrationCoordinator {
  func directoryManifest(at root: URL) throws -> DirectoryManifest {
    var entries: [DirectoryManifest.Entry] = []
    try appendManifestEntries(root: root, current: root, result: &entries)
    return DirectoryManifest(
      entries: entries.sorted { $0.relativePath < $1.relativePath }
    )
  }

  func manifestSHA256(_ manifest: DirectoryManifest) -> String {
    let rows = manifest.entries.map { entry in
      [
        entry.relativePath,
        entry.kind.rawValue,
        entry.size.map(String.init) ?? "",
        entry.posixPermissions.map(String.init) ?? "",
        entry.digestOrTarget ?? "",
      ].joined(separator: "\u{1f}")
    }.joined(separator: "\u{1e}")
    return LibraryPersistence.sha256(Data(rows.utf8))
  }

  func verifySourceUnchanged(_ source: SourceRecord) throws {
    guard
      source.sourceExists,
      let expectedManifest = source.sourceManifest
    else {
      return
    }
    let attributes = try fileSystem.attributesOfItem(
      at: source.canonicalSourceURL
    )
    guard
      attributes.kind == .directory,
      attributes.identity == source.sourceIdentity,
      try directoryManifest(at: source.canonicalSourceURL)
        == expectedManifest
    else {
      throw LibraryMigrationError.sourceChanged
    }
  }

  func appendManifestEntries(
    root: URL,
    current: URL,
    result: inout [DirectoryManifest.Entry]
  ) throws {
    let attributes = try fileSystem.attributesOfItem(at: current)
    let relative = relativePath(of: current, under: root)
    switch attributes.kind {
    case .directory:
      result.append(
        .init(
          relativePath: relative,
          kind: .directory,
          size: nil,
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: nil
        )
      )
      for child in try fileSystem.contentsOfDirectory(at: current)
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      {
        try appendManifestEntries(root: root, current: child, result: &result)
      }
    case .regularFile:
      let data = try fileSystem.readData(at: current)
      result.append(
        .init(
          relativePath: relative,
          kind: .regularFile,
          size: UInt64(data.count),
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: LibraryPersistence.sha256(data)
        )
      )
    case .symbolicLink:
      result.append(
        .init(
          relativePath: relative,
          kind: .symbolicLink,
          size: attributes.size,
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: try fileSystem.destinationOfSymbolicLink(at: current)
        )
      )
    case .other:
      throw LibraryMigrationError.unsupportedSourceItem(current.path)
    }
  }

  func relativePath(of url: URL, under root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = url.standardizedFileURL.pathComponents
    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }

  func ownerMarkerURL(
    destination: URL,
    mapping: LibraryMigrationPathMapping
  ) -> URL {
    destination
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(mapping.profileStorageID.uuidString.lowercased())."
          + "\(mapping.applicationStorageID.uuidString.lowercased()).owner",
        isDirectory: false
      )
  }

  func resolvedPaths(
    for mapping: LibraryMigrationPathMapping
  ) throws -> ResolvedProfilePaths {
    let destination = URL(
      fileURLWithPath: mapping.newCanonicalPath,
      isDirectory: true
    )
    let components = destination.pathComponents
    let suffix = [
      ".parallax",
      "Applications",
      mapping.applicationStorageID.uuidString.lowercased(),
      "Profiles",
      mapping.profileStorageID.uuidString.lowercased(),
    ]
    guard
      components.count > suffix.count,
      Array(components.suffix(suffix.count)) == suffix
    else {
      throw LibraryMigrationError.invalidJournal
    }
    let baseComponents = components.dropLast(suffix.count)
    let basePath = NSString.path(
      withComponents: Array(baseComponents)
    )
    let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
      baseRootURL: URL(fileURLWithPath: basePath, isDirectory: true),
      applicationStorageID: mapping.applicationStorageID,
      profileStorageID: mapping.profileStorageID
    )
    guard resolved.profileRoot.url.path == destination.path else {
      throw LibraryMigrationError.invalidJournal
    }
    return resolved
  }

  func ownerData(
    for journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping
  ) -> Data {
    Data(
      "\(journal.migrationID.uuidString.lowercased()):"
        .appending(mapping.profileStorageID.uuidString.lowercased())
        .utf8
    )
  }
}
