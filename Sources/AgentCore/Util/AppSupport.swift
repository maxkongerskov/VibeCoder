//
//  AppSupport.swift
//
//  Canonical Application Support root for VibeCoder, plus a one-shot
//  migration from legacy AgentOS folder names.
//

import Foundation

public enum AppSupport {
    /// Folder under Application Support: `~/Library/Application Support/VibeCoder`.
    public static let folderName = AppBranding.appSupportFolderName

    /// Legacy roots written by earlier AgentOS / NEW DAY builds.
    private static let legacyFolderNames = ["AgentOS-NewDay", "AgentOS"]

    // Protected by `migrateLock`; marked unsafe for Swift 6 shared mutable state.
    nonisolated(unsafe) private static var didMigrate = false
    private static let migrateLock = NSLock()

    /// `~/Library/Application Support/VibeCoder` (created if needed).
    public static var rootDirectory: URL {
        migrateLegacyIfNeeded()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Child directory under the VibeCoder Application Support root.
    public static func directory(_ component: String) -> URL {
        let url = rootDirectory.appendingPathComponent(component, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func file(_ name: String) -> URL {
        rootDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Merge legacy AgentOS trees into `VibeCoder` if needed. Safe to call repeatedly.
    public static func migrateLegacyIfNeeded() {
        migrateLock.lock()
        defer { migrateLock.unlock() }
        if didMigrate { return }
        didMigrate = true

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dest = appSupport.appendingPathComponent(folderName, isDirectory: true)

        var isDir: ObjCBool = false
        let destExists = fm.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue

        var anyLegacy = false
        for legacy in legacyFolderNames {
            let src = appSupport.appendingPathComponent(legacy, isDirectory: true)
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
                anyLegacy = true
                break
            }
        }
        guard anyLegacy else { return }

        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        for legacy in legacyFolderNames {
            let src = appSupport.appendingPathComponent(legacy, isDirectory: true)
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // If dest was empty and this is the first legacy, try a clean rename.
            if !destExists,
               legacy == legacyFolderNames.first,
               (try? fm.contentsOfDirectory(atPath: dest.path))?.isEmpty != false {
                // dest may have been just created empty — remove and rename.
                try? fm.removeItem(at: dest)
                do {
                    try fm.moveItem(at: src, to: dest)
                    Diagnostics.info("Migrated Application Support \(legacy) → \(folderName)")
                    continue
                } catch {
                    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    Diagnostics.warn("Rename \(legacy) failed, merging: \(error.localizedDescription)")
                }
            }

            mergeDirectory(from: src, to: dest, fm: fm)
            try? fm.removeItem(at: src)
            Diagnostics.info("Merged Application Support \(legacy) → \(folderName)")
        }
    }

    /// Copy items from `from` into `to` without overwriting existing files.
    private static func mergeDirectory(from: URL, to: URL, fm: FileManager) {
        guard let items = try? fm.contentsOfDirectory(
            at: from,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            let destItem = to.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: destItem.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    mergeDirectory(from: item, to: destItem, fm: fm)
                }
                // Keep existing file; skip overwrite.
                continue
            }
            try? fm.copyItem(at: item, to: destItem)
        }
    }
}
