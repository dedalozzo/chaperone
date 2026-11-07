import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-svg.swift input.svg output.png\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: input) else {
    fputs("Could not read SVG: \(input.path)\n", stderr)
    exit(1)
}

let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create bitmap context.\n", stderr)
    exit(1)
}

bitmap.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create graphics context.\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
image.draw(
    in: NSRect(x: 0, y: 0, width: side, height: side),
    from: .zero,
    operation: .copy,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG.\n", stderr)
    exit(1)
}
do {
    try png.write(to: output, options: .atomic)
} catch {
    fputs("Could not write PNG: \(error)\n", stderr)
    exit(1)
}
