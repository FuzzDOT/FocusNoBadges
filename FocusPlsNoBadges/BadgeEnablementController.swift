//
//  BadgeEnablementController.swift
//  FocusPlsNoBadges
//
//  Modernized for current macOS.
//

import Foundation

/// Coordinates global notification badge suppression and restoration.
final class BadgeEnablementController {

    private static let stateKey = "FocusPlsNoBadges.SuppressedBadgeState"

    /// The notification preference bit that controls whether an application's
    /// badge is enabled.
    private static let badgeMask: Int = 1 << 1

    // MARK: - Suppression

    @discardableResult
    func turnOffAllBadges() -> Bool {
        print("Turning off all badges…")

        do {
            var prefs = try AppNotificationPreferences.loadCurrent()
            let changes = prefs.turnOffAllBadges()

            guard !changes.isEmpty else {
                print("No enabled application badges found.")
                return true
            }

            let previousState = persistedState
            var state = previousState

            for change in changes where state[change.bundleID] == nil {
                state[change.bundleID] = change.originalFlags
            }

            // Keep track of whether FocusPlsNoBadges is currently suppressing
            // badges. This is also useful for recovery after a relaunch.
            persistedState = state

            do {
                try prefs.saveAsCurrent()
            } catch {
                persistedState = previousState
                throw error
            }

            restartUserNotificationsDaemon()

            print("Badges successfully suppressed for \(changes.count) application(s).")
            return true

        } catch {
            print("❌ Could not disable notification badges: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restoration

    /// Restores badges globally by enabling the badge bit for every registered
    /// notification application.
    ///
    /// This intentionally uses the same mechanism as the known-working manual
    /// recovery command:
    ///
    ///     flags |= 0x2
    ///
    /// followed by:
    ///
    ///     killall usernoted
    ///
    /// We do not attempt to restore individual saved flag values because the
    /// global restoration mechanism has proven more reliable on current macOS.
    @discardableResult
    func restoreBadges() -> Bool {
        print("Restoring all notification badges…")

        do {
            let plistURL = Self.notificationPreferencesURL

            guard FileManager.default.isReadableFile(atPath: plistURL.path) else {
                print("❌ Cannot read notification preferences.")
                print("   Full Disk Access may be required.")
                return false
            }

            let data = try Data(contentsOf: plistURL)

            guard var plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                print("❌ Could not parse notification preferences plist.")
                return false
            }

            guard var apps = plist["apps"] as? [[String: Any]] else {
                print("❌ Could not find the notification apps array.")
                return false
            }

            var changedCount = 0

            for index in apps.indices {
                guard let flags = Self.integerValue(apps[index]["flags"]) else {
                    continue
                }

                let newFlags = flags | Self.badgeMask

                if newFlags != flags {
                    apps[index]["flags"] = NSNumber(value: newFlags)
                    changedCount += 1
                }
            }

            plist["apps"] = apps

            let updatedData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )

            try updatedData.write(to: plistURL, options: .atomic)

            print("Enabled badges for \(changedCount) application(s).")

            // usernoted must be restarted so macOS reloads the updated
            // notification preferences.
            restartUserNotificationsDaemon()

            // The global restore has succeeded. Clear the recovery state.
            persistedState = [:]

            print("✅ All notification badges restored.")
            return true

        } catch {
            print("❌ Could not restore notification badges: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - State

    var hasSuppressedBadges: Bool {
        !persistedState.isEmpty
    }

    private var persistedState: [String: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else {
                return [:]
            }

            do {
                return try JSONDecoder().decode(
                    [String: Int].self,
                    from: data
                )
            } catch {
                print("⚠️ Could not decode saved badge state: \(error.localizedDescription)")
                return [:]
            }
        }

        set {
            do {
                let data = try JSONEncoder().encode(newValue)

                UserDefaults.standard.set(
                    data,
                    forKey: Self.stateKey
                )

                UserDefaults.standard.synchronize()

            } catch {
                print("⚠️ Could not save badge state: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - usernoted

    private func restartUserNotificationsDaemon() {
        print("Restarting usernoted…")

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/killall"
        )
        process.arguments = ["usernoted"]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                print("usernoted terminated; launchd should restart it automatically.")
            } else {
                print(
                    "usernoted termination exited with status \(process.terminationStatus)"
                )
            }

        } catch {
            print("❌ Could not restart usernoted: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static let notificationPreferencesURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
            )
    }()

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? NSNumber {
            return value.intValue
        }

        return nil
    }
}
