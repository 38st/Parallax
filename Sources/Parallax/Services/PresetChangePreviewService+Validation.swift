import Foundation

extension PresetChangePreviewService {
    func settingUserDataDirectory(
        _ value: String?,
        parsedWords: [String]
    ) -> String {
        var retained: [String] = []
        var index = 0
        while index < parsedWords.count {
            let word = parsedWords[index]
            if word == "--" {
                retained.append(contentsOf: parsedWords[index...])
                break
            }
            if UserDataDirectoryOptionResolver.options.contains(where: {
                word.hasPrefix("\($0)=")
            }) {
                index += 1
                continue
            }
            if UserDataDirectoryOptionResolver.options.contains(word) {
                if parsedWords.indices.contains(index + 1),
                   !parsedWords[index + 1].hasPrefix("-")
                {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            retained.append(word)
            index += 1
        }
        if let value {
            retained.insert(
                "--user-data-dir=\(value)",
                at: retained.firstIndex(of: "--") ?? retained.endIndex
            )
        }
        return LaunchArgumentParser.serialize(retained)
    }

    func settingCodexHome(
        _ value: String?,
        in text: String,
        entries: [LaunchEnvironmentEntry]
    ) -> String {
        let removedLines = Set(entries.map(\.range.start.line))
        var lines = text.components(separatedBy: "\n")
            .enumerated()
            .compactMap { index, line in
                removedLines.contains(index + 1) ? nil : line
            }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if let value {
            lines.append("CODEX_HOME=\(value)")
        }
        return lines.joined(separator: "\n")
    }

    func validateCurrentSource(
        _ preview: PresetChangePreview,
        currentApplication: ManagedApplication,
        requireSameResolvedTarget: Bool
    ) throws {
        guard
            currentApplication.id == preview.applicationID,
            currentApplication.storageID == preview.applicationStorageID,
            currentApplication.preset == preview.sourcePreset,
            currentApplication.baseStoragePath
                == preview.sourceBaseStoragePath,
            currentApplication.profiles == preview.sourceProfiles,
            try sourceSignature(
                applicationID: currentApplication.id,
                applicationStorageID: currentApplication.storageID,
                sourcePreset: currentApplication.preset,
                sourceBaseStoragePath: currentApplication.baseStoragePath,
                sourceProfiles: currentApplication.profiles
            ) == preview.sourceSignature
        else {
            throw PresetChangePreviewError.stalePreview
        }
        if requireSameResolvedTarget {
            guard resolvedPreset(
                preview.targetPreset,
                application: currentApplication
            ) == preview.targetResolvedPreset else {
                throw PresetChangePreviewError.stalePreview
            }
        }
    }

    func resolvedPreset(
        _ preset: AppPreset,
        application: ManagedApplication
    ) -> AppPreset {
        preset == .automatic
            ? AppPreset.detected(
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier
            )
            : preset
    }

    func isSafeAbsolutePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.contains("\0"),
            (path as NSString).isAbsolutePath
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first == "" else { return false }
        return !components.dropFirst().contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    private struct SignatureSource: Encodable {
        let applicationID: UUID
        let applicationStorageID: UUID
        let sourcePreset: AppPreset
        let sourceBaseStoragePath: String?
        let sourceProfiles: [LaunchProfile]
    }

    func sourceSignature(
        applicationID: UUID,
        applicationStorageID: UUID,
        sourcePreset: AppPreset,
        sourceBaseStoragePath: String?,
        sourceProfiles: [LaunchProfile]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(
            SignatureSource(
                applicationID: applicationID,
                applicationStorageID: applicationStorageID,
                sourcePreset: sourcePreset,
                sourceBaseStoragePath: sourceBaseStoragePath,
                sourceProfiles: sourceProfiles
            )
        )
        return LibraryPersistence.sha256(bytes)
    }
}
