#!/usr/bin/env swift
//
//  make-icons.swift
//  PasteBop
//
//  Regenerates every raster asset from the artwork in img/.
//  Run from the repository root:  swift Scripts/make-icons.swift
//
//  The output is committed, so CI never needs to run this.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Inputs and outputs

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// Source artwork for the app icon. Flattened on its own dark background, which
/// becomes the icon tile.
let artwork = root.appending(path: "img/pastebop-avatar-v2.png")

/// Hand-drawn template glyph for the menu bar, used exactly as delivered.
let menuBarSource = root.appending(path: "img/menu-bar/PasteBopTemplate.imageset")

let iconset = root.appending(path: "App/AppIcon.iconset")
let assets = root.appending(path: "App/Assets.xcassets")

/// The macOS icon grid. On a 1024 pt canvas the icon body is an 824 pt rounded
/// square with a 185.4 pt corner radius; the margin is what makes an app icon
/// sit correctly beside its neighbours in the Dock.
enum IconGrid {
    static let canvas = 1024.0
    static let body = 824.0
    static let cornerRadius = 185.4

    static func bodyRect(in size: Double) -> CGRect {
        let side = size * body / canvas
        let inset = (size - side) / 2
        return CGRect(x: inset, y: inset, width: side, height: side)
    }

    static func radius(in size: Double) -> Double {
        size * cornerRadius / canvas
    }
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadBitmap(_ url: URL) -> CGImage {
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(url.path)") }
    return image
}

func newContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("cannot build \(size)px context") }
    context.interpolationQuality = .high
    return context
}

/// Draws the artwork edge to edge inside the rounded icon body, leaving the
/// surrounding margin transparent.
func renderIcon(_ image: CGImage, size: Int) -> CGImage {
    let context = newContext(size: size)
    let rect = IconGrid.bodyRect(in: Double(size))
    let radius = IconGrid.radius(in: Double(size))
    context.addPath(CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    ))
    context.clip()
    context.draw(image, in: rect)
    guard let result = context.makeImage() else { fail("render failed at \(size)px") }
    return result
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot finalize \(url.path)") }
    print("  \(url.lastPathComponent) (\(image.width)x\(image.height))")
}

func writeJSON(_ object: Any, to url: URL) {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
}

func imagesetContents(_ entries: [(scale: String, file: String)], template: Bool) -> [String: Any] {
    var contents: [String: Any] = [
        "images": entries.map { ["idiom": "mac", "scale": $0.scale, "filename": $0.file] },
        "info": ["author": "pastebop", "version": 1],
    ]
    if template {
        contents["properties"] = ["template-rendering-intent": "template"]
    }
    return contents
}

// MARK: - App icon

print("App icon")
let source = loadBitmap(artwork)
try? FileManager.default.removeItem(at: iconset)

let iconSizes: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for (base, scale) in iconSizes {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    write(renderIcon(source, size: base * scale),
          to: iconset.appending(path: "icon_\(base)x\(base)\(suffix).png"))
}

// MARK: - Mascot, for the Help window

print("Mascot")
for (scale, suffix) in [(1, ""), (2, "@2x")] {
    write(renderIcon(source, size: 128 * scale),
          to: assets.appending(path: "Mascot.imageset/Mascot\(suffix).png"))
}
writeJSON(
    imagesetContents([(scale: "1x", file: "Mascot.png"), (scale: "2x", file: "Mascot@2x.png")],
                     template: false),
    to: assets.appending(path: "Mascot.imageset/Contents.json")
)

// MARK: - Menu bar glyph, copied from the hand-drawn master

print("Menu bar icon")
let menuBarTarget = assets.appending(path: "MenuBarIcon.imageset")
try? FileManager.default.removeItem(at: menuBarTarget)
let menuBarNames = [
    ("PasteBopTemplate.png", "MenuBarIcon.png"),
    ("PasteBopTemplate@2x.png", "MenuBarIcon@2x.png"),
]
do {
    try FileManager.default.createDirectory(at: menuBarTarget, withIntermediateDirectories: true)
    for (source, name) in menuBarNames {
        let destination = menuBarTarget.appending(path: name)
        try FileManager.default.copyItem(at: menuBarSource.appending(path: source), to: destination)
        let image = loadBitmap(destination)
        print("  \(name) (\(image.width)x\(image.height))")
    }
} catch {
    fail("cannot copy the menu bar glyph: \(error.localizedDescription)")
}
writeJSON(
    imagesetContents([(scale: "1x", file: "MenuBarIcon.png"), (scale: "2x", file: "MenuBarIcon@2x.png")],
                     template: true),
    to: menuBarTarget.appending(path: "Contents.json")
)

writeJSON(["info": ["author": "pastebop", "version": 1]],
          to: assets.appending(path: "Contents.json"))

print("Done.")
