import Darwin
import Foundation

extension SettingsPrimaryMutationLock {
    func openOrCreateSettings(
        _ resources: Resources
    ) throws {
        let preflight = pathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .inspectSettingsPath
        )
        let expectedBefore: SettingsPrimaryFileMetadata?
        switch preflight {
        case .metadata(let metadata):
            try validateDirectory(
                metadata,
                item: .settingsDirectory,
                exactMode: 0o700
            )
            expectedBefore = metadata
        case .failure(let code):
            guard code == ENOENT else {
                throw system(
                    "inspect Settings directory path",
                    code
                )
            }
            expectedBefore = nil
        }
        boundaryHook(.afterSettingsPreflight)

        if let expectedBefore {
            let settings = try openSettings(
                parent: resources.container,
                name: Self.settingsName
            )
            resources.settings = settings
            let opened = try descriptorMetadata(
                settings,
                call: .inspectSettings,
                operation: "inspect opened Settings directory"
            )
            try validateDirectory(
                opened,
                item: .settingsDirectory,
                exactMode: 0o700
            )
            guard opened == expectedBefore else {
                throw changed(.settingsDirectory)
            }
            try finishSettingsValidation(
                resources,
                pathName: Self.settingsName
            )
        } else {
            try createAndPublishSettings(resources)
        }
        boundaryHook(.afterSettingsOpen)
    }

    private func createAndPublishSettings(
        _ resources: Resources
    ) throws {
        var stagingName: String?
        for _ in 0 ..< Self.settingsStagingAttemptLimit {
            let candidate = Self.settingsStagingPrefix
                + String(stagingNameSource(), radix: 16)
            let result: Int32
            let code: Int32
            if let injected = systemCallHook(.createSettings) {
                result = -1
                code = injected
            } else {
                result = mkdirat(resources.container, candidate, 0o700)
                code = result == 0 ? 0 : errno
            }
            if result == 0 {
                stagingName = candidate
                break
            }
            guard code == EEXIST else {
                throw system("create staging Settings directory", code)
            }
        }
        guard let stagingName else {
            throw system(
                "exhaust staging Settings directory names",
                EEXIST
            )
        }

        let settings = tryOpenSettings(
            parent: resources.container,
            name: stagingName
        )
        guard settings.descriptor >= 0 else {
            if settings.errorCode == ELOOP {
                throw unsafe(.settingsDirectory, .symbolicLink)
            }
            if settings.errorCode == ENOTDIR {
                throw unsafe(.settingsDirectory, .unsupportedType)
            }
            throw system(
                "open staging Settings directory \(stagingName)",
                settings.errorCode
            )
        }
        resources.settings = settings.descriptor

        let created = try descriptorMetadata(
            settings.descriptor,
            call: .inspectSettings,
            operation: "inspect staging Settings directory"
        )
        guard created.kind == .directory,
              created.owner == geteuid()
        else {
            throw changed(.settingsDirectory)
        }
        let createdPath = try requiredPathMetadata(
            parent: resources.container,
            name: stagingName,
            call: .inspectCreatedSettingsPath,
            operation: "inspect staging Settings directory path"
        )
        guard sameIdentity(created, createdPath) else {
            throw changed(.settingsDirectory)
        }
        boundaryHook(.afterSettingsCreatedIdentity)

        try callStatus(
            .setSettingsMode,
            operation: "set staging Settings directory mode"
        ) {
            fchmod(settings.descriptor, 0o700)
        }

        let final = try descriptorMetadata(
            settings.descriptor,
            call: .reinspectSettings,
            operation: "reinspect staging Settings directory"
        )
        try validateDirectory(
            final,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            settings.descriptor,
            item: .settingsDirectory,
            operation: "inspect staging Settings directory ACL"
        )
        let stagingPath = try requiredPathMetadata(
            parent: resources.container,
            name: stagingName,
            call: .reinspectSettingsPath,
            operation: "reinspect staging Settings directory path"
        )
        guard final == stagingPath else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = final
        boundaryHook(.beforeSettingsPublish)

        try callStatus(
            .publishSettings,
            operation: "publish Settings directory"
        ) {
            renameatx_np(
                resources.container,
                stagingName,
                resources.container,
                Self.settingsName,
                UInt32(RENAME_EXCL)
            )
        }
        boundaryHook(.afterSettingsPublish)

        let publishedDescriptor = try descriptorMetadata(
            settings.descriptor,
            call: .reinspectSettings,
            operation: "verify published Settings directory descriptor"
        )
        try validateDirectory(
            publishedDescriptor,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        let published = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .inspectPublishedSettingsPath,
            operation: "verify published Settings directory path"
        )
        guard publishedDescriptor == published else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = publishedDescriptor
        try fullSync(
            resources.container,
            call: .syncContainer,
            operation: "synchronize trusted settings container"
        )
    }

    func finishSettingsValidation(
        _ resources: Resources,
        pathName: String
    ) throws {
        let final = try descriptorMetadata(
            resources.settings,
            call: .reinspectSettings,
            operation: "reinspect Settings directory"
        )
        try validateDirectory(
            final,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "inspect Settings directory ACL"
        )
        let finalPath = try requiredPathMetadata(
            parent: resources.container,
            name: pathName,
            call: .reinspectSettingsPath,
            operation: "reinspect Settings directory path"
        )
        guard final == finalPath else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = final
    }

    private func openSettings(
        parent: Int32,
        name: String
    ) throws -> Int32 {
        let opened = tryOpenSettings(parent: parent, name: name)
        guard opened.descriptor >= 0 else {
            if opened.errorCode == ELOOP {
                throw unsafe(.settingsDirectory, .symbolicLink)
            }
            if opened.errorCode == ENOTDIR {
                throw unsafe(.settingsDirectory, .unsupportedType)
            }
            throw system("open Settings directory", opened.errorCode)
        }
        return opened.descriptor
    }

    private func tryOpenSettings(
        parent: Int32,
        name: String
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(.openSettings) {
            return (-1, code)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }
}
