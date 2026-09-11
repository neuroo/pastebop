//
//  make-demo.swift
//  PasteBop
//
//  Renders the animated demo in the README. Run it through its wrapper, which
//  compiles it against the real table:
//
//      Scripts/make-demo.sh
//
//  The before and after text, the characters highlighted, and the menu lines
//  all come from the real table and the real ActivityReport, so the demo
//  cannot drift from what the app does.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Content, from the real code

let sample = """
    Here\u{2019}s the thing\u{2014}it\u{2019}s not just speed\u{2026}
    The \u{201C}right\u{201D} answer depends\u{2014}always.
    """

let cleaned = TextNormalizer.normalized(sample)
let tally = TextNormalizer.tally(sample)
let provenance = Provenance(tally: tally, characterCount: 900)
let report = ActivityReport(
    isEnabled: true,
    copyCount: 812,
    tally: tally,
    locale: Locale(identifier: "en_US"),
    lastProvenance: provenance,
    lastCopyCharacters: tally.characterCount,
    machineWrittenCopies: 512
)

// MARK: - Canvas

enum Style {
    static let width = 880.0
    static let height = 344.0
    static let scale = 2.0

    static let backdrop = CGColor(red: 0.957, green: 0.957, blue: 0.969, alpha: 1)
    static let menuBar = CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
    static let card = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let ink = CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
    static let faint = CGColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
    static let before = CGColor(red: 0.98, green: 0.72, blue: 0.25, alpha: 0.42)
    static let after = CGColor(red: 0.42, green: 0.78, blue: 0.50, alpha: 0.40)
    static let accent = CGColor(red: 0.47, green: 0.42, blue: 0.78, alpha: 1)

    static let mono = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
    static let label = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let menuFont = NSFont.systemFont(ofSize: 13, weight: .regular)
}

/// The shipped template glyph, tinted for the menu bar.
let menuGlyph: CGImage = {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "img/menu-bar/PasteBopTemplate.imageset/PasteBopTemplate@2x.png")
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("missing the menu bar glyph at \(url.path)") }
    return image
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func newContext() -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: Int(Style.width * Style.scale),
        height: Int(Style.height * Style.scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("cannot create the context") }
    context.scaleBy(x: Style.scale, y: Style.scale)
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}

// MARK: - Text

@discardableResult
func draw(
    _ text: String,
    _ font: NSFont,
    _ color: CGColor,
    at point: CGPoint,
    in context: CGContext
) -> CTLine {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? .black,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
    return line
}

/// Boxes the runs of `text` that the table rewrites, so the eye lands on them.
func highlight(
    _ text: String,
    changedRanges: [Range<String.Index>],
    font: NSFont,
    colour: CGColor,
    at point: CGPoint,
    in context: CGContext
) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    context.setFillColor(colour)
    for range in changedRanges {
        let lower = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        let upper = text.utf16.distance(from: text.utf16.startIndex, to: range.upperBound.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        let startX = CTLineGetOffsetForStringIndex(line, lower, nil)
        let endX = CTLineGetOffsetForStringIndex(line, upper, nil)
        let box = CGRect(
            x: point.x + startX - 2,
            y: point.y - 5,
            width: max(6, endX - startX) + 4,
            height: font.pointSize + 8
        )
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
    }
}

/// Which characters on a line the rules touch.
func changedRanges(in line: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var index = line.startIndex
    while index < line.endIndex {
        let next = line.index(after: index)
        if TextNormalizer.needsRewrite(String(line[index..<next])) {
            ranges.append(index..<next)
        }
        index = next
    }
    return ranges
}

// MARK: - Scene

func card(_ context: CGContext, y: CGFloat, height: CGFloat) -> CGRect {
    let rect = CGRect(x: 60, y: y, width: Style.width - 120, height: height)
    context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                      color: CGColor(gray: 0, alpha: 0.10))
    context.setFillColor(Style.card)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    return rect
}

func drawMenuBar(_ context: CGContext, glyphHighlighted: Bool) {
    let barHeight = 28.0
    context.setFillColor(Style.menuBar)
    context.fill(CGRect(x: 0, y: Style.height - barHeight, width: Style.width, height: barHeight))

    let glyphBox = CGRect(x: Style.width - 88, y: Style.height - 24, width: 20, height: 20)
    if glyphHighlighted {
        context.setFillColor(Style.accent)
        context.addPath(CGPath(
            roundedRect: glyphBox.insetBy(dx: -7, dy: -3),
            cornerWidth: 5, cornerHeight: 5, transform: nil
        ))
        context.fillPath()
    }

    // The glyph is black artwork on alpha, so it is used as a mask and filled
    // the way a template image is in a real menu bar.
    context.saveGState()
    context.clip(to: glyphBox, mask: menuGlyph)
    context.setFillColor(CGColor(gray: 1, alpha: glyphHighlighted ? 1 : 0.85))
    context.fill(glyphBox)
    context.restoreGState()

    draw("Fri 22:00", NSFont.systemFont(ofSize: 12, weight: .regular),
         CGColor(gray: 1, alpha: 0.55),
         at: CGPoint(x: Style.width - 200, y: Style.height - 19), in: context)
}

/// The before/after card.
func drawTextScene(_ context: CGContext, showingCleaned: Bool) {
    let rect = card(context, y: 74, height: 158)
    let label = showingCleaned ? "PASTED" : "COPIED"
    draw(label, Style.label, showingCleaned ? Style.accent : Style.faint,
         at: CGPoint(x: rect.minX + 26, y: rect.maxY - 32), in: context)

    let body = showingCleaned ? cleaned : sample
    let lines = body.components(separatedBy: "\n")
    for (offset, line) in lines.enumerated() {
        let origin = CGPoint(x: rect.minX + 26, y: rect.maxY - 78 - Double(offset) * 36)
        let source = sample.components(separatedBy: "\n")[offset]
        let ranges = showingCleaned
            ? changedRanges(in: source).isEmpty ? [] : rewrittenRanges(source: source, cleaned: line)
            : changedRanges(in: source)
        highlight(line, changedRanges: ranges, font: Style.mono,
                  colour: showingCleaned ? Style.after : Style.before,
                  at: origin, in: context)
        draw(line, Style.mono, Style.ink, at: origin, in: context)
    }
}

/// Where the replacements ended up in the cleaned line, so the green boxes sit
/// under the characters that actually changed.
func rewrittenRanges(source: String, cleaned: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var sourceIndex = source.startIndex
    var cleanIndex = cleaned.startIndex
    while sourceIndex < source.endIndex, cleanIndex < cleaned.endIndex {
        let character = String(source[sourceIndex])
        if let replacement = TextNormalizer.normalize(character) {
            let end = cleaned.index(cleanIndex, offsetBy: replacement.count, limitedBy: cleaned.endIndex)
                ?? cleaned.endIndex
            if replacement.isEmpty == false { ranges.append(cleanIndex..<end) }
            cleanIndex = end
        } else {
            cleanIndex = cleaned.index(after: cleanIndex)
        }
        sourceIndex = source.index(after: sourceIndex)
    }
    return ranges
}

/// The menu, dropped down from the glyph.
func drawMenu(_ context: CGContext, revealed: Int) {
    let lines: [(String, Bool)] = [
        ("\u{2713}  Enable PasteBop", false),
        (report.activityLine, false),
        (report.lastCopyLine?.replacingOccurrences(of: "\u{2570}\u{2500}", with: "\u{2514}\u{2500}") ?? "", true),
    ]
    let shown = Array(lines.prefix(revealed))
    guard !shown.isEmpty else { return }

    let height = 23.0 * Double(shown.count) + 18
    let rect = CGRect(x: Style.width - 452, y: Style.height - 32 - height, width: 392, height: height)
    context.setShadow(offset: CGSize(width: 0, height: -3), blur: 14,
                      color: CGColor(gray: 0, alpha: 0.22))
    context.setFillColor(CGColor(red: 0.99, green: 0.99, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    for (offset, entry) in shown.enumerated() {
        let y = rect.maxY - 25 - Double(offset) * 23
        draw(entry.0, Style.menuFont, entry.1 ? Style.accent : Style.ink,
             at: CGPoint(x: rect.minX + 16, y: y), in: context)
    }
}

func frame(cleaned showCleaned: Bool, menuLines: Int, glyph: Bool) -> CGImage {
    let context = newContext()
    context.setFillColor(Style.backdrop)
    context.fill(CGRect(x: 0, y: 0, width: Style.width, height: Style.height))

    drawTextScene(context, showingCleaned: showCleaned)
    draw(showCleaned
         ? "curly quotes, em dashes and ellipses replaced automatically"
         : "copied from a chat assistant",
         NSFont.systemFont(ofSize: 14, weight: .regular), Style.faint,
         at: CGPoint(x: 62, y: 40), in: context)

    drawMenuBar(context, glyphHighlighted: glyph)
    drawMenu(context, revealed: menuLines)

    guard let image = context.makeImage() else { fail("render failed") }
    return image
}

// MARK: - Assemble

let frames: [(image: CGImage, delay: Double)] = [
    (frame(cleaned: false, menuLines: 0, glyph: false), 1.8),
    (frame(cleaned: true, menuLines: 0, glyph: true), 0.5),
    (frame(cleaned: true, menuLines: 0, glyph: false), 1.0),
    (frame(cleaned: true, menuLines: 1, glyph: true), 0.35),
    (frame(cleaned: true, menuLines: 2, glyph: true), 0.5),
    (frame(cleaned: true, menuLines: 3, glyph: true), 2.6),
]

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "img/demo.gif")
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.gif.identifier as CFString, frames.count, nil
) else { fail("cannot write \(output.path)") }

CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)

for entry in frames {
    CGImageDestinationAddImage(destination, entry.image, [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFUnclampedDelayTime: entry.delay,
            kCGImagePropertyGIFDelayTime: entry.delay,
        ],
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fail("cannot finalize the gif") }

let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
let size = (attributes?[.size] as? Int) ?? 0
print("img/demo.gif  \(frames.count) frames  \(size / 1024) KB")
print("  before: \(sample.components(separatedBy: "\n")[0])")
print("  after:  \(cleaned.components(separatedBy: "\n")[0])")
print("  menu:   \(report.activityLine)")
print("          \(report.lastCopyLine ?? "-")")
