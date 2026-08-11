import Foundation

enum LibraryImportArtifactKind: Sendable, Equatable {
    case libraryDocument
    case portableLibraryMetadata
    case portableConfiguration
}

struct DecodedLibraryImportArtifact: Sendable {
    let kind: LibraryImportArtifactKind?
    let validation: LibraryImportValidationReport
}

/// Classifies an import envelope once, validates its portable contract, and
/// delegates nested library semantics to `LibraryImportValidator`.
///
/// The byte limit is enforced before JSON parsing or any typed decoder. Raw
/// nested library JSON is validated before a portable artifact is decoded as a
/// whole, keeping untrusted library content behind the existing validation
/// boundary.
struct LibraryImportArtifactDecoder: Sendable {
    private let limits: LibraryImportLimits
    private let validator: LibraryImportValidator
    private let portableConfiguration: PortableConfigurationService

    init(
        limits: LibraryImportLimits = LibraryImportLimits(),
        validator: LibraryImportValidator? = nil,
        portableConfiguration: PortableConfigurationService? = nil
    ) {
        self.limits = limits
        self.validator = validator ?? LibraryImportValidator(limits: limits)
        self.portableConfiguration = portableConfiguration
            ?? PortableConfigurationService(
                maximumEncodedArtifactBytes: limits.maximumBytes
            )
    }

    func decode(_ data: Data) throws -> DecodedLibraryImportArtifact {
        guard data.count <= limits.maximumBytes else {
            return DecodedLibraryImportArtifact(
                kind: nil,
                validation: validator.validate(data)
            )
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            root["version"] == nil,
            root["header"] != nil
        else {
            return DecodedLibraryImportArtifact(
                kind: .libraryDocument,
                validation: validator.validate(data)
            )
        }

        let portableKind = try portableArtifactKind(in: root)
        let importKind: LibraryImportArtifactKind
        switch portableKind {
        case .libraryMetadata:
            importKind = .portableLibraryMetadata
        case .portableConfiguration:
            importKind = .portableConfiguration
        case .settingsAndTemplates, .fullBackup:
            throw PortableConfigurationError.unexpectedArtifactKind
        }

        let header = try portableHeader(in: root)
        try portableConfiguration.validate(
            header,
            expectedKind: portableKind
        )

        let validation = try validateNestedLibrary(in: root)
        guard validation.isValid else {
            return DecodedLibraryImportArtifact(
                kind: importKind,
                validation: validation
            )
        }

        do {
            switch portableKind {
            case .libraryMetadata:
                _ = try portableConfiguration.decodeLibraryMetadataExport(
                    from: data
                )
            case .portableConfiguration:
                _ = try portableConfiguration
                    .decodePortableConfigurationExport(from: data)
            case .settingsAndTemplates, .fullBackup:
                throw PortableConfigurationError.unexpectedArtifactKind
            }
        } catch let error as PortableConfigurationError {
            throw error
        } catch {
            throw PortableConfigurationError.invalidArtifactPayload
        }

        return DecodedLibraryImportArtifact(
            kind: importKind,
            validation: validation
        )
    }

    private func portableArtifactKind(
        in root: [String: Any]
    ) throws -> PortableArtifactKind {
        guard
            let header = root["header"] as? [String: Any],
            let rawKind = header["kind"] as? String,
            let kind = PortableArtifactKind(rawValue: rawKind)
        else {
            throw PortableConfigurationError.unexpectedArtifactKind
        }
        return kind
    }

    private func portableHeader(
        in root: [String: Any]
    ) throws -> PortableArtifactHeader {
        guard
            let rawHeader = root["header"],
            JSONSerialization.isValidJSONObject(rawHeader)
        else {
            throw PortableConfigurationError.invalidDisclosure
        }
        let headerData = try JSONSerialization.data(
            withJSONObject: rawHeader,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard headerData.count <= limits.maximumBytes else {
            throw PortableConfigurationError.inputTooLarge
        }
        do {
            return try JSONDecoder().decode(
                PortableArtifactHeader.self,
                from: headerData
            )
        } catch {
            throw PortableConfigurationError.invalidDisclosure
        }
    }

    private func validateNestedLibrary(
        in root: [String: Any]
    ) throws -> LibraryImportValidationReport {
        guard
            let rawLibrary = root["library"],
            JSONSerialization.isValidJSONObject(rawLibrary)
        else {
            throw PortableConfigurationError.invalidArtifactPayload
        }
        let libraryData = try JSONSerialization.data(
            withJSONObject: rawLibrary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return validator.validate(libraryData)
    }
}
