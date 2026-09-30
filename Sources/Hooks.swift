import AppKit

/// Adds/removes Claude Buddy's hooks in ~/.claude/settings.json, pointing at wherever this app lives.
enum HookInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]
    static let settingsURL = ProcessInfo.processInfo.environment["CLAUDE_BUDDY_SETTINGS"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    enum Status { case connected, stale, missing }

    static var command: String { "'\(Bundle.main.executablePath!)' hook" }

    static func isOurs(_ command: String) -> Bool { command.contains("ClaudeBuddy") && command.hasSuffix(" hook") }

    /// True when running from a quarantined download (macOS runs it from a random read-only copy).
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static func status() -> Status {
        guard let settings = try? load(), let hooks = settings["hooks"] as? [String: Any] else { return .missing }
        var found = false, exact = true
        for event in events {
            let commands = commandsIn(hooks[event]).filter(isOurs)
            found = found || !commands.isEmpty
            exact = exact && commands == [command]
        }
        return !found ? .missing : exact ? .connected : .stale
    }

    static func install() throws {
        var settings = try load()
        var hooks = strip(settings["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = try load()
        let hooks = strip(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings)
    }

    // MARK: Helpers

    private static func commandsIn(_ groups: Any?) -> [String] {
        ((groups as? [[String: Any]]) ?? []).flatMap { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// Removes every Claude Buddy hook (any path), dropping groups/events left empty.
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                var g = group
                g["hooks"] = entries.filter { !isOurs($0["command"] as? String ?? "") }
                return (g["hooks"] as! [[String: Any]]).isEmpty ? nil : g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    private static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }

    private static func save(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("bak.claude-buddy")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

extension AppDelegate {
    /// On launch: keep hooks pointed at this copy of the app, or offer to connect them the first time.
    func setUpHooks() {
        if HookInstaller.isTranslocated {
            ask("Move Claude Buddy to Applications",
                "Drag Claude Buddy into your Applications folder, then open it from there so it can connect to Claude Code.",
                buttons: ["OK"])
            return
        }
        switch HookInstaller.status() {
        case .connected:
            break
        case .stale:  // the app moved (or an older install): quietly repoint the hooks
            try? HookInstaller.install()
        case .missing:
            guard !defaults.bool(forKey: "declinedHooks") else { return }
            let answer = ask("Connect to Claude Code?",
                             """
                             Claude Buddy adds a few hooks to ~/.claude/settings.json so it can see when your agents \
                             are working, need you, or finish. Your existing settings are kept (a backup is saved \
                             next to the file). Sessions that are already open pick this up after a restart.
                             """,
                             buttons: ["Connect", "Not Now"])
            if answer == .alertFirstButtonReturn { connectHooks() } else { defaults.set(true, forKey: "declinedHooks") }
        }
    }

    func connectHooks() {
        do {
            try HookInstaller.install()
            defaults.set(false, forKey: "declinedHooks")
        } catch {
            ask("Couldn't update Claude Code settings", "\(HookInstaller.settingsURL.path): \(error.localizedDescription)",
                buttons: ["OK"])
        }
    }

    @objc func toggleHooks() {
        if HookInstaller.status() == .missing {
            connectHooks()
        } else {
            try? HookInstaller.uninstall()
            defaults.set(true, forKey: "declinedHooks")
        }
    }

    @discardableResult
    func ask(_ title: String, _ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
