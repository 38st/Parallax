import Darwin
import Foundation

extension SettingsPrimaryPublication {
    func verifyWrittenTemporary(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        let descriptor = try metadata(
            resources.descriptor,
            call: .reinspectTemporary,
            operation: "verify written settings publication temporary"
        )
        try validateTemporary(descriptor)
        guard descriptor.size == Int64(request.targetBytes.count),
              sameIdentity(descriptor, resources.identity),
              try exactDescriptorBytes(
                  resources.descriptor,
                  expected: request.targetBytes,
                  token: request.targetToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("written temporary metadata")
        }
        try validateACL(resources.descriptor)
        let path = try pathMetadata(
            settingsDescriptor,
            resources.name,
            call: .inspectTemporaryPath,
            operation: "verify written settings publication temporary path"
        )
        guard descriptor == path else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("written temporary path")
        }
        resources.identity = descriptor
    }

    func publishTemporary(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        name: String
    ) throws {
        switch request.prior {
        case .missing:
            try callStatus(
                .renameMissing,
                operation: "publish missing settings primary"
            ) {
                renameatx_np(
                    settingsDescriptor,
                    name,
                    settingsDescriptor,
                    SettingsPrimaryLocation.fileName,
                    UInt32(RENAME_EXCL)
                )
            }
        case .current:
            try callStatus(
                .renameCurrent,
                operation: "publish current settings primary"
            ) {
                renameatx_np(
                    settingsDescriptor,
                    name,
                    settingsDescriptor,
                    SettingsPrimaryLocation.fileName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    func verifyPublishedTarget(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        let descriptor = try metadata(
            resources.descriptor,
            call: .reinspectTemporary,
            operation: "verify published target descriptor"
        )
        try validateTemporary(descriptor)
        try validateACL(resources.descriptor)
        guard descriptor.size == Int64(request.targetBytes.count),
              sameIdentity(descriptor, resources.identity),
              try exactDescriptorBytes(
                  resources.descriptor,
                  expected: request.targetBytes,
                  token: request.targetToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .publishedIdentityMismatch
        }
        let path = try pathMetadata(
            settingsDescriptor,
            SettingsPrimaryLocation.fileName,
            call: .inspectPublishedPrimaryPath,
            operation: "verify published primary target path"
        )
        guard descriptor == path else {
            throw SettingsPrimaryPublicationFailure
                .publishedIdentityMismatch
        }
    }

    func verifyDisplacedPrior(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        guard case .current(let priorBytes, let priorToken) =
            request.prior,
            resources.displacedDescriptor >= 0
        else {
            throw SettingsPrimaryPublicationFailure
                .displacedPriorMismatch
        }
        let descriptor = try metadata(
            resources.displacedDescriptor,
            call: .inspectDisplacedPrior,
            operation: "inspect displaced prior settings"
        )
        guard descriptor.kind == .regularFile,
              descriptor.linkCount == 1,
              SettingsPrimaryDescriptorSecurity.ownershipAndModeViolation(descriptor) == nil
        else {
            throw SettingsPrimaryPublicationFailure.invalidRequest("unsafe temporary")
        }
        try validateACL(resources.displacedDescriptor)
        let path = try pathMetadata(
            settingsDescriptor,
            resources.name,
            call: .inspectDisplacedPriorPath,
            operation: "inspect displaced prior settings path"
        )
        guard descriptor == path,
              descriptor.size == Int64(priorBytes.count),
              try exactDescriptorBytes(
                  resources.displacedDescriptor,
                  expected: priorBytes,
                  token: priorToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .displacedPriorMismatch
        }
    }
}
