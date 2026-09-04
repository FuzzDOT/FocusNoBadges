//
//  ModelFiles+Current.swift
//  FocusPlsNoBadges
//
//  Modernized for current macOS.
//

import Foundation

private let doNotDisturbDBDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library")
    .appendingPathComponent("DoNotDisturb")
    .appendingPathComponent("DB")

private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    do {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw FocusDatabaseError.readFailed(url, error)
    }
}

extension AssertionsFile {
    static func loadCurrent() throws -> Self {
        let url = doNotDisturbDBDirectory.appendingPathComponent("Assertions.json")
        return try loadJSON(Self.self, from: url)
    }

    static var current: Self {
        do {
            return try loadCurrent()
        } catch {
            fatalError("Unable to read Focus assertions: \(error.localizedDescription)")
        }
    }
}

extension ModeConfigurationsFile {
    static func loadCurrent() throws -> Self {
        let url = doNotDisturbDBDirectory.appendingPathComponent("ModeConfigurations.json")
        return try loadJSON(Self.self, from: url)
    }

    static var current: Self {
        do {
            return try loadCurrent()
        } catch {
            fatalError("Unable to read Focus mode configurations: \(error.localizedDescription)")
        }
    }
}

enum FocusDatabaseError: LocalizedError {
    case readFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .readFailed(let url, let error):
            return "Cannot read \(url.path). macOS denied access (\(error.localizedDescription)). Grant Full Disk Access to the built app (and Xcode while debugging), then relaunch it."
        }
    }
}
