import SwiftUI

struct LibraryImportConflictResolutionView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resolve Import Conflict")
                .font(.title2)
                .fontWeight(.semibold)

            Text(
                store.pendingImportConflictMessage
                    ?? "Choose how to resolve this imported item."
            )

            if store.pendingImportConflictTargets.isEmpty {
                Text("No matching existing target is available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.pendingImportConflictTargets) { target in
                    GroupBox(target.label) {
                        HStack {
                            Button("Keep Existing") {
                                store.resolvePendingImportConflict(
                                    .keepExisting,
                                    target: target
                                )
                            }
                            Button("Use Imported") {
                                store.resolvePendingImportConflict(
                                    .useImported,
                                    target: target
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Divider()

            HStack {
                Button("Keep Both (Rename Imported)") {
                    store.resolvePendingImportConflict(.keepBoth)
                }
                Button("Skip Imported Item") {
                    store.resolvePendingImportConflict(.skip)
                }
                Spacer()
                Button("Cancel Import", role: .cancel) {
                    store.cancelImport()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600)
    }
}

struct ImportedLaunchReviewView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Imported Launch Configuration")
                .font(.title2)
                .fontWeight(.semibold)

            if let review = store.pendingImportedLaunchReview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        applicationSection(review)
                        argumentsSection(review)
                        environmentSection(review)
                        isolationSection(review)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 340)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.cancelImportedLaunchReview()
                }
                Button("Approve and Launch") {
                    store.confirmImportedLaunchReview()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 500)
    }

    @ViewBuilder
    private func applicationSection(
        _ review: ImportedLaunchReview
    ) -> some View {
        GroupBox("Application and Profile") {
            VStack(alignment: .leading, spacing: 5) {
                Text(review.application.displayName)
                Text(review.application.canonicalPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Profile: \(review.profileName)")
                Text(
                    "Expected bundle: \(review.application.expectedBundleIdentifier ?? "Not recorded")"
                )
                Text(
                    "Verified bundle: \(review.application.verifiedBundleIdentifier ?? "Not verified")"
                )
                Text("Managed base: \(review.configuredBaseRoot)")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func argumentsSection(
        _ review: ImportedLaunchReview
    ) -> some View {
        GroupBox("Arguments") {
            if review.arguments.isEmpty {
                Text("No arguments")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(review.arguments.enumerated()),
                    id: \.offset
                ) { _, argument in
                    Text(argument)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func environmentSection(
        _ review: ImportedLaunchReview
    ) -> some View {
        GroupBox("Environment Keys (values are never shown)") {
            if review.environmentEntries.isEmpty {
                Text("No environment changes")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(review.environmentEntries.enumerated()),
                    id: \.offset
                ) { _, entry in
                    HStack {
                        Text(entry.key)
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced
                                )
                            )
                        Text(entry.operation.rawValue)
                            .foregroundStyle(.secondary)
                        if !entry.risks.isEmpty {
                            Text(
                                entry.risks.map(\.rawValue)
                                    .joined(separator: ", ")
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            if review.inheritsCompleteProcessEnvironment {
                Label(
                    "Advanced process-environment inheritance is enabled.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func isolationSection(
        _ review: ImportedLaunchReview
    ) -> some View {
        GroupBox("Isolation Paths") {
            if review.isolationPaths.isEmpty {
                Text("No validated isolation paths")
                    .foregroundStyle(.orange)
            } else {
                ForEach(
                    Array(review.isolationPaths.enumerated()),
                    id: \.offset
                ) { _, path in
                    VStack(alignment: .leading) {
                        Text(
                            "\(path.role.rawValue): \(path.authority.rawValue)"
                        )
                        Text(path.canonicalPath)
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced
                                )
                            )
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
