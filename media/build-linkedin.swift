// Renders media/linkedin-1200x627.png, the image for LinkedIn posts.
//
// 1200 x 627 (1.91:1) is the landscape size LinkedIn shows uncropped in the
// feed. Run from the repository root:
//
//   swift media/build-linkedin.swift
//
// It uses only AppKit and the system fonts, and draws the app icon from
// icon/Chaperone-1024.png. Colors are the icon's own.

import AppKit
import Foundation

let width = 1200
let height = 627
let output = URL(fileURLWithPath: "media/linkedin-1200x627.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

guard let icon = NSImage(contentsOfFile: "icon/Chaperone-1024.png") else {
    fputs("Run from the repository root: icon/Chaperone-1024.png not found\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    fputs("Could not create the bitmap\n", stderr)
    exit(1)
}
bitmap.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Background: the icon's navy gradient, with its blue bloom behind the icon.
NSGradient(colors: [color(0x233B66), color(0x172849), color(0x11192F)],
           atLocations: [0, 0.48, 1], colorSpace: .sRGB)!
    .draw(in: canvas, angle: -28)
NSGradient(starting: color(0x5579C1, 0.40), ending: color(0x5579C1, 0))!
    .draw(fromCenter: NSPoint(x: 260, y: 330), radius: 0,
          toCenter: NSPoint(x: 260, y: 330), radius: 420, options: [])

// A faint route line along the bottom, echoing the icon's waves.
let wave = NSBezierPath()
wave.move(to: NSPoint(x: -20, y: 70))
wave.curve(to: NSPoint(x: 1220, y: 120),
           controlPoint1: NSPoint(x: 380, y: -10),
           controlPoint2: NSPoint(x: 760, y: 190))
wave.lineWidth = 2
color(0x83F0E5, 0.10).setStroke()
wave.stroke()

// The icon, with a soft shadow.
let iconSide: CGFloat = 400
let iconRect = NSRect(x: 64, y: (CGFloat(height) - iconSide) / 2 - 4,
                      width: iconSide, height: iconSide)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x05080F, 0.55)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
icon.draw(in: iconRect)
NSGraphicsContext.restoreGraphicsState()

// Text, left-aligned in a column to the right of the icon.
let left: CGFloat = 510
let column: CGFloat = CGFloat(width) - left - 56

func draw(_ text: NSAttributedString, top: CGFloat) -> CGFloat {
    let bounds = text.boundingRect(
        with: NSSize(width: column, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
    let rect = NSRect(x: left, y: CGFloat(height) - top - ceil(bounds.height),
                      width: column, height: ceil(bounds.height))
    text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return top + ceil(bounds.height)
}

func text(_ s: String, _ font: NSFont, _ c: NSColor, kern: CGFloat = 0,
          lineHeight: CGFloat? = nil) -> NSMutableAttributedString {
    let style = NSMutableParagraphStyle()
    if let lineHeight {
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
    }
    return NSMutableAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: c, .kern: kern, .paragraphStyle: style,
    ])
}

let mono = { (size: CGFloat, weight: NSFont.Weight) in
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

var y: CGFloat = 64
y = draw(text("Chaperone", .systemFont(ofSize: 84, weight: .bold),
              color(0xFFFFFF), kern: -1.5), top: y)
y = draw(text("Let AI coding agents build and run code on macOS without the XProtect first-launch scan.",
              .systemFont(ofSize: 28, weight: .regular), color(0xB8D4F5),
              lineHeight: 36), top: y + 6)

// The agents it is for: any tool that runs your builds in its own shell.
let agents = ["Claude Code", "Codex", "Gemini CLI", "Cursor", "Copilot", "Hermes"]
let agentLine = NSMutableAttributedString()
for (i, name) in agents.enumerated() {
    if i > 0 { agentLine.append(text("  ·  ", .systemFont(ofSize: 19, weight: .regular), color(0x5E7AA6))) }
    agentLine.append(text(name, .systemFont(ofSize: 19, weight: .semibold), color(0x83F0E5)))
}
y = draw(agentLine, top: y + 14)

// The measurement: before (the worst case, with a busy scan queue), arrow,
// after.
let stat = text("up to ", .systemFont(ofSize: 26, weight: .medium), color(0x8FA6C8))
stat.append(text("38 s", mono(58, .semibold), color(0xFFB27A)))
stat.append(text(" → ", mono(46, .regular), color(0x8FA6C8)))
stat.append(text("0.010 s", mono(58, .semibold), color(0x83F0E5)))
y = draw(stat, top: y + 30)
y = draw(text("first launch of a fresh binary, without and with Chaperone",
              .systemFont(ofSize: 20, weight: .medium), color(0x8FA6C8)), top: y + 4)

// Footer: where to get it.
_ = draw(text("github.com/dedalozzo/chaperone", mono(23, .medium), color(0xFFD88A)),
         top: CGFloat(height) - 108)
_ = draw(text("macOS  ·  Swift  ·  MIT  ·  MacPorts",
              .systemFont(ofSize: 19, weight: .medium), color(0x8FA6C8), kern: 0.4),
         top: CGFloat(height) - 74)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode the PNG\n", stderr)
    exit(1)
}
try png.write(to: output)
print("Wrote \(output.path) (\(width)x\(height))")
