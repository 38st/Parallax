import Foundation

struct ValidApplicationBundleFixture {
    let url: URL
    let bundleIdentifier: String
    let executableName: String

    static func create(
        in parent: URL,
        name: String = "Fixture.app",
        bundleIdentifier: String = "com.example.fixture",
        executableName: String = "Fixture"
    ) throws -> ValidApplicationBundleFixture {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try plistData.write(
            to: contents.appendingPathComponent("Info.plist")
        )
        let executableURL = macOS.appendingPathComponent(executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        return ValidApplicationBundleFixture(
            url: url,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName
        )
    }
}
