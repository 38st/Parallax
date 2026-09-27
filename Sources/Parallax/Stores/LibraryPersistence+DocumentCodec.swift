import Foundation

extension LibraryPersistence {
    func encodeDocument(_ document: LibraryDocument) throws -> Data {
        try LibraryDocumentCodec.encodeDocument(document)
    }

    static func decodeApplications(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [ManagedApplication] {
        try LibraryDocumentCodec.decodeApplications(
            from: data,
            decoder: decoder
        )
    }

    static func decodeCurrentDocument(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> LibraryDocument {
        try LibraryDocumentCodec.decodeCurrentDocument(
            from: data,
            decoder: decoder
        )
    }

    static func decodeLibrary(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> LibraryLoadResult {
        try LibraryDocumentCodec.decodeLibrary(
            from: data,
            decoder: decoder
        )
    }

    static func validateCurrentApplications(
        _ applications: [ManagedApplication]
    ) throws {
        try LibraryDocumentCodec.validateCurrentApplications(applications)
    }

    static func sha256(_ data: Data) -> String {
        LibraryDocumentCodec.sha256(data)
    }

}
