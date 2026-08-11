import Darwin
@testable import Parallax
import XCTest

final class SettingsSecureFileFactsTests: XCTestCase {
    func testMetadataConversionPreservesSecurityAndChangeFacts() {
        var status = stat()
        status.st_mode = S_IFREG | 0o7640
        status.st_dev = 11
        status.st_ino = 13
        status.st_uid = 17
        status.st_nlink = 19
        status.st_size = 23
        status.st_mtimespec = timespec(tv_sec: 29, tv_nsec: 31)
        status.st_ctimespec = timespec(tv_sec: 37, tv_nsec: 41)

        let metadata = SettingsPrimaryDescriptorSecurity.metadata(from: status)

        XCTAssertEqual(metadata.kind, .regularFile)
        XCTAssertEqual(metadata.device, 11)
        XCTAssertEqual(metadata.inode, 13)
        XCTAssertEqual(metadata.owner, 17)
        XCTAssertEqual(metadata.mode, 0o7640)
        XCTAssertEqual(metadata.linkCount, 19)
        XCTAssertEqual(metadata.size, 23)
        XCTAssertEqual(metadata.modificationSeconds, 29)
        XCTAssertEqual(metadata.modificationNanoseconds, 31)
        XCTAssertEqual(metadata.changeSeconds, 37)
        XCTAssertEqual(metadata.changeNanoseconds, 41)

        status.st_mode = S_IFDIR | 0o700
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.metadata(from: status).kind,
            .directory
        )
        status.st_mode = S_IFLNK | 0o700
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.metadata(from: status).kind,
            .symbolicLink
        )
        status.st_mode = S_IFIFO | 0o600
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.metadata(from: status).kind,
            .other
        )
    }

    func testIdentityIsNarrowerThanFullMetadataEquality() {
        let original = metadata()
        var changedFacts = original
        changedFacts.owner &+= 1
        changedFacts.mode = 0o400
        changedFacts.size += 1
        changedFacts.changeNanoseconds += 1

        XCTAssertNotEqual(original, changedFacts)
        XCTAssertEqual(original.identity, changedFacts.identity)

        changedFacts.inode &+= 1
        XCTAssertNotEqual(original.identity, changedFacts.identity)
    }

    func testNeutralOwnerAndModeViolationsHaveExactPrecedence() {
        let safe = metadata(owner: geteuid(), mode: 0o600)
        XCTAssertNil(
            SettingsPrimaryDescriptorSecurity.ownershipAndModeViolation(safe)
        )

        var wrongOwnerAndMode = safe
        wrongOwnerAndMode.owner &+= 1
        wrongOwnerAndMode.mode = 0o7777
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeViolation(wrongOwnerAndMode),
            .wrongOwner
        )
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeReason(wrongOwnerAndMode),
            .wrongOwner
        )

        var permissiveAndSpecial = safe
        permissiveAndSpecial.mode = 0o4670
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeViolation(permissiveAndSpecial),
            .permissiveMode
        )
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeReason(permissiveAndSpecial),
            .permissiveMode
        )

        var special = safe
        special.mode = 0o4600
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeViolation(special),
            .specialMode
        )
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeReason(special),
            .specialMode
        )

        var restrictiveButNotCanonical = safe
        restrictiveButNotCanonical.mode = 0o400
        XCTAssertNil(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeViolation(restrictiveButNotCanonical),
            "Exact-mode callers must continue enforcing their own 0600/0700 policy."
        )
    }

    func testACLDirectivesResolveWithoutTouchingTheDescriptor() {
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.extendedACL(
                descriptor: -1,
                directive: .absent
            ),
            .absent
        )
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.extendedACL(
                descriptor: -1,
                directive: .present
            ),
            .present
        )
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity.extendedACL(
                descriptor: -1,
                directive: .failure(code: EIO)
            ),
            .failure(code: EIO)
        )
    }

    func testPrimaryLocationPreservesReaderCompatibilityAlias() {
        XCTAssertEqual(SettingsPrimaryLocation.fileName, "settings.json")
        XCTAssertEqual(
            SettingsPrimaryFileAccess.primaryName,
            SettingsPrimaryLocation.fileName
        )
    }

    private func metadata(
        owner: uid_t = 501,
        mode: UInt16 = 0o600
    ) -> SettingsPrimaryFileMetadata {
        .init(
            kind: .regularFile,
            device: 7,
            inode: 9,
            owner: owner,
            mode: mode,
            linkCount: 1,
            size: 11,
            modificationSeconds: 13,
            modificationNanoseconds: 17,
            changeSeconds: 19,
            changeNanoseconds: 23
        )
    }
}
