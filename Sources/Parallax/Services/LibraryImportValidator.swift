import Foundation

/// Behavior-preserving facade for the ordered import validation pipeline.
struct LibraryImportValidator: Sendable {
    private let limits: LibraryImportLimits

    init(limits: LibraryImportLimits = LibraryImportLimits()) {
        self.limits = limits
    }

    func validate(_ data: Data) -> LibraryImportValidationReport {
        switch LibraryImportEnvelopeParser(limits: limits).parse(data) {
        case let .rejected(report):
            return report
        case let .accepted(dictionary):
            var issues = LibraryImportRawSchemaValidator(limits: limits)
                .validate(dictionary)
            let decoded = LibraryImportTypedDocumentDecoder.decode(
                data,
                issues: &issues
            )
            let hasErrors = issues.contains { $0.severity == .error }
            let document = hasErrors
                ? nil
                : decoded.map {
                    LibraryImportDocumentNormalizer(limits: limits)
                        .normalize($0)
                }
            return LibraryImportValidationReport(
                document: document,
                issues: issues
            )
        }
    }
}
