import Foundation
import Observation

struct LibraryEditBaseline: Hashable, Sendable {
    let containerID: UUID?
    let targetID: UUID
    let storageID: UUID
    let libraryRevision: LibraryRevision
    let libraryFingerprint: String?

    init(
        containerID: UUID? = nil,
        targetID: UUID,
        storageID: UUID,
        libraryVersion: LibraryVersionToken
    ) {
        self.containerID = containerID
        self.targetID = targetID
        self.storageID = storageID
        libraryRevision = libraryVersion.revision
        libraryFingerprint = libraryVersion.primarySHA256
    }
}

struct LibraryEditPersistenceFailure:
    LocalizedError,
    Equatable,
    Sendable
{
    let message: String

    var errorDescription: String? {
        message
    }
}

enum LibraryEditApplyResult<Field>: Equatable, Sendable
where Field: Hashable & Sendable {
    case applied(version: LibraryVersionToken)
    case noChanges(version: LibraryVersionToken)
    case conflicts(Set<Field>)
    case targetChanged
    case persistenceFailed(LibraryEditPersistenceFailure)
}

enum ManagedApplicationEditField:
    String,
    CaseIterable,
    Hashable,
    Sendable
{
    case displayName
    case bundleIdentifier
    case appPath
    case preset
}

struct ManagedApplicationEditDraft: Equatable, Sendable {
    var displayName: String
    var bundleIdentifier: String?
    var appPath: String
    var preset: AppPreset

    init(application: ManagedApplication) {
        displayName = application.displayName
        bundleIdentifier = application.bundleIdentifier
        appPath = application.appPath
        preset = application.preset
    }
}

@Observable
@MainActor
final class ManagedApplicationEditSession {
    let origin: LibraryEditBaseline
    var draft: ManagedApplicationEditDraft
    private(set) var lastPersistenceFailure:
        LibraryEditPersistenceFailure?
    private(set) var baselineVersion: LibraryVersionToken

    @ObservationIgnored
    private var baseline: ManagedApplication

    init(
        application: ManagedApplication,
        libraryVersion: LibraryVersionToken
    ) {
        origin = LibraryEditBaseline(
            targetID: application.id,
            storageID: application.storageID,
            libraryVersion: libraryVersion
        )
        baseline = application
        baselineVersion = libraryVersion
        draft = ManagedApplicationEditDraft(application: application)
        lastPersistenceFailure = nil
    }

    var dirtyFields: Set<ManagedApplicationEditField> {
        var fields = Set<ManagedApplicationEditField>()
        if draft.displayName != baseline.displayName {
            fields.insert(.displayName)
        }
        if draft.bundleIdentifier != baseline.bundleIdentifier {
            fields.insert(.bundleIdentifier)
        }
        if draft.appPath != baseline.appPath {
            fields.insert(.appPath)
        }
        if draft.preset != baseline.preset {
            fields.insert(.preset)
        }
        return fields
    }

    var isDirty: Bool {
        !dirtyFields.isEmpty
    }

    func cancel() {
        draft = ManagedApplicationEditDraft(application: baseline)
        lastPersistenceFailure = nil
    }

    func apply(
        to latest: ManagedApplication,
        libraryVersion: LibraryVersionToken,
        persist: (
            _ merged: ManagedApplication,
            _ expectedVersion: LibraryVersionToken
        ) throws -> (
            persisted: ManagedApplication,
            version: LibraryVersionToken
        )
    ) -> LibraryEditApplyResult<ManagedApplicationEditField> {
        guard latest.id == origin.targetID,
              latest.storageID == origin.storageID
        else {
            return .targetChanged
        }

        let locallyDirty = dirtyFields
        guard !locallyDirty.isEmpty else {
            accept(latest, version: libraryVersion)
            return .noChanges(version: libraryVersion)
        }

        var merged = latest
        var conflicts = Set<ManagedApplicationEditField>()

        merge(
            .displayName,
            baseline: baseline.displayName,
            local: draft.displayName,
            latest: latest.displayName,
            conflicts: &conflicts
        ) {
            merged.displayName = $0
        }
        merge(
            .bundleIdentifier,
            baseline: baseline.bundleIdentifier,
            local: draft.bundleIdentifier,
            latest: latest.bundleIdentifier,
            conflicts: &conflicts
        ) {
            merged.bundleIdentifier = $0
        }
        merge(
            .appPath,
            baseline: baseline.appPath,
            local: draft.appPath,
            latest: latest.appPath,
            conflicts: &conflicts
        ) {
            merged.appPath = $0
        }
        merge(
            .preset,
            baseline: baseline.preset,
            local: draft.preset,
            latest: latest.preset,
            conflicts: &conflicts
        ) {
            merged.preset = $0
        }

        guard conflicts.isEmpty else {
            return .conflicts(conflicts)
        }

        if merged.appPath != latest.appPath
            || merged.bundleIdentifier != latest.bundleIdentifier
        {
            for index in merged.profiles.indices
            where merged.profiles[index].launchConfigurationTrust.isImported {
                merged.profiles[index].markLaunchConfigurationImported()
            }
        }

        do {
            let receipt = try persist(merged, libraryVersion)
            guard receipt.persisted.id == origin.targetID,
                  receipt.persisted.storageID == origin.storageID
            else {
                let failure = LibraryEditPersistenceFailure(
                    message: String(
                        localized:
                            "The saved application no longer has the edit session's storage identity."
                    )
                )
                lastPersistenceFailure = failure
                return .persistenceFailed(failure)
            }
            accept(receipt.persisted, version: receipt.version)
            return .applied(version: receipt.version)
        } catch {
            let failure = LibraryEditPersistenceFailure(
                message: error.localizedDescription
            )
            lastPersistenceFailure = failure
            return .persistenceFailed(failure)
        }
    }

    private func accept(
        _ application: ManagedApplication,
        version: LibraryVersionToken
    ) {
        baseline = application
        baselineVersion = version
        draft = ManagedApplicationEditDraft(application: application)
        lastPersistenceFailure = nil
    }
}

enum LaunchProfileEditField:
    String,
    CaseIterable,
    Hashable,
    Sendable
{
    case name
    case argumentsText
    case environmentText
    case notes
    case isolationOwnership
    case childEnvironmentPolicy
    case sensitiveEnvironmentKeys
}

struct LaunchProfileEditDraft: Equatable, Sendable {
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String
    var isolationOwnership: ProfileIsolationOwnership
    var childEnvironmentPolicy: ChildEnvironmentPolicy
    var sensitiveEnvironmentKeys: [String]

    init(profile: LaunchProfile) {
        name = profile.name
        argumentsText = profile.argumentsText
        environmentText = profile.environmentText
        notes = profile.notes
        isolationOwnership = profile.isolationOwnership
        childEnvironmentPolicy = profile.childEnvironmentPolicy
        sensitiveEnvironmentKeys = Self.normalized(
            profile.sensitiveEnvironmentKeys
        )
    }

    fileprivate static func normalized(_ keys: [String]) -> [String] {
        Array(Set(keys)).sorted()
    }
}

@Observable
@MainActor
final class LaunchProfileEditSession {
    let origin: LibraryEditBaseline
    var draft: LaunchProfileEditDraft
    private(set) var lastPersistenceFailure:
        LibraryEditPersistenceFailure?
    private(set) var baselineVersion: LibraryVersionToken

    @ObservationIgnored
    private var baseline: LaunchProfile

    init(
        applicationID: UUID,
        profile: LaunchProfile,
        libraryVersion: LibraryVersionToken
    ) {
        origin = LibraryEditBaseline(
            containerID: applicationID,
            targetID: profile.id,
            storageID: profile.storageID,
            libraryVersion: libraryVersion
        )
        baseline = profile
        baselineVersion = libraryVersion
        draft = LaunchProfileEditDraft(profile: profile)
        lastPersistenceFailure = nil
    }

    var dirtyFields: Set<LaunchProfileEditField> {
        var fields = Set<LaunchProfileEditField>()
        if draft.name != baseline.name {
            fields.insert(.name)
        }
        if draft.argumentsText != baseline.argumentsText {
            fields.insert(.argumentsText)
        }
        if draft.environmentText != baseline.environmentText {
            fields.insert(.environmentText)
        }
        if draft.notes != baseline.notes {
            fields.insert(.notes)
        }
        if draft.isolationOwnership != baseline.isolationOwnership {
            fields.insert(.isolationOwnership)
        }
        if draft.childEnvironmentPolicy
            != baseline.childEnvironmentPolicy
        {
            fields.insert(.childEnvironmentPolicy)
        }
        if LaunchProfileEditDraft.normalized(
            draft.sensitiveEnvironmentKeys
        ) != LaunchProfileEditDraft.normalized(
            baseline.sensitiveEnvironmentKeys
        ) {
            fields.insert(.sensitiveEnvironmentKeys)
        }
        return fields
    }

    var isDirty: Bool {
        !dirtyFields.isEmpty
    }

    func cancel() {
        draft = LaunchProfileEditDraft(profile: baseline)
        lastPersistenceFailure = nil
    }

    func apply(
        to latest: LaunchProfile,
        in applicationID: UUID,
        libraryVersion: LibraryVersionToken,
        persist: (
            _ merged: LaunchProfile,
            _ expectedVersion: LibraryVersionToken
        ) throws -> (
            persisted: LaunchProfile,
            version: LibraryVersionToken
        )
    ) -> LibraryEditApplyResult<LaunchProfileEditField> {
        guard applicationID == origin.containerID,
              latest.id == origin.targetID,
              latest.storageID == origin.storageID
        else {
            return .targetChanged
        }

        let locallyDirty = dirtyFields
        guard !locallyDirty.isEmpty else {
            accept(latest, version: libraryVersion)
            return .noChanges(version: libraryVersion)
        }

        var merged = latest
        var conflicts = Set<LaunchProfileEditField>()

        merge(
            .name,
            baseline: baseline.name,
            local: draft.name,
            latest: latest.name,
            conflicts: &conflicts
        ) {
            merged.name = $0
        }
        merge(
            .argumentsText,
            baseline: baseline.argumentsText,
            local: draft.argumentsText,
            latest: latest.argumentsText,
            conflicts: &conflicts
        ) {
            merged.argumentsText = $0
        }
        merge(
            .environmentText,
            baseline: baseline.environmentText,
            local: draft.environmentText,
            latest: latest.environmentText,
            conflicts: &conflicts
        ) {
            merged.environmentText = $0
        }
        merge(
            .notes,
            baseline: baseline.notes,
            local: draft.notes,
            latest: latest.notes,
            conflicts: &conflicts
        ) {
            merged.notes = $0
        }
        merge(
            .isolationOwnership,
            baseline: baseline.isolationOwnership,
            local: draft.isolationOwnership,
            latest: latest.isolationOwnership,
            conflicts: &conflicts
        ) {
            merged.isolationOwnership = $0
        }
        merge(
            .childEnvironmentPolicy,
            baseline: baseline.childEnvironmentPolicy,
            local: draft.childEnvironmentPolicy,
            latest: latest.childEnvironmentPolicy,
            conflicts: &conflicts
        ) {
            merged.childEnvironmentPolicy = $0
        }
        merge(
            .sensitiveEnvironmentKeys,
            baseline: LaunchProfileEditDraft.normalized(
                baseline.sensitiveEnvironmentKeys
            ),
            local: LaunchProfileEditDraft.normalized(
                draft.sensitiveEnvironmentKeys
            ),
            latest: LaunchProfileEditDraft.normalized(
                latest.sensitiveEnvironmentKeys
            ),
            conflicts: &conflicts
        ) {
            merged.sensitiveEnvironmentKeys = $0
        }

        guard conflicts.isEmpty else {
            return .conflicts(conflicts)
        }

        do {
            let receipt = try persist(merged, libraryVersion)
            guard receipt.persisted.id == origin.targetID,
                  receipt.persisted.storageID == origin.storageID
            else {
                let failure = LibraryEditPersistenceFailure(
                    message: String(
                        localized:
                            "The saved profile no longer has the edit session's storage identity."
                    )
                )
                lastPersistenceFailure = failure
                return .persistenceFailed(failure)
            }
            accept(receipt.persisted, version: receipt.version)
            return .applied(version: receipt.version)
        } catch {
            let failure = LibraryEditPersistenceFailure(
                message: error.localizedDescription
            )
            lastPersistenceFailure = failure
            return .persistenceFailed(failure)
        }
    }

    private func accept(
        _ profile: LaunchProfile,
        version: LibraryVersionToken
    ) {
        baseline = profile
        baselineVersion = version
        draft = LaunchProfileEditDraft(profile: profile)
        lastPersistenceFailure = nil
    }
}

private func merge<Field, Value>(
    _ field: Field,
    baseline: Value,
    local: Value,
    latest: Value,
    conflicts: inout Set<Field>,
    apply: (Value) -> Void
) where Field: Hashable, Value: Equatable {
    guard local != baseline else { return }
    if latest != baseline && latest != local {
        conflicts.insert(field)
    } else {
        apply(local)
    }
}
