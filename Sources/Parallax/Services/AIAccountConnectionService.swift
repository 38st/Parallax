import AppKit
import CoreFoundation
import Foundation
import os

enum AIAccountConnectionService {
    static func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .userInitiated) {
            switch provider {
            case .codex:
                return try await runCodexLogin(accountID: accountID)
            case .claude:
                let configDirectory = try claudeConfig(accountID: accountID)
                try await runClaudeLogin(configDirectory: configDirectory)
                return try await readClaudeStatus(
                    configDirectory: configDirectory
                )
            }
        }
    }

    static func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .utility) {
            switch provider {
            case .codex:
                try await readCodexStatus(accountID: accountID)
            case .claude:
                try await readClaudeStatus(
                    configDirectory: claudeConfig(accountID: accountID)
                )
            }
        }
    }

    static func accountSessionDirectory(
        accountID: UUID,
        component: String,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let base: URL
        if let applicationSupportURL {
            base = applicationSupportURL
        } else {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        guard component == "ClaudeConfig" || component == "CodexHome" else {
            throw AIAccountConnectionError.statusUnavailable
        }
        let directory = base
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("AccountSessions", isDirectory: true)
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    static func trustedExecutable(
        named name: String
    ) throws -> TrustedProviderExecutable {
        do {
            return try ProviderExecutableLocator().locate(named: name)
        } catch {
            throw AIAccountConnectionError.executableMissing(name.capitalized)
        }
    }

    private static func runCancellableWorker<T: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
