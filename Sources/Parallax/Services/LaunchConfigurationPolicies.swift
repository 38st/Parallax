import Foundation

enum LaunchPreparationValidator {
    static func validate(
        _ analysis: LaunchAnalysis,
        override: LaunchDiagnosticOverride?
    ) throws {
        let blocking = analysis.diagnostics.filter {
            $0.severity == .error
        }
        guard !blocking.isEmpty else {
            if let override,
               override.requestID != analysis.requestID
                    || override.configurationFingerprint
                        != analysis.configurationFingerprint
            {
                throw LaunchPreparationError.overrideDoesNotMatchRequest
            }
            return
        }
        guard
            let override,
            override.requestID == analysis.requestID,
            override.configurationFingerprint
                == analysis.configurationFingerprint,
            blocking.allSatisfy({
                $0.isOverridable
                    || (
                        override.allowsActiveProfileRisk
                            && $0.code
                                == .profileHealth(.profileActive)
                    )
            })
        else {
            throw LaunchPreparationError.blocked(blocking)
        }
    }
}

enum LaunchConfigurationProjection {
    static func preparedArguments(
        _ words: [String],
        resolution: UserDataDirectoryResolution,
        isolation: LaunchIsolationAnalysis
    ) -> [String] {
        guard let path = isolation.userDataURL?.path else {
            return words
        }
        var result = words
        if resolution.occurrences.isEmpty {
            if isolation.userData?.isManaged == true {
                result.append("--user-data-dir=\(path)")
            }
            return result
        }
        guard resolution.occurrences.count == 1 else { return result }

        var index = 0
        while index < result.count {
            if result[index].hasPrefix("--user-data-dir=") {
                result[index] = "--user-data-dir=\(path)"
                return result
            }
            if result[index] == "--user-data-dir",
               result.indices.contains(index + 1)
            {
                result[index + 1] = path
                return result
            }
            index += 1
        }
        return result
    }

    static func preparedEnvironmentAssignments(
        _ assignments: [StoredEnvironmentAssignment],
        isolation: LaunchIsolationAnalysis
    ) -> [StoredEnvironmentAssignment] {
        guard
            let codexHome = isolation.codexHome
        else {
            return assignments
        }
        let replacement = StoredEnvironmentAssignment(
            key: "CODEX_HOME",
            value: .literal(codexHome.url.path)
        )
        var result = assignments.filter { $0.key != "CODEX_HOME" }
        result.append(replacement)
        return result
    }

    static func previewEnvironmentAssignments(
        _ assignments: [StoredEnvironmentAssignment],
        unsetKeys: Set<String>,
        policy: ChildEnvironmentPolicy,
        processEnvironment: [String: String],
        identity: ChildEnvironmentIdentity
    ) -> [StoredEnvironmentAssignment] {
        var effective = policy.baseEnvironment(
            processEnvironment: processEnvironment,
            identity: identity
        ).mapValues { StoredEnvironmentValue.literal($0) }
        for key in unsetKeys {
            effective.removeValue(forKey: key)
        }
        for assignment in assignments {
            effective[assignment.key] = assignment.value
        }
        return effective.keys.sorted().compactMap { key in
            effective[key].map {
                StoredEnvironmentAssignment(key: key, value: $0)
            }
        }
    }

    static func effectiveEnvironment(
        _ entries: [LaunchEnvironmentEntry]
    ) -> (
        assignments: [StoredEnvironmentAssignment],
        unsetKeys: Set<String>
    ) {
        var lastEntries: [String: (Int, LaunchEnvironmentOperation)] = [:]
        for (index, entry) in entries.enumerated() {
            lastEntries[entry.name] = (index, entry.operation)
        }
        let ordered = lastEntries.sorted { $0.value.0 < $1.value.0 }
        var assignments: [StoredEnvironmentAssignment] = []
        var unsetKeys: Set<String> = []
        for (key, indexedOperation) in ordered {
            switch indexedOperation.1 {
            case .set(let value):
                assignments.append(
                    StoredEnvironmentAssignment(
                        key: key,
                        value: StoredEnvironmentValue(storedText: value)
                    )
                )
            case .unset:
                unsetKeys.insert(key)
            }
        }
        return (assignments, unsetKeys)
    }

    static func compilerDiagnostic(
        _ diagnostic: LaunchParsingDiagnostic
    ) -> LaunchCompilerDiagnostic {
        let overridable: Bool
        switch diagnostic.code {
        case .unmatchedSingleQuote,
             .unmatchedDoubleQuote,
             .trailingEscape,
             .invalidEnvironmentName,
             .malformedEnvironmentLine:
            overridable = true
        case .unsupportedControlCharacter,
             .blankUserDataDirectory,
             .missingUserDataDirectory,
             .duplicateUserDataDirectory,
             .duplicateEnvironmentName:
            overridable = false
        }
        return LaunchCompilerDiagnostic(
            code: .parsing(diagnostic.code),
            severity: diagnostic.severity,
            isOverridable: overridable,
            sourceRange: diagnostic.range,
            path: nil
        )
    }
}
