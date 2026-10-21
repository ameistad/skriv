import AppKit
import SkrivCore

LaunchMetrics.shared.begin(.coldStartup)
let app = NSApplication.shared
LaunchMetrics.shared.markStartupCheckpoint("application")
let delegate = AppDelegate()
LaunchMetrics.shared.markStartupCheckpoint("delegate")
app.setActivationPolicy(.regular)
app.delegate = delegate
LaunchMetrics.shared.markStartupCheckpoint("activationPolicy")
app.run()
