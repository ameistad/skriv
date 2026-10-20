import AppKit
import Darwin

/// Opt-in JSONL diagnostics. No file, timer, or subprocess is created in normal use.
@MainActor
public final class LaunchMetrics {
    public enum Kind: String { case coldStartup, warmInvocation }
    public static let shared = LaunchMetrics()
    private let output: URL?
    private let processStarted: UInt64?
    private var started: UInt64?
    private var kind: Kind = .coldStartup
    private var inputMilliseconds: Double?
    private var phaseStarted: UInt64?
    private var phases: [(String, Double)] = []

    private init() {
        if let path = ProcessInfo.processInfo.environment["SKRIV_METRICS_PATH"], !path.isEmpty {
            output = URL(fileURLWithPath: path)
        } else {
            output = nil
        }
        processStarted = ProcessInfo.processInfo.environment["SKRIV_PROCESS_LAUNCH_UPTIME_NS"].flatMap(UInt64.init)
    }

    public func begin(_ kind: Kind) {
        guard output != nil else { return }
        self.kind = kind
        started = DispatchTime.now().uptimeNanoseconds
        phaseStarted = started
        phases.removeAll(keepingCapacity: true)
        inputMilliseconds = nil
    }

    /// Collect in memory only; flush after the measured opening path finishes.
    func markPhase(_ name: String) {
        guard let phaseStarted, started != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        phases.append((name, Double(now - phaseStarted) / 1_000_000))
        self.phaseStarted = now
    }

    public func markInputReady() {
        guard let started, inputMilliseconds == nil else { return }
        inputMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    /// AppKit drawing has been submitted. This does not measure compositor presentation.
    public func markDisplaySubmitted() {
        guard let started else { return }
        let displayMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        // Capture both timestamps before any metrics serialization or disk I/O.
        if let inputMilliseconds { record(stage: "inputReady", milliseconds: inputMilliseconds) }
        record(stage: "displaySubmitted", milliseconds: displayMilliseconds)
        if kind == .coldStartup, let processStarted, processStarted <= started {
            let offset = Double(started - processStarted) / 1_000_000
            if let inputMilliseconds {
                record(stage: "inputReady", milliseconds: offset + inputMilliseconds, kindName: "coldProcess")
            }
            record(stage: "displaySubmitted", milliseconds: offset + displayMilliseconds, kindName: "coldProcess")
        }
        for (name, milliseconds) in phases {
            record(stage: name, milliseconds: milliseconds, kindName: kind.rawValue + "Phase")
        }
        phases.removeAll(keepingCapacity: true)
        phaseStarted = nil
        self.started = nil
    }

    public func recordMemory(stage: String) {
        guard output != nil else { return }
        write(["kind": "memory", "stage": stage, "residentBytes": residentBytes(), "pid": getpid()])
    }

    private func record(stage: String, milliseconds: Double, kindName: String? = nil) {
        write([
            "kind": kindName ?? kind.rawValue, "stage": stage,
            "milliseconds": milliseconds,
            "residentBytes": residentBytes(), "pid": getpid(),
        ])
    }

    private func write(_ sample: [String: Any]) {
        guard let output, let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        do {
            if !FileManager.default.fileExists(atPath: output.path) {
                FileManager.default.createFile(atPath: output.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch {
            // Diagnostics must never prevent an editor from opening.
            fputs("Skriv: could not write launch metrics: \(error.localizedDescription)\n", stderr)
        }
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
