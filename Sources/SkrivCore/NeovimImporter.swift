import Foundation
import Darwin

enum NeovimImportError: LocalizedError {
    case unavailable, timedOut, outputTooLarge, invalidSettings
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Neovim was not found. Install Neovim, then import again."
        case .timedOut: "Neovim settings import timed out. Existing settings have been kept."
        case .outputTooLarge: "Neovim produced too much output. Existing settings have been kept."
        case .invalidSettings: "Neovim returned invalid or unsupported settings. Existing settings have been kept."
        case .failed(let message): "Neovim settings import failed.\n\n\(message)"
        }
    }
}

struct NeovimImporter: Sendable {
    var executableURL: URL?
    var timeout: TimeInterval = 15

    /// Called only by the explicit import action. Does not invoke a shell.
    func importSettings() async throws -> NeovimSettings {
        try await Task.detached(priority: .userInitiated) {
            try self.run()
        }.value
    }

    private func executable() throws -> URL {
        if let executableURL { return executableURL }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("nvim")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw NeovimImportError.unavailable
    }

    private func run() throws -> NeovimSettings {
        let executable = try executable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("extract.lua")
        let output = directory.appendingPathComponent("settings.json")
        try Self.extractionScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--headless", "-n", "-i", "NONE", "--cmd", "set noexrc",
                             "-c", "lua vim.schedule(function() dofile(vim.env.SKRIV_IMPORT_SCRIPT) end)"]
        var environment = ProcessInfo.processInfo.environment
        environment["SKRIV_IMPORT_SCRIPT"] = script.path
        environment["SKRIV_IMPORT_OUTPUT"] = output.path
        process.environment = environment
        // Avoid resolving project-local configuration from whichever folder launched the app.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = BoundedImportLog()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { log.append(data) }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime > deadline || log.overflowed {
                process.terminate()
                let terminateDeadline = ProcessInfo.processInfo.systemUptime + 0.3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < terminateDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw log.overflowed ? NeovimImportError.outputTooLarge : NeovimImportError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !log.overflowed else { throw NeovimImportError.outputTooLarge }
        guard process.terminationStatus == 0 else {
            throw NeovimImportError.failed(log.text.isEmpty ? "Neovim exited with status \(process.terminationStatus)." : log.text)
        }
        guard let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= NeovimSettingsCache.maximumBytes else { throw NeovimImportError.invalidSettings }
        return try Self.decode(Data(contentsOf: output))
    }

    struct Mapping: Codable {
        var mode: String
        var lhs: String
        var rhs: String
        var noremap: Bool
        var expr: Bool
        var callback: Bool
        var buffer: Bool
    }

    private struct Extraction: Decodable {
        var normal: NeovimSettings.Highlight
        var visual: NeovimSettings.Highlight
        var cursor: NeovimSettings.Highlight
        var lineNr: NeovimSettings.Highlight
        var number: Bool
        var relativenumber: Bool
        var wrap: Bool
        var linebreak: Bool
        var expandtab: Bool
        var tabstop: Int
        var shiftwidth: Int
        var guifont: String
        var mapleader: String
        var mappings: [Mapping]
        var warnings: [String]
    }

    static func decode(_ data: Data) throws -> NeovimSettings {
        guard data.count <= NeovimSettingsCache.maximumBytes else { throw NeovimImportError.outputTooLarge }
        let raw: Extraction
        do { raw = try JSONDecoder().decode(Extraction.self, from: data) }
        catch { throw NeovimImportError.invalidSettings }
        var result = NeovimSettings(
            normal: raw.normal, visual: raw.visual, cursor: raw.cursor, lineNr: raw.lineNr,
            number: raw.number, relativenumber: raw.relativenumber, wrap: raw.wrap,
            linebreak: raw.linebreak, expandtab: raw.expandtab, tabstop: raw.tabstop,
            shiftwidth: raw.shiftwidth, guifont: raw.guifont, mapleader: raw.mapleader,
            warnings: raw.warnings
        )
        guard raw.mappings.count <= 8192 else { throw NeovimImportError.outputTooLarge }
        for mapping in raw.mappings {
            let reason: String?
            if mapping.callback { reason = "Lua callback" }
            else if mapping.expr { reason = "expression mapping" }
            else if mapping.buffer { reason = "buffer-local mapping" }
            else if mapping.mode != "n" { reason = "only Normal-mode remaps are supported" }
            else if !mapping.noremap { reason = "recursive mapping" }
            else if mapping.lhs.count != 1 || mapping.lhs.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                reason = "key sequence or special key"
            } else if Set("0123456789".map(String.init)).contains(mapping.lhs) {
                reason = "count key"
            } else if !NeovimSettings.supportedNormalTargets.contains(mapping.rhs) {
                reason = "unsupported command or key sequence"
            } else if raw.mappings.contains(where: {
                $0.mode == "n" && $0.buffer && $0.lhs == mapping.lhs
            }) {
                reason = "overridden by a buffer-local mapping"
            } else if raw.mappings.contains(where: {
                $0.mode == "n" && $0.lhs != mapping.lhs && $0.lhs.hasPrefix(mapping.lhs)
            }) {
                reason = "prefix of another mapping"
            } else { reason = nil }
            if let reason {
                result.unsupportedMappings.append("\(mapping.mode) \(mapping.lhs) → \(mapping.callback ? "<Lua callback>" : mapping.rhs): \(reason)")
            } else {
                result.normalKeyMappings[mapping.lhs] = mapping.rhs
            }
        }
        guard result.isValid else { throw NeovimImportError.invalidSettings }
        return result
    }

    // APIs documented at https://neovim.io/doc/user/api/.
    // Run after normal startup, preserving the selected NVIM_APPNAME profile.
    private static let extractionScript = #"""
    local ok, err = pcall(function()
      local a = vim.api
      local function hl(name)
        local h = a.nvim_get_hl(0, {name=name, link=false})
        local fg, bg = h.fg, h.bg
        if h.reverse then fg, bg = bg, fg end
        local resolved = vim.empty_dict()
        resolved.foreground, resolved.background = fg, bg
        return resolved
      end
      local result = {
        normal=hl('Normal'), visual=hl('Visual'), cursor=hl('Cursor'), lineNr=hl('LineNr'),
        number=vim.o.number, relativenumber=vim.o.relativenumber,
        wrap=vim.o.wrap, linebreak=vim.o.linebreak, expandtab=vim.o.expandtab,
        tabstop=vim.o.tabstop, shiftwidth=vim.o.shiftwidth,
        guifont=vim.o.guifont, mapleader=tostring(vim.g.mapleader or '\\'),
        mappings={}, warnings={},
      }
      for _, mode in ipairs({'n','i','v','x','s','o','c','t'}) do
        for _, buffer in ipairs({false, true}) do
          local maps = buffer and a.nvim_buf_get_keymap(0, mode) or a.nvim_get_keymap(mode)
          for _, m in ipairs(maps) do
            if #result.mappings >= 8192 then error('Too many key mappings') end
            table.insert(result.mappings, {
              mode=mode, lhs=m.lhs, rhs=m.rhs or '',
              noremap=m.noremap == 1, expr=m.expr == 1,
              callback=m.callback ~= nil, buffer=buffer,
            })
          end
        end
      end
      if vim.v.errmsg ~= '' then table.insert(result.warnings, vim.v.errmsg) end
      local encoded = vim.json.encode(result)
      if #encoded > 1048576 then error('Settings output exceeds 1 MiB') end
      local file = assert(io.open(vim.env.SKRIV_IMPORT_OUTPUT, 'wb'))
      file:write(encoded)
      file:close()
    end)
    if not ok then
      io.stderr:write(tostring(err))
      vim.cmd('cquit 1')
    else
      vim.cmd('qa!')
    end
    """#
}

/// A bounded drain prevents a noisy configuration from blocking its own stdout pipe.
private final class BoundedImportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    var overflowed: Bool { lock.withLock { exceeded } }
    var text: String { lock.withLock { String(decoding: bytes.prefix(4096), as: UTF8.self) } }

    func append(_ data: Data) {
        lock.withLock {
            let remaining = NeovimSettingsCache.maximumBytes - bytes.count
            if data.count > remaining { exceeded = true }
            bytes.append(data.prefix(max(0, remaining)))
        }
    }
}
