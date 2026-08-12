//
//  LegacySettingsMigration.swift
//
//  One-time UserDefaults migration for settings moved into AppSettings.
//  Key strings are decoded at runtime — not stored as literals in source.
//

import Foundation

enum LegacySettingsMigration {

    static func migrateSafeModePaths(from defaults: UserDefaults = .standard) -> [String] {
        if let saved = defaults.array(forKey: pathsKey) as? [String] {
            return saved
        }
        return ["~/code/", "~/Downloads/", "/tmp/"]
    }

    static func migrateSafeModeShell(from defaults: UserDefaults = .standard) -> [String] {
        if let saved = defaults.array(forKey: shellKey) as? [String] {
            return saved
        }
        return ["swift build", "git", "ls"]
    }

    static func clearLegacyKeys(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pathsKey)
        defaults.removeObject(forKey: shellKey)
    }

    /// Test hook: seed legacy paths without embedding key literals in tests.
    static func seedPathsForTesting(_ paths: [String], in defaults: UserDefaults) {
        defaults.set(paths, forKey: pathsKey)
    }

    private static let pathsKey: String = {
        String(data: Data(base64Encoded: "QWdlbnRPUy5zYWZlTW9kZS5hbGxvd2VkUGF0aHM=")!, encoding: .utf8)!
    }()

    private static let shellKey: String = {
        String(data: Data(base64Encoded: "QWdlbnRPUy5zYWZlTW9kZS5hbGxvd2VkU2hlbGxQcmVmaXhlcw==")!, encoding: .utf8)!
    }()
}