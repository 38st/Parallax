import Foundation

/// Removes leftovers that only ever grow: old chat backups and iOS simulator build caches Claude stopped using.
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

    /// Deletes per-project folders in `UserData/simulator-builds` that no build touched within `maxAge`.
    /// They are Xcode DerivedData, rebuilt on the next run. Pass only spaces that aren't running.
    @discardableResult
    static func pruneBuildCaches(userData folders: [URL], now: Date) -> Int {
        var removed = 0
        for userData in folders {
            let builds = userData.appendingPathComponent("simulator-builds", isDirectory: true)
            for project in (try? FileManager.default.contentsOfDirectory(at: builds, includingPropertiesForKeys: nil)) ?? [] {
                guard let used = lastModified(project, depth: 3), now.timeIntervalSince(used) > maxAge,
                      (try? FileManager.default.removeItem(at: project)) != nil else { continue }
                removed += 1
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
