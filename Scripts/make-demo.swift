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
//  all come from the real table and a real ActivityReport, so the demo cannot
//  claim something the app does not do.
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

let report = ActivityReport(
    isEnabled: true,
    copyCount: 812,
    tally: tally,
    locale: Locale(identifier: "en_US"),
    lastProvenance: Provenance(tally: tally, characterCount: 900),
    lastCopyCharacters: tally.characterCount,
    machineWrittenCopies: 512
)

// MARK: - Style

enum Style {
    static let width = 880.0
    static let height = 344.0
    static let scale = 2.0
    static let menuBarHeight = 28.0

    static let backdrop = CGColor(red: 0.957, green: 0.957, blue: 0.969, alpha: 1)
    static let menuBar = CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
    static let card = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let popover = CGColor(red: 0.99, green: 0.99, blue: 1, alpha: 1)
    static let ink = CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
    static let faint = CGColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
    static let beforeMark = CGColor(red: 0.98, green: 0.72, blue: 0.25, alpha: 0.42)
    static let afterMark = CGColor(red: 0.42, green: 0.78, blue: 0.50, alpha: 0.40)
    static let accent = CGColor(red: 0.47, green: 0.42, blue: 0.78, alpha: 1)

    static let mono = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let menuItem = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let clock = NSFont.systemFont(ofSize: 12, weight: .regular)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The shipped template glyph, drawn the way a real menu bar draws one.
let menuGlyph: CGImage = {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "img/menu-bar/PasteBopTemplate.imageset/PasteBopTemplate@2x.png")
    guard let data = try? Data(contentsOf: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("missing the menu bar glyph at \(url.path)") }
    return image
}()

// MARK: - Drawing

struct Canvas {
    let context: CGContext

    init() {
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
        self.context = context
    }

    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    func rounded(_ rect: CGRect, radius: Double, _ color: CGColor, shadow: Bool = false) {
        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -3),
                blur: 12,
                color: CGColor(gray: 0, alpha: 0.16)
            )
        }
        context.setFillColor(color)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.fillPath()
        if shadow {
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
    }

    func text(_ string: String, font: NSFont, color: CGColor, at point: CGPoint) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .black,
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// Boxes the given ranges of a monospaced line, so the eye lands on the
    /// characters that change.
    func highlight(
        _ string: String,
        ranges: [Range<String.Index>],
        color: CGColor,
        at point: CGPoint
    ) {
        guard !ranges.isEmpty else { return }
        let attributed = NSAttributedString(string: string, attributes: [.font: Style.mono])
        let line = CTLineCreateWithAttributedString(attributed)
        context.setFillColor(color)
        for range in ranges {
            let lower = string.utf16Offset(of: range.lowerBound)
            let upper = string.utf16Offset(of: range.upperBound)
            let startX = CTLineGetOffsetForStringIndex(line, lower, nil)
            let endX = CTLineGetOffsetForStringIndex(line, upper, nil)
            let box = CGRect(
                x: point.x + startX - 2,
                y: point.y - 5,
                width: max(6, endX - startX) + 4,
                height: Style.mono.pointSize + 8
            )
            context.addPath(CGPath(
                roundedRect: box,
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            ))
            context.fillPath()
        }
    }

    /// Fills the glyph through its own alpha, as a template image.
    func glyph(_ image: CGImage, in box: CGRect, color: CGColor) {
        context.saveGState()
        context.clip(to: box, mask: image)
        context.setFillColor(color)
        context.fill(box)
        context.restoreGState()
    }

    func image() -> CGImage {
        guard let image = context.makeImage() else { fail("render failed") }
        return image
    }
}

private extension String {
    func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index.samePosition(in: utf16) ?? utf16.startIndex)
    }
}

// MARK: - Which characters change

/// The characters on a line that the rules touch.
func markedInSource(_ line: String) -> [Range<String.Index>] {
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

/// Where those replacements ended up, so the boxes on the cleaned line sit
/// under the characters that actually changed.
func markedInResult(source: String, cleaned: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var sourceIndex = source.startIndex
    var cleanIndex = cleaned.startIndex
    while sourceIndex < source.endIndex, cleanIndex < cleaned.endIndex {
        let character = String(source[sourceIndex])
        if let replacement = TextNormalizer.normalize(character) {
            let end = cleaned.index(
                cleanIndex,
                offsetBy: replacement.count,
                limitedBy: cleaned.endIndex
            ) ?? cleaned.endIndex
            if !replacement.isEmpty { ranges.append(cleanIndex..<end) }
            cleanIndex = end
        } else {
            cleanIndex = cleaned.index(after: cleanIndex)
        }
        sourceIndex = source.index(after: sourceIndex)
    }
    return ranges
}

// MARK: - Scene

func drawMenuBar(on canvas: Canvas, open isOpen: Bool) {
    canvas.fill(
        CGRect(
            x: 0,
            y: Style.height - Style.menuBarHeight,
            width: Style.width,
            height: Style.menuBarHeight
        ),
        Style.menuBar
    )

    let box = CGRect(x: Style.width - 88, y: Style.height - 24, width: 20, height: 20)
    if isOpen {
        canvas.rounded(box.insetBy(dx: -7, dy: -3), radius: 5, Style.accent)
    }
    canvas.glyph(menuGlyph, in: box, color: CGColor(gray: 1, alpha: isOpen ? 1 : 0.85))
    canvas.text(
        "Fri 22:00",
        font: Style.clock,
        color: CGColor(gray: 1, alpha: 0.55),
        at: CGPoint(x: Style.width - 200, y: Style.height - 19)
    )
}

func drawCard(on canvas: Canvas, cleaned showCleaned: Bool) {
    let rect = CGRect(x: 60, y: 74, width: Style.width - 120, height: 158)
    canvas.rounded(rect, radius: 12, Style.card, shadow: true)
    canvas.text(
        showCleaned ? "PASTED" : "COPIED",
        font: Style.label,
        color: showCleaned ? Style.accent : Style.faint,
        at: CGPoint(x: rect.minX + 26, y: rect.maxY - 32)
    )

    let sourceLines = sample.components(separatedBy: "\n")
    let shownLines = (showCleaned ? cleaned : sample).components(separatedBy: "\n")
    for (offset, line) in shownLines.enumerated() {
        let origin = CGPoint(x: rect.minX + 26, y: rect.maxY - 78 - Double(offset) * 36)
        let source = sourceLines[offset]
        let ranges = showCleaned
            ? markedInResult(source: source, cleaned: line)
            : markedInSource(source)
        canvas.highlight(
            line,
            ranges: ranges,
            color: showCleaned ? Style.afterMark : Style.beforeMark,
            at: origin
        )
        canvas.text(line, font: Style.mono, color: Style.ink, at: origin)
    }
}

func drawMenu(on canvas: Canvas, revealed: Int) {
    let reading = report.lastCopyLine?
        .replacingOccurrences(of: "\u{2570}\u{2500}", with: "\u{2514}\u{2500}") ?? ""
    let items: [(text: String, accented: Bool)] = [
        ("\u{2713}  Enable PasteBop", false),
        (report.activityLine, false),
        (reading, true),
    ]
    let shown = Array(items.prefix(revealed))
    guard !shown.isEmpty else { return }

    let height = 23.0 * Double(shown.count) + 18
    let rect = CGRect(
        x: Style.width - 452,
        y: Style.height - 32 - height,
        width: 392,
        height: height
    )
    canvas.rounded(rect, radius: 8, Style.popover, shadow: true)

    for (offset, item) in shown.enumerated() {
        canvas.text(
            item.text,
            font: Style.menuItem,
            color: item.accented ? Style.accent : Style.ink,
            at: CGPoint(x: rect.minX + 16, y: rect.maxY - 25 - Double(offset) * 23)
        )
    }
}

func frame(cleaned showCleaned: Bool, menuLines: Int, menuOpen: Bool) -> CGImage {
    let canvas = Canvas()
    canvas.fill(CGRect(x: 0, y: 0, width: Style.width, height: Style.height), Style.backdrop)
    drawCard(on: canvas, cleaned: showCleaned)
    canvas.text(
        showCleaned
            ? "curly quotes, em dashes and ellipses replaced automatically"
            : "copied from a chat assistant",
        font: Style.caption,
        color: Style.faint,
        at: CGPoint(x: 62, y: 40)
    )
    drawMenuBar(on: canvas, open: menuOpen)
    drawMenu(on: canvas, revealed: menuLines)
    return canvas.image()
}

// MARK: - Assemble

let frames: [(image: CGImage, delay: Double)] = [
    (frame(cleaned: false, menuLines: 0, menuOpen: false), 1.8),
    (frame(cleaned: true, menuLines: 0, menuOpen: true), 0.5),
    (frame(cleaned: true, menuLines: 0, menuOpen: false), 1.0),
    (frame(cleaned: true, menuLines: 1, menuOpen: true), 0.35),
    (frame(cleaned: true, menuLines: 2, menuOpen: true), 0.5),
    (frame(cleaned: true, menuLines: 3, menuOpen: true), 2.6),
]

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "img/demo.gif")
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.gif.identifier as CFString,
    frames.count,
    nil
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
print("img/demo.gif  \(frames.count) frames  \(((attributes?[.size] as? Int) ?? 0) / 1024) KB")
print("  before: \(sample.components(separatedBy: "\n")[0])")
print("  after:  \(cleaned.components(separatedBy: "\n")[0])")
print("  menu:   \(report.activityLine)")
print("          \(report.lastCopyLine ?? "-")")
