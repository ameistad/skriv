#!/usr/bin/env swift
// Development-only benchmarks and Vim differential checks. No external Swift packages.
import Foundation
import CryptoKit
import Darwin

typealias Object = [String: Any]
nonisolated var fm: FileManager { .default }
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let compilerFlags = ["-O", "-whole-module-optimization", "-swift-version", "6"]
let workloads = [("unicode", 100_000), ("unicode", 1_000_000), ("singleLine", 10_000_000), ("denseLines", 1_000_000)]

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
struct ProcessTimeout: Error { let seconds: Double }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
func path(_ string: String) -> URL { URL(fileURLWithPath: (string as NSString).expandingTildeInPath).standardizedFileURL }
func directory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
func temporary(_ prefix: String, in parent: URL = fm.temporaryDirectory) throws -> URL {
    let result = parent.appendingPathComponent(prefix + UUID().uuidString.lowercased())
    try directory(result)
    return result
}
func json(_ value: Any, pretty: Bool = true) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed])
}
func readJSON(_ data: Data) throws -> Object {
    guard let value = try JSONSerialization.jsonObject(with: data) as? Object else { throw Failure("Expected a JSON object") }
    return value
}
func readJSON(_ url: URL) throws -> Object { try readJSON(Data(contentsOf: url)) }
func writeJSON(_ value: Any, to url: URL) throws {
    try directory(url.deletingLastPathComponent())
    try (json(value) + Data("\n".utf8)).write(to: url, options: .atomic)
}
func display(_ value: Any) throws { print(String(decoding: try json(value), as: UTF8.self)); fflush(stdout) }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func executable(_ name: String) throws -> URL {
    if name.contains("/") {
        let url = path(name)
        try require(fm.isExecutableFile(atPath: url.path), "Executable not found: \(name)")
        return url
    }
    for component in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
        let url = path(component.isEmpty ? "." : String(component)).appendingPathComponent(name)
        if fm.isExecutableFile(atPath: url.path) { return url }
    }
    if name == "nvim", fm.isExecutableFile(atPath: "/opt/homebrew/bin/nvim") { return path("/opt/homebrew/bin/nvim") }
    throw Failure("Executable not found: \(name)")
}
struct ProcessResult { let output: Data; let error: Data; let elapsedMilliseconds: Double }
// Files avoid pipe-buffer deadlocks when a fixture produces a large JSON report.
func run(_ command: [String], cwd: URL? = nil, environment: [String: String] = [:], timeout: Double = 300,
         launchClock: Bool = false) throws -> ProcessResult {
    let work = try temporary("skriv-process-")
    defer { try? fm.removeItem(at: work) }
    let outURL = work.appendingPathComponent("stdout"), errURL = work.appendingPathComponent("stderr")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
    defer { try? out.close(); try? err.close() }
    let process = Process()
    process.executableURL = try executable(command[0])
    process.arguments = Array(command.dropFirst())
    process.currentDirectoryURL = cwd
    process.standardOutput = out
    process.standardError = err
    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completed.signal() }
    var env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    let start = DispatchTime.now().uptimeNanoseconds
    if launchClock { env["SKRIV_PROCESS_LAUNCH_UPTIME_NS"] = String(start) }
    process.environment = env
    try process.run()
    if completed.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        // Give normal termination a short grace period, then reap an unresponsive fixture.
        if completed.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        throw ProcessTimeout(seconds: timeout)
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    process.waitUntilExit()
    let result = ProcessResult(output: try Data(contentsOf: outURL), error: try Data(contentsOf: errURL), elapsedMilliseconds: elapsed)
    try require(process.terminationStatus == 0,
                "\(command.joined(separator: " ")) exited \(process.terminationStatus):\n\(String(decoding: result.error, as: UTF8.self))\(String(decoding: result.output, as: UTF8.self))")
    return result
}
func output(_ command: [String]) throws -> String {
    String(decoding: try run(command).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func median(_ values: [Double]) -> Double {
    let sorted = values.sorted(), middle = values.count / 2
    return values.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
func rounded(_ number: Double, _ digits: Int) -> Double {
    let factor = pow(10.0, Double(digits))
    return (number * factor).rounded(.toNearestOrEven) / factor
}
func summarize(_ values: [Double], digits: Int = 3) throws -> Object {
    try require(!values.isEmpty && values.allSatisfy(\.isFinite), "Cannot summarize empty or non-finite samples")
    let sorted = values.sorted()
    return ["samples": values.count, "median": rounded(median(sorted), digits),
            "p95": rounded(sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], digits),
            "min": rounded(sorted.first!, digits), "max": rounded(sorted.last!, digits)]
}
func addSummary(_ report: Object) throws -> Object {
    var result = report, summary: Object = [:]
    for (key, value) in report where key.hasSuffix("Milliseconds") {
        if let values = value as? [Double] { summary[key] = try summarize(values, digits: 6) }
    }
    result["summary"] = summary
    return result
}
func fullReadiness(_ samples: [Object]) throws -> [Object] {
    var result = samples
    for kind in ["coldStartup", "coldProcess", "warmInvocation"] {
        func times(_ stage: String) -> [Double] {
            samples.filter { $0["kind"] as? String == kind && $0["stage"] as? String == stage }.compactMap { $0["milliseconds"] as? Double }
        }
        let event = times("eventLoopReady"), interface = times("interfaceComplete")
        try require(event.count == interface.count, "Unpaired readiness samples for \(kind)")
        for (a, b) in zip(event, interface) {
            result.append(["kind": kind, "stage": "fullyReady", "milliseconds": max(a, b), "derived": true])
        }
    }
    return result
}
func aggregate(_ samples: [Object]) throws -> Object {
    var groups: [String: [Double]] = [:]
    for sample in samples {
        guard let kind = sample["kind"] as? String, let stage = sample["stage"] as? String else { throw Failure("Invalid metrics sample") }
        let field = kind == "memory" ? "residentBytes" : "milliseconds"
        guard let value = sample[field] as? Double else { throw Failure("Missing metric \(field)") }
        groups["\(kind).\(stage).\(field)", default: []].append(value)
    }
    return try groups.mapValues { try summarize($0) }
}
func metrics(_ url: URL) throws -> [Object] {
    try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map { try readJSON(Data($0.utf8)) }
}

struct Arguments {
    var values: [String: [String]] = [:]
    init(_ arguments: [String], flags: Set<String> = [], lists: Set<String> = [], options: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            try require(options.contains(key) || flags.contains(key) || lists.contains(key), "Unknown option: \(key)")
            try require(values[key] == nil, "Repeated option: \(key)")
            index += 1
            if flags.contains(key) { values[key] = []; continue }
            var items: [String] = []
            while index < arguments.count && !arguments[index].hasPrefix("--") {
                items.append(arguments[index]); index += 1
                if !lists.contains(key) { break }
            }
            try require(!items.isEmpty, "Missing value for \(key)")
            values[key] = items
        }
    }
    func has(_ key: String) -> Bool { values[key] != nil }
    func string(_ key: String, _ fallback: String? = nil) throws -> String {
        guard let value = values[key]?.first ?? fallback else { throw Failure("Required option: \(key)") }
        return value
    }
    func int(_ key: String, _ fallback: Int, range: ClosedRange<Int> = 1...Int.max) throws -> Int {
        guard let value = Int(try string(key, String(fallback))), range.contains(value) else { throw Failure("Invalid \(key); expected \(range)") }
        return value
    }
    func selections(_ key: String, default fallback: [String], allowed: Set<String>) throws -> [String] {
        let items = values[key] ?? fallback
        try require(items.allSatisfy { allowed.contains($0) }, "Invalid \(key); choose \(allowed.sorted().joined(separator: ", "))")
        return items
    }
}
func metadata(sources: [URL], fixture: URL, sourceRoot: URL, flags: [String]) throws -> Object {
    ["recordedAt": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
     "cpu": try output(["sysctl", "-n", "machdep.cpu.brand_string"]), "swift": try output(["swiftc", "--version"]),
     "compilerFlags": flags, "sourceRoot": sourceRoot.path,
     "sourceSHA256": try Dictionary(uniqueKeysWithValues: sources.map { ($0.lastPathComponent, try hash($0)) }),
     "fixtureSHA256": try hash(fixture)]
}
func compile(_ sources: [URL], fixture: URL, work: URL, flags: [String] = compilerFlags) throws -> URL {
    let main = work.appendingPathComponent("main.swift"), binary = work.appendingPathComponent("benchmark")
    try fm.copyItem(at: fixture, to: main)
    _ = try run(["swiftc"] + flags + sources.map(\.path) + [main.path, "-o", binary.path])
    return binary
}

func launch(app: URL, runs: Int, warm: Int, destination: URL, requireReadiness: Bool) throws -> (Object, URL) {
    let binary = app.appendingPathComponent("Contents/MacOS/Skriv")
    try require(fm.isExecutableFile(atPath: binary.path), "Build the release bundle first: ./scripts/build-app.sh release")
    let work = try temporary("run-", in: destination)
    let configuration = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/skriv/config.skriv")
    func configData() throws -> Data? { fm.fileExists(atPath: configuration.path) ? try Data(contentsOf: configuration) : nil }
    let before = try configData()
    var samples: [Object] = []
    for index in 0..<runs {
        let file = work.appendingPathComponent("process-\(index + 1).jsonl")
        _ = try run([binary.path, "--benchmark-launch-count", String(warm)], environment: ["SKRIV_METRICS_PATH": file.path],
                    timeout: Double(30 + warm), launchClock: true)
        let batch = try metrics(file)
        for (kind, expected) in [("coldStartup", 1), ("coldProcess", 1), ("warmInvocation", warm)] {
            let stages = ["inputReady", "displaySubmitted"] + (requireReadiness ? ["eventLoopReady", "interfaceComplete"] : [])
            var boundaries: [String: [Double]] = [:]
            for stage in stages {
                let values = batch.filter { $0["kind"] as? String == kind && $0["stage"] as? String == stage }.compactMap { $0["milliseconds"] as? Double }
                try require(values.count == expected, "Run \(index + 1): expected \(expected) \(kind)/\(stage), got \(values.count)")
                boundaries[stage] = values
            }
            if requireReadiness {
                for i in 0..<expected {
                    try require(boundaries["inputReady"]![i] <= boundaries["displaySubmitted"]![i]
                                && boundaries["displaySubmitted"]![i] <= min(boundaries["eventLoopReady"]![i], boundaries["interfaceComplete"]![i]),
                                "Run \(index + 1): invalid readiness ordering for \(kind)")
                }
            }
        }
        samples += try fullReadiness(batch)
        print("Process \(index + 1)/\(runs) complete"); fflush(stdout)
    }
    try require(before == configData(), "Editor settings changed during the benchmark; rerun with a stable configuration.")
    let results = try aggregate(samples)
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])!
    var bundleBytes = 0
    for case let url as URL in enumerator {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if properties.isRegularFile == true { bundleBytes += properties.fileSize ?? 0 }
    }
    let report: Object = [
        "recordedAt": ISO8601DateFormatter().string(from: Date()),
        "hardware": ["model": try output(["sysctl", "-n", "hw.model"]), "cpu": try output(["sysctl", "-n", "machdep.cpu.brand_string"]),
                     "memoryBytes": Int(try output(["sysctl", "-n", "hw.memsize"]))!, "architecture": try output(["uname", "-m"])],
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "clock": ["implementation": "DispatchTime.uptimeNanoseconds (mach_absolute_time)", "monotonic": true, "adjustable": false,
                  "resolution": Double(timebase.numer) / Double(timebase.denom) / 1e9],
        "configurationPath": configuration.path, "configurationPresent": before != nil,
        "configurationSHA256": before.map(hash) as Any? ?? NSNull(), "executable": binary.path,
        "bundleBytes": bundleBytes, "executableBytes": try binary.resourceValues(forKeys: [.fileSizeKey]).fileSize!,
        "runs": runs, "warmOpensPerProcess": warm, "requiresReadiness": requireReadiness, "results": results,
        "limitations": [
            "Build release immediately before benchmarking; configuration is not inferred.",
            "coldProcess begins immediately before Swift Process.run, including environment assignment, process creation, and dyld; excludes Launch Services.",
            "coldStartup begins in main. Neither cold measurement forces OS filesystem caches to be cold.",
            "Warm timing invokes the shared document action, excluding hardware key delivery.",
            "Input readiness means the editor was assigned first responder, not event delivery latency.",
            "eventLoopReady requires a main-queue turn, active app, key window and editor first responder; it does not measure hardware input latency.",
            "interfaceComplete includes secondary UI and its AppKit drawing submission; full usability requires eventLoopReady as well.",
            "Display submission is AppKit draw completion, not compositor or screen presentation.",
            "Resident bytes are point-in-time RSS, not memory pressure or physical footprint.",
            "Benchmark processes use current local settings and do not alter them."
        ]
    ]
    let reportURL = work.appendingPathComponent("summary.json")
    try writeJSON(report, to: reportURL)
    try display(results)
    print("Bundle: \(bundleBytes) bytes\nFull report: \(reportURL.path)")
    return (report, work)
}

func editing(_ args: Arguments) throws {
    let sourceRoot = path(try args.string("--source-root", root.path))
    let destination = path(try args.string("--output"))
    let native = args.has("--native")
    let fixture = root.appendingPathComponent("scripts/fixtures/\(native ? "NativeEditingBenchmarkMain" : "EditingBenchmarkMain").swift")
    let sources = (["VimEngine.swift", "LiteralSearch.swift"] + (native ? ["VimTextView.swift"] : [])).map { sourceRoot.appendingPathComponent("Sources/SkrivCore/" + $0) }
    let work = try temporary("skriv-editing-")
    defer { try? fm.removeItem(at: work) }
    let binary = try compile(sources, fixture: fixture, work: work)
    var report = try readJSON(run([binary.path], timeout: 180).output)
    var info = try metadata(sources: sources, fixture: fixture, sourceRoot: sourceRoot, flags: compilerFlags)
    info["workload"] = native ? "offscreenAppKit" : "engine"
    report["metadata"] = info
    guard let raw = report["workloads"] as? [Object] else { throw Failure("Missing editing workloads") }
    report["workloads"] = try raw.map { item in
        let result = try addSummary(item)
        try display(result.filter { !($0.value is [Any]) })
        return result
    }
    try writeJSON(report, to: destination)
}
func markdown(_ args: Arguments) throws {
    let sourceRoot = path(try args.string("--source-root", root.path)), destination = path(try args.string("--output"))
    let runs = try args.int("--runs", 3)
    let sources = try fm.contentsOfDirectory(at: sourceRoot.appendingPathComponent("Sources/SkrivCore"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let fixture = root.appendingPathComponent("scripts/fixtures/MarkdownBenchmarkMain.swift")
    let flags = compilerFlags + ["-D", "MARKDOWN_DIAGNOSTICS"]
    let info = try metadata(sources: sources, fixture: fixture, sourceRoot: sourceRoot, flags: flags)
    let work = try temporary("skriv-markdown-")
    defer { try? fm.removeItem(at: work) }
    let binary = try compile(sources, fixture: fixture, work: work, flags: flags)
    var results: [Object] = []
    for index in 0..<runs {
        for (shape, size) in [("notes", 10_000), ("notes", 100_000), ("notes", 1_000_000),
                              ("notes", 1_500_000), ("dense", 100_000), ("long", 100_000), ("short", 1_000_000)] {
            for enabled in index.isMultiple(of: 2) ? ["off", "on"] : ["on", "off"] {
                var report = try readJSON(run([binary.path, shape, String(size), enabled, "--benchmark-launch-count", "1"], timeout: 120).output)
                report["run"] = index
                results.append(report)
                print("Markdown \(index + 1)/\(runs): \(shape) \(size) \(enabled)"); fflush(stdout)
            }
        }
    }
    try writeJSON(["metadata": info, "workloads": results], to: destination)
}

func largeFiles(_ args: Arguments) throws {
    let sourceRoot = path(try args.string("--source-root", root.path)), destination = path(try args.string("--output"))
    let runs = try args.int("--runs", 3)
    let profiles = try args.selections("--profiles", default: ["offscreen"], allowed: ["offscreen", "engine", "visible"])
    let shapes = try args.selections("--shapes", default: ["unicode", "singleLine", "denseLines"], allowed: ["unicode", "singleLine", "denseLines"])
    guard let timeout = Double(try args.string("--timeout", "300")), timeout.isFinite, timeout > 0 else { throw Failure("--timeout must be positive and finite") }
    let sources = try fm.contentsOfDirectory(at: sourceRoot.appendingPathComponent("Sources/SkrivCore"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let fixture = root.appendingPathComponent("scripts/fixtures/LargeFileBenchmarkMain.swift")
    let flags = compilerFlags + (args.has("--diagnostics") ? ["-D", "LAZY_INDEX_DIAGNOSTICS"] : [])
    let info = try metadata(sources: sources, fixture: fixture, sourceRoot: sourceRoot, flags: flags)
    let work = try temporary("skriv-large-files-")
    defer { try? fm.removeItem(at: work) }
    let binary = try compile(sources, fixture: fixture, work: work, flags: flags)
    var results: [Object] = []
    for index in 0..<runs {
        for profile in profiles {
            for (shape, repetitions) in workloads where shapes.contains(shape) {
                let command = [binary.path, shape, String(repetitions), profile] + (profile == "visible" ? ["--benchmark-launch-count", "1"] : [])
                var report: Object
                do { report = try readJSON(run(command, environment: ["SKRIV_BENCHMARK_DIRECTORY": work.path], timeout: timeout).output) }
                catch is ProcessTimeout { report = ["profile": profile, "shape": shape, "repetitions": repetitions, "error": "processTimeout", "timeoutSeconds": timeout] }
                report["run"] = index
                report = try addSummary(report)
                results.append(report)
                try display(report.filter { !($0.value is [Any]) })
            }
        }
    }
    try writeJSON(["metadata": info, "workloads": results], to: destination)
}

// Fixed-seed generator makes bootstrap intervals reproducible without external packages.
struct BootstrapRandom: RandomNumberGenerator {
    var state: UInt64 = 0
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
func pairedChange(_ before: [Double], _ after: [Double]) throws -> Object {
    try require(!before.isEmpty && before.count == after.count, "Unpaired launch comparison samples")
    let deltas = zip(before, after).map { $1 - $0 }
    var random = BootstrapRandom()
    let bootstraps = (0..<5000).map { _ in median(deltas.map { _ in deltas[Int.random(in: deltas.indices, using: &random)] }) }.sorted()
    return ["pairs": deltas.count, "medianDeltaMilliseconds": rounded(median(deltas), 3),
            "medianDelta95PercentBootstrapInterval": [rounded(bootstraps[124], 3), rounded(bootstraps[4874], 3)],
            "deltasMilliseconds": deltas]
}
func compare(_ args: Arguments) throws {
    let apps = ["before": path(try args.string("--before")), "after": path(try args.string("--after", root.appendingPathComponent("build/Skriv.app").path))]
    let pairs = try args.int("--pairs", 5, range: 1...50), warm = try args.int("--warm", 20, range: 1...1000)
    func fingerprints() throws -> [String: String] { try apps.mapValues { try hash($0.appendingPathComponent("Contents/MacOS/Skriv")) } }
    let initialHashes = try fingerprints()
    let work = try temporary("comparison-", in: path(args.string("--output", root.appendingPathComponent("build/benchmarks").path)))
    var measured: [String: URL] = [:]
    for name in ["before", "after"] {
        let copy = work.appendingPathComponent("Skriv-\(name).app")
        try fm.copyItem(at: apps[name]!, to: copy)
        let plist = copy.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? Object else { throw Failure("Invalid app Info.plist") }
        info["CFBundleIdentifier"] = "no.skriv.\(work.lastPathComponent).\(name)"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        _ = try run(["codesign", "--force", "--sign", "-", copy.path])
        measured[name] = copy
    }
    var samples: [String: [Object]] = ["before": [], "after": []], info: Object = [:], firstLaunch: Object = [:]
    var configHashes = Set<String>()
    var cold: [String: [String: [Double]]] = ["before": [:], "after": [:]]
    for pair in 0..<pairs {
        for name in (pair.isMultiple(of: 2) ? ["before", "after"] : ["after", "before"]) {
            let destination = work.appendingPathComponent("\(pair + 1)-\(name)")
            let log = work.appendingPathComponent("\(pair + 1)-\(name).log")
            let report: Object, runDirectory: URL
            do {
                (report, runDirectory) = try launch(app: measured[name]!, runs: 1, warm: warm, destination: destination, requireReadiness: args.has("--require-readiness"))
                try "Full report: \(runDirectory.appendingPathComponent("summary.json").path)\n".write(to: log, atomically: true, encoding: .utf8)
            } catch {
                try String(describing: error).write(to: log, atomically: true, encoding: .utf8)
                throw Failure("Benchmark failed; see \(log.path): \(error)")
            }
            info[name] = report
            configHashes.insert(report["configurationSHA256"] as? String ?? "absent")
            let results = report["results"] as! Object
            var current: Object = [:]
            for (key, value) in results where key.hasPrefix("coldProcess.") {
                let number = (value as! Object)["median"] as! Double
                cold[name]![key, default: []].append(number)
                current[key] = number
            }
            if pair == 0 { firstLaunch[name] = current }
            let raw = try fm.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
            for file in raw { samples[name]! += try fullReadiness(metrics(file)) }
        }
        print("Pair \(pair + 1)/\(pairs) complete"); fflush(stdout)
    }
    try require(configHashes.count == 1, "Editor settings changed between builds; comparison is invalid.")
    try require(initialHashes == fingerprints(), "A binary changed during measurement; comparison is invalid.")
    let results = try samples.mapValues(aggregate)
    var changes: Object = [:]
    for key in Set(cold["before"]!.keys).intersection(cold["after"]!.keys) {
        changes[key] = try pairedChange(cold["before"]![key]!, cold["after"]![key]!)
    }
    let summary: Object = ["pairs": pairs, "warmPerProcess": warm, "binarySHA256": initialHashes,
                           "metadata": info, "results": results, "firstLaunch": firstLaunch, "pairedChanges": changes]
    let destination = work.appendingPathComponent("summary.json")
    try writeJSON(summary, to: destination)
    for name in ["before", "after"] {
        print(name)
        try display(results[name]!.filter { $0.key.hasSuffix("inputReady.milliseconds") || $0.key.hasSuffix("fullyReady.milliseconds") })
    }
    print("Full report: \(destination.path)")
}

let neovimLua = #"""
local input, output, shape, repetitions = unpack(arg)
local uv = vim.uv
local function measure(work)
  local start = uv.hrtime()
  work()
  return (uv.hrtime() - start) / 1000000
end
vim.o.swapfile = false
vim.o.undofile = false
vim.o.wrap = false
vim.cmd('syntax off')
vim.cmd('filetype off')
local result = {memory = {baselineResidentBytes = uv.resident_set_memory()}, timings = {}}
result.timings.loadMilliseconds = measure(function() vim.cmd.edit(vim.fn.fnameescape(input)) end)
assert(vim.api.nvim_buf_line_count(0) == (shape == 'singleLine' and 1 or tonumber(repetitions)))
result.memory.loadedResidentBytes = uv.resident_set_memory()
result.timings.firstMotionMilliseconds = measure(function() vim.cmd('normal! l') end)
assert(vim.api.nvim_win_get_cursor(0)[2] == (shape == 'denseLines' and 0 or 1))
result.timings.lastLineJumpMilliseconds = measure(function() vim.cmd('normal! G') end)
assert(vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(0))
result.memory.afterMotionResidentBytes = uv.resident_set_memory()
vim.fn.writefile({vim.json.encode(result)}, output)
vim.cmd('qa!')
"""#
func neovim(_ args: Arguments) throws {
    let runs = try args.int("--runs", 3), destination = path(try args.string("--output"))
    let nvim = try executable("nvim").path
    let work = try temporary("skriv-neovim-")
    defer { try? fm.removeItem(at: work) }
    let script = work.appendingPathComponent("benchmark.lua")
    try neovimLua.write(to: script, atomically: true, encoding: .utf8)
    var startup: [Double] = [], reports: [Object] = []
    for _ in 0..<runs {
        let result = try run([nvim, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n", "+qa"], timeout: 30)
        startup.append(result.elapsedMilliseconds)
    }
    let units = ["unicode": "En norsk notatlinje: blåbær, øl, ål, ærlig arbeid og 👩🏽‍💻.\n", "singleLine": "a", "denseLines": "a\n"]
    for index in 0..<runs {
        for (shape, repetitions) in workloads {
            let source = work.appendingPathComponent("input.txt"), resultURL = work.appendingPathComponent("result.json")
            let unit = units[shape]!, block = Data(String(repeating: unit, count: 1000).utf8)
            fm.createFile(atPath: source.path, contents: nil)
            let file = try FileHandle(forWritingTo: source)
            do {
                for _ in 0..<(repetitions / 1000) { try file.write(contentsOf: block) }
                try file.close()
            } catch { try? file.close(); throw error }
            let result = try run(["/usr/bin/time", "-l", nvim, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n", "-l", script.path, source.path, resultURL.path, shape, String(repetitions)])
            var report = try readJSON(resultURL)
            let stderr = String(decoding: result.error, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #"(\d+)\s+maximum resident set size"#)
            guard let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
                  let range = Range(match.range(at: 1), in: stderr), let peak = Int(stderr[range]) else { throw Failure("Missing macOS time peak RSS measurement") }
            report.merge(["shape": shape, "repetitions": repetitions, "run": index, "sha256": try hash(source), "utf8Bytes": unit.utf8.count * repetitions]) { _, new in new }
            var memory = report["memory"] as! Object
            memory["peakResidentBytes"] = peak
            report["memory"] = memory
            reports.append(report)
            try display(report)
        }
    }
    try writeJSON([
        "metadata": ["recordedAt": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                     "neovim": try output([nvim, "--version"]).components(separatedBy: .newlines)[0],
                     "startupDefinition": "fresh empty headless process through immediate exit; no file load; measured around Swift Process.run through termination notification",
                     "configuration": "No config/plugins/swap/persistent undo/highlighting; wrap disabled; headless"],
        "emptyProcessMilliseconds": startup, "emptyProcessSummary": try summarize(startup), "workloads": reports
    ], to: destination)
}

let oracleScript = #"""
set nocompatible nomore startofline
let cases = json_decode(join(readfile('cases.json'), "\n"))
let results = []
for item in cases
  enew!
  call setline(1, split(item.text, "\n", 1))
  call setreg('"', '', 'v')
  let prefix = strpart(item.text, 0, item.caret)
  let parts = split(prefix, "\n", 1)
  call cursor(len(parts), strlen(parts[-1]) + 1)
  call feedkeys(item.keys, 'nxt')
  let before = line('.') > 1 ? join(getline(1, line('.') - 1), "\n") . "\n" : ''
  call add(results, {'text': join(getline(1, '$'), "\n"), 'caret': strlen(before) + col('.') - 1, 'reg': getreg('"'), 'type': getregtype('"')})
endfor
call writefile([json_encode(results)], 'neovim.json')
qa!
"""#
func conformance(_ args: Arguments) throws {
    let nvim = try executable(args.string("--nvim", "nvim"))
    let documents = ["one two three", "one\ntwo\nthree", "  one\n  two\nthree", "one\n\nthree", "one\n", "a b c", "one, two!", "one  \ntwo", "\n", ""]
    let commands = [
        "h", "j", "k", "l", "0", "^", "$", "gg", "G", "w", "b", "e", "W", "B", "E",
        "2w", "2e", "x", "X", "dd", "cc", "yy", "dw", "cw", "yw", "db", "yb", "de",
        "ce", "d$", "dj", "dk", "dG", "dgg", "2dd", "d2w", "c2w", "y2w", "D", "C",
        "Y", "yj", "yk", "yG", "ygg", "d0", "d^", "dh", "dl", "d2j", "3dd", "2cc",
        "2yy", "yyp", "yyP", "ylp", "ylP", "vy", "vly", "vhy", "vwy", "vey", "vby", "v0y", "v$y", "vjy", "vky",
        "vggd", "vGd", "v2ld", "vhd", "vjc", "vody", "Vd", "Vjd", "Vkd", "Vy", "Vjy", "Vky", "Vc", "Vjc", "vVjd", "Vvld"
    ]
    var cases: [Object] = []
    for text in documents {
        for caret in Set([0, text.count / 2, max(0, text.count - 1)]).sorted() {
            for keys in commands { cases.append(["text": text, "caret": caret, "keys": keys]) }
        }
    }
    if args.has("--large-files") {
        let commands = ["l", "w", "b", "e", "j", "k", "G", "gg", "2dd", "dj", "dk", "dG", "dgg", "vjy", "vGd", "Vjd", "yyp", "dw", "d$", "cw", "Ggg", "Gkgg", "ggG0", "Gvggy", "ggvGy", "Ggg2w"]
        for text in [String(repeating: String(repeating: "one two three ", count: 7) + "\n", count: 700), String(repeating: "one two three ", count: 5000)] {
            for caret in [0, 16_383, 16_384, 32_767, 32_768, text.count / 2, text.count - 1] {
                for keys in commands { cases.append(["text": text, "caret": caret, "keys": keys]) }
            }
        }
    }
    let work = try temporary("skriv-vim-conformance-")
    defer { try? fm.removeItem(at: work) }
    try writeJSON(cases, to: work.appendingPathComponent("cases.json"))
    try oracleScript.write(to: work.appendingPathComponent("oracle.vim"), atomically: true, encoding: .utf8)
    let binary = try compile([root.appendingPathComponent("Sources/SkrivCore/VimEngine.swift")], fixture: root.appendingPathComponent("scripts/fixtures/VimConformanceMain.swift"), work: work, flags: [])
    let nativeData = try run([binary.path, work.appendingPathComponent("cases.json").path]).output
    _ = try run([nvim.path, "--clean", "-n", "--headless", "-S", "oracle.vim"], cwd: work, timeout: 30)
    guard let native = try JSONSerialization.jsonObject(with: nativeData) as? [Object],
          let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: work.appendingPathComponent("neovim.json"))) as? [Object] else { throw Failure("Invalid conformance result") }
    try require(native.count == cases.count && expected.count == cases.count, "Oracle returned an incomplete result set")
    var failures: [Object] = []
    for index in cases.indices {
        let item = cases[index], actual = native[index], oracle = expected[index], keys = item["keys"] as! String
        let fields = ["text", "reg", "type"] + (!keys.contains("c") && keys != "C" ? ["caret"] : [])
        let differences = fields.filter { field in
            guard let a = actual[field] as? NSObject, let b = oracle[field] as? NSObject else { return true }
            return !a.isEqual(b)
        }
        if !differences.isEmpty { failures.append(["case": item, "fields": differences, "native": actual, "neovim": oracle]) }
    }
    print("\(cases.count) cases; \(failures.count) differences (Neovim with startofline).")
    for failure in failures { try display(failure) }
    try require(failures.isEmpty, "Vim conformance differences found")
}

let usage = """
Usage: swift scripts/benchmark.swift <command> [options]

  launch       [--app build/Skriv.app] [--runs 10] [--warm 20]
               [--output build/benchmarks] [--require-readiness]
  compare      --before APP [--after APP] [--pairs 5] [--warm 20]
               [--output build/benchmarks] [--require-readiness]
  editing      --output FILE [--source-root DIR] [--native]
  markdown     --output FILE [--source-root DIR] [--runs 3]
  large-files  --output FILE [--source-root DIR] [--runs 3] [--timeout 300]
               [--profiles offscreen engine visible] [--shapes unicode singleLine denseLines]
               [--diagnostics]
  neovim       --output FILE [--runs 3]
  conformance  [--nvim PATH] [--large-files]

Requires macOS and Swift; neovim/conformance also require Neovim.
Launch/compare open isolated benchmark windows using current local settings.
Other commands use temporary fixtures; only the visible profile opens windows.
"""
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") { print(usage) }
    else {
        let tail = Array(arguments.dropFirst())
        switch arguments[0] {
        case "launch":
            let args = try Arguments(tail, flags: ["--require-readiness"], options: ["--app", "--runs", "--warm", "--output"])
            _ = try launch(app: path(args.string("--app", "build/Skriv.app")), runs: args.int("--runs", 10, range: 1...100), warm: args.int("--warm", 20, range: 1...1000), destination: path(args.string("--output", "build/benchmarks")), requireReadiness: args.has("--require-readiness"))
        case "compare": try compare(Arguments(tail, flags: ["--require-readiness"], options: ["--before", "--after", "--pairs", "--warm", "--output"]))
        case "editing": try editing(Arguments(tail, flags: ["--native"], options: ["--source-root", "--output"]))
        case "markdown": try markdown(Arguments(tail, options: ["--source-root", "--runs", "--output"]))
        case "large-files": try largeFiles(Arguments(tail, flags: ["--diagnostics"], lists: ["--profiles", "--shapes"], options: ["--source-root", "--runs", "--timeout", "--output"]))
        case "neovim": try neovim(Arguments(tail, options: ["--runs", "--output"]))
        case "conformance": try conformance(Arguments(tail, flags: ["--large-files"], options: ["--nvim"]))
        default: throw Failure("Unknown command: \(arguments[0])\n\(usage)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
    exit(1)
}
