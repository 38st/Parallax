import Darwin
import Foundation

extension ProfileDataTransactionCoordinator {
  func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
    try encoder.encode(value)
  }

  func controlPlanPath(_ transactionID: UUID) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased() + ".plan.json"
    ])
  }

  func controlRecordPath(
    transactionID: UUID,
    sequence: Int
  ) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased()
        + "."
        + String(format: "%06d", sequence)
        + ".record.json"
    ])
  }

  func controlReceiptPath(
    _ transactionID: UUID
  ) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased() + ".receipt.json"
    ])
  }

  func controlURL(for path: SecureManagedPath) -> URL {
    path.components.reduce(controlRootURL) {
      $0.appendingPathComponent($1, isDirectory: false)
    }
  }

  func validateControlRoot() throws {
    let attributes = try fileSystem.attributesOfItem(at: controlRootURL)
    guard
      attributes.kind == .directory,
      attributes.identity == controlRootIdentity
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: controlRootURL.path
      )
    }
  }

  func readControlFile(_ path: SecureManagedPath) throws -> Data {
    try validateControlRoot()
    let data = try readNoFollow(
      path: path,
      rootURL: controlRootURL,
      expectedRootIdentity: controlRootIdentity,
      maximumBytes: path.components.last?.hasSuffix(".plan.json") == true
        || path.components.last?.hasSuffix(".record.json") == true
        ? Self.maximumJournalBytes : 4 * 1_024 * 1_024
    )
    try validateControlRoot()
    return data
  }

  func readManagedFile(
    _ path: SecureManagedPath,
    root: RootBinding
  ) throws -> Data {
    let attributes = try fileSystem.attributesOfItem(at: root.url)
    guard attributes.identity == root.identity else {
      throw ProfileDataTransactionError(
        .sourceChanged,
        path: root.path
      )
    }
    return try readNoFollow(
      path: path,
      rootURL: root.url,
      expectedRootIdentity: root.identity
    )
  }

  func readNoFollow(
    path: SecureManagedPath,
    rootURL: URL,
    expectedRootIdentity: FileSystemObjectIdentity,
    maximumBytes: Int = 4 * 1_024 * 1_024
  ) throws -> Data {
    var descriptor = open(
      rootURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }
    var rootStatus = stat()
    guard
      fstat(descriptor, &rootStatus) == 0,
      UInt64(bitPattern: Int64(rootStatus.st_dev)) == expectedRootIdentity.volumeID,
      UInt64(rootStatus.st_ino) == expectedRootIdentity.fileID
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: rootURL.path
      )
    }

    for component in path.components.dropLast() {
      let next = openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard next >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      close(descriptor)
      descriptor = next
    }
    guard let leaf = path.components.last else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    let file = openat(
      descriptor,
      leaf,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard file >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(file) }
    var status = stat()
    guard
      fstat(file, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1
    else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      result.append(buffer, count: count)
      guard result.count <= maximumBytes else {
        throw ProfileDataTransactionError(
          .invalidJournal,
          path: rootURL.path
        )
      }
    }
    return result
  }
}
