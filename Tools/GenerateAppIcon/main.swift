import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// Renders the MixPill app icon.
//
// The mark: two capsules — the "pills" — interlocked like a pair of chain
// links, laid on the diagonal. One is solid, the other a ring, and the
// solid one passes through the ring: an application routed into an output,
// which is the one sentence that describes what MixPill does.
//
// The solid/hollow pairing is not decoration. Two equal thin rings on a
// diagonal is the hyperlink glyph every browser and text editor ships, and
// a menu bar mark that reads "open a URL" is worse than no mark at all.
// Filling one link breaks that reading, and it also survives the 16 pt
// rung, where a solid mass still reads after two hairline rings have
// merged into grey.
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

/// Tile and mark, flat. No gradient, no highlight, no shadow under the mark:
/// the whole point of a two-colour mark is that it survives being printed,
/// embroidered, stamped into a favicon or dropped on someone else's slide,
/// and a light ramp is the first thing to fail at all four.
struct Scheme {
    let tile: RGB
    let mark: RGB

    static let black = Scheme(tile: RGB(r: 17, g: 17, b: 19),
                              mark: RGB(r: 255, g: 255, b: 255))
    static let white = Scheme(tile: RGB(r: 255, g: 255, b: 255),
                              mark: RGB(r: 17, g: 17, b: 19))
    // The one colour the brand is allowed. Orange reads at a glance in a Dock
    // full of blue, and it is the pro-audio convention besides.
    static let orange = Scheme(tile: RGB(r: 255, g: 90, b: 31),
                               mark: RGB(r: 17, g: 17, b: 19))
}

// Which one ships. Everything else about the icon is derived.
let scheme: Scheme = .black

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

/// A capsule, the shape the whole mark is built from. `length` is the
/// distance between the two end centres, so the overall span is
/// `length + 2 * radius` — the parameterisation that keeps a ring's wall
/// an even thickness when the radius shrinks and the length does not.
func capsule(centre: CGPoint, length: CGFloat, radius: CGFloat, angle: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
        .rotated(by: angle)
    let box = CGRect(x: -(length / 2 + radius), y: -radius,
                     width: length + radius * 2, height: radius * 2)
    return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius,
                  transform: &transform)
}

/// Everything on one side of the line through `centre` perpendicular to
/// `angle`. The mark has 180° rotational symmetry, so this single line
/// separates the two crossings — and which link is drawn on top in each
/// half is the whole difference between "interlocked" and "overlapping".
func halfPlane(through centre: CGPoint, angle: CGFloat,
               side: CGFloat, extent: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
        .rotated(by: angle)
    let box = CGRect(x: side > 0 ? 0 : -extent, y: -extent,
                     width: extent, height: extent * 2)
    return CGPath(rect: box, transform: &transform)
}

/// Proportions of the mark, as fractions of the grid it is drawn on.
///
/// The menu bar carries its own set rather than a scaled copy of the
/// icon's: at 16 pt the wall that looks elegant at 512 pt is a third of a
/// pixel, and the break at the crossing closes up entirely.
struct MarkMetrics {
    let radius: CGFloat        // outer radius of a link
    let thickness: CGFloat     // wall of the hollow link
    let length: CGFloat        // between a link's two end centres
    let separation: CGFloat    // between the two link centres
    let gap: CGFloat           // the break that reads as "passes behind"

    static let icon = MarkMetrics(radius: 0.106, thickness: 0.062, length: 0.175,
                                  separation: 0.280, gap: 0.024)
    static let menuBar = MarkMetrics(radius: 0.158, thickness: 0.080, length: 0.250,
                                     separation: 0.400, gap: 0.058)
}

/// The mark, rendered into its own context.
///
/// It has to be isolated: the crossings are cut with `.clear`, and cutting
/// them straight into the icon would punch holes through the body and its
/// gradient rather than through the mark.
func renderMark(size: CGFloat, metrics: MarkMetrics, color: CGColor) -> CGImage? {
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

    let angle = CGFloat.pi / 4        // up and to the right
    let axis = CGPoint(x: cos(angle), y: sin(angle))
    let centre = CGPoint(x: size / 2, y: size / 2)

    let radius = metrics.radius * size
    let length = metrics.length * size
    let separation = metrics.separation * size
    let gap = metrics.gap * size
    let inner = radius - metrics.thickness * size

    // The solid link sits low and left, where its weight grounds the mark.
    let solidCentre = CGPoint(x: centre.x - axis.x * separation / 2,
                              y: centre.y - axis.y * separation / 2)
    let ringCentre = CGPoint(x: centre.x + axis.x * separation / 2,
                             y: centre.y + axis.y * separation / 2)

    let solid = capsule(centre: solidCentre, length: length, radius: radius, angle: angle)
    let ringOuter = capsule(centre: ringCentre, length: length, radius: radius, angle: angle)
    let ringInner = capsule(centre: ringCentre, length: length, radius: inner, angle: angle)

    let solidHalo = capsule(centre: solidCentre, length: length,
                            radius: radius + gap, angle: angle)
    let ringHalo = capsule(centre: ringCentre, length: length,
                           radius: radius + gap, angle: angle)

    func fillSolid() {
        context.addPath(solid)
        context.fillPath()
    }
    func fillRing() {
        context.addPath(ringOuter)
        context.addPath(ringInner)
        context.fillPath(using: .evenOdd)
    }

    context.setFillColor(color)
    fillSolid()
    fillRing()

    // Toward the ring, the solid link is in front: clear a halo around it,
    // which takes the ring's wall with it, then put the solid link back.
    context.saveGState()
    context.addPath(halfPlane(through: centre, angle: angle, side: 1, extent: size * 2))
    context.clip()
    context.setBlendMode(.clear)
    context.addPath(solidHalo)
    context.fillPath()
    context.setBlendMode(.normal)
    context.setFillColor(color)
    fillSolid()
    context.restoreGState()

    // And behind it, the other way round — which is what links them.
    context.saveGState()
    context.addPath(halfPlane(through: centre, angle: angle, side: -1, extent: size * 2))
    context.clip()
    context.setBlendMode(.clear)
    context.addPath(ringHalo)
    context.fillPath()
    context.setBlendMode(.normal)
    context.setFillColor(color)
    fillRing()
    context.restoreGState()

    return context.makeImage()
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
    context.addPath(squirclePath(in: body, cornerRadius: bodyCorner))
    context.setFillColor(scheme.tile.color())
    context.fillPath()

    // The mark is rendered at the full canvas resolution and drawn down, so
    // the crossings stay clean at 32 pt instead of being cut at 32 pt.
    guard let mark = renderMark(size: canvasUnit * max(scale, 1),
                                metrics: .icon,
                                color: scheme.mark.color())
    else { return nil }
    context.draw(mark, in: CGRect(x: 0, y: 0, width: canvasUnit, height: canvasUnit))

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

/// The menu bar glyph: the same two links, drawn as a flat monochrome
/// mark. Menu bar images are templates — only the alpha channel is used,
/// and macOS tints them for light, dark, and the highlighted state — so
/// this draws in solid black with no gradient, shadow, or background.
func renderMenuBarGlyph(size: CGFloat) -> CGImage? {
    renderMark(size: size, metrics: .menuBar,
               color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
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
