import Foundation

/// Removes leftovers that only ever grow: old chat backups, and VM images and simulator builds Claude stopped using.
enum Housekeeping {
    static let maxAge: TimeInterval = 14 * 86_400

    /// Deletes backup folders whose name stamp is older than `maxAge`. Folders without a readable stamp are kept.
    @discardableResult
    static func pruneBackups(in backups: URL, now: Date) -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        var removed = 0
        for folder in (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [] {
            guard let stamp = formatter.date(from: String(folder.lastPathComponent.prefix(20))),
                  now.timeIntervalSince(stamp) > maxAge,
                  (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// Claude data that it rebuilds on demand, and how deep to look for signs of use.
    /// `simulator-builds` holds Xcode DerivedData per project; `vm_bundles` holds the ~10 GB VM image,
    /// whose disk files change whenever the VM runs and which Claude downloads again when it's missing.
    static let caches: [(folder: String, depth: Int)] = [("simulator-builds", 3), ("vm_bundles", 1)]

    /// Deletes items in each `caches` folder that weren't used within `maxAge`. Pass only spaces that aren't running.
    @discardableResult
    static func pruneCaches(userData folders: [URL], now: Date) -> Int {
        var removed = 0
        for userData in folders {
            for cache in caches {
                let parent = userData.appendingPathComponent(cache.folder, isDirectory: true)
                for item in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                    guard let used = lastModified(item, depth: cache.depth), now.timeIntervalSince(used) > maxAge,
                          (try? FileManager.default.removeItem(at: item)) != nil else { continue }
                    removed += 1
                }
            }
        }
        return removed
    }

    /// Newest modification date of `url` and the folders and files up to `depth` levels below it.
    /// Xcode touches its Logs and Build folders on every build, so a shallow look is enough.
    private static func lastModified(_ url: URL, depth: Int) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate else { return nil }
        guard depth > 0, values.isDirectory == true, values.isSymbolicLink != true,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return date }
        return children.compactMap { lastModified($0, depth: depth - 1) }.reduce(date) { max($0, $1) }
    }
}

/// Disk use of one space's data folder, split into the parts worth knowing about.
struct SpaceStorage: Identifiable, Equatable, Sendable {
    var id: UUID
    var total: Int64 = 0
    var vmImage: Int64 = 0
    var chats: Int64 = 0
    var buildCaches: Int64 = 0
    var other: Int64 { max(0, total - vmImage - chats - buildCaches) }

    /// Sizes count each file in full, so chats that are APFS clones of another space's copy may use less.
    static func measure(spaceID: UUID, folder: URL) -> SpaceStorage {
        let userData = folder.appendingPathComponent("UserData", isDirectory: true)
        func size(_ path: String) -> Int64 { Housekeeping.size(of: userData.appendingPathComponent(path)) }
        return SpaceStorage(
            id: spaceID, total: Housekeeping.size(of: folder), vmImage: size("vm_bundles"),
            chats: size("ClaudeConfig/projects") + size("claude-code-sessions"), buildCaches: size("simulator-builds")
        )
    }
}

extension Housekeeping {
    /// Allocated bytes of a file or folder, without following symbolic links.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes a space's Claude VM image. Claude downloads it again when the space next needs it.
    static func removeVMImage(folder: URL) throws {
        let bundles = folder.appendingPathComponent("UserData/vm_bundles", isDirectory: true)
        for item in (try? FileManager.default.contentsOfDirectory(at: bundles, includingPropertiesForKeys: nil)) ?? [] {
            try FileManager.default.removeItem(at: item)
        }
    }
}
