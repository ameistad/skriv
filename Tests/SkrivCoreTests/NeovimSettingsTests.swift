import XCTest
@testable import SkrivCore

final class NeovimSettingsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCacheIsAnExplicitSnapshotAndResetRemovesIt() throws {
        let cache = NeovimSettingsCache(url: try temporaryDirectory().appendingPathComponent("settings.json"))
        var source = NeovimSettings()
        source.number = true
        source.normal.background = 0x1E1E1E
        try cache.save(source)
        source.number = false
        XCTAssertEqual(cache.load()?.number, true, "Changing the live source must not silently mutate the snapshot.")
        try cache.save(source)
        XCTAssertEqual(cache.load()?.number, false)
        try cache.remove()
        XCTAssertNil(cache.load())
    }

    func testMissingCorruptFutureAndOversizeCacheFallBack() throws {
        let cache = NeovimSettingsCache(url: try temporaryDirectory().appendingPathComponent("settings.json"))
        XCTAssertNil(cache.load())
        try Data("broken".utf8).write(to: cache.url)
        XCTAssertNil(cache.load())
        try cache.save(NeovimSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: cache.url)
        XCTAssertNil(cache.load())
        try Data(repeating: 32, count: NeovimSettingsCache.maximumBytes + 1).write(to: cache.url)
        XCTAssertNil(cache.load())
    }

    func testInvalidSavePreservesLastValidCache() throws {
        let cache = NeovimSettingsCache(url: try temporaryDirectory().appendingPathComponent("settings.json"))
        let original = NeovimSettings()
        try cache.save(original)
        var invalid = original
        invalid.tabstop = 0
        XCTAssertThrowsError(try cache.save(invalid))
        XCTAssertEqual(cache.load(), original)
        invalid = original
        invalid.normal.foreground = 0xFFFFFFFF
        XCTAssertThrowsError(try cache.save(invalid))
    }

    private func extraction(mappings: [[String: Any]] = []) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(NeovimSettings())) as? [String: Any])
        object["mappings"] = mappings
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func mapping(_ lhs: String, _ rhs: String, mode: String = "n", recursive: Bool = false,
                         expression: Bool = false, callback: Bool = false, buffer: Bool = false) -> [String: Any] {
        ["mode": mode, "lhs": lhs, "rhs": rhs, "noremap": !recursive,
         "expr": expression, "callback": callback, "buffer": buffer]
    }

    func testOnlyExactlySupportedMappingsAreTranslated() throws {
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
        XCTAssertEqual(result.normalKeyMappings, ["H": "h", "L": "l", "Q": "d"])
        XCTAssertEqual(result.unsupportedMappings.count, 11)
        XCTAssertTrue(result.unsupportedMappings.contains { $0.contains("Lua callback") })
        XCTAssertTrue(result.unsupportedMappings.contains { $0.contains("prefix of another mapping") })
    }

    func testDecodeRejectsInvalidSettingsAndOversizeOutput() throws {
        XCTAssertThrowsError(try NeovimImporter.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try NeovimImporter.decode(Data(repeating: 32, count: NeovimSettingsCache.maximumBytes + 1)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: extraction()) as? [String: Any])
        object["tabstop"] = -1
        XCTAssertThrowsError(try NeovimImporter.decode(JSONSerialization.data(withJSONObject: object)))
    }

    private func executableScript(_ body: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("fake-nvim")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testProcessImportUsesExplicitExtractionFile() async throws {
        let json = String(decoding: try extraction(), as: UTF8.self)
        let executable = try executableScript("cat > \"$SKRIV_IMPORT_OUTPUT\" <<'SETTINGS'\n\(json)\nSETTINGS\n")
        let settings = try await NeovimImporter(executableURL: executable).importSettings()
        XCTAssertEqual(settings, NeovimSettings())
    }

    func testImportTimesOut() async throws {
        let executable = try executableScript("while :; do :; done\n")
        do {
            _ = try await NeovimImporter(executableURL: executable, timeout: 0.1).importSettings()
            XCTFail("Expected a bounded timeout")
        } catch NeovimImportError.timedOut { }
    }

    func testImportBoundsNoisyConfigurationOutput() async throws {
        let executable = try executableScript("while :; do printf 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\\n'; done\n")
        do {
            _ = try await NeovimImporter(executableURL: executable, timeout: 5).importSettings()
            XCTFail("Expected output limit")
        } catch NeovimImportError.outputTooLarge { }
    }

    func testRealNeovimExplicitIntegration() async throws {
        guard ProcessInfo.processInfo.environment["SKRIV_TEST_REAL_NVIM"] == "1" else {
            throw XCTSkip("Opt in explicitly: SKRIV_TEST_REAL_NVIM=1 swift test --filter testRealNeovimExplicitIntegration")
        }
        let result = try await NeovimImporter().importSettings()
        XCTAssertTrue(result.isValid)
        XCTAssertNotNil(result.normal.background)
        print("Explicit Neovim import: Normal.bg=\(String(result.normal.background ?? 0, radix: 16)), " +
              "number=\(result.number), relativenumber=\(result.relativenumber), " +
              "wrap=\(result.wrap), linebreak=\(result.linebreak), " +
              "tabstop=\(result.tabstop), shiftwidth=\(result.shiftwidth), " +
              "appliedMappings=\(result.normalKeyMappings.count), unsupportedMappings=\(result.unsupportedMappings.count)")
    }

    func testRealNeovimUnsetHighlightsUseFallbacks() async throws {
        guard ProcessInfo.processInfo.environment["SKRIV_TEST_REAL_NVIM"] == "1" else {
            throw XCTSkip("Real Neovim subprocess tests require explicit SKRIV_TEST_REAL_NVIM=1.")
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let binary = try XCTUnwrap(paths.map { URL(fileURLWithPath: $0).appendingPathComponent("nvim") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let quotedBinary = "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Force a clean profile with no Normal colors, while using the production extractor.
        let executable = try executableScript("exec \(quotedBinary) -u NONE \"$@\" '+highlight clear Normal'\n")
        let result = try await NeovimImporter(executableURL: executable).importSettings()
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.normal.background)
        XCTAssertNil(result.normal.foreground)
    }
}
