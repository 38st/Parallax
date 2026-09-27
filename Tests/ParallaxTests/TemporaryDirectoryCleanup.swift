import Darwin
import Foundation

/// Removes a test-owned root, including read-only directories copied by storage tests.
/// Only directories are chmod'ed: symlinks and hard-linked files must not change
/// permissions on an item outside the disposable root.
func removeTestDirectory(at root: URL) throws {
    func restoreDirectoryPermissions(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return }
        guard chmod(url.path, (status.st_mode & 0o7777) | 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) {
            try restoreDirectoryPermissions(at: child)
        }
    }

    try restoreDirectoryPermissions(at: root)
    do {
        try FileManager.default.removeItem(at: root)
    } catch CocoaError.fileNoSuchFile {
        // Cleanup is also used when setup fails before creating the root.
    }
}
