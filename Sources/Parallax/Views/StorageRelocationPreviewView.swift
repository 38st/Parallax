import SwiftUI

struct StorageRelocationPreviewView: View {
    @Bindable var store: LibraryStore
    let preview: StorageRelocationPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Storage Location")
                .font(.title2.weight(.semibold))

            Text(
                "Review the canonical locations before moving managed profile and archive data."
            )
            .foregroundStyle(.secondary)

            pathRow(
                title: "Current",
                path: preview.source.canonicalBaseRootURL.path
            )
            pathRow(
                title: "New",
                path: preview.destination.canonicalBaseRootURL.path
            )

            if !preview.isPreparing {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Managed data")
                            .foregroundStyle(.secondary)
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(
                                    clamping: preview.sourceEstimate.allocatedBytes
                                ),
                                countStyle: .file
                            )
                        )
                    }
                    GridRow {
                        Text("Move strategy")
                            .foregroundStyle(.secondary)
                        Text(
                            preview.strategy == .sameVolume
                                ? String(
                                    localized:
                                        "Same-volume copy and verification"
                                )
                                : String(
                                    localized:
                                        "Cross-volume copy and verification"
                                )
                        )
                    }
                    GridRow {
                        Text("Generated paths")
                            .foregroundStyle(.secondary)
                        Text("\(preview.generatedRewrites.count) will be updated")
                    }
                    GridRow {
                        Text("External paths")
                            .foregroundStyle(.secondary)
                        Text("\(preview.preservedExternalPaths.count) will be preserved")
                    }
                }

                if !preview.preservedExternalPaths.isEmpty {
                    Label(
                        "Explicit external CODEX_HOME, CLAUDE_CONFIG_DIR, and user-data locations are not moved or rewritten.",
                        systemImage: "externaldrive"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if !preview.blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Relocation cannot start",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)

                        ForEach(
                            Array(preview.blockers.enumerated()),
                            id: \.offset
                        ) { _, blocker in
                            Text("• \(description(for: blocker))")
                                .font(.callout)
                        }
                    }
                }

            }

            if let progress = store.storageRelocationProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(description(for: progress))
                        .font(.callout)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    store.cancelStorageRelocation(preview)
                }
                Button("Move Storage") {
                    store.beginStorageRelocation(preview)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !preview.blockers.isEmpty || preview.isPreparing
                        || store.isStorageRelocationRunning
                )
            }
        }
        .padding(24)
        .frame(minWidth: 620)
        .interactiveDismissDisabled(store.storageRelocationProgress != nil)
    }

    private func pathRow(title: LocalizedStringKey, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func description(
        for blocker: StorageRelocationBlocker
    ) -> String {
        switch blocker {
        case .sameStorageLocation:
            String(localized: "The selected folder is the current storage location.")
        case .overlappingStorageLocations:
            String(localized: "The current and selected storage locations overlap.")
        case .unexpectedDestination:
            String(localized: "Managed data already exists at the destination.")
        case let .insufficientSpace(required, available):
            String(
                localized: "The destination has \(ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: Int64(clamping: required), countStyle: .file)) is required."
            )
        case .capacityUnavailable:
            String(localized: "Available destination capacity could not be verified.")
        case .unsupportedDestinationPermissions:
            String(localized: "The destination must support POSIX file permissions. Choose a compatible storage volume.")
        case .configuredPathInsideManagedStorage:
            String(localized: "An explicit isolation path points inside the managed data being moved. Update that configuration before relocating storage.")
        case let .profileConfiguration(applicationName, profileName, problem):
            String(localized: "\(applicationName) / \(profileName): \(problem)")
        case let .dependentProfile(applicationName, profileName, path):
            String(localized: "\(applicationName) / \(profileName) uses data inside this storage at \(path). Update that profile before relocating storage.")
        case .unfinishedTransaction:
            StorageRelocationError(.unfinishedTransaction).localizedDescription
        case let .activeProfiles(profileIDs):
            String.localizedStringWithFormat(
                String(localized: "relocation-active-profile-count", defaultValue: "%lld profiles are active. Quit them before moving storage.", bundle: PackagedRuntimeResources.bundle),
                Int64(profileIDs.count)
            )
        }
    }

    private func description(
        for progress: StorageRelocationProgress
    ) -> LocalizedStringKey {
        switch progress {
        case .preparing:
            "Preparing relocation…"
        case .stagingApplication:
            "Copying managed profiles…"
        case .stagingArchives:
            "Copying managed archives…"
        case .publishingApplication:
            "Publishing managed profiles…"
        case .publishingArchives:
            "Publishing managed archives…"
        case .committingMetadata:
            "Updating the library…"
        case .cleaningSource:
            "Removing verified source data…"
        case .rollingBack:
            "Restoring the original storage location…"
        case .completed:
            "Storage relocation completed."
        }
    }
}
