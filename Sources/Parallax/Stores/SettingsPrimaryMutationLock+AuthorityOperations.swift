import Darwin
import Foundation

extension SettingsPrimaryMutationLock {
    func readPrimary(
        _ resources: Resources
    ) -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        do {
            let parentBefore = try revalidateAuthority(resources)
            let result = try lockedInspectionReader.readPinnedThrowing(
                parent: resources.settings,
                parentBefore: parentBefore,
                maximumBytes:
                    SettingsPrimaryFileAccess.maximumLockedInspectionBytes
            ) {
                _ = try revalidateAuthority(resources)
            }
            return .success(result)
        } catch let error as SettingsPrimaryLockedInspectionError {
            return .failure(error)
        } catch let error as SettingsPrimaryMutationLockError {
            return .failure(.lockValidation(error))
        } catch let error as SettingsPrimaryFileAccessError {
            return .failure(.fileAccess(error))
        } catch {
            return .failure(
                .lockValidation(
                    system(
                        "unexpected locked inspection validation",
                        EIO
                    )
                )
            )
        }
    }

    func inspectPublicationResiduals(
        _ resources: Resources
    ) -> Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    > {
        do {
            _ = try revalidateAuthority(resources)
        } catch {
            return .failure(residualInventoryAuthorityError(error))
        }

        let snapshot = publicationResidualInventory.inspect(
            settingsDescriptor: resources.settings
        )
        do {
            _ = try revalidateAuthority(resources)
            return .success(snapshot)
        } catch {
            return .success(
                snapshot.appendingPartial(
                    .authorityPostflight(
                        residualInventoryAuthorityError(error)
                    )
                )
            )
        }
    }

    func residualInventoryAuthorityError(
        _ error: any Error
    ) -> SettingsPrimaryLockedInspectionError {
        if let error =
            error as? SettingsPrimaryLockedInspectionError
        {
            return error
        }
        if let error = error as? SettingsPrimaryMutationLockError {
            return .lockValidation(error)
        }
        return .lockValidation(
            system(
                "unexpected residual inventory validation",
                EIO
            )
        )
    }

    func readPrimaryAfterPublicationMutation(
        _ resources: Resources
    ) -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        do {
            // Creating, renaming, or removing our publication temporary
            // legitimately changes the directory metadata. Refresh only after
            // revalidating the pinned descriptor, its secure properties, ACL,
            // and the exact path identity.
            try refreshSettingsIdentity(resources)
        } catch let error as SettingsPrimaryMutationLockError {
            return .failure(.lockValidation(error))
        } catch {
            return .failure(
                .lockValidation(
                    system(
                        "refresh Settings after publication mutation",
                        EIO
                    )
                )
            )
        }
        return readPrimary(resources)
    }

    func revalidateAuthority(
        _ resources: Resources
    ) throws -> SettingsPrimaryFileMetadata {
        let reopened = try openContainer(call: .reopenContainer)
        let validation: Result<
            SettingsPrimaryFileMetadata,
            SettingsPrimaryMutationLockError
        >
        do {
            try validatePinnedState(
                resources,
                reopenedContainer: reopened
            )
            guard let identity = resources.settingsIdentity else {
                throw changed(.settingsDirectory)
            }
            validation = .success(identity)
        } catch let error as SettingsPrimaryMutationLockError {
            validation = .failure(error)
        } catch {
            validation = .failure(
                system(
                    "unexpected locked inspection validation",
                    EIO
                )
            )
        }

        let closeFailure = closeAuthorityContainer(reopened)
        switch (validation, closeFailure) {
        case (.success(let identity), nil):
            return identity
        case (.success, .some(let close)):
            throw SettingsPrimaryLockedInspectionError
                .authorityContainerClose(close)
        case (.failure(let validation), nil):
            throw validation
        case (.failure(let validation), .some(let close)):
            throw SettingsPrimaryLockedInspectionError
                .lockValidationAndAuthorityContainerClose(
                    validation: validation,
                    close: close
                )
        }
    }

    func closeAuthorityContainer(
        _ descriptor: Int32
    ) -> SettingsPrimaryMutationLockSystemFailure? {
        let outcome = SettingsDescriptorClose.descriptor(descriptor) {
            systemCallHook(.closeAuthorityContainer)
        }
        guard case .failure(let code) = outcome else {
            return nil
        }
        return .init(
            operation: "close transient trusted settings container",
            code: code
        )
    }
}
