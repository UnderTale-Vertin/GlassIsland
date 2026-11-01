import AppKit

/// Resolves the user's Obsidian context: reads the front window title
/// ("Note - Vault - Obsidian"), maps vault names to on-disk paths via
/// Obsidian's own registry, and locates the note file inside the vault.
enum ObsidianSupport {
    struct WindowSource: Equatable {
        let noteName: String
        let vaultName: String
    }

    // MARK: - Window title

    static func parseWindowTitle(_ title: String) -> WindowSource? {
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 3, parts.last == "Obsidian" else { return nil }
        let vault = parts[parts.count - 2]
        // The note title itself may contain " - "; everything before the
        // vault segment is the title.
        let note = parts[0..<(parts.count - 2)].joined(separator: " - ")
        guard !note.isEmpty, !vault.isEmpty else { return nil }
        return WindowSource(noteName: note, vaultName: vault)
    }

    /// Reads the frontmost Obsidian window title via System Events.
    /// needsPermission == true means macOS denied the Apple Event (the user
    /// must allow GlassIsland in 隐私与安全性 → 辅助功能/自动化).
    static func frontWindowTitle() -> (value: String?, needsPermission: Bool) {
        guard let script = NSAppleScript(source:
            "tell application \"System Events\" to tell process \"Obsidian\" to get name of front window"
        ) else { return (nil, false) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let number = (error["ErrorNumber"] as? NSNumber)?.intValue ?? 0
            DiagLog.log("appleEvent error \(number): \(error)")
            return (nil, number == -1743)
        }
        return (output.stringValue ?? "", false)
    }

    @discardableResult
    static func activateObsidian() -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").first {
            app.activate()
            if app.isActive { return true }
        }
        // activate() from a non-active accessory app is often ignored;
        // re-opening through the workspace reliably brings Obsidian forward.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        DiagLog.log("activateObsidian via openApplication")
        return true
    }

    // MARK: - Vault registry

    /// name → path, from Obsidian's own vault registry.
    static func vaultPaths() -> [String: String] {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return vaultPaths(from: data)
    }

    static func vaultPaths(from data: Data) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (_, entry) in vaults {
            guard let entry = entry as? [String: Any],
                  let path = entry["path"] as? String else { continue }
            let name = (path as NSString).lastPathComponent
            result[name] = path
        }
        return result
    }

    struct VaultEntry {
        let name: String
        let path: String
        let isOpen: Bool
        let ts: Double
    }

    static func vaultEntries(from data: Data) -> [VaultEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any] else { return [] }
        var result: [VaultEntry] = []
        for (_, entry) in vaults {
            guard let entry = entry as? [String: Any],
                  let path = entry["path"] as? String else { continue }
            result.append(VaultEntry(
                name: (path as NSString).lastPathComponent,
                path: path,
                isOpen: (entry["open"] as? Bool) ?? false,
                ts: (entry["ts"] as? Double) ?? 0
            ))
        }
        return result
    }

    /// The vault Obsidian last had open (its own "open" flag, else newest).
    static func preferredVault() -> VaultEntry? {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let entries = vaultEntries(from: data)
        return entries.first { $0.isOpen } ?? entries.max { $0.ts < $1.ts }
    }

    static func vaultPath(named name: String) -> String? {
        vaultPaths()[name]
    }

    /// Finds the note file inside the vault by title (shortest match wins).
    static func resolveNote(noteName: String, vaultName: String, vaults: [String: String]) -> (path: String, vaultPath: String)? {
        guard let vaultPath = vaults[vaultName] else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: vaultPath),
            includingPropertiesForKeys: nil
        ) else { return nil }
        var best: URL?
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            if url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(noteName) == .orderedSame {
                if best == nil || url.path.count < best!.path.count {
                    best = url
                }
            }
        }
        guard let found = best else { return nil }
        return (found.path, vaultPath)
    }
}
