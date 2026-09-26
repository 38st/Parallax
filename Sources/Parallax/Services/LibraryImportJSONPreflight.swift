import Foundation

/// Both Foundation decoders must see one unambiguous value for every key.
/// Field-specific limits remain the responsibility of the schema validator.
enum LibraryImportJSONPreflight {
    static func validate(_ data: Data, maximumBytes: Int) throws {
        let result = StrictJSONPreflight(
            limits: .init(
                maximumBytes: maximumBytes,
                maximumArrayItems: maximumBytes,
                maximumObjectMembers: maximumBytes,
                maximumKeyUTF8Bytes: 256,
                maximumStringUTF8Bytes: maximumBytes,
                maximumNumberBytes: 128,
                maximumNestingDepth: 256,
                maximumTokenCount: maximumBytes
            ),
            rootRequirement: .any,
            topLevelProbe: nil
        ).scan(data)
        if case .failure(let issue) = result { throw issue }
    }
}
