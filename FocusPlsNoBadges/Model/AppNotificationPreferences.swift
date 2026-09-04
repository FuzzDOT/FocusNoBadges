//
//  AppNotificationPreferences.swift
//  FocusPlsNoBadges
//
//  Modernized for current macOS notification storage.
//

import Foundation

/// Accesses the private notification preferences used by usernoted.
///
/// On current macOS releases the old `com.apple.ncprefs` domain is no longer
/// present. The per-application notification records are stored in:
///
///   ~/Library/Group Containers/group.com.apple.usernoted/
///       Library/Preferences/group.com.apple.usernoted.plist
///
/// The plist contains a top-level `apps` array. Each application record has a
/// `bundle-id` and a `flags` integer. Testing on the current macOS version
/// confirmed that bit 1 (0x2) controls "Badge application icon": clearing it
/// disables badges without changing the other notification flags.
///
/// This is intentionally using a private macOS implementation detail. There
/// is no public API for changing another application's badge setting.
struct AppNotificationPreferences {
    private static let appsKey = "apps"
    private static let bundleIDKey = "bundle-id"
    private static let flagsKey = "flags"
    static let badgeMask: Int = 1 << 1

    struct BadgeChange {
        let bundleID: String
        let originalFlags: Int
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("group.com.apple.usernoted", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("group.com.apple.usernoted.plist")
    }

    private var root: [String: Any]
    private var content: [[String: Any]]

    /// Clears the badge bit from every currently-enabled app.
    ///
    /// The returned records contain the exact flags observed before this
    /// operation. The controller persists those originals before committing
    /// the modified plist.
    mutating func turnOffAllBadges() -> [BadgeChange] {
        var changes = [BadgeChange]()

        for index in content.indices {
            var app = content[index]

            guard let bundleID = app[Self.bundleIDKey] as? String,
                  let flags = Self.integerValue(app[Self.flagsKey]) else {
                continue
            }

            guard (flags & Self.badgeMask) != 0 else {
                continue
            }

            changes.append(
                BadgeChange(
                    bundleID: bundleID,
                    originalFlags: flags
                )
            )

            // Preserve every other notification flag exactly as-is.
            app[Self.flagsKey] = NSNumber(value: flags & ~Self.badgeMask)
            content[index] = app
        }

        root[Self.appsKey] = content
        return changes
    }

    /// Returns whether every requested application currently has the requested
    /// badge state. Used to verify that usernoted accepted a direct plist edit.
    func badgeState(bundleIDs: Set<String>, enabled: Bool) -> Bool {
        guard !bundleIDs.isEmpty else { return true }

        var found = Set<String>()
        for app in content {
            guard let bundleID = app[Self.bundleIDKey] as? String,
                  bundleIDs.contains(bundleID),
                  let flags = Self.integerValue(app[Self.flagsKey]) else {
                continue
            }

            let isEnabled = (flags & Self.badgeMask) != 0
            if isEnabled != enabled {
                return false
            }
            found.insert(bundleID)
        }

        return found == bundleIDs
    }

    /// Restores only the badge bit according to the saved original state.
    ///
    /// We intentionally do NOT replace the complete saved flags value. Other
    /// bits may have changed legitimately while Focus was active, so those
    /// current values are preserved.
    mutating func restoreBadges(from originalFlagsByBundleID: [String: Int]) -> (processed: Set<String>, changed: Bool) {
        let current = originalFlagsByBundleID
        var processed = Set<String>()
        var changed = false

        for index in content.indices {
            var app = content[index]

            guard let bundleID = app[Self.bundleIDKey] as? String,
                  let originalFlags = current[bundleID],
                  let flags = Self.integerValue(app[Self.flagsKey]) else {
                continue
            }

            processed.insert(bundleID)

            let originalBadgeEnabled = (originalFlags & Self.badgeMask) != 0
            let currentBadgeEnabled = (flags & Self.badgeMask) != 0

            // Only restore when the badge is still in the state produced by
            // suppression. If the user or macOS has already changed it, do not
            // blindly overwrite that newer decision.
            if !currentBadgeEnabled && originalBadgeEnabled {
                app[Self.flagsKey] = NSNumber(value: flags | Self.badgeMask)
                content[index] = app
                changed = true
            }
        }

        if changed {
            root[Self.appsKey] = content
        }
        return (processed: processed, changed: changed)
    }

    func saveAsCurrent() throws {
        let url = Self.plistURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotificationPreferencesError.fileUnavailable(url.path)
        }

        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .binary,
                options: 0
            )
        } catch {
            throw NotificationPreferencesError.serializationFailed(error.localizedDescription)
        }

        do {
            // Atomic replacement keeps a partially-written plist from being
            // observed if usernoted happens to read it during the write.
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotificationPreferencesError.saveFailed(error.localizedDescription)
        }
    }

    static func loadCurrent() throws -> AppNotificationPreferences {
        let url = Self.plistURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotificationPreferencesError.fileUnavailable(url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NotificationPreferencesError.readFailed(error.localizedDescription)
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: nil
            )
        } catch {
            throw NotificationPreferencesError.serializationFailed(error.localizedDescription)
        }

        guard let root = propertyList as? [String: Any] else {
            throw NotificationPreferencesError.rootInvalid
        }

        guard let apps = root[Self.appsKey] as? [[String: Any]] else {
            throw NotificationPreferencesError.appsKeyUnavailable
        }

        return .init(root: root, content: apps)
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Int64 {
            return Int(exactly: value)
        }
        if let value = value as? UInt64 {
            return Int(exactly: value)
        }
        return nil
    }

    /// Compatibility with the original source. Prefer `loadCurrent()`.
    static var current: AppNotificationPreferences {
        do {
            return try loadCurrent()
        } catch {
            fatalError("Unable to read macOS notification preferences: \(error.localizedDescription)")
        }
    }
}

enum NotificationPreferencesError: LocalizedError {
    case fileUnavailable(String)
    case readFailed(String)
    case rootInvalid
    case appsKeyUnavailable
    case serializationFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileUnavailable(let path):
            return "The current usernoted notification preferences were not found at \(path)."
        case .readFailed(let message):
            return "Could not read the usernoted notification preferences: \(message)"
        case .rootInvalid:
            return "The usernoted notification preferences are not a property-list dictionary."
        case .appsKeyUnavailable:
            return "The usernoted notification preferences do not contain the expected 'apps' array."
        case .serializationFailed(let message):
            return "Could not decode/encode the usernoted notification preferences: \(message)"
        case .saveFailed(let message):
            return "Could not save the usernoted notification preferences: \(message)"
        }
    }
}
