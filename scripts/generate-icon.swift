#!/usr/bin/env swift
import AppKit

// Render the editable vector directly at every macOS icon size. No raster
// intermediates or third-party tooling are needed.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("build")
let iconset = output.appendingPathComponent("Skriv.iconset")
let fileManager = FileManager.default

guard let logo = NSImage(contentsOf: root.appendingPathComponent("logo.svg")) else {
    fatalError("Could not load logo.svg")
}
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create a \(pixels)-pixel icon canvas")
        }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill()
        canvas.fill(using: .copy)
        // Match the visual footprint of macOS icons while retaining the
        // supplied mark's silhouette and transparent corners.
        let inset = CGFloat(pixels) * 0.07
        logo.draw(in: canvas.insetBy(dx: inset, dy: inset),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode the \(pixels)-pixel icon")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output",
                      output.appendingPathComponent("Skriv.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
