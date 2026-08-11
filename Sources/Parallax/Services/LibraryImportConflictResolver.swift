enum LibraryImportConflictResolver {
    static func resolve(
        existing: [LibraryImportApplication],
        imported: [LibraryImportApplication],
        resolutions: [
            LibraryImportConflictID: LibraryImportConflictResolution
        ]
    ) throws -> LibraryImportResolutionResult {
        var working = existing
        var conflicts: [LibraryImportConflict] = []
        var unresolved: [LibraryImportConflictID] = []

        for incoming in imported {
            var matches = LibraryImportConflictMatcher.applications(
                matching: incoming,
                in: working
            )
            guard !matches.isEmpty else {
                working.append(
                    LibraryImportContentTransformer.applicationShell(
                        from: incoming
                    )
                )
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: working.index(before: working.endIndex),
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            let selectedIndex = matches[0].index
            let selected = working[selectedIndex]
            let fieldDifferences = LibraryImportConflictFieldDiffer
                .application(selected, incoming)
            if !fieldDifferences.isEmpty {
                matches[0].reasons.insert(
                    .applicationFields(fieldDifferences)
                )
            }
            if matches.count > 1 {
                matches[0].reasons.insert(.ambiguousApplicationMatch)
            }

            if !LibraryImportConflictMatcher.requiresApplicationDecision(
                matches: matches,
                fieldDifferences: fieldDifferences
            ),
               incoming.application.id == selected.application.id,
               incoming.application.storageID
                    == selected.application.storageID
            {
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: selectedIndex,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            let conflict = LibraryImportConflictMatcher.applicationConflict(
                incoming: incoming,
                matches: matches,
                working: working
            )
            conflicts.append(conflict)
            guard let externalResolution = resolutions[conflict.id] else {
                unresolved.append(conflict.id)
                // Provisional keep-existing lets preview discover later
                // profile/batch conflicts without publishing partial state.
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: selectedIndex,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            let decision = try LibraryImportScopedDecision.application(
                externalResolution
            )
            if let destination = try LibraryImportConflictResolutionApplier
                .applyApplication(
                    decision,
                    incoming: incoming,
                    matches: matches,
                    working: &working
                )
            {
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: destination,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
            }
        }

        return LibraryImportResolutionResult(
            conflicts: conflicts,
            unresolvedConflictIDs: unresolved,
            applications: unresolved.isEmpty
                ? working.map(\.application)
                : nil,
            projectedApplications: working.map(\.application)
        )
    }

    private static func mergeProfiles(
        from incoming: LibraryImportApplication,
        intoApplicationAt destinationIndex: Int,
        working: inout [LibraryImportApplication],
        resolutions: [
            LibraryImportConflictID: LibraryImportConflictResolution
        ],
        conflicts: inout [LibraryImportConflict],
        unresolved: inout [LibraryImportConflictID]
    ) throws {
        for importedProfile in incoming.application.profiles {
            let matches = LibraryImportConflictMatcher.profiles(
                matching: importedProfile,
                destinationIndex: destinationIndex,
                in: working
            )
            guard !matches.isEmpty else {
                LibraryImportConflictResolutionApplier.appendImportedProfile(
                    importedProfile,
                    destinationIndex: destinationIndex,
                    working: &working
                )
                continue
            }

            if matches.count == 1 {
                let location = matches[0].location
                let existingProfile = working[location.applicationIndex]
                    .application.profiles[location.profileIndex]
                if LibraryImportConflictFieldDiffer.profile(
                    existingProfile,
                    importedProfile
                ).isEmpty {
                    continue
                }
            }

            let conflict = LibraryImportConflictMatcher.profileConflict(
                importedApplicationID: incoming.application.id,
                importedProfile: importedProfile,
                matches: matches,
                working: working
            )
            conflicts.append(conflict)
            guard let externalResolution = resolutions[conflict.id] else {
                unresolved.append(conflict.id)
                continue
            }
            let decision = try LibraryImportScopedDecision.profile(
                externalResolution
            )
            try LibraryImportConflictResolutionApplier.applyProfile(
                decision,
                importedProfile: importedProfile,
                destinationIndex: destinationIndex,
                matches: matches,
                working: &working
            )
        }
    }
}
