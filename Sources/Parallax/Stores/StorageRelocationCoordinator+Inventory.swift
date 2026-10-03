import CryptoKit
import Darwin
import Foundation

extension StorageRelocationCoordinator {
  func estimateApplicationStorage(
    _ paths: ResolvedApplicationStoragePaths
  ) throws -> StorageTreeEstimate {
    try estimateIfPresent(source: paths.applicationRoot)
      + estimateIfPresent(source: paths.applicationArchiveRoot)
  }

  func estimateIfPresent(
    source: any ManagedMutationPath
  ) throws -> StorageTreeEstimate {
    guard fileSystem.fileExists(at: source.url) else { return .zero }
    _ = try pathResolver.revalidateForMutation(source)
    return try estimate(at: source.url)
  }

  func estimate(at url: URL) throws -> StorageTreeEstimate {
    try checkPreparationCancellation(at: url)
    let attributes = try fileSystem.attributesOfItem(at: url)
    switch attributes.kind {
    case .directory:
      var result = StorageTreeEstimate(
        allocatedBytes: 0,
        itemCount: 1
      )
      for child in try fileSystem.contentsOfDirectory(at: url) {
        result = result + (try estimate(at: child))
      }
      return result
    case .regularFile:
      // Each copied file occupies whole allocation blocks. Counting logical
      // bytes underestimates profiles made of many small files.
      let size = attributes.size ?? 0
      let blockSize: UInt64 = 4_096
      return StorageTreeEstimate(
        allocatedBytes: (size / blockSize + (size % blockSize == 0 ? 0 : 1)) * blockSize,
        itemCount: 1
      )
    case .symbolicLink, .other:
      throw StorageRelocationError(
        .unsafeSource,
        path: url.path
      )
    }
  }

  func fingerprintIfPresent(
    _ path: any ManagedMutationPath
  ) throws -> String? {
    guard fileSystem.fileExists(at: path.url) else { return nil }
    _ = try pathResolver.revalidateForMutation(path)
    return try fingerprint(at: path.url)
  }

  func fingerprint(at root: URL) throws -> String {
    var entries: [RelocationManifestEntry] = []
    try appendManifest(
      at: root,
      relativePath: ".",
      entries: &entries
    )
    let manifestEncoder = JSONEncoder()
    manifestEncoder.outputFormatting = [.sortedKeys]
    return LibraryPersistence.sha256(try manifestEncoder.encode(entries))
  }

  func appendManifest(
    at url: URL,
    relativePath: String,
    entries: inout [RelocationManifestEntry]
  ) throws {
    try checkPreparationCancellation(at: url)
    let attributes = try fileSystem.attributesOfItem(at: url)
    switch attributes.kind {
    case .directory:
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath.precomposedStringWithCanonicalMapping,
          kind: "directory",
          size: nil,
          contentSHA256: nil
        )
      )
      for child in try fileSystem.contentsOfDirectory(at: url)
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      {
        try appendManifest(
          at: child,
          relativePath: relativePath == "."
            ? child.lastPathComponent
            : relativePath + "/" + child.lastPathComponent,
          entries: &entries
        )
      }
    case .regularFile:
      let digest = try contentDigest(at: url)
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath.precomposedStringWithCanonicalMapping,
          kind: "file",
          size: digest.size,
          contentSHA256: digest.sha256
        )
      )
    case .symbolicLink, .other:
      throw StorageRelocationError(.unsafeSource, path: url.path)
    }
  }

  func availableCapacity(at url: URL) -> UInt64? {
    capacityProvider(url)
  }

  static func systemAvailableCapacity(at url: URL) -> UInt64? {
    guard
      let values = try? url.resourceValues(
        forKeys: [
          .volumeAvailableCapacityForImportantUsageKey,
          .volumeAvailableCapacityKey,
        ]
      )
    else { return nil }
    if let important = values.volumeAvailableCapacityForImportantUsage,
      important >= 0
    {
      return UInt64(important)
    }
    if let available = values.volumeAvailableCapacity, available >= 0 {
      return UInt64(available)
    }
    return nil
  }

  func checkPreparationCancellation(at url: URL) throws {
    guard let preparationCancellation else { return }
    try checkCancellation(preparationCancellation)
    try transactionBoundary?(.beforePreviewRead(url))
    try checkCancellation(preparationCancellation)
  }

  func contentDigest(at url: URL) throws -> (size: UInt64, sha256: String) {
    guard fileSystem is LocalFileSystem else {
      try checkPreparationCancellation(at: url)
      let data = try fileSystem.readData(at: url)
      try checkPreparationCancellation(at: url)
      return (UInt64(data.count), LibraryPersistence.sha256(data))
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw StorageRelocationError(.sourceChanged, path: url.path) }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1 else { throw StorageRelocationError(.unsafeSource, path: url.path) }
    return try contentDigest(descriptor: descriptor, url: url)
  }

  func contentDigest(descriptor: Int32, url: URL) throws -> (size: UInt64, sha256: String) {
    var hasher = SHA256()
    var size: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      try checkPreparationCancellation(at: url)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw StorageRelocationError(.sourceChanged, path: url.path)
      }
      size += UInt64(count)
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  func previewManifest(in secure: SecureManagedFileSystem, at path: SecureManagedPath,
    url: URL) throws -> [StorageRelocationManifestEntry] {
    let (parent, leaf) = try secure.openParent(of: path, createMissing: false)
    defer { close(parent) }
    func readItem(parent: Int32, name: String, components: [String]) throws -> [StorageRelocationManifestEntry] {
      let itemURL = components.reduce(url) { $0.appendingPathComponent($1) }
      try checkPreparationCancellation(at: itemURL)
      let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw StorageRelocationError(.unsafeSource, path: itemURL.path) }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR || status.st_mode & S_IFMT == S_IFREG,
        status.st_mode & S_IFMT == S_IFDIR || status.st_nlink == 1
      else { throw StorageRelocationError(.unsafeSource, path: itemURL.path) }
      let directory = status.st_mode & S_IFMT == S_IFDIR
      let digest = directory ? nil : try contentDigest(descriptor: descriptor, url: itemURL)
      var entries = [StorageRelocationManifestEntry(relativeComponents: components,
        kind: directory ? "directory" : "regularFile", byteCount: digest?.size ?? 0,
        permissions: UInt16(status.st_mode & 0o777), sha256: digest?.sha256)]
      if directory {
        for child in try secure.directoryEntryNames(descriptor) {
          entries += try readItem(parent: descriptor, name: child, components: components + [child])
        }
      }
      var final = stat()
      guard fstat(descriptor, &final) == 0, SecureManagedFileSystem.isSameObject(status, final),
        status.st_size == final.st_size, status.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
        status.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else {
        throw StorageRelocationError(.sourceChanged, path: itemURL.path)
      }
      return entries
    }
    let entries = try readItem(parent: parent, name: leaf, components: [])
    try secure.verifyRootIdentity()
    return entries
  }

}
