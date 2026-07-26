import Foundation

enum FileImporterFailure {
    static func userFacingMessage(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        if let cocoaError = error as? CocoaError,
           cocoaError.code == .userCancelled
        {
            return nil
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.userCancelled.rawValue
        {
            return nil
        }
        return error.localizedDescription
    }
}
