import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: build-icns.swift iconset-folder output.icns\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries: [(name: String, code: String, pixels: UInt32)] = [
    ("icon_16x16.png", "icp4", 16),
    ("icon_16x16@2x.png", "icp5", 32),
    ("icon_32x32@2x.png", "icp6", 64),
    ("icon_128x128.png", "ic07", 128),
    ("icon_128x128@2x.png", "ic08", 256),
    ("icon_256x256@2x.png", "ic09", 512),
    ("icon_512x512@2x.png", "ic10", 1024),
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

var chunks = Data()
for entry in entries {
    let file = iconset.appendingPathComponent(entry.name)
    do {
        let png = try Data(contentsOf: file)
        guard png.count >= 24,
              Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            fputs("Not a PNG: \(file.path)\n", stderr)
            exit(1)
        }
        let width = UInt32(png[16]) << 24 | UInt32(png[17]) << 16 | UInt32(png[18]) << 8 | UInt32(png[19])
        let height = UInt32(png[20]) << 24 | UInt32(png[21]) << 16 | UInt32(png[22]) << 8 | UInt32(png[23])
        guard width == entry.pixels && height == entry.pixels else {
            fputs("Unexpected dimensions in \(file.lastPathComponent): \(width)x\(height)\n", stderr)
            exit(1)
        }

        chunks.append(contentsOf: entry.code.utf8)
        appendBigEndian(UInt32(png.count + 8), to: &chunks)
        chunks.append(png)
    } catch {
        fputs("Could not read \(file.path): \(error)\n", stderr)
        exit(1)
    }
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)
do {
    try icns.write(to: output, options: .atomic)
} catch {
    fputs("Could not write \(output.path): \(error)\n", stderr)
    exit(1)
}
