import Foundation

enum LaunchConfigurationFingerprintFactory {
    static func fingerprint(
        _ source: LaunchConfigurationSource
    ) -> LaunchConfigurationFingerprint {
        var builder = LengthPrefixedSHA256FingerprintBuilder(
            domain: "com.parallax.launch-configuration-confirmation",
            version: 1
        )
        builder.append(
            source.requestID.uuidString.lowercased(),
            for: "requestID"
        )
        builder.append(
            source.applicationID.uuidString.lowercased(),
            for: "applicationID"
        )
        builder.append(
            source.applicationStorageID.uuidString.lowercased(),
            for: "applicationStorageID"
        )
        builder.append(
            source.profileID.uuidString.lowercased(),
            for: "profileID"
        )
        builder.append(
            source.profileStorageID.uuidString.lowercased(),
            for: "profileStorageID"
        )
        builder.append(
            String(source.configurationRevision),
            for: "configurationRevision"
        )
        builder.append(
            source.applicationURL.absoluteString,
            for: "applicationURL"
        )
        builder.append(
            source.expectedBundleIdentifier.map { "some:\($0)" } ?? "none",
            for: "expectedBundleIdentifier"
        )
        builder.append(source.configuredBaseRoot, for: "configuredBaseRoot")
        builder.append(source.argumentsText, for: "argumentsText")
        builder.append(source.environmentText, for: "environmentText")
        builder.append(
            source.isolationOwnership.userData.rawValue,
            for: "userDataIsolationOwnership"
        )
        builder.append(
            source.isolationOwnership.codexHome.rawValue,
            for: "codexHomeIsolationOwnership"
        )
        builder.append(
            source.childEnvironmentPolicy.rawValue,
            for: "childEnvironmentPolicy"
        )
        let sensitiveKeys = source.sensitiveEnvironmentKeys.sorted()
        builder.append(
            String(sensitiveKeys.count),
            for: "sensitiveEnvironmentKeyCount"
        )
        for key in sensitiveKeys {
            builder.append(key, for: "sensitiveEnvironmentKey")
        }

        let peers = source.peerProfiles.sorted(by: {
            $0.profileID.uuidString < $1.profileID.uuidString
        })
        builder.append(String(peers.count), for: "peerProfileCount")
        for peer in peers {
            builder.append(
                peer.profileID.uuidString.lowercased(),
                for: "peerProfileID"
            )
            builder.append(
                peer.profileStorageID.uuidString.lowercased(),
                for: "peerProfileStorageID"
            )
            builder.append(peer.argumentsText, for: "peerArgumentsText")
            builder.append(peer.environmentText, for: "peerEnvironmentText")
            builder.append(
                peer.isolationOwnership.userData.rawValue,
                for: "peerUserDataIsolationOwnership"
            )
            builder.append(
                peer.isolationOwnership.codexHome.rawValue,
                for: "peerCodexHomeIsolationOwnership"
            )
        }
        return LaunchConfigurationFingerprint(
            digest: builder.finalizeHexDigest()
        )
    }
}
