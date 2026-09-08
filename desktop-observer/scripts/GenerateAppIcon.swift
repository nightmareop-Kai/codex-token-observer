#!/usr/bin/swift
// Rebuild all platform icons from the checked-in, approved Zuno artwork:
// swift desktop-observer/scripts/GenerateAppIcon.swift
// Optional: [ICNS destination] [source PNG] [ICO destination] [macOS PNG destination]
// Uses only AppKit and iconutil supplied by macOS; no network or new illustration.
import AppKit
import Foundation

enum IconError: Error {
    case invalidSource(String)
    case bitmapUnavailable
    case encodingFailed
    case iconutilFailed(Int32)
}

let files = FileManager.default
let repository = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
func path(_ index: Int, _ fallback: String) -> URL {
    if arguments.indices.contains(index) {
        return URL(fileURLWithPath: arguments[index]).standardizedFileURL
    }
    return repository.appendingPathComponent(fallback)
}

let icnsURL = path(0, "desktop-observer/Resources/AppIcon.icns")
let sourceURL = path(1, "assets/branding/zuno-icon.png")
let icoURL = path(2, "assets/branding/Zuno.ico")
let macPreviewURL = path(3, "assets/branding/zuno-icon-macos.png")
let sourceData = try Data(contentsOf: sourceURL)
guard let sourceBitmap = NSBitmapImageRep(data: sourceData),
      let artwork = NSImage(data: sourceData),
      sourceBitmap.pixelsWide == sourceBitmap.pixelsHigh,
      sourceBitmap.pixelsWide >= 1024 else {
    throw IconError.invalidSource("Expected a square PNG, at least 1024 pixels: \(sourceURL.path)")
}
let sourceSide = CGFloat(sourceBitmap.pixelsWide)
artwork.size = NSSize(width: sourceSide, height: sourceSide)

// Add background-only breathing room by extending the artwork's outermost
// pixels. This retains every source pixel and avoids inventing a new background
// color or redrawing the cat. The approved image has background on all edges.
func drawPaddedArtwork(in tile: NSRect, padding: CGFloat) {
    let inner = tile.insetBy(dx: padding, dy: padding)
    let source = [CGFloat(0), CGFloat(1), sourceSide - 1, sourceSide]
    let destinationX = [tile.minX, inner.minX, inner.maxX, tile.maxX]
    let destinationY = [tile.minY, inner.minY, inner.maxY, tile.maxY]
    for row in 0..<3 {
        for column in 0..<3 where row != 1 || column != 1 {
            let from = NSRect(x: source[column], y: source[row],
                              width: source[column + 1] - source[column],
                              height: source[row + 1] - source[row])
            let to = NSRect(x: destinationX[column], y: destinationY[row],
                            width: destinationX[column + 1] - destinationX[column],
                            height: destinationY[row + 1] - destinationY[row])
            artwork.draw(in: to, from: from, operation: .copy, fraction: 1)
        }
    }
    artwork.draw(in: inner, from: NSRect(x: 0, y: 0, width: sourceSide, height: sourceSide),
                 operation: .copy, fraction: 1)
}

func renderPNG(pixels: Int, macOS: Bool) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.bitmapUnavailable
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    if macOS {
        // A true-alpha 64-pixel outer margin and macOS-style rounded tile.
        // The additional 24-pixel inner padding protects the ear and long tail.
        let tile = NSRect(x: 64, y: 64, width: 896, height: 896)
        NSBezierPath(roundedRect: tile, xRadius: 196, yRadius: 196).addClip()
        drawPaddedArtwork(in: tile, padding: 24)
    } else {
        // Windows has no universal tile mask: retain the entire square artwork.
        artwork.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                     from: NSRect(x: 0, y: 0, width: sourceSide, height: sourceSide),
                     operation: .copy, fraction: 1)
    }
    context.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.encodingFailed
    }
    return data
}

func write(_ data: Data, to destination: URL) throws {
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

// ICO directory entries followed by independent PNG payloads. Windows treats
// zero in the one-byte width/height fields as 256 pixels.
let windowsSizes = [16, 24, 32, 48, 64, 128, 256]
let windowsPNGs = try windowsSizes.map { try renderPNG(pixels: $0, macOS: false) }
var ico = Data()
ico.appendLE(UInt16(0))
ico.appendLE(UInt16(1))
ico.appendLE(UInt16(windowsSizes.count))
var offset = UInt32(6 + 16 * windowsSizes.count)
for (size, png) in zip(windowsSizes, windowsPNGs) {
    ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(0) // palette colors
    ico.append(0) // reserved
    ico.appendLE(UInt16(1))
    ico.appendLE(UInt16(32))
    ico.appendLE(UInt32(png.count))
    ico.appendLE(offset)
    offset += UInt32(png.count)
}
for png in windowsPNGs { ico.append(png) }
try write(ico, to: icoURL)
print("Windows ICO: \(icoURL.path) — \(windowsSizes)")

let working = files.temporaryDirectory.appendingPathComponent("zuno-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = working.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try write(renderPNG(pixels: size, macOS: true),
              to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try write(renderPNG(pixels: size * 2, macOS: true),
              to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try write(renderPNG(pixels: 1024, macOS: true), to: macPreviewURL)
try files.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try conversion.run()
conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else {
    throw IconError.iconutilFailed(conversion.terminationStatus)
}
// Keep these temporary previews available for visual QA; no output is a new
// illustration, and the source file is never modified by this script.
for (size, png) in zip(windowsSizes, windowsPNGs) {
    try write(png, to: working.appendingPathComponent("windows-\(size).png"))
}
print("macOS ICNS: \(icnsURL.path)")
print("macOS PNG: \(macPreviewURL.path)")
print("QA iconset: \(iconset.path)")
print("QA Windows PNGs: \(working.path)")
