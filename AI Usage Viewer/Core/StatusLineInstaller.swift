// StatusLineInstaller.swift
// AI Usage Viewer
//
// Installs a Claude Code status-line script that saves `rate_limits` to a
// file the app watches, so usage arrives live while you use Claude Code
// without spending the usage endpoint's shared rate limit. Any status line
// you already had keeps working: the script runs it with the same input,
// and uninstalling restores it exactly.

import Foundation

nonisolated struct StatusLineInstaller: Sendable {
    enum State: Equatable, Sendable {
        case notInstalled
        case installed
        // Our script is installed but settings.json points somewhere else.
        case replaced
    }

    enum InstallError: LocalizedError {
        case unreadableSettings(String)
        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let why):
                "Couldn't read ~/.claude/settings.json (\(why)). It was left unchanged."
            }
        }
    }

    let settingsURL: URL
    let supportDir:  URL

    var scriptURL:          URL { supportDir.appendingPathComponent("statusline-feed.sh") }
    var feedURL:            URL { supportDir.appendingPathComponent("statusline-feed.json") }
    var previousObjectURL:  URL { supportDir.appendingPathComponent("previous-statusline.json") }
    var previousCommandURL: URL { supportDir.appendingPathComponent("previous-statusline-command") }
    var backupURL:          URL { settingsURL.appendingPathExtension("usage-viewer-backup") }

    var command: String { Self.shellQuote(scriptURL.path) }

    func state() -> State {
        let settings = try? readSettings()
        let current = (settings?["statusLine"] as? [String: Any])?["command"] as? String
        if current == command { return .installed }
        return FileManager.default.fileExists(atPath: scriptURL.path) ? .replaced : .notInstalled
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        var settings = try readSettings()

        // Always rewrite the script so an app update can change it.
        try Data(Self.script(supportDir: supportDir.path).utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let previous = settings["statusLine"] as? [String: Any]
        if (previous?["command"] as? String) == command { return }

        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: settingsURL, to: backupURL)
        }
        if let previous {
            try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys])
                .write(to: previousObjectURL, options: .atomic)
            if let cmd = previous["command"] as? String, !cmd.isEmpty {
                try Data(cmd.utf8).write(to: previousCommandURL, options: .atomic)
            } else {
                try? fm.removeItem(at: previousCommandURL)
            }
        } else {
            try? fm.removeItem(at: previousObjectURL)
            try? fm.removeItem(at: previousCommandURL)
        }

        var ours: [String: Any] = ["type": "command", "command": command]
        if let padding = previous?["padding"] { ours["padding"] = padding }
        settings["statusLine"] = ours
        try writeSettings(settings)
    }

    func uninstall() throws {
        let fm = FileManager.default
        var settings = try readSettings()
        let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
        if current == command {
            if let data = try? Data(contentsOf: previousObjectURL),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings["statusLine"] = previous
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            try writeSettings(settings)
        }
        for url in [scriptURL, previousObjectURL, previousCommandURL, feedURL] {
            try? fm.removeItem(at: url)
        }
    }

    // After the support folder moves, point an installed status line at
    // the script's new home. The saved previous status line moved with the
    // folder, so it's kept as is rather than re-saved (re-saving would make
    // the old, now missing, script the "previous" one).
    @discardableResult
    func adopt(legacyCommand: String) throws -> Bool {
        let fm = FileManager.default
        var settings = try readSettings()
        guard var line = settings["statusLine"] as? [String: Any],
              (line["command"] as? String) == legacyCommand else { return false }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try Data(Self.script(supportDir: supportDir.path).utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try? fm.removeItem(at: backupURL)
        try fm.copyItem(at: settingsURL, to: backupURL)
        line["command"] = command
        settings["statusLine"] = line
        try writeSettings(settings)
        return true
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: settingsURL) } catch {
            throw InstallError.unreadableSettings(error.localizedDescription)
        }
        if data.isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadableSettings("not a JSON object")
        }
        return obj
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func script(supportDir: String) -> String {
        """
        #!/bin/sh
        # Installed by AI Usage Viewer. Claude Code runs this as its status
        # line and passes session JSON on stdin. We keep only `rate_limits` for
        # the menu-bar app, then hand the same input to your previous status
        # line (if any) so its output is unchanged. Remove it from the app's
        # Settings; that restores your previous status line.
        dir=\(shellQuote(supportDir))
        input=$(cat)
        umask 077
        tmp="$dir/.feed.$$"
        if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$tmp" - 2>/dev/null; then
          mv -f "$tmp" "$dir/statusline-feed.json"
        else
          rm -f "$tmp"
        fi
        if [ -s "$dir/previous-statusline-command" ]; then
          printf '%s' "$input" | /bin/sh -c "$(cat "$dir/previous-statusline-command")"
        fi

        """
    }
}

// The app was called Claude Usage Viewer until it grew Gemini and OpenAI
// support. Its support folder (history, live-feed script, your saved status
// line) moves to the new name once; nothing happens if it already moved.
nonisolated enum SupportFolderMigration {
    enum Outcome: Equatable, Sendable {
        case nothingToDo
        case moved(statusLineUpdated: Bool)
        case failed(String)
    }

    static func run(from old: URL, to new: URL, settingsURL: URL, fm: FileManager = .default) -> Outcome {
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return .nothingToDo }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
        } catch {
            return .failed("couldn't move \(old.lastPathComponent): \(error.localizedDescription)")
        }
        let legacy = StatusLineInstaller(settingsURL: settingsURL, supportDir: old)
        let current = StatusLineInstaller(settingsURL: settingsURL, supportDir: new)
        do {
            return .moved(statusLineUpdated: try current.adopt(legacyCommand: legacy.command))
        } catch {
            // Put the folder back so the status line's script still exists;
            // the next launch tries again.
            try? fm.moveItem(at: new, to: old)
            return .failed("couldn't update the status line: \(error.localizedDescription)")
        }
    }
}
