import CryptoKit
import Darwin
import Foundation

extension StorageRelocationCoordinator {
  func requireDestinationAbsent(
    _ paths: ResolvedApplicationStoragePaths
  ) throws {
    guard
      !fileSystem.fileExists(at: paths.applicationRoot.url),
      !fileSystem.fileExists(at: paths.applicationArchiveRoot.url)
    else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: paths.canonicalBaseRootURL.path
      )
    }
    _ = try pathResolver.revalidateForMutation(paths.applicationRoot)
    _ = try pathResolver.revalidateForMutation(
      paths.applicationArchiveRoot
    )
  }

  func restoreOriginal(
    source: any ManagedMutationPath,
    destination: any ManagedMutationPath,
    staged: RelocationManagedPath,
    retired: RelocationManagedPath,
    strategy: StorageRelocationStrategy
  ) throws {
    if fileSystem.fileExists(at: source.url) {
      try removeIfPresent(destination)
      try removeIfPresent(staged)
      try removeIfPresent(retired)
      return
    }
    if fileSystem.fileExists(at: retired.url) {
      try move(retired, to: source)
      try removeIfPresent(destination)
      try removeIfPresent(staged)
      return
    }
    if strategy == .sameVolume,
      fileSystem.fileExists(at: destination.url)
    {
      try move(destination, to: source)
      try removeIfPresent(staged)
      return
    }
    if strategy == .sameVolume,
      fileSystem.fileExists(at: staged.url)
    {
      try move(staged, to: source)
      try removeIfPresent(destination)
      return
    }
    throw StorageRelocationError(
      .rollbackRequired,
      path: source.url.path
    )
  }

  func exists(_ path: any ManagedMutationPath) -> Bool {
    fileSystem.fileExists(at: path.url)
  }

  func createDirectory(_ path: any ManagedMutationPath) throws {
    let url = try pathResolver.revalidateForMutation(path)
    if fileSystem is LocalFileSystem,
      let securePath = try securePath(path)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: path.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.createDirectory(at: securePath)
      return
    }
    try fileSystem.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    try fileSystem.setPOSIXPermissions(0o700, at: url)
  }

  func copy(
    _ source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    guard !fileSystem.fileExists(at: destinationURL) else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: destinationURL.path
      )
    }
    if fileSystem is LocalFileSystem,
      let sourcePath = try securePath(source),
      let destinationPath = try securePath(destination)
    {
      let sourceFileSystem = try SecureManagedFileSystem(
        rootURL: source.validationContext.canonicalBaseRootURL
      )
      let destinationFileSystem = try SecureManagedFileSystem(
        rootURL: destination.validationContext.canonicalBaseRootURL
      )
      do {
        try sourceFileSystem.copyTree(from: sourcePath, to: destinationPath, in: destinationFileSystem)
      } catch SecureManagedFileSystemError.manifestMismatch {
        throw StorageRelocationError(.copyVerificationFailed)
      }
      return
    }
    do { try fileSystem.copyItem(at: sourceURL, to: destinationURL) }
    catch SecureManagedFileSystemError.manifestMismatch { throw StorageRelocationError(.copyVerificationFailed) }
  }

  func move(
    _ source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    guard !fileSystem.fileExists(at: destinationURL) else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: destinationURL.path
      )
    }
    if fileSystem is LocalFileSystem,
      source.validationContext.canonicalBaseRootURL
        == destination.validationContext.canonicalBaseRootURL,
      let sourcePath = try securePath(source),
      let destinationPath = try securePath(destination)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: source.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.rename(
        from: sourcePath,
        to: destinationPath
      )
      return
    }
    try fileSystem.moveItem(at: sourceURL, to: destinationURL)
  }

  func removeIfPresent(
    _ path: any ManagedMutationPath
  ) throws {
    guard fileSystem.fileExists(at: path.url) else { return }
    let url = try pathResolver.revalidateForMutation(path)
    if fileSystem is LocalFileSystem,
      let securePath = try securePath(path)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: path.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.removeTree(at: securePath)
      return
    }
    try fileSystem.removeItem(at: url)
  }

  func securePath(
    _ path: any ManagedMutationPath
  ) throws -> SecureManagedPath? {
    let rootComponents =
      path.validationContext.canonicalBaseRootURL.pathComponents
    let pathComponents = path.url.pathComponents
    guard
      pathComponents.count > rootComponents.count,
      Array(pathComponents.prefix(rootComponents.count))
        == rootComponents
    else { return nil }
    return try SecureManagedPath(
      Array(pathComponents.dropFirst(rootComponents.count))
    )
  }

  func persist(
    _ receipt: StorageRelocationReceipt,
    at path: RelocationReceiptPath
  ) throws {
    let data = try encoder.encode(receipt)
    // The resolver's mutation path contract describes directories. Validate
    // the containing transaction directory immediately before writing the
    // fixed receipt filename, rather than treating an existing JSON file as
    // a directory target on subsequent state transitions.
    let parent = RelocationManagedPath(
      url: path.url.deletingLastPathComponent(),
      validationContext: path.validationContext
    )
    _ = try pathResolver.revalidateForMutation(parent)
    try fileSystem.writeDataAtomically(data, to: path.url)
  }

  func child(
    _ name: String,
    in staging: ManagedStagingRootPath
  ) -> RelocationManagedPath {
    RelocationManagedPath(
      url: staging.url.appendingPathComponent(name, isDirectory: true),
      validationContext: staging.validationContext
    )
  }

  func childFile(
    _ name: String,
    in staging: ManagedStagingRootPath
  ) -> RelocationReceiptPath {
    RelocationReceiptPath(
      url: staging.url.appendingPathComponent(name, isDirectory: false),
      validationContext: staging.validationContext
    )
  }

  func synchronizeDestination(_ paths: ResolvedApplicationStoragePaths) throws {
    let roots: [any ManagedMutationPath] = [paths.applicationRoot, paths.applicationArchiveRoot]
    for path in roots {
      guard let relative = try securePath(path) else { continue }
      let secure = try SecureManagedFileSystem(rootURL: path.validationContext.canonicalBaseRootURL)
      guard try secure.itemState(at: relative) != .missing else { continue }
      try transactionBoundary?(.beforeDestinationSync(path.url))
      let (parent, leaf) = try secure.openParent(of: relative, createMissing: false)
      defer { close(parent) }
      let root = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard root >= 0 else { throw StorageRelocationError(.sourceChanged, path: path.url.path) }
      defer { close(root) }
      // copyTree already fsyncs every item. Flush the drive cache once for
      // this root and once for its publication directory, not for every file.
      try synchronizeDescriptor(root)
      try synchronizeDescriptor(parent)
      try secure.verifyRootIdentity()
    }
  }

  static func synchronizeFully(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    let code = errno
    guard code == EINVAL || code == ENOTSUP || code == ENOTTY || code == ENOSYS else {
      throw SecureManagedFileSystemError.systemCall(operation: "synchronize relocation data", code: code)
    }
    guard fsync(descriptor) == 0 else {
      throw SecureManagedFileSystemError.systemCall(operation: "synchronize relocation data", code: errno)
    }
  }
}
