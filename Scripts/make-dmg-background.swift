#!/usr/bin/env swift
//
//  make-dmg-background.swift
//  PasteBop
//
//  Draws the disk image window background. Run from the repository root:
//      swift Scripts/make-dmg-background.swift
//
//  The output is committed; Scripts/package.sh only copies it.
//

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appending(path: "img/pastebop-avatar-v2.png")
let output = root.appending(path: "App/dmg")

/// Matches the window geometry in Scripts/make-dmg-layout.py. Changing one
/// without the other puts the arrow in the wrong place.
enum Window {
    static let width = 560.0
    static let height = 400.0
    static let appIcon = CGPoint(x: 150, y: 180)
    static let applicationsIcon = CGPoint(x: 410, y: 180)
    /// Finder can be configured to show a status bar, which eats roughly 28
    /// points off the bottom. The caption sits above that so it is never
    /// half-covered.
    static let captionBaseline = 76.0
    /// Finder measures icon positions from the top left; Core Graphics draws
    /// from the bottom left.
    static func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// A very light vertical wash, so the window reads as a surface rather than a
/// hole punched in the desktop.
func drawBackdrop(in context: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.976, green: 0.976, blue: 0.984, alpha: 1),
            CGColor(red: 0.925, green: 0.925, blue: 0.945, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) else { fail("cannot build the gradient") }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: Window.height),
        end: .zero,
        options: []
    )
}

/// From the app towards the Applications alias, stopping well short of both so
/// it never sits under an icon label.
func drawArrow(in context: CGContext) {
    let from = Window.flipped(Window.appIcon)
    let to = Window.flipped(Window.applicationsIcon)
    let inset = 78.0
    let start = CGPoint(x: from.x + inset, y: from.y)
    let end = CGPoint(x: to.x - inset, y: to.y)

    context.setStrokeColor(CGColor(red: 0.47, green: 0.42, blue: 0.78, alpha: 0.55))
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [1, 9])
    context.move(to: start)
    context.addLine(to: CGPoint(x: end.x - 10, y: end.y))
    context.strokePath()

    context.setLineDash(phase: 0, lengths: [])
    context.setFillColor(CGColor(red: 0.47, green: 0.42, blue: 0.78, alpha: 0.75))
    context.move(to: end)
    context.addLine(to: CGPoint(x: end.x - 15, y: end.y + 9))
    context.addLine(to: CGPoint(x: end.x - 15, y: end.y - 9))
    context.closePath()
    context.fillPath()
}

func drawText(
    _ string: String,
    font: NSFont,
    color: NSColor,
    centeredAt point: CGPoint,
    in context: CGContext
) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: string, attributes: attributes)
    )
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(x: point.x - bounds.width / 2, y: point.y)
    CTLineDraw(line, context)
}

func draw(scale: Int) -> CGImage {
    let width = Int(Window.width) * scale
    let height = Int(Window.height) * scale
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("cannot build a \(width)x\(height) context") }

    context.scaleBy(x: Double(scale), y: Double(scale))
    context.interpolationQuality = .high

    drawBackdrop(in: context)
    drawArrow(in: context)
    drawText(
        "PasteBop",
        font: .systemFont(ofSize: 22, weight: .semibold),
        color: NSColor(white: 0.12, alpha: 1),
        centeredAt: CGPoint(x: Window.width / 2, y: Window.height - 58),
        in: context
    )
    drawText(
        "Drag PasteBop into your Applications folder",
        font: .systemFont(ofSize: 13, weight: .regular),
        color: NSColor(white: 0.42, alpha: 1),
        centeredAt: CGPoint(x: Window.width / 2, y: Window.captionBaseline),
        in: context
    )

    guard let image = context.makeImage() else { fail("render failed") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot finalize \(url.path)") }
    print("  \(url.lastPathComponent) (\(image.width)x\(image.height))")
}

guard FileManager.default.fileExists(atPath: artwork.path) else {
    fail("missing \(artwork.path)")
}

print("Disk image background")
let onex = output.appending(path: "background.png")
let twox = output.appending(path: "background@2x.png")
write(draw(scale: 1), to: onex)
write(draw(scale: 2), to: twox)

// Finder picks the right representation out of a multi-resolution TIFF. A
// plain PNG would be upscaled on every Retina display.
print("Combining into a multi-resolution TIFF")
let tiff = output.appending(path: "background.tiff")
let combine = Process()
combine.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
combine.arguments = ["-cathidpicheck", onex.path, twox.path, "-out", tiff.path]
combine.standardOutput = FileHandle.nullDevice
do {
    try combine.run()
    combine.waitUntilExit()
} catch {
    fail("cannot run tiffutil: \(error.localizedDescription)")
}
guard combine.terminationStatus == 0 else { fail("tiffutil failed") }

// The PNGs are only inputs to the TIFF; only the TIFF ships.
try? FileManager.default.removeItem(at: onex)
try? FileManager.default.removeItem(at: twox)
print("  background.tiff")
print("Done.")
