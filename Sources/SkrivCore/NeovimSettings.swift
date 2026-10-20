import Foundation

/// Resolved snapshot, regenerated only by an explicit import. Neovim owns these values.
struct NeovimSettings: Codable, Equatable, Sendable {
    struct Highlight: Codable, Equatable, Sendable {
        var foreground: UInt32?
        var background: UInt32?

        var isValid: Bool {
            [foreground, background].compactMap { $0 }.allSatisfy { $0 <= 0xFFFFFF }
        }
    }

    var normal = Highlight()
    var visual = Highlight()
    var cursor = Highlight()
    var lineNr = Highlight()
    var number = false
    var relativenumber = false
    var wrap = true
    var linebreak = false
    var expandtab = false
    var tabstop = 8
    var shiftwidth = 0
    var guifont = ""
    var mapleader = "\\"
    var normalKeyMappings: [String: String] = [:]
    var unsupportedMappings: [String] = []
    var warnings: [String] = []

    // Standalone native commands and operators, never an Ex/plugin command or key sequence.
    static let supportedNormalTargets = Set("hjklwbeWBE0$^iaIAoOxXpPuDCYGdcy".map(String.init))

    var isValid: Bool {
        [normal, visual, cursor, lineNr].allSatisfy(\.isValid)
            && (1...9999).contains(tabstop) && (0...9999).contains(shiftwidth)
            && guifont.utf8.count <= 4096 && mapleader.utf8.count <= 256
            && normalKeyMappings.count <= 4096
            && normalKeyMappings.allSatisfy { key, value in
                key.count == 1 && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && !Set("0123456789".map(String.init)).contains(key)
                    && Self.supportedNormalTargets.contains(value)
            }
            && unsupportedMappings.count <= 8192 && warnings.count <= 128
    }
}

struct NeovimSettingsCache: Sendable {
    static let version = 1
    static let maximumBytes = 1_048_576
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Skriv", isDirectory: true)
        .appendingPathComponent("neovim-settings-v1.json")) {
        self.url = url
    }

    private struct Envelope: Codable {
        let version: Int
        let importedAt: Date
        let settings: NeovimSettings
    }

    func load() -> NeovimSettings? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.version, envelope.settings.isValid else { return nil }
        return envelope.settings
    }

    func save(_ settings: NeovimSettings) throws {
        guard settings.isValid else { throw NeovimImportError.invalidSettings }
        let data = try JSONEncoder().encode(Envelope(version: Self.version, importedAt: Date(), settings: settings))
        guard data.count <= Self.maximumBytes else { throw NeovimImportError.outputTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
