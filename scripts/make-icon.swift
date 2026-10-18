// Renders assets/icon.png, the package icon Sileo and Zebra show (512 x 512), in the look of the
// settings icon (Prefs/Resources/icon*.png): a purple rounded square with a white music note.
//
//   swift scripts/make-icon.swift [output.png]
import AppKit

let size: CGFloat = 512
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon.png"

// Sampled from Prefs/Resources/icon@2x.png (lighter at the top, darker at the bottom), so the
// package and the settings row match.
let top = NSColor(srgbRed: 0x6E / 255.0, green: 0x5E / 255.0, blue: 0xD9 / 255.0, alpha: 1)
let bottom = NSColor(srgbRed: 0x4B / 255.0, green: 0x3F / 255.0, blue: 0xA7 / 255.0, alpha: 1)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("cannot make a bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Package managers round the corners themselves on some screens; a full-bleed square with iOS's
// continuous-ish corner looks right either way.
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let square = NSBezierPath(roundedRect: bounds, xRadius: size * 0.2237, yRadius: size * 0.2237)
NSGradient(starting: bottom, ending: top)?.draw(in: square, angle: 90)

let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
    fatalError("SF Symbol music.note is missing")
}
let noteSize = note.size
note.draw(in: NSRect(x: (size - noteSize.width) / 2, y: (size - noteSize.height) / 2,
                     width: noteSize.width, height: noteSize.height))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("cannot encode PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
