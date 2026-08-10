import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// Renders the MixPill app icon.
//
// The mark: a capsule — the "pill" — laid on the diagonal, with three
// mixer slots cut clean through it. The slots read as an equalizer at
// large sizes and simply as a pill at 16 pt, which is the size that
// decides whether an icon works.
//
// Geometry follows Apple's macOS icon grid: on a 1024 pt canvas the body
// is an 824 pt superellipse, leaving the surrounding padding the system
// expects for shadows and optical alignment.
//
//   swift Tools/GenerateAppIcon/main.swift <output-appiconset-dir>

let canvasUnit: CGFloat = 1024
let bodyInset: CGFloat = 100          // 824 pt body on a 1024 pt canvas
let bodyCorner: CGFloat = 185

struct RGB {
    let r, g, b: CGFloat
    func color(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }
}

// A deep indigo→violet ramp: saturated enough to hold its own against the
// colourful default macOS icons, dark enough that a white mark sings.
let gradientTop = RGB(r: 122, g: 92, b: 255)
let gradientBottom = RGB(r: 58, g: 38, b: 168)

/// Superellipse approximating the macOS icon shape. A plain rounded rect
/// reads subtly "off" next to system icons; the continuous curve does not.
func squirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = min(cornerRadius, min(rect.width, rect.height) / 2)
    let k = r * 0.2               // continuous-curvature control offset
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY

    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + r),
                  control1: CGPoint(x: maxX - k, y: minY),
                  control2: CGPoint(x: maxX, y: minY + k))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(to: CGPoint(x: maxX - r, y: maxY),
                  control1: CGPoint(x: maxX, y: maxY - k),
                  control2: CGPoint(x: maxX - k, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - r),
                  control1: CGPoint(x: minX + k, y: maxY),
                  control2: CGPoint(x: minX, y: maxY - k))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(to: CGPoint(x: minX + r, y: minY),
                  control1: CGPoint(x: minX, y: minY + k),
                  control2: CGPoint(x: minX + k, y: minY))
    path.closeSubpath()
    return path
}

/// A capsule, the shape the whole mark is built from.
func capsule(centre: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let radius = min(width, height) / 2
    return CGPath(
        roundedRect: CGRect(x: centre.x - width / 2, y: centre.y - height / 2,
                            width: width, height: height),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

/// The mark: three channel faders, each a recessed track carrying a
/// capsule cap set to a different level.
///
/// A mixer is the one image that says "per-app volume" without a caption,
/// and the caps are pills — the name, drawn rather than spelled. Three
/// heavy verticals also survive the 16 pt rung, where a detailed glyph
/// would collapse into mush.
struct Fader {
    let track: CGPath
    let cap: CGPath
}

func faders(centre: CGPoint) -> [Fader] {
    let spacing = canvasUnit * 0.200
    let trackWidth = canvasUnit * 0.058
    let trackHeight = canvasUnit * 0.420
    let capWidth = canvasUnit * 0.130
    let capHeight = canvasUnit * 0.190

    // Staggered levels: a mixer at rest looks wrong, a mixer mid-adjustment
    // looks alive.
    let levels: [CGFloat] = [0.24, -0.20, 0.06]

    return levels.enumerated().map { index, level in
        let x = centre.x + CGFloat(index - 1) * spacing
        return Fader(
            track: capsule(centre: CGPoint(x: x, y: centre.y),
                           width: trackWidth, height: trackHeight),
            cap: capsule(centre: CGPoint(x: x, y: centre.y + level * trackHeight),
                         width: capWidth, height: capHeight)
        )
    }
}

func renderIcon(size: CGFloat) -> CGImage? {
    let scale = size / canvasUnit
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: canvasUnit - bodyInset * 2,
                      height: canvasUnit - bodyInset * 2)
    let bodyPath = squirclePath(in: body, cornerRadius: bodyCorner)

    // Background gradient.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [gradientBottom.color(), gradientTop.color()] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: []
    )

    // A soft highlight along the top edge, the way system icons catch light.
    let highlight = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: []
    )
    context.restoreGState()

    let channels = faders(centre: CGPoint(x: canvasUnit / 2, y: canvasUnit / 2))

    // Tracks first: darkened rather than lightened, so they read as
    // recessed slots cut into the face instead of as painted stripes.
    context.saveGState()
    for channel in channels {
        context.addPath(channel.track)
    }
    context.setFillColor(CGColor(srgbRed: 0.09, green: 0.05, blue: 0.36, alpha: 0.55))
    context.fillPath()
    context.restoreGState()

    // Caps on top, each casting a small contact shadow into its track.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvasUnit * 0.010),
                      blur: canvasUnit * 0.028,
                      color: CGColor(srgbRed: 0.04, green: 0.02, blue: 0.20, alpha: 0.45))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    for channel in channels {
        context.addPath(channel.cap)
        context.fillPath()
    }
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon", code: 2)
    }
}

// macOS wants every rung of the ladder: Finder, Dock, Spotlight, System
// Settings and the About panel each pick a different one.
let ladder: [(idiom: String, size: Int, scale: Int)] = [
    ("mac", 16, 1), ("mac", 16, 2),
    ("mac", 32, 1), ("mac", 32, 2),
    ("mac", 128, 1), ("mac", 128, 2),
    ("mac", 256, 1), ("mac", 256, 2),
    ("mac", 512, 1), ("mac", 512, 2),
]

/// The menu bar glyph: the same three faders, drawn as a flat monochrome
/// mark. Menu bar images are templates — only the alpha channel is used,
/// and macOS tints them for light, dark, and the highlighted state — so
/// this draws in solid black with no gradient, shadow, or background.
///
/// Proportions are heavier than the app icon's: at 16 pt the hairlines
/// that look elegant at 512 pt disappear entirely.
func renderMenuBarGlyph(size: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    let unit = size / 16.0            // designed on a 16 pt grid
    context.scaleBy(x: unit, y: unit)

    let centre = CGPoint(x: 8, y: 8)
    let spacing: CGFloat = 4.6
    let trackWidth: CGFloat = 1.5
    let trackHeight: CGFloat = 11.5
    let capWidth: CGFloat = 3.6
    let capHeight: CGFloat = 4.2
    let levels: [CGFloat] = [0.24, -0.20, 0.06]

    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))

    for (index, level) in levels.enumerated() {
        let x = centre.x + CGFloat(index - 1) * spacing
        let track = capsule(centre: CGPoint(x: x, y: centre.y),
                            width: trackWidth, height: trackHeight)
        context.addPath(track)
        context.fillPath()
    }

    // Caps are knocked out of the tracks and redrawn, so each cap reads as
    // a distinct object rather than a bulge in the line.
    for (index, level) in levels.enumerated() {
        let x = centre.x + CGFloat(index - 1) * spacing
        let capCentre = CGPoint(x: x, y: centre.y + level * trackHeight)
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(capsule(centre: capCentre,
                                width: capWidth + 1.1, height: capHeight + 1.1))
        context.fillPath()
        context.restoreGState()

        context.addPath(capsule(centre: capCentre, width: capWidth, height: capHeight))
        context.fillPath()
    }

    return context.makeImage()
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: main.swift <appiconset-dir> [menubar-imageset-dir]\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

var entries: [[String: String]] = []
for rung in ladder {
    let pixels = rung.size * rung.scale
    let filename = "icon_\(rung.size)x\(rung.size)\(rung.scale == 2 ? "@2x" : "").png"
    guard let image = renderIcon(size: CGFloat(pixels)) else {
        FileHandle.standardError.write(Data("failed to render \(pixels)px\n".utf8))
        exit(1)
    }
    try write(image, to: outputDirectory.appendingPathComponent(filename))
    entries.append([
        "idiom": rung.idiom,
        "size": "\(rung.size)x\(rung.size)",
        "scale": "\(rung.scale)x",
        "filename": filename,
    ])
    print("wrote \(filename) (\(pixels)px)")
}

let contents: [String: Any] = [
    "images": entries,
    "info": ["version": 1, "author": "xcode"],
]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("wrote Contents.json")

guard arguments.count > 2 else { exit(0) }

let menuBarDirectory = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: menuBarDirectory, withIntermediateDirectories: true)

var menuBarEntries: [[String: String]] = []
// macOS displays are 1x or 2x; a 3x entry is an unassigned child.
for scale in 1...2 {
    let filename = "menubar\(scale == 1 ? "" : "@\(scale)x").png"
    guard let image = renderMenuBarGlyph(size: CGFloat(16 * scale)) else {
        FileHandle.standardError.write(Data("failed to render menu bar glyph @\(scale)x\n".utf8))
        exit(1)
    }
    try write(image, to: menuBarDirectory.appendingPathComponent(filename))
    menuBarEntries.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
    print("wrote \(filename)")
}

let menuBarContents: [String: Any] = [
    "images": menuBarEntries,
    "info": ["version": 1, "author": "xcode"],
    "properties": ["template-rendering-intent": "template"],
]
let menuBarData = try JSONSerialization.data(withJSONObject: menuBarContents,
                                             options: [.prettyPrinted, .sortedKeys])
try menuBarData.write(to: menuBarDirectory.appendingPathComponent("Contents.json"))
print("wrote menu bar Contents.json")
