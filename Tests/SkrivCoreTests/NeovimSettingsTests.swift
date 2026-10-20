import Foundation
import Testing
@testable import SkrivCore

private let realNeovimRequested = ProcessInfo.processInfo.environment["SKRIV_TEST_REAL_NVIM"] == "1"

struct NeovimSettingsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func cacheIsAnExplicitSnapshotAndResetRemovesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeovimSettingsCache(url: directory.appendingPathComponent("settings.json"))
        var source = NeovimSettings()
        source.number = true
        source.normal.background = 0x1E1E1E
        try cache.save(source)
        source.number = false
        #expect(cache.load()?.number == true, "Changing the live source must not silently mutate the snapshot.")
        try cache.save(source)
        #expect(cache.load()?.number == false)
        try cache.remove()
        #expect(cache.load() == nil)
    }

    @Test func missingCorruptFutureAndOversizeCacheFallBack() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeovimSettingsCache(url: directory.appendingPathComponent("settings.json"))
        #expect(cache.load() == nil)
        try Data("broken".utf8).write(to: cache.url)
        #expect(cache.load() == nil)
        try cache.save(NeovimSettings())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: cache.url)
        #expect(cache.load() == nil)
        try Data(repeating: 32, count: NeovimSettingsCache.maximumBytes + 1).write(to: cache.url)
        #expect(cache.load() == nil)
    }

    @Test func invalidSavePreservesLastValidCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NeovimSettingsCache(url: directory.appendingPathComponent("settings.json"))
        let original = NeovimSettings()
        try cache.save(original)
        var invalid = original
        invalid.tabstop = 0
        #expect(throws: NeovimImportError.invalidSettings) { try cache.save(invalid) }
        #expect(cache.load() == original)
        invalid = original
        invalid.normal.foreground = 0xFFFFFFFF
        #expect(throws: NeovimImportError.invalidSettings) { try cache.save(invalid) }
    }

    private func extraction(mappings: [[String: Any]] = []) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(NeovimSettings())) as? [String: Any])
        object["mappings"] = mappings
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func mapping(_ lhs: String, _ rhs: String, mode: String = "n", recursive: Bool = false,
                         expression: Bool = false, callback: Bool = false, buffer: Bool = false) -> [String: Any] {
        ["mode": mode, "lhs": lhs, "rhs": rhs, "noremap": !recursive,
         "expr": expression, "callback": callback, "buffer": buffer]
    }

    @Test func onlyExactlySupportedMappingsAreTranslated() throws {
        let result = try NeovimImporter.decode(extraction(mappings: [
            mapping("H", "h"), mapping("L", "l"), mapping("Q", "d"),
            mapping("j", "k", recursive: true),
            mapping("k", "j", expression: true),
            mapping("q", "", callback: true),
            mapping("jk", "<Esc>", mode: "i"),
            mapping("z", ":PluginCommand<CR>"),
            mapping("v", "h", buffer: true),
            mapping("f", "h"), mapping("ff", "l"),
            mapping("0", "^"),
            mapping("T", "h"), mapping("T", "l", buffer: true),
        ]))
        #expect(result.normalKeyMappings == ["H": "h", "L": "l", "Q": "d"])
        #expect(result.unsupportedMappings.count == 11)
        #expect(result.unsupportedMappings.contains { $0.contains("Lua callback") })
        #expect(result.unsupportedMappings.contains { $0.contains("prefix of another mapping") })
    }

    @Test func decodeRejectsInvalidSettingsAndOversizeOutput() throws {
        #expect(throws: NeovimImportError.invalidSettings) { try NeovimImporter.decode(Data("{}".utf8)) }
        #expect(throws: NeovimImportError.outputTooLarge) {
            try NeovimImporter.decode(Data(repeating: 32, count: NeovimSettingsCache.maximumBytes + 1))
        }
        var object = try #require(JSONSerialization.jsonObject(with: extraction()) as? [String: Any])
        object["tabstop"] = -1
        #expect(throws: NeovimImportError.invalidSettings) {
            try NeovimImporter.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    private func executableScript(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-nvim")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func processImportUsesExplicitExtractionFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = String(decoding: try extraction(), as: UTF8.self)
        let executable = try executableScript("cat > \"$SKRIV_IMPORT_OUTPUT\" <<'SETTINGS'\n\(json)\nSETTINGS\n", in: directory)
        let settings = try await NeovimImporter(executableURL: executable).importSettings()
        #expect(settings == NeovimSettings())
    }

    @Test func importTimesOutEvenWhileSpammingOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try executableScript("while :; do echo noise; echo noise >&2; done\n", in: directory)
        await #expect(throws: NeovimImportError.timedOut) {
            _ = try await NeovimImporter(executableURL: executable, timeout: 0.2).importSettings()
        }
    }

    @Test func failureReportsAtMostTheFirstFourKiBOfErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try executableScript("head -c 2000000 /dev/zero | tr '\\0' x >&2; exit 1\n", in: directory)
        do {
            _ = try await NeovimImporter(executableURL: executable, timeout: 5).importSettings()
            Issue.record("Expected a failed import")
        } catch NeovimImportError.failed(let message) {
            #expect(message.hasSuffix("xxxx"))
            #expect(message.utf8.count <= 4096 + "Neovim settings import failed.\n\n".utf8.count)
        }
    }

    @Test(.enabled(if: realNeovimRequested, "Opt in explicitly: SKRIV_TEST_REAL_NVIM=1 swift test --filter NeovimSettingsTests"))
    func realNeovimExplicitIntegration() async throws {
        let result = try await NeovimImporter().importSettings()
        #expect(result.isValid)
        #expect(result.normal.background != nil)
        print("Explicit Neovim import: Normal.bg=\(String(result.normal.background ?? 0, radix: 16)), " +
              "number=\(result.number), relativenumber=\(result.relativenumber), " +
              "wrap=\(result.wrap), linebreak=\(result.linebreak), " +
              "tabstop=\(result.tabstop), shiftwidth=\(result.shiftwidth), " +
              "appliedMappings=\(result.normalKeyMappings.count), unsupportedMappings=\(result.unsupportedMappings.count)")
    }

    @Test(.enabled(if: realNeovimRequested, "Real Neovim subprocess tests require explicit SKRIV_TEST_REAL_NVIM=1."))
    func realNeovimUnsetHighlightsUseFallbacks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let binary = try #require(paths.map { URL(fileURLWithPath: $0).appendingPathComponent("nvim") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let quotedBinary = "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Force a clean profile with no Normal colors, while using the production extractor.
        let executable = try executableScript("exec \(quotedBinary) -u NONE \"$@\" '+highlight clear Normal'\n", in: directory)
        let result = try await NeovimImporter(executableURL: executable).importSettings()
        #expect(result.isValid)
        #expect(result.normal.background == nil)
        #expect(result.normal.foreground == nil)
    }
}
