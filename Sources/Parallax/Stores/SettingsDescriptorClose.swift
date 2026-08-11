import Darwin

enum SettingsDescriptorCloseOutcome: Equatable, Sendable {
    case success
    case failure(code: Int32)
}

enum SettingsDescriptorClose {
    static func descriptor(
        _ descriptor: Int32,
        injectedEvidence: () -> Int32?
    ) -> SettingsDescriptorCloseOutcome {
        let injectedEvidence = injectedEvidence()
        let result = Darwin.close(descriptor)
        let realFailure = result == 0 ? nil : errno
        return outcome(
            realFailure: realFailure,
            injectedEvidence: injectedEvidence
        )
    }

    static func directoryStream(
        _ stream: UnsafeMutablePointer<DIR>,
        injectedEvidence: () -> Int32?
    ) -> SettingsDescriptorCloseOutcome {
        let injectedEvidence = injectedEvidence()
        let result = closedir(stream)
        let realFailure = result == 0 ? nil : errno
        return outcome(
            realFailure: realFailure,
            injectedEvidence: injectedEvidence
        )
    }

    private static func outcome(
        realFailure: Int32?,
        injectedEvidence: Int32?
    ) -> SettingsDescriptorCloseOutcome {
        if let injectedEvidence {
            return .failure(code: injectedEvidence)
        }
        if let realFailure {
            return .failure(code: realFailure)
        }
        return .success
    }
}
