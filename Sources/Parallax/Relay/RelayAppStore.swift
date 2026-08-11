import AppKit
import Foundation
import Observation
import RelayCore
import SwiftUI

struct RelayAppStoreFocusedValueKey: FocusedValueKey {
    typealias Value = RelayAppStore
}

extension FocusedValues {
    var relayAppStore: RelayAppStore? {
        get { self[RelayAppStoreFocusedValueKey.self] }
        set { self[RelayAppStoreFocusedValueKey.self] = newValue }
    }
}

@MainActor
@Observable
final class RelayAppStore {
    private(set) var projections: [RelayProjection] = []
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var failureMessage: String?
    var selection: UUID?
    var intakeDraft = RelayIntakeDraft()
    var isShowingIntake = false

    private let coordinator: RelayCoordinator?
    private let startupFailure: String?

    init(applicationSupportURL: URL?) {
        if let applicationSupportURL {
            coordinator = RelayCoordinator(
                applicationSupportURL: applicationSupportURL
            )
            startupFailure = nil
        } else {
            coordinator = nil
            startupFailure = String(
                localized: "Application Support is unavailable. Relay data was not created."
            )
            failureMessage = startupFailure
        }
    }

    static func production(trustedContainerURL: URL?) -> RelayAppStore {
        RelayAppStore(
            applicationSupportURL:
                trustedContainerURL?.deletingLastPathComponent()
        )
    }

    var presentations: [RelayTaskPresentation] {
        projections.compactMap(RelayPresentationAdapter.make)
    }

    var repositoryValidationMessage: String? {
        let value = intakeDraft.repositoryPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: value,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return String(localized: "The repository folder is unavailable.")
        }
        return nil
    }

    var actions: RelayWorkspaceActions {
        RelayWorkspaceActions(
            newRelay: { [weak self] in self?.showIntake() },
            pause: { _ in },
            resume: { _ in },
            stop: { [weak self] id in self?.stop(id) },
            retry: { _ in },
            recover: { [weak self] _ in self?.reload() },
            approveGate: { _, _ in },
            denyGate: { _, _, _ in }
        )
    }

    func reload() {
        guard let coordinator else {
            failureMessage = startupFailure
            return
        }
        isLoading = true
        Task {
            do {
                projections = try await coordinator.load()
                failureMessage = nil
                if selection == nil { selection = projections.first?.task?.id.rawValue }
            } catch {
                failureMessage = String(
                    format: String(localized: "Relay recovery is blocked: %@"),
                    String(describing: error)
                )
            }
            isLoading = false
        }
    }

    func showIntake() {
        failureMessage = startupFailure
        isShowingIntake = coordinator != nil
    }

    func dismissFailure() {
        failureMessage = nil
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Repository")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        intakeDraft.repositoryPath = url.path
        if intakeDraft.title.isEmpty {
            intakeDraft.title = url.lastPathComponent
        }
    }

    func startRelay() {
        guard let coordinator,
              intakeDraft.canStart,
              repositoryValidationMessage == nil,
              !isSubmitting
        else { return }
        let submitted = intakeDraft
        isSubmitting = true
        Task {
            do {
                let projection = try await coordinator.create(submitted)
                projections = try await coordinator.load()
                selection = projection.task?.id.rawValue
                intakeDraft = RelayIntakeDraft()
                isShowingIntake = false
                failureMessage = nil
            } catch {
                projections = (try? await coordinator.load()) ?? projections
                failureMessage = String(
                    format: String(localized: "Relay could not start: %@"),
                    String(describing: error)
                )
                // Preserve the filled intake form so the user can correct or
                // retry it without reconstructing the task.
            }
            isSubmitting = false
        }
    }

    private func stop(_ rawID: UUID) {
        guard let coordinator else { return }
        Task {
            do {
                _ = try await coordinator.stop(taskID: RelayTaskID(rawID))
                projections = try await coordinator.load()
                failureMessage = nil
            } catch {
                failureMessage = String(
                    format: String(localized: "Relay could not stop safely: %@"),
                    String(describing: error)
                )
            }
        }
    }
}
