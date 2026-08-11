import Darwin
import Foundation

protocol PathWriteAccessChecking: Sendable {
    func isWritable(at url: URL) -> Bool
}

struct POSIXPathWriteAccessChecker: PathWriteAccessChecking {
    func isWritable(at url: URL) -> Bool {
        access(url.path, W_OK) == 0
    }
}
