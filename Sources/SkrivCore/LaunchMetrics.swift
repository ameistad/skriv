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
    private var detailStarted: UInt64?
    private var details: [(String, Double)] = []

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
        detailStarted = started
        phases.removeAll(keepingCapacity: true)
        details.removeAll(keepingCapacity: true)
        inputMilliseconds = nil
    }

    /// A separate clock preserves the existing aggregate `beforeWindow` phase.
    public func markStartupCheckpoint(_ name: String) {
        guard let detailStarted, started != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        details.append((name, Double(now - detailStarted) / 1_000_000))
        self.detailStarted = now
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
    func markDisplaySubmitted(window: NSWindow, editor: NSView) -> Opening? {
        guard let started else { return nil }
        let displayMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let opening = Opening(metrics: self, started: started, kind: kind,
                              input: inputMilliseconds, display: displayMilliseconds,
                              phases: phases, details: details, window: window, editor: editor)
        phases.removeAll(keepingCapacity: true)
        details.removeAll(keepingCapacity: true)
        phaseStarted = nil
        detailStarted = nil
        self.started = nil
        return opening
    }

    /// Each opening owns its pending samples, so another document cannot overwrite them.
    /// AppKit notifications and one main-queue turn replace polling or a readiness timer.
    @MainActor
    final class Opening: NSObject {
        private let metrics: LaunchMetrics
        private let started: UInt64
        private let kind: Kind
        private var stages: [(String, Double)]
        private let phases: [(String, Double)]
        private let details: [(String, Double)]
        private weak var window: NSWindow?
        private weak var editor: NSView?
        private var eventLoopReady = false
        private var interfaceComplete = false
        private(set) var isFinished = false

        fileprivate init(metrics: LaunchMetrics, started: UInt64, kind: Kind,
                         input: Double?, display: Double, phases: [(String, Double)],
                         details: [(String, Double)], window: NSWindow, editor: NSView) {
            self.metrics = metrics
            self.started = started
            self.kind = kind
            stages = input.map { [("inputReady", $0)] } ?? []
            stages.append(("displaySubmitted", display))
            self.phases = phases
            self.details = details
            self.window = window
            self.editor = editor
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(queueReadinessCheck(_:)),
                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
            center.addObserver(self, selector: #selector(queueReadinessCheck(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(cancel(_:)),
                               name: NSWindow.willCloseNotification, object: window)
            queueReadinessCheck()
        }

        @objc private func queueReadinessCheck(_ notification: Notification? = nil) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFinished, !self.eventLoopReady,
                      NSApp.isActive, let window = self.window, window.isKeyWindow,
                      let editor = self.editor, window.firstResponder === editor else { return }
                self.eventLoopReady = true
                self.mark("eventLoopReady")
                self.flushIfComplete()
            }
        }

        func markInterfaceComplete() {
            guard !isFinished, !interfaceComplete else { return }
            interfaceComplete = true
            mark("interfaceComplete")
            flushIfComplete()
        }

        private func mark(_ stage: String) {
            stages.append((stage, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
        }

        @objc func cancel(_ notification: Notification? = nil) {
            isFinished = true
            NotificationCenter.default.removeObserver(self)
        }

        private func flushIfComplete() {
            guard eventLoopReady, interfaceComplete, !isFinished else { return }
            cancel()
            // All four boundaries are captured before diagnostics perform any I/O.
            for (name, milliseconds) in stages {
                metrics.record(stage: name, milliseconds: milliseconds, kindName: kind.rawValue)
                if kind == .coldStartup, let processStarted = metrics.processStarted, processStarted <= started {
                    metrics.record(stage: name, milliseconds: milliseconds + Double(started - processStarted) / 1_000_000,
                                   kindName: "coldProcess")
                }
            }
            for (suffix, samples) in [("Phase", phases), ("Detail", details)] {
                for (name, milliseconds) in samples {
                    metrics.record(stage: name, milliseconds: milliseconds, kindName: kind.rawValue + suffix)
                }
            }
        }
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
