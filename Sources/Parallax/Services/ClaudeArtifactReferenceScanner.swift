import Foundation

struct ClaudeArtifactReference: Equatable, Sendable, Identifiable {
    let url: String
    let sourceFilePath: String?
    var id: String { url }
}

enum ClaudeArtifactReferenceScanner {
    private static let urlPattern = try? NSRegularExpression(
        pattern: #"https://claude\.ai/[^\s"<>\\]+"#, options: [.caseInsensitive]
    )

    static func scan(_ transcript: Data) -> [ClaudeArtifactReference] {
        var orderedURLs: [String] = []
        var seen = Set<String>()
        var paths: [String: Set<String>] = [:]
        HistoryFileBuffer.forEachLine(in: transcript) { line in
            let urls = artifactURLs(in: String(decoding: line, as: UTF8.self))
            for url in urls where seen.insert(url).inserted { orderedURLs.append(url) }
            guard !urls.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) else { return }
            associatePaths(in: object, paths: &paths)
        }
        return orderedURLs.map { url in
            let candidates = paths[url] ?? []
            return ClaudeArtifactReference(url: url, sourceFilePath: candidates.count == 1 ? candidates.first : nil)
        }
    }

    private static func artifactURLs(in text: String) -> [String] {
        let text = text.replacingOccurrences(of: #"\/"#, with: "/")
        let matches = urlPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}'"))
            guard let url = URLComponents(string: value), url.host?.lowercased() == "claude.ai" else { return nil }
            let components = url.path.split(separator: "/")
            guard components.dropLast().contains(where: { $0 == "artifact" || $0 == "artifacts" }) else { return nil }
            return value
        }
    }

    private static func associatePaths(in object: Any, paths: inout [String: Set<String>]) {
        if let object = object as? [String: Any] {
            // Only a file_path in the URL's object or its tool_use input is evidence.
            // Never infer a link between separate tool calls or JSONL records.
            let input = object["type"] as? String == "tool_use" ? object["input"] as? [String: Any] : nil
            if let path = (object["file_path"] ?? input?["file_path"]) as? String,
               isLocalFilePath(path), filePathsInObject(object) == [path] {
                let urls = Set(urlsInObject(object))
                if urls.count == 1, let url = urls.first { paths[url, default: []].insert(path) }
            }
            for value in object.values { associatePaths(in: value, paths: &paths) }
        } else if let array = object as? [Any] {
            for value in array { associatePaths(in: value, paths: &paths) }
        }
    }

    private static func filePathsInObject(_ object: Any) -> Set<String> {
        if let object = object as? [String: Any] {
            var paths = Set(object.values.flatMap { filePathsInObject($0) })
            if let path = object["file_path"] as? String { paths.insert(path) }
            return paths
        }
        if let array = object as? [Any] { return Set(array.flatMap { filePathsInObject($0) }) }
        return []
    }

    private static func urlsInObject(_ object: Any) -> [String] {
        if let text = object as? String { return artifactURLs(in: text) }
        if let object = object as? [String: Any] { return object.values.flatMap(urlsInObject) }
        if let array = object as? [Any] { return array.flatMap(urlsInObject) }
        return []
    }

    private static func isLocalFilePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && !path.hasSuffix("/")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && path.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
