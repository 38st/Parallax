import Foundation

struct ClaudeArtifactReview {
    struct Item: Identifiable {
        let reference: ClaudeArtifactReference
        let sourceFileExists: Bool
        var id: String { reference.id }
    }

    let items: [Item]

    init(references: [ClaudeArtifactReference], fileManager: FileManager = .default) {
        items = references.map { reference in
            var isDirectory: ObjCBool = false
            let exists = reference.sourceFilePath.map {
                fileManager.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue
            } ?? false
            return Item(reference: reference, sourceFileExists: exists)
        }
    }

    var republishPrompt: String? {
        var seen = Set<String>()
        let paths = items.compactMap { item -> String? in
            guard item.sourceFileExists, let path = item.reference.sourceFilePath,
                  seen.insert(path).inserted else { return nil }
            return path
        }
        guard !paths.isEmpty else { return nil }
        return String(localized: "Please republish these files as new artifacts:", bundle: PackagedRuntimeResources.bundle)
            + "\n" + paths.joined(separator: "\n")
    }

    static func conversationWarning(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "claude-conversation-artifact-count", defaultValue: "This conversation links to %lld Claude artifacts. Artifacts are stored on claude.ai under the original account and will not open in the destination space.", bundle: PackagedRuntimeResources.bundle),
            Int64(count)
        )
    }

    static func sharedHistoryWarning(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "claude-shared-history-artifact-count", defaultValue: "These conversations link to %lld Claude artifacts. Artifacts are stored on claude.ai under the original account and will not open in spaces signed into another account.", bundle: PackagedRuntimeResources.bundle),
            Int64(count)
        )
    }
}
