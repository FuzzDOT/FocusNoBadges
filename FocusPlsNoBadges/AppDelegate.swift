//
//  AppDelegate.swift
//  FocusPlsNoBadges
//
//  Modernized for current macOS.
//

import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let badgeController = BadgeEnablementController()
    private var timer: Timer?
    private var badgesAreSuppressed = false
    private var lastSuppressionRefresh = Date.distantPast
    private let suppressionRefreshInterval: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("FocusPlsNoBadges started.")
        print("Focus DB: ~/Library/DoNotDisturb/DB")
        print("Notification prefs: ~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist")

        timer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )

        tick()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do restoration before AppKit begins tearing down the process. This is
        // more reliable than applicationWillTerminate for a synchronous cleanup
        // operation involving an external daemon.
        timer?.invalidate()
        timer = nil

        let restored = badgeController.restoreBadges()
        badgesAreSuppressed = !restored

        return restored ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil

        // Normally applicationShouldTerminate already completed restoration.
        // This is a final best-effort fallback for normal termination paths.
        _ = badgeController.restoreBadges()
        badgesAreSuppressed = false
    }

    @objc private func tick() {
        guard let shouldHide = shouldHideApplicationBadges else {
            // If the Focus database becomes temporarily unavailable, do not
            // assume that Focus ended. Keeping the current state avoids
            // accidentally re-enabling badges during a transient TCC/read
            // failure.
            return
        }

        if shouldHide {
            // Suppress once when Focus starts, then periodically reconcile in
            // case a new notification record appears while Focus is active.
            // The controller never overwrites an already-saved original state.
            let needsInitialSuppression = !badgesAreSuppressed
            let needsPeriodicRefresh = Date().timeIntervalSince(lastSuppressionRefresh) >= suppressionRefreshInterval

            if needsInitialSuppression || needsPeriodicRefresh {
                badgesAreSuppressed = badgeController.turnOffAllBadges()
                lastSuppressionRefresh = Date()
            }
        } else {
            // Always give the controller an opportunity to recover state left
            // by an earlier process instance. It is a no-op when nothing is
            // pending.
            let restored = badgeController.restoreBadges()
            if restored {
                badgesAreSuppressed = false
                lastSuppressionRefresh = Date.distantPast
            }
        }
    }

    private var shouldHideApplicationBadges: Bool? {
        do {
            let assertions = try AssertionsFile.loadCurrent()
            let configurations = try ModeConfigurationsFile.loadCurrent()

            guard let activeModeIdentifier = assertions.activeModeIdentifier else {
                return false
            }

            guard let activeMode = configurations.modeConfigurations.first(where: {
                $0.mode.modeIdentifier == activeModeIdentifier
            }) else {
                print("No configuration found for active Focus \(activeModeIdentifier)")
                return false
            }

            return activeMode.configuration.shouldHideApplicationBadges
        } catch {
            print("⚠️ Focus state unavailable: \(error.localizedDescription)")
            return nil
        }
    }
}
