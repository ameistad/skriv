import AppKit
import SkrivCore

LaunchMetrics.shared.begin(.coldStartup)
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
