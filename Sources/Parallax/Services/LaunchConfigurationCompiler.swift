import Foundation

struct LaunchConfigurationCompiler: Sendable {
    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    private let healthService: LaunchHealthService
    private let identity: ChildEnvironmentIdentity
    private let processEnvironment: [String: String]
    private let secretResolver: any SecretResolving
    var enrollPreparedStorage: (@Sendable (LaunchConfigurationSource, ResolvedProfilePaths) async -> Void)?
    private let preparationHook: @Sendable () async throws -> Void

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        pathResolver: ManagedPathResolver? = nil,
        writeAccess: any PathWriteAccessChecking =
            POSIXPathWriteAccessChecker(),
        activityProvider: any ProfileHealthActivityProviding =
            NoProfileHealthActivityProvider(),
        identity: ChildEnvironmentIdentity = .current,
        processEnvironment: [String: String] =
            ProcessInfo.processInfo.environment,
        secretResolver: any SecretResolving = KeychainSecretStore(),
        preparationHook:
            @escaping @Sendable () async throws -> Void = {}
    ) {
        self.fileSystem = fileSystem
        self.pathResolver = pathResolver ?? ManagedPathResolver(fileSystem: fileSystem)
        healthService = LaunchHealthService(
            fileSystem: fileSystem,
            pathResolver: self.pathResolver,
            writeAccess: writeAccess,
            activityProvider: activityProvider
        )
        self.identity = identity
        self.processEnvironment = processEnvironment
        self.secretResolver = secretResolver
        self.preparationHook = preparationHook
    }

    func analyze(_ source: LaunchConfigurationSource) async -> LaunchAnalysis {
        await Task.detached {
            analysisContext(for: source).analysis
        }.value
    }

    nonisolated static func configurationFingerprint(
        for source: LaunchConfigurationSource
    ) -> LaunchConfigurationFingerprint {
        LaunchConfigurationFingerprintFactory.fingerprint(source)
    }

    func prepare(
        _ source: LaunchConfigurationSource,
        override: LaunchDiagnosticOverride? = nil
    ) async throws -> PreparedLaunch {
        let task = Task.detached {
            try Task.checkCancellation()
            let context = analysisContext(for: source)
            try LaunchPreparationValidator.validate(
                context.analysis,
                override: override
            )

            try await preparationHook()
            try Task.checkCancellation()

            let environment = try await LaunchEnvironmentPreparer(
                policy: source.childEnvironmentPolicy,
                identity: identity,
                processEnvironment: processEnvironment,
                secretResolver: secretResolver
            ).prepare(
                context.assignments,
                unsetKeys: context.unsetKeys
            )
            try Task.checkCancellation()

            if let managedPaths = context.managedPaths {
                try LaunchManagedDirectoryPreparer(
                    pathResolver: pathResolver
                ).prepare(
                    context.directoryPreparationPlan,
                    managedPaths: managedPaths,
                    applicationStorageID: source.applicationStorageID
                )
            }
            try Task.checkCancellation()

            let arguments = LaunchConfigurationProjection.preparedArguments(
                context.analysis.argumentResult.words,
                resolution: context.analysis.userDataResolution,
                isolation: context.analysis.isolation
            )
            guard
                let canonicalApplicationURL =
                    context.analysis.applicationHealth
                        .canonicalApplicationURL,
                let bundleIdentifier =
                    context.analysis.applicationHealth.bundleIdentifier,
                !bundleIdentifier.isEmpty
            else {
                throw LaunchPreparationError.blocked(
                    context.analysis.diagnostics
                )
            }
            if let managedPaths = context.managedPaths {
                await enrollPreparedStorage?(source, managedPaths)
            }
            try Task.checkCancellation()
            return PreparedLaunch(
                requestID: source.requestID,
                applicationID: source.applicationID,
                applicationStorageID: source.applicationStorageID,
                profileID: source.profileID,
                profileStorageID: source.profileStorageID,
                applicationIdentity: WorkspaceApplicationBundleIdentity(
                    bundleURL: canonicalApplicationURL,
                    bundleIdentifier: bundleIdentifier
                ),
                arguments: arguments,
                environment: environment,
                isolation: PreparedLaunchIsolation(
                    userDataURL: context.analysis.isolation.userDataURL,
                    codexHomeURL: context.analysis.isolation.codexHomeURL,
                    managesUserData:
                        context.analysis.isolation.userData?.isManaged ?? false,
                    managesCodexHome:
                        context.analysis.isolation.codexHome?.isManaged ?? false,
                    managedFirefoxProfileURL: context.analysis.isolation.presetFolders[.firefoxProfile]
                        .flatMap { $0.isManaged ? $0.url : nil },
                    verifiesUserData: source.preset != .firefox
                ),
                configurationFingerprint:
                    context.analysis.configurationFingerprint
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func analysisContext(
        for source: LaunchConfigurationSource
    ) -> LaunchConfigurationAnalysisContext {
        LaunchConfigurationAnalyzer(
            pathResolver: pathResolver,
            healthService: healthService,
            identity: identity,
            processEnvironment: processEnvironment
        ).analyze(for: source)
    }
}
