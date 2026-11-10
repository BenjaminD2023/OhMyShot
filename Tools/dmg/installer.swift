// The installer disk image's window: the picture Finder shows behind the app and the Applications folder, and the
// .DS_Store that tells Finder how to lay the window out over it. One set of numbers (Layout) places both, so the
// picture and the icons can't drift apart. Scripts/make-dmg.sh runs it; DESIGN.md (Installer Disk Image) describes it.
//
// Usage: swift Tools/dmg/installer.swift <folder> <volume name> <app's file name>
//
// Writes <folder>/.background/background.tiff (the picture at 1x and 2x in one file) and <folder>/.DS_Store. Both are
// the same bytes every run: the grain comes from a fixed seed, and nothing in the .DS_Store depends on this Mac or on
// the time. Finder is never asked to arrange anything, so this runs without a window server too.
import AppKit
import ImageIO

// MARK: - Layout (points, from the top left of the window's content)

enum Layout {
    /// What the window shows under its title bar. The picture is exactly this large and ends in white on every side,
    /// which is what Finder shows past a picture's edge: a window made larger, or one with a shorter title bar, shows
    /// more white and no seam.
    static let content = CGSize(width: 660, height: 400)
    /// Finder's title bar since macOS 26.
    static let titleBar: CGFloat = 32
    /// Where the window opens, from the screen's bottom left: clear of the Dock and the menu bar on a 13-inch display.
    static let origin = CGPoint(x: 240, y: 260)
    static let iconSize: CGFloat = 128
    static let labelSize: CGFloat = 13
    /// The centers of the two icons; Finder puts each name 83 pt under its icon's center.
    static let app = CGPoint(x: 170, y: 184)
    static let applications = CGPoint(x: 490, y: 184)
    /// The selection drawn around Applications, as the capture overlay frames a chosen area: the icon and its name.
    static let selection = CGRect(x: applications.x - 88, y: applications.y - 84, width: 176, height: 188)
    /// The arrow mark from the app to the selection, its middle lifted off the straight line.
    static let arrowStart = CGPoint(x: app.x + 80, y: app.y + 4)
    static let arrowEnd = CGPoint(x: selection.minX - 18, y: app.y + 4)
    static let arrowBend: CGFloat = -9
    static let arrowWidth: CGFloat = 6
}

// MARK: - Colors (sRGB; DESIGN.md names each)

struct RGB { var r, g, b: Double }
func rgb(_ hex: UInt32) -> RGB {
    RGB(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
}
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
}
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ c: RGB, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), alpha])!
}
func gray(_ white: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: sRGB, components: [white, white, white, alpha])!
}

/// The app icon's ground, the Ocean background fill.
let oceanBlue = rgb(0x5E9CF5), oceanTeal = rgb(0x37CDBE)
/// The default mark ink.
let markRed = rgb(0xFF3B30)

// MARK: - The ground: Ocean as a glow on white

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// How far a point is from the shape the Ocean fills: the selection, and the cone that opens onto it from the middle
/// of the app's icon, as what a lens sees opens from the lens. Nothing inside it.
func distanceFromBeam(_ x: Double, _ y: Double) -> Double {
    let s = Layout.selection
    // Clockwise as the window shows it (y down), so a point outside is on an edge's left.
    let corners: [(Double, Double)] = [
        (Double(Layout.app.x), Double(Layout.app.y)), (Double(s.minX), Double(s.minY)), (Double(s.maxX), Double(s.minY)),
        (Double(s.maxX), Double(s.maxY)), (Double(s.minX), Double(s.maxY)),
    ]
    var inside = true
    var nearest = Double.infinity
    for index in corners.indices {
        let (ax, ay) = corners[index], (bx, by) = corners[(index + 1) % corners.count]
        let ex = bx - ax, ey = by - ay
        if ex * (y - ay) - ey * (x - ax) < 0 { inside = false }
        let t = min(max(((x - ax) * ex + (y - ay) * ey) / (ex * ex + ey * ey), 0), 1)
        nearest = min(nearest, ((x - ax - t * ex) * (x - ax - t * ex) + (y - ay - t * ey) * (y - ay - t * ey)).squareRoot())
    }
    return inside ? 0 : nearest
}

/// The ground's color at a point: the Ocean inside the beam, strongest at the selection, where it is the room around
/// a chosen area, and gone before any edge of the content, so the picture ends in white.
func ground(_ x: Double, _ y: Double) -> RGB {
    let s = Layout.selection
    // From the app to the selection the beam grows stronger and its edge softer.
    let near = smoothstep(Double(Layout.app.x) + 30, Double(s.minX), x)
    let reach = 36 + 42 * near
    let u = min(distanceFromBeam(x, y) / reach, 1)
    let falloff = 1 - u * u * u * (u * (6 * u - 15) + 10)
    // Blue toward the app, teal past Applications, turning a little down the window as the icon's ground does.
    let along = smoothstep(Double(Layout.app.x) + 60, Double(Layout.content.width) - 30, x + (y - Double(Layout.app.y)) * 0.4)
    return mix(RGB(r: 1, g: 1, b: 1), mix(oceanBlue, oceanTeal, along), (0.3 + 0.36 * near) * falloff)
}

/// A fixed-seed generator, so the grain is the same bytes every run.
struct Grain {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    /// Triangular noise of one 8-bit step each way: the gradient is rounded to 8 bits through it and shows no bands.
    mutating func dither() -> Double { next() - next() }
}

func groundImage(scale: Int) -> CGImage {
    let width = Int(Layout.content.width) * scale, height = Int(Layout.content.height) * scale
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var grain = Grain()
    for py in 0..<height {
        for px in 0..<width {
            let c = ground((Double(px) + 0.5) / Double(scale), (Double(py) + 0.5) / Double(scale))
            let noise = grain.dither()
            let at = (py * width + px) * 4
            pixels[at] = UInt8(min(max(c.r * 255 + noise + 0.5, 0), 255))
            pixels[at + 1] = UInt8(min(max(c.g * 255 + noise + 0.5, 0), 255))
            pixels[at + 2] = UInt8(min(max(c.b * 255 + noise + 0.5, 0), 255))
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
}

// MARK: - The arrow mark (the editor's classic arrow, as MarkPaths.swift draws it)

struct Curve {
    var start, control, end: CGPoint

    init(start: CGPoint, end: CGPoint, bend: CGFloat) {
        let length = max(hypot(end.x - start.x, end.y - start.y), .ulpOfOne)
        let normal = CGVector(dx: -(end.y - start.y) / length, dy: (end.x - start.x) / length)
        self.start = start
        self.end = end
        control = CGPoint(x: (start.x + end.x) / 2 + normal.dx * bend * 2, y: (start.y + end.y) / 2 + normal.dy * bend * 2)
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    func tangent(at t: CGFloat) -> CGVector {
        let dx = 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
        let length = max(hypot(dx, dy), .ulpOfOne)
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// The parameter where the curve is `distance` from its end, in a straight line.
    func parameter(atDistanceFromEnd distance: CGFloat) -> CGFloat {
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<40 {
            let middle = (low + high) / 2
            let p = point(at: middle)
            if hypot(end.x - p.x, end.y - p.y) > distance { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

/// The arrow's body, to stroke `width` wide with round caps, and its head, to fill: a head 3 widths plus 4 pt long
/// with a notched back, the body ending inside it.
func arrow(_ curve: Curve, width: CGFloat) -> (body: CGPath, head: CGPath) {
    let length = width * 3 + 4
    let stop = curve.parameter(atDistanceFromEnd: length * 0.72)
    let body = CGMutablePath()
    body.move(to: curve.start)
    // The curve up to `stop`, as its own quadratic.
    let bodyEnd = curve.point(at: stop)
    body.addQuadCurve(to: bodyEnd, control: CGPoint(
        x: curve.start.x + stop * (curve.control.x - curve.start.x), y: curve.start.y + stop * (curve.control.y - curve.start.y)))
    let direction = curve.tangent(at: 1)
    let normal = CGVector(dx: -direction.dy, dy: direction.dx)
    let tip = curve.end
    let back = CGPoint(x: tip.x - direction.dx * length, y: tip.y - direction.dy * length)
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: back.x + normal.dx * length * 0.6, y: back.y + normal.dy * length * 0.6))
    head.addLine(to: CGPoint(x: tip.x - direction.dx * length * 0.72, y: tip.y - direction.dy * length * 0.72))
    head.addLine(to: CGPoint(x: back.x - normal.dx * length * 0.6, y: back.y - normal.dy * length * 0.6))
    head.closeSubpath()
    return (body, head)
}

// MARK: - The picture

/// The size a capture of the selection would have on a Retina display, as the reading capsule words it.
let reading = "\(Int(Layout.selection.width) * 2) × \(Int(Layout.selection.height) * 2)"

func picture(scale: Int) -> CGImage {
    let width = Int(Layout.content.width) * scale, height = Int(Layout.content.height) * scale
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(groundImage(scale: scale), in: CGRect(x: 0, y: 0, width: width, height: height))
    // Points from the top left from here on, as Finder counts them.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    /// A shadow in the design system's words (a layer's radius, a drop in points); Core Graphics counts both in
    /// pixels, its blur twice a layer's radius, and y upward.
    func shadow(opacity: CGFloat, radius: CGFloat, drop: CGFloat) {
        context.setShadow(offset: CGSize(width: 0, height: -drop * CGFloat(scale)), blur: radius * 2 * CGFloat(scale), color: gray(0, opacity))
    }

    // The selection, as SelectionChromeView draws one that can be resized. What it holds is clear of the glow, as a
    // chosen area is clear of the room's dimming.
    let frame = Layout.selection
    context.setFillColor(gray(1, 0.5))
    context.fill(frame)
    let edge = CGPath(rect: frame.insetBy(dx: -0.75, dy: -0.75), transform: nil)
    let arm: CGFloat = 18
    let arms = CGMutablePath()
    for (x, y, dx, dy) in [(frame.minX - 1.5, frame.minY - 1.5, 1.0, 1.0), (frame.maxX + 1.5, frame.minY - 1.5, -1.0, 1.0),
                           (frame.maxX + 1.5, frame.maxY + 1.5, -1.0, -1.0), (frame.minX - 1.5, frame.maxY + 1.5, 1.0, -1.0)] {
        arms.move(to: CGPoint(x: x + dx * arm, y: y))
        arms.addLine(to: CGPoint(x: x, y: y))
        arms.addLine(to: CGPoint(x: x, y: y + dy * arm))
    }
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (path, line, stroke) in [(edge as CGPath, 3.5, gray(0, 0.32)), (arms, 5.5, gray(0, 0.32)), (edge, 1.5, gray(1, 1)), (arms, 3, gray(1, 1))] {
        context.addPath(path)
        context.setLineWidth(line)
        context.setStrokeColor(stroke)
        context.strokePath()
    }

    // The size reading above the selection's top-left corner: the reading capsule, with the floating reading shadow.
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? font
    let text = NSAttributedString(string: reading, attributes: [.font: rounded, .foregroundColor: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)])
    let textHeight = ceil(rounded.ascender - rounded.descender)
    let capsuleSize = CGSize(width: ceil(text.size().width) + 22, height: textHeight + 9)
    let capsule = CGRect(origin: CGPoint(x: frame.minX, y: frame.minY - capsuleSize.height - 10), size: capsuleSize).integral
    let capsulePath = CGPath(roundedRect: capsule, cornerWidth: capsule.height / 2, cornerHeight: capsule.height / 2, transform: nil)
    context.saveGState()
    shadow(opacity: 0.18, radius: 8, drop: 2)
    context.addPath(capsulePath)
    context.setFillColor(gray(1, 0.96))
    context.fillPath()
    context.restoreGState()
    context.addPath(CGPath(roundedRect: capsule.insetBy(dx: 0.25, dy: 0.25), cornerWidth: capsule.height / 2 - 0.25, cornerHeight: capsule.height / 2 - 0.25, transform: nil))
    context.setLineWidth(0.5)
    context.setStrokeColor(gray(0, 0.08))
    context.strokePath()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    text.draw(at: CGPoint(x: capsule.midX - text.size().width / 2, y: capsule.minY + (capsule.height - textHeight) / 2 - 0.5))
    NSGraphicsContext.restoreGraphicsState()

    // The arrow from the app to the selection: the editor's default mark, red with the mark shadow.
    let mark = arrow(Curve(start: Layout.arrowStart, end: Layout.arrowEnd, bend: Layout.arrowBend), width: Layout.arrowWidth)
    context.saveGState()
    shadow(opacity: 0.3, radius: 1.5, drop: 1)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(mark.body)
    context.setLineWidth(Layout.arrowWidth)
    context.setStrokeColor(color(markRed))
    context.strokePath()
    context.addPath(mark.head)
    context.setFillColor(color(markRed))
    context.fillPath()
    context.endTransparencyLayer()
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - The .DS_Store

/// Bytes of big-endian fields, which is how both the .DS_Store and an alias record are written.
struct Bytes {
    var data = Data()
    mutating func u8(_ value: Int) { data.append(UInt8(value)) }
    mutating func u16(_ value: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian) { data.append(contentsOf: $0) } }
    mutating func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }
    mutating func raw(_ value: Data) { data.append(value) }
    /// A Pascal string in a field `size` bytes long.
    mutating func pascal(_ value: String, size: Int) {
        u8(value.utf8.count)
        ascii(value)
        zeros(size - 1 - value.utf8.count)
    }
}

/// An alias record (version 2) for a file in a folder at the top of the volume. It names the file by its path alone,
/// with no file numbers or dates, which is all Finder needs to find the picture on a volume it has just mounted, and
/// what keeps the record the same for every image built.
func alias(volume: String, folder: String, file: String) -> Data {
    var body = Bytes()
    body.u16(0) // a file
    body.pascal(volume, size: 28)
    body.u32(0) // the volume's creation date
    body.ascii("H+")
    body.u16(5) // a disk image
    body.u32(0) // the folder's number
    body.pascal(file, size: 64)
    body.u32(0) // the file's number
    body.u32(0) // its creation date
    body.zeros(8) // creator and type
    body.u16(-1) // levels from and to: not relative
    body.u16(-1)
    body.u32(0xD02) // the volume's attributes
    body.u16(0)
    body.zeros(10)
    func tag(_ kind: Int, _ value: Data) {
        body.u16(kind)
        body.u16(value.count)
        body.raw(value)
        if value.count % 2 == 1 { body.u8(0) }
    }
    func unicode(_ value: String) -> Data {
        var bytes = Bytes()
        bytes.u16(value.utf16.count)
        value.utf16.forEach { bytes.u16(Int($0)) }
        return bytes.data
    }
    tag(0, Data(folder.utf8))
    tag(2, Data("\(volume):\(folder):\u{0}\(file)".utf8))
    tag(14, unicode(file))
    tag(15, unicode(volume))
    tag(18, Data("/\(folder)/\(file)".utf8))
    tag(19, Data("/Volumes/\(volume)".utf8))
    body.u16(-1)
    body.u16(0)
    var record = Bytes()
    record.zeros(4)
    record.u16(body.data.count + 8)
    record.u16(2)
    record.raw(body.data)
    return record.data
}

/// A .DS_Store holding the window's settings and where its two icons stand, laid out as Finder lays out a store of
/// one node: the header, the tree's description at 0x40, the node at 0x1000 and the block table at 0x2000.
func store(volume: String, app: String) -> Data {
    /// A binary property list of the pairs, added in the order written here to a Foundation dictionary, whose order
    /// follows from its keys alone: a Swift dictionary's changes from run to run, and the store's bytes with it.
    func plist(_ pairs: KeyValuePairs<String, Any>) -> Data {
        let dictionary = NSMutableDictionary()
        for (key, value) in pairs { dictionary[key as NSString] = value }
        return try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    func blob(_ value: Data) -> Data {
        var bytes = Bytes()
        bytes.u32(value.count)
        bytes.raw(value)
        return bytes.data
    }
    func place(_ point: CGPoint) -> Data {
        var bytes = Bytes()
        bytes.u32(Int(point.x))
        bytes.u32(Int(point.y))
        bytes.raw(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]))
        return blob(bytes.data)
    }
    let window = CGRect(origin: Layout.origin, size: CGSize(width: Layout.content.width, height: Layout.content.height + Layout.titleBar))
    let bounds = "{{\(Int(window.minX)), \(Int(window.minY))}, {\(Int(window.width)), \(Int(window.height))}}"
    let windowSettings: KeyValuePairs<String, Any> = [
        "WindowBounds": bounds, "ShowToolbar": false, "ShowStatusBar": false, "ShowPathbar": false, "ShowTabView": false,
        "ShowSidebar": false, "ContainerShowSidebar": false,
    ]
    let iconView: KeyValuePairs<String, Any> = [
        "viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": Double(Layout.iconSize), "textSize": Double(Layout.labelSize),
        "labelOnBottom": true, "showItemInfo": false, "showIconPreview": true, "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "backgroundType": 2, "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": alias(volume: volume, folder: ".background", file: "background.tiff"),
    ]
    // (file, kind of record, type, value), in the tree's order: by file name without regard to case, then by kind.
    var records: [(String, String, String, Data)] = [
        (".", "bwsp", "blob", blob(plist(windowSettings))),
        (".", "icvp", "blob", blob(plist(iconView))),
        (".", "vSrn", "long", Data([0, 0, 0, 1])),
        ("Applications", "Iloc", "blob", place(Layout.applications)),
        (app, "Iloc", "blob", place(Layout.app)),
    ]
    records.sort { ($0.0.lowercased(), $0.1) < ($1.0.lowercased(), $1.1) }

    var node = Bytes()
    node.u32(0) // a leaf
    node.u32(records.count)
    for (file, kind, type, value) in records {
        node.u32(file.utf16.count)
        file.utf16.forEach { node.u16(Int($0)) }
        node.ascii(kind)
        node.ascii(type)
        node.raw(value)
    }
    precondition(node.data.count <= 0x1000, "the records no longer fit one node")

    var tree = Bytes()
    tree.u32(2) // the root node's block
    tree.u32(0) // levels under it
    tree.u32(records.count)
    tree.u32(1) // nodes
    tree.u32(0x1000) // a node's size

    // The block table: each block's offset with the power of two of its size in the low five bits, the directory
    // (the tree is block 1), and the free blocks of each size, which between them and the three blocks above cover
    // the whole of the allocator's 2 GB.
    var table = Bytes()
    table.u32(3)
    table.u32(0)
    for block in [0x2000 | 11, 0x40 | 5, 0x1000 | 12] { table.u32(block) }
    table.zeros(4 * 253)
    table.u32(1)
    table.u8(4)
    table.ascii("DSDB")
    table.u32(1)
    var free: [Int: [Int]] = [5: [0x20, 0x60], 7: [0x80], 8: [0x100], 9: [0x200], 10: [0x400], 11: [0x800, 0x2800], 12: [0x3000]]
    for power in 14...30 { free[power] = [1 << power] }
    for power in 0..<32 {
        let blocks = free[power] ?? []
        table.u32(blocks.count)
        blocks.forEach { table.u32($0) }
    }
    precondition(table.data.count <= 0x800)

    // Offsets in the file are 4 more than the allocator's, which start after the file's first word.
    var file = Data(count: 4 + 0x2800)
    func put(_ data: Data, at offset: Int) { file.replaceSubrange((4 + offset)..<(4 + offset + data.count), with: data) }
    var header = Bytes()
    header.ascii("Bud1")
    header.u32(0x2000) // the block table: where, how large, and where again
    header.u32(0x800)
    header.u32(0x2000)
    header.u32(0x100C)
    file[3] = 1
    put(header.data, at: 0)
    put(tree.data, at: 0x40)
    put(node.data, at: 0x1000)
    put(table.data, at: 0x2000)
    return file
}

// MARK: - Main

func fail(_ message: String) -> Never {
    fputs("installer.swift: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: swift Tools/dmg/installer.swift <folder> <volume name> <app's file name>") }
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let volume = arguments[2], app = arguments[3]
// The alias record holds the volume's name in 27 bytes.
guard volume.utf8.count <= 27 else { fail("the volume's name is longer than an alias can hold: \(volume)") }

do {
    let background = folder.appendingPathComponent(".background", isDirectory: true)
    try FileManager.default.createDirectory(at: background, withIntermediateDirectories: true)
    // One TIFF with the picture at both scales, told apart by their resolution, as Finder wants a Retina background.
    let tiff = background.appendingPathComponent("background.tiff")
    guard let destination = CGImageDestinationCreateWithURL(tiff as CFURL, "public.tiff" as CFString, 2, nil) else {
        fail("can't write \(tiff.path)")
    }
    for scale in [1, 2] {
        CGImageDestinationAddImage(destination, picture(scale: scale), [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5], // LZW
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(tiff.path)") }
    try store(volume: volume, app: app).write(to: folder.appendingPathComponent(".DS_Store"))
} catch {
    fail("\(error.localizedDescription)")
}
