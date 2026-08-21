import AppKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

/// A disposable, uniquely identified AppKit application used only for real
/// Launch Services integration tests. It never resolves or launches an
/// installed user application.
@MainActor
final class ProductionLaunchApplicationFixture {
    enum Mode: String {
        case created
        case selfExit = "self-exit"
        case singleton
        case activationCapable = "activation-capable"
        case cooperativeQuit = "cooperative-quit"
    }

    struct JournalEvent: Decodable, Equatable {
        let event: String
        let processIdentifier: pid_t
        let arguments: [String]
        let environmentValue: String?
        let bundlePath: String
        let bundleIdentifier: String
        let startTimeSeconds: UInt64
        let startTimeMicroseconds: UInt64

        private enum CodingKeys: String, CodingKey {
            case event
            case processIdentifier = "pid"
            case arguments
            case environmentValue
            case bundlePath
            case bundleIdentifier
            case startTimeSeconds
            case startTimeMicroseconds
        }
    }

    let mode: Mode
    let rootURL: URL
    let applicationURL: URL
    let bundleIdentifier: String
    let journalURL: URL
    private var directlyLaunchedProcesses: [pid_t: Process] = [:]

    private init(
        mode: Mode,
        rootURL: URL,
        applicationURL: URL,
        bundleIdentifier: String,
        journalURL: URL
    ) {
        self.mode = mode
        self.rootURL = rootURL
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.journalURL = journalURL
    }

    static func build(
        mode: Mode,
        compilerExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        compilerArgumentsOverride: [String]? = nil,
        compilerTimeout: TimeInterval = 15,
        suffixOverride: String? = nil
    ) throws -> ProductionLaunchApplicationFixture {
        let suffix = suffixOverride
            ?? UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-production-adapter-fixture.\(suffix)",
            isDirectory: true
        )
        let application = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let bundleIdentifier = "dev.parallax.production-adapter.\(suffix)"
        let journal = root.appendingPathComponent("journal.jsonl")
        var buildSucceeded = false
        defer {
            if !buildSucceeded {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "ProductionLaunchFixture",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Parallax Production Adapter Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": false,
            "LSMultipleInstancesProhibited": mode == .singleton,
            "NSPrincipalClass": "NSApplication",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let sourceURL = root.appendingPathComponent("main.m")
        try objectiveCSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        let executable = macOS.appendingPathComponent("ProductionLaunchFixture")
        let compiler = Process()
        compiler.executableURL = compilerExecutableURL
        let compilerArguments = [
            "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra",
            "-Werror", "-framework", "AppKit", sourceURL.path,
            "-o", executable.path,
        ]
        compiler.arguments = compilerArgumentsOverride ?? compilerArguments
        let compilerErrorURL = root.appendingPathComponent("compiler.stderr")
        FileManager.default.createFile(atPath: compilerErrorURL.path, contents: nil)
        let compilerError = try FileHandle(forWritingTo: compilerErrorURL)
        compiler.standardError = compilerError
        let compilerFinished = DispatchSemaphore(value: 0)
        compiler.terminationHandler = { _ in compilerFinished.signal() }
        try compiler.run()
        if compilerFinished.wait(timeout: .now() + compilerTimeout) == .timedOut {
            compiler.terminate()
            if compilerFinished.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(compiler.processIdentifier, SIGKILL)
                guard compilerFinished.wait(timeout: .now() + 1) == .success else {
                    throw ProductionLaunchApplicationFixtureError
                        .compilerTerminationTimedOut
                }
            }
            compiler.waitUntilExit()
            try compilerError.close()
            throw ProductionLaunchApplicationFixtureError.compilationTimedOut
        }
        compiler.waitUntilExit()
        try compilerError.close()
        guard compiler.terminationStatus == 0 else {
            let data = try Data(contentsOf: compilerErrorURL)
            let message = String(decoding: data, as: UTF8.self)
            throw ProductionLaunchApplicationFixtureError.compilationFailed(message)
        }

        let fixture = ProductionLaunchApplicationFixture(
            mode: mode,
            rootURL: root,
            applicationURL: application,
            bundleIdentifier: bundleIdentifier,
            journalURL: journal
        )
        buildSucceeded = true
        return fixture
    }

    func managedApplication(profiles: [LaunchProfile]) -> ManagedApplication {
        ManagedApplication(
            displayName: "Production Adapter Fixture",
            bundleIdentifier: bundleIdentifier,
            appPath: applicationURL.path,
            preset: .custom,
            baseStoragePath: rootURL.path,
            profiles: profiles
        )
    }

    func preparedLaunch(
        application: ManagedApplication,
        profile: LaunchProfile,
        arguments: [String],
        environmentValue: String
    ) -> PreparedLaunch {
        PreparedLaunch(
            requestID: UUID(),
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            applicationIdentity: WorkspaceApplicationBundleIdentity(
                bundleURL: applicationURL,
                bundleIdentifier: bundleIdentifier
            ),
            arguments: arguments,
            environment: [
                "PARALLAX_FIXTURE_MODE": mode.rawValue,
                "PARALLAX_FIXTURE_JOURNAL": journalURL.path,
                "PARALLAX_FIXTURE_VALUE": environmentValue,
            ],
            isolation: PreparedLaunchIsolation(
                userDataURL: nil,
                codexHomeURL: nil,
                managesUserData: false,
                managesCodexHome: false
            ),
            configurationFingerprint: LaunchConfigurationFingerprint(
                digest: "production-adapter-\(UUID().uuidString)"
            )
        )
    }

    func openPreexisting(
        arguments: [String],
        environmentValue: String
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.arguments = arguments
        configuration.environment = [
            "PARALLAX_FIXTURE_MODE": mode.rawValue,
            "PARALLAX_FIXTURE_JOURNAL": journalURL.path,
            "PARALLAX_FIXTURE_VALUE": environmentValue,
        ]
        return try await awaitOpen(timeout: .seconds(10)) { completion in
            NSWorkspace.shared.openApplication(
                at: self.applicationURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }

    func awaitOpen(
        timeout: Duration,
        operation: @escaping @MainActor (
            @escaping @Sendable (NSRunningApplication?, Error?) -> Void
        ) -> Void
    ) async throws -> NSRunningApplication {
        let gate = ProductionLaunchOpenGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            operation { application, error in
                if let error {
                    gate.resume(.failure(error))
                } else if let application {
                    gate.resume(.success(application))
                } else {
                    gate.resume(
                        .failure(
                            ProductionLaunchApplicationFixtureError.openReturnedNil
                        )
                    )
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(
                    .failure(
                        ProductionLaunchApplicationFixtureError.openTimedOut
                    )
                )
            }
        }
    }

    func launchUnregistered(
        arguments: [String],
        environmentValue: String
    ) throws -> Process {
        let process = Process()
        process.executableURL = applicationURL
            .appendingPathComponent("Contents/MacOS/ProductionLaunchFixture")
        process.arguments = arguments
        process.environment = [
            "PARALLAX_FIXTURE_MODE": "unregistered",
            "PARALLAX_FIXTURE_JOURNAL": journalURL.path,
            "PARALLAX_FIXTURE_VALUE": environmentValue,
        ]
        try process.run()
        directlyLaunchedProcesses[process.processIdentifier] = process
        return process
    }

    func journalEvents() throws -> [JournalEvent] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        return try String(contentsOf: journalURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                try JSONDecoder().decode(JournalEvent.self, from: Data(line.utf8))
            }
    }

    func wait(
        description: String = "condition",
        timeout: Duration = .seconds(8),
        until predicate: @escaping @MainActor () throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProductionLaunchApplicationFixtureError.timedOut(description)
    }

    func cleanup() async throws {
        let inspector = SystemProcessIdentityInspector()
        let exactApplications = exactRunningApplications()
        var capturedTargets = Dictionary(
            uniqueKeysWithValues: exactApplications.compactMap { application in
                switch inspector.inspect(
                    processIdentifier: application.processIdentifier
                ) {
                case .live(let identity):
                    (application.processIdentifier, identity)
                case .dead, .ambiguous:
                    nil
                }
            }
        )
        for event in try journalEvents() where event.event == "launched" {
            guard event.bundleIdentifier == bundleIdentifier,
                  canonical(URL(fileURLWithPath: event.bundlePath))
                    == canonical(applicationURL)
            else {
                throw ProductionLaunchApplicationFixtureError.cleanupFailed
            }
            capturedTargets[event.processIdentifier] = ProcessStartIdentity(
                processIdentifier: event.processIdentifier,
                startTimeSeconds: event.startTimeSeconds,
                startTimeMicroseconds: event.startTimeMicroseconds
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for application in exactApplications {
            _ = application.terminate()
        }
        while hasLiveExactTarget(capturedTargets, inspector: inspector),
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        for signal in [SIGTERM, SIGKILL] {
            guard hasLiveExactTarget(capturedTargets, inspector: inspector) else {
                break
            }
            for expected in capturedTargets.values {
                if case .live(let current) = inspector.inspect(
                    processIdentifier: expected.processIdentifier
                ), current == expected {
                    _ = Darwin.kill(expected.processIdentifier, signal)
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        for process in directlyLaunchedProcesses.values where !process.isRunning {
            process.waitUntilExit()
        }

        // Launch Services can keep a terminated fixture visible briefly after
        // the kernel has reaped it, especially under coverage instrumentation.
        // Wait for that registration to converge before judging cleanup.
        let registrationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while targetsAreDeadOrRebound(capturedTargets, inspector: inspector),
              !exactRunningApplications().isEmpty,
              ContinuousClock.now < registrationDeadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard targetsAreDeadOrRebound(capturedTargets, inspector: inspector),
              exactRunningApplications().isEmpty
        else {
            throw ProductionLaunchApplicationFixtureError.cleanupFailed
        }
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        directlyLaunchedProcesses.removeAll()
    }

    func exactRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && isExact($0)
        }
    }

    private func hasLiveExactTarget(
        _ targets: [pid_t: ProcessStartIdentity],
        inspector: SystemProcessIdentityInspector
    ) -> Bool {
        targets.values.contains { expected in
            if case .live(let current) = inspector.inspect(
                processIdentifier: expected.processIdentifier
            ) {
                return current == expected
            }
            return false
        }
    }

    private func targetsAreDeadOrRebound(
        _ targets: [pid_t: ProcessStartIdentity],
        inspector: SystemProcessIdentityInspector
    ) -> Bool {
        targets.values.allSatisfy { expected in
            switch inspector.inspect(processIdentifier: expected.processIdentifier) {
            case .dead:
                true
            case .live(let current):
                current != expected
            case .ambiguous:
                false
            }
        }
    }

    private func isExact(_ application: NSRunningApplication) -> Bool {
        guard application.bundleIdentifier == bundleIdentifier,
              let bundleURL = application.bundleURL
        else { return false }
        return canonical(bundleURL) == canonical(applicationURL)
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static let objectiveCSource = #"""
    #import <AppKit/AppKit.h>
    #import <fcntl.h>
    #import <libproc.h>
    #import <unistd.h>

    @interface FixtureDelegate : NSObject <NSApplicationDelegate>
    @property(nonatomic, strong) NSWindow *window;
    @end

    @implementation FixtureDelegate
    - (void)record:(NSString *)event {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *journal = environment[@"PARALLAX_FIXTURE_JOURNAL"];
        if (journal.length == 0) { return; }
        struct proc_bsdinfo info = {0};
        int infoSize = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        if (infoSize != sizeof(info)) { _exit(70); }
        NSDictionary *record = @{
            @"event": event,
            @"pid": @(getpid()),
            @"arguments": NSProcessInfo.processInfo.arguments,
            @"environmentValue": environment[@"PARALLAX_FIXTURE_VALUE"] ?: [NSNull null],
            @"bundlePath": NSBundle.mainBundle.bundleURL.path ?: @"",
            @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"startTimeSeconds": @(info.pbi_start_tvsec),
            @"startTimeMicroseconds": @(info.pbi_start_tvusec)
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
        NSMutableData *line = [json mutableCopy];
        const char newline = '\n';
        [line appendBytes:&newline length:1];
        int descriptor = open(journal.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (descriptor < 0) { _exit(71); }
        const uint8_t *cursor = line.bytes;
        size_t remaining = line.length;
        while (remaining > 0) {
            ssize_t count = write(descriptor, cursor, remaining);
            if (count < 0 && errno == EINTR) { continue; }
            if (count <= 0) { (void)close(descriptor); _exit(72); }
            cursor += count;
            remaining -= (size_t)count;
        }
        if (close(descriptor) != 0) { _exit(73); }
    }

    - (void)applicationDidFinishLaunching:(NSNotification *)notification {
        (void)notification;
        self.window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(40, 40, 240, 120)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered
            defer:NO];
        self.window.title = @"Parallax Disposable Fixture";
        [self.window orderFront:nil];
        [self record:@"launched"];
        if ([NSProcessInfo.processInfo.environment[@"PARALLAX_FIXTURE_MODE"] isEqualToString:@"self-exit"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ _exit(0); });
        }
    }

    - (void)applicationDidBecomeActive:(NSNotification *)notification {
        (void)notification;
        [self record:@"activated"];
    }

    - (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
        (void)sender;
        [self record:@"quit-requested"];
        return NSTerminateNow;
    }
    @end

    int main(int argc, const char *argv[]) {
        (void)argc;
        (void)argv;
        @autoreleasepool {
            FixtureDelegate *delegate = [[FixtureDelegate alloc] init];
            if ([NSProcessInfo.processInfo.environment[@"PARALLAX_FIXTURE_MODE"] isEqualToString:@"unregistered"]) {
                [delegate record:@"launched"];
                for (;;) { pause(); }
            }
            NSApplication *application = NSApplication.sharedApplication;
            application.delegate = delegate;
            [application setActivationPolicy:NSApplicationActivationPolicyRegular];
            [application run];
        }
        return 0;
    }
    """#
}

enum ProductionLaunchApplicationFixtureError: Error {
    case compilationFailed(String)
    case compilationTimedOut
    case compilerTerminationTimedOut
    case openReturnedNil
    case openTimedOut
    case timedOut(String)
    case cleanupFailed
}

private final class ProductionLaunchOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSRunningApplication, Error>?

    func install(_ continuation: CheckedContinuation<NSRunningApplication, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<NSRunningApplication, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<NSRunningApplication, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
