import Darwin
import Foundation

/// Opens once, checks the opened object, and bounds every read even if it grows.
enum LibraryImportFileReader {
    static func read(
        at url: URL,
        maximumBytes: Int,
        readChunk: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
    ) throws -> Data {
        guard url.isFileURL, !url.path.contains("\0"),
              maximumBytes >= 0, maximumBytes < Int.max
        else { throw LibraryImportStoreError.invalidImportFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= Int64(maximumBytes)
        else { throw LibraryImportStoreError.invalidImportFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let chunk = try readChunk(handle, min(64 * 1_024, maximumBytes - data.count + 1)),
              !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw LibraryImportStoreError.invalidImportFile
            }
        }
        return data
    }
}
