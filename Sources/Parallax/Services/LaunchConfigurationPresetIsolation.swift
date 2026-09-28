import Foundation

enum PresetIsolationFolder: String, CaseIterable, Hashable, Sendable {
    case firefoxProfile
    case extensions

    var options: Set<String> {
        switch self {
        case .firefoxProfile: ["-profile", "--profile"]
        case .extensions: ["--extensions-dir"]
        }
    }

    var managedRole: ProfileHealthPathRole {
        self == .firefoxProfile ? .managedFirefoxProfile : .managedExtensions
    }

    var externalRole: ProfileHealthPathRole {
        self == .firefoxProfile ? .externalFirefoxProfile : .externalExtensions
    }

    var label: String {
        switch self {
        case .firefoxProfile: String(localized: "Firefox profile folder")
        case .extensions: String(localized: "Extensions folder")
        }
    }

    func managedPath(in paths: ResolvedProfilePaths) -> ManagedPresetDataPath {
        self == .firefoxProfile ? paths.firefoxProfile : paths.extensions
    }

    func applies(to preset: AppPreset) -> Bool {
        self == .firefoxProfile ? preset == .firefox : preset == .visualStudioCode
    }

    var ownershipKeyPath: WritableKeyPath<ProfileIsolationOwnership, IsolationPathOwnership> {
        switch self {
        case .firefoxProfile: \.firefoxProfile
        case .extensions: \.extensions
        }
    }

    func ownership(in value: ProfileIsolationOwnership) -> IsolationPathOwnership {
        value[keyPath: ownershipKeyPath]
    }

    static func firefoxSelectionRanges(in words: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            let name = String(word.split(separator: "=", maxSplits: 1).first ?? "")
            if ["-p", "--p", "-profilemanager", "--profilemanager", "-createprofile", "--createprofile"].contains(name) {
                let takesValue = name == "-p" || name == "--p" || name == "-createprofile" || name == "--createprofile"
                let hasValue = takesValue && !word.contains("=") && index + 1 < words.count && !words[index + 1].hasPrefix("-")
                ranges.append(index..<(index + (hasValue ? 2 : 1)))
                if hasValue { index += 1 }
            }
            index += 1
        }
        return ranges
    }

    static func hasFirefoxSelection(argumentsText: String, environmentText: String) -> Bool {
        !firefoxSelectionRanges(in: LaunchArgumentParser.parse(argumentsText).words).isEmpty
            || LaunchEnvironmentParser.parse(environmentText).effectiveValues["XRE_PROFILE_PATH"] != nil
    }

    func diagnostic(in parsed: LaunchArgumentParseResult) -> LaunchCompilerDiagnostic? {
        let option = resolve(in: parsed.words)
        guard !option.isValid, let first = option.ranges.first, let last = option.ranges.last else { return nil }
        return LaunchCompilerDiagnostic(
            code: .invalidPresetOption(self), severity: .error, isOverridable: false,
            sourceRange: LaunchSourceRange(start: parsed.tokens[first.lowerBound].range.start,
                                          end: parsed.tokens[last.upperBound - 1].range.end), path: nil)
    }

    func setting(_ path: String?, in text: String, includingNoRemote: Bool = true) throws -> String {
        let parsed = LaunchArgumentParser.parse(text)
        guard !parsed.hasErrors else {
            throw LaunchPreparationError.blocked(parsed.diagnostics.map(LaunchConfigurationProjection.compilerDiagnostic))
        }
        var words = parsed.words
        for range in resolve(in: words).ranges.reversed() { words.removeSubrange(range) }
        if let path {
            var values = self == .firefoxProfile ? ["-profile", path] : ["--extensions-dir=\(path)"]
            if self == .firefoxProfile, includingNoRemote,
               !words.contains(where: { ["-no-remote", "--no-remote"].contains($0.lowercased()) }) {
                values.append("-no-remote")
            }
            words.insert(contentsOf: values, at: words.firstIndex(of: "--") ?? words.endIndex)
        }
        return words.map(ShellWordsParser.quote).joined(separator: " ")
    }

    func resolve(in words: [String]) -> PresetIsolationOptionResolution {
        var ranges: [Range<Int>] = []
        var values: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if self == .extensions, word == "--" { break }
            // Firefox's startup CheckArg is case-insensitive and scans past --.
            let normalized = self == .firefoxProfile ? word.lowercased() : word
            if let equals = word.firstIndex(of: "="),
               options.contains(self == .firefoxProfile ? String(word[..<equals]).lowercased() : String(word[..<equals])) {
                ranges.append(index..<(index + 1))
                values.append(String(word[word.index(after: equals)...]))
            } else if options.contains(normalized) {
                let hasValue = index + 1 < words.count && !words[index + 1].hasPrefix("-")
                ranges.append(index..<(index + (hasValue ? 2 : 1)))
                values.append(hasValue ? words[index + 1] : "")
                if hasValue { index += 1 }
            }
            index += 1
        }
        return PresetIsolationOptionResolution(ranges: ranges, values: values)
    }

    func project(_ words: [String], path: LaunchIsolationPath) -> [String] {
        let resolution = resolve(in: words)
        guard resolution.isPresent, resolution.isValid else { return words }
        var result = words
        for range in resolution.ranges.reversed() { result.removeSubrange(range) }
        let options: [String]
        switch self {
        case .firefoxProfile:
            options = ["-profile", path.url.path]
        case .extensions:
            options = ["--extensions-dir=\(path.url.path)"]
        }
        let terminator = result.firstIndex(of: "--") ?? result.endIndex
        let insertion = self == .firefoxProfile
            ? min(resolution.ranges.first?.lowerBound ?? result.endIndex, terminator) : terminator
        result.insert(contentsOf: options, at: insertion)
        return result
    }

    static func removingOverrides(from text: String, preset: AppPreset, includingFirefoxSelections: Bool = false) throws -> String {
        let folders = allCases.filter { $0.applies(to: preset) }
        guard !folders.isEmpty else { return text }
        let parsed = LaunchArgumentParser.parse(text)
        guard !parsed.hasErrors else {
            throw LaunchPreparationError.blocked(parsed.diagnostics.map(LaunchConfigurationProjection.compilerDiagnostic))
        }
        let ranges = folders.flatMap {
            $0.resolve(in: parsed.words).ranges
        } + (includingFirefoxSelections && preset == .firefox ? firefoxSelectionRanges(in: parsed.words) : [])
        let result = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let start = parsed.tokens[range.lowerBound].range.start.utf16Offset
            let end = parsed.tokens[range.upperBound - 1].range.end.utf16Offset
            result.deleteCharacters(in: NSRange(location: start, length: end - start))
        }
        return result as String
    }
}

struct PresetIsolationOptionResolution {
    let ranges: [Range<Int>]
    let values: [String]

    var isPresent: Bool { !ranges.isEmpty }
    var isValid: Bool {
        values.count <= 1 && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var value: String? { isValid ? values.first : nil }
}
