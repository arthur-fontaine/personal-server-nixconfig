// Build phase of HermesWidgets: the Live Activity's pet fonts (Shared/TimerAnimation.swift), one
// per row of the pet the app is built with (Pet/spritesheet.webp, the server's current pet), so
// it follows the pet with no font tools on the build machine: ImageIO and Core Graphics only.
// Each is the template HermesFrames.ttf (scripts/make-timer-fonts.py: glyphs .notdef, space,
// colon, d0-d9) with its `sbix` table replaced by the row's frames (digit d: frame d % count)
// and its `name` table by HermesPet-<row>.
// Usage: make-pet-fonts.swift <spritesheet> <template.ttf> <out-dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let rows: [(String, Int)] = [("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5),
                             ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6)]
// One strike per size the pet is drawn at, in pixels (24 and 48 pt at 2x and 3x, and 96):
// iOS picks the strike for the size, so the pixel art is never resampled (which blurred its
// outline into light fringes).
let strikes = [48, 72, 96, 144]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-pet-fonts: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: make-pet-fonts.swift <spritesheet> <template.ttf> <out-dir>") }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(args[1])") }
guard let template = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: - Frames

func rgba(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}

let cw = sheet.width / 8, ch = sheet.height / rows.count
let cells: [[CGImage]] = rows.enumerated().map { i, row in
    (0..<row.1).compactMap { c in sheet.cropping(to: CGRect(x: c * cw, y: i * ch, width: cw, height: ch)) }
}
// One box over every frame of every row (top-left origin): the pet keeps its size and place
// from row to row.
var box = (minX: cw, minY: ch, maxX: 0, maxY: 0)
for frame in cells.joined() {
    let (data, w, h) = rgba(frame)
    for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 16 {
        box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x + 1), max(box.maxY, y + 1))
    } }
}
guard box.maxX > box.minX else { fail("the sheet is empty") }
let side = max(box.maxX - box.minX, box.maxY - box.minY)

func png(_ frame: CGImage, _ pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    let scale = Double(pixels) / Double(side)
    let crop = frame.cropping(to: CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX, height: box.maxY - box.minY))!
    let w = (Double(crop.width) * scale).rounded(), h = (Double(crop.height) * scale).rounded()
    // Centred on whole pixels, feet on the bottom (Core Graphics' origin is at the bottom left).
    ctx.draw(crop, in: CGRect(x: ((Double(pixels) - w) / 2).rounded(.down), y: 0, width: w, height: h))
    // Opaque or clear, as PetStill.hardenAlpha: no grey halo from the background removal.
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let row = ctx.bytesPerRow
    for i in stride(from: 0, to: row * pixels, by: 4) {
        let a = Int(p[i + 3])
        if a < 128 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0 }
        else if a < 255 { for c in 0..<3 { p[i + c] = UInt8(min(255, Int(p[i + c]) * 255 / a)) }; p[i + 3] = 255 }
    }
    // The chroma key's spill (magenta, or green) on the pixels next to the cut-out: the
    // colour channels above the third brought down to it, a grey stays a grey.
    let edge = max(1, pixels / 48)
    for y in 0..<pixels { for x in 0..<pixels {
        let i = y * row + x * 4
        guard p[i + 3] == 255 else { continue }
        var near = false
        for dy in -edge...edge where !near { for dx in -edge...edge {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= pixels || ny >= pixels || p[ny * row + nx * 4 + 3] == 0 { near = true; break }
        } }
        guard near else { continue }
        let r = p[i], g = p[i + 1], b = p[i + 2]
        if r > g && b > g { let m = g; p[i] = min(r, m); p[i + 2] = min(b, m) }
        else if g > r && g > b { p[i + 1] = max(r, b) }
    } }
    // The cut-out's rim: a pixel next to the clear area lighter than the darkest opaque pixel
    // around it is the background removal's grey fringe, not the drawing: it takes that
    // darkest colour (the outline's). Two passes, for a rim two pixels thick at large sizes.
    func lum(_ i: Int) -> Int { Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) }
    for _ in 0..<2 {
        let snapshot = Array(UnsafeBufferPointer(start: p, count: row * pixels))
        for y in 0..<pixels { for x in 0..<pixels {
            let i = y * row + x * 4
            guard snapshot[i + 3] == 255 else { continue }
            var rim = false, darkest = i, darkestLum = Int.max
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= pixels || ny >= pixels { rim = true; continue }
                let j = ny * row + nx * 4
                if snapshot[j + 3] == 0 { rim = true; continue }
                let l = Int(snapshot[j]) + Int(snapshot[j + 1]) + Int(snapshot[j + 2])
                if l < darkestLum { darkestLum = l; darkest = j }
            } }
            guard rim, darkestLum != .max,
                  Int(snapshot[i]) + Int(snapshot[i + 1]) + Int(snapshot[i + 2]) > darkestLum + 12 else { continue }
            // Not the drawing's own light edge: only when the darkest neighbour is dark (an outline).
            guard darkestLum < 3 * 80 else { continue }
            for c in 0..<3 { p[i + c] = snapshot[darkest + c] }
        } }
        _ = lum
    }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: - Font

func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
func be16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
func checksum(_ d: Data) -> UInt32 {
    let b = [UInt8](d) + [UInt8](repeating: 0, count: (4 - d.count % 4) % 4)
    return stride(from: 0, to: b.count, by: 4).reduce(UInt32(0)) { $0 &+ u32(b, $1) }
}

func tables(_ font: Data) -> [String: Data] {
    let b = [UInt8](font)
    var out: [String: Data] = [:]
    for i in 0..<u16(b, 4) {
        let r = 12 + i * 16
        let offset = Int(u32(b, r + 8)), length = Int(u32(b, r + 12))
        out[String(decoding: b[r..<(r + 4)], as: UTF8.self)] = Data(b[offset..<(offset + length)])
    }
    return out
}

func sbix(_ frames: [[Data]]) -> Data {
    // frames[strike][frame]; one strike per entry of `strikes`.
    let glyphCount = 13, firstDigit = 3
    let header = 4 + (glyphCount + 1) * 4
    var bodies: [Data] = []
    for (k, size) in strikes.enumerated() {
        var glyphs = Data(), offsets: [UInt32] = []
        for g in 0..<glyphCount {
            offsets.append(UInt32(header + glyphs.count))
            guard g >= firstDigit else { continue }
            glyphs.append(be16(0)); glyphs.append(be16(0)); glyphs.append(Data("png ".utf8))
            glyphs.append(frames[k][(g - firstDigit) % frames[k].count])
        }
        offsets.append(UInt32(header + glyphs.count))
        var strike = be16(size) + be16(72)
        for o in offsets { strike.append(be32(o)) }
        strike.append(glyphs)
        bodies.append(strike)
    }
    var table = be16(1) + be16(1) + be32(UInt32(strikes.count))
    var offset = 8 + 4 * strikes.count
    for body in bodies { table.append(be32(UInt32(offset))); offset += body.count }
    for body in bodies { table.append(body) }
    return table
}

func name(_ name: String) -> Data {
    let records: [(Int, String)] = [(1, name), (2, "Regular"), (4, name), (6, name)]
    var table = be16(0) + be16(records.count) + be16(6 + 12 * records.count), strings = Data()
    for (id, text) in records {
        let utf16 = Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        table += be16(3) + be16(1) + be16(0x409) + be16(id) + be16(utf16.count) + be16(strings.count)
        strings.append(utf16)
    }
    return table + strings
}

func write(_ tables: [String: Data]) -> Data {
    var tables = tables
    tables["head"]!.replaceSubrange(8..<12, with: be32(0))
    let tags = tables.keys.sorted(), n = tags.count
    var selector = 0
    while 1 << (selector + 1) <= n { selector += 1 }
    var font = be32(0x0001_0000) + be16(n) + be16((1 << selector) * 16) + be16(selector) + be16(n * 16 - (1 << selector) * 16)
    var offset = 12 + n * 16, body = Data(), headAt = 0
    for tag in tags {
        let d = tables[tag]!
        if tag == "head" { headAt = offset }
        font += Data(tag.utf8) + be32(checksum(d)) + be32(UInt32(offset)) + be32(UInt32(d.count))
        let pad = (4 - d.count % 4) % 4
        body += d + Data(count: pad)
        offset += d.count + pad
    }
    font.append(body)
    font.replaceSubrange((headAt + 8)..<(headAt + 12), with: be32(0xB1B0_AFBA &- checksum(font)))
    return font
}

let base = tables(template)
guard base["sbix"] != nil, base["name"] != nil, base["head"] != nil else { fail("\(args[2]) isn't the template") }
for (i, row) in rows.enumerated() {
    var t = base
    t["sbix"] = sbix(strikes.map { size in cells[i].map { png($0, size) } })
    t["name"] = name("HermesPet-\(row.0)")
    try! write(t).write(to: out.appending(path: "HermesPet-\(row.0).ttf"))
}
