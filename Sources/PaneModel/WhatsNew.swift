import Foundation

/// Remembers the release notes of an update that is being installed, so the new version can show them once.
public enum WhatsNew {
    private static let buildKey = "whatsNewBuild", notesKey = "whatsNewNotes", versionKey = "whatsNewVersion"

    public static func save(version: String, build: Int, notes: String, defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: buildKey); defaults.set(notes, forKey: notesKey); defaults.set(version, forKey: versionKey)
    }

    /// The notes to show when the running build is the one that was just installed.
    public static func pending(currentBuild: Int, defaults: UserDefaults = .standard) -> (title: String, lines: [String])? {
        guard defaults.integer(forKey: buildKey) == currentBuild, currentBuild > 0,
              let notes = defaults.string(forKey: notesKey), !notes.isEmpty else { return nil }
        let version = defaults.string(forKey: versionKey) ?? ""
        return ("\(version) (\(currentBuild))", lines(from: notes))
    }

    public static func clear(defaults: UserDefaults = .standard) {
        for k in [buildKey, notesKey, versionKey] { defaults.removeObject(forKey: k) }
    }

    /// Notes are written as sentences separated by new lines or semicolons.
    public static func lines(from notes: String) -> [String] {
        notes.replacingOccurrences(of: ";", with: "\n").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
