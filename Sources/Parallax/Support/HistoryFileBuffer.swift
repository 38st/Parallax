import Darwin
import Foundation

/// Private, immediately unlinked scratch storage. The returned private mapping
/// owns its pages independently of this writer and releases the backing file when
/// its last Data reference disappears. Live provider files are never mapped.
final class HistoryFileBuffer {
    private let descriptor: Int32
    private(set) var count = 0
    private var finished = false

    init(directory: URL = FileManager.default.temporaryDirectory) throws {
        var template = Array(directory.appendingPathComponent("parallax-history-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw SecureManagedFileSystem.systemError("create history scratch file", errno)
        }
        guard unlink(template) == 0 else {
            let code = errno
            close(descriptor)
            throw SecureManagedFileSystem.systemError("unlink history scratch file", code)
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(descriptor)
            throw SecureManagedFileSystem.systemError("protect history scratch descriptor", code)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    func append(_ data: Data) throws {
        try data.withUnsafeBytes { try append($0) }
    }

    func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard !finished else { throw SecureManagedFileSystemError.itemIdentityChanged }
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let written = Darwin.write(descriptor, base.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw SecureManagedFileSystem.systemError("write history scratch file", written < 0 ? errno : EIO)
            }
            offset += written
            count += written
        }
    }

    func finish() throws -> Data {
        guard !finished else { throw SecureManagedFileSystemError.itemIdentityChanged }
        finished = true
        guard count > 0 else { return Data() }
        // Data's mutation APIs require writable memory. MAP_PRIVATE makes those
        // writes copy-on-write pages; they cannot change the backing snapshot.
        let mapping = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, 0)
        guard mapping != MAP_FAILED, let mapping else {
            throw SecureManagedFileSystem.systemError("map history scratch file", errno)
        }
        _ = madvise(mapping, count, MADV_SEQUENTIAL)
        return Data(bytesNoCopy: mapping, count: count, deallocator: .custom { pointer, length in
            munmap(pointer, length)
        })
    }

    /// Visits one JSONL record at a time without making a whole-transcript String
    /// or an array of all lines. Memory use follows the current record's size.
    static func forEachLine(in data: Data, visit: (Data) throws -> Void) rethrows {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let start = base.advanced(by: offset)
                let end = memchr(start, 0x0A, bytes.count - offset)
                let length = end.map { start.distance(to: UnsafeRawPointer($0)) } ?? (bytes.count - offset)
                if length > 0 {
                    try autoreleasepool { try visit(Data(bytes: start, count: length)) }
                }
                offset += length + (end == nil ? 0 : 1)
            }
        }
    }
}
