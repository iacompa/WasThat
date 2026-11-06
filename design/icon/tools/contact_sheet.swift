// contact_sheet.swift: compose the icon contact sheet.
//
// Build:  swiftc -O contact_sheet.swift -o .build/contact_sheet
// Usage:  contact_sheet <out.png> <A-1024.png> <B-1024.png> <C-1024.png>
//
// Two bands (light / dark desktop). Each variant gets a column with the
// 1024 px icon at 1:1, then 128, 32 and 16 px at true pixel size, plus the
// 32 and 16 px renders blown up with nearest-neighbour so individual pixels
// can be judged. Small sizes are made by repeated 2x high-quality halving,
// which approximates what sips/iconutil produce from the 1024 master.

import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: contact_sheet <out.png> <icon1024.png>...\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[0]
let inputs = Array(args.dropFirst())
let labels = ["A  Badge", "B  Perch", "C  Comic", "D", "E"]

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func loadCG(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot load \(path)") }
    return img
}

func resize(_ img: CGImage, _ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func downscale(_ img: CGImage, to size: Int) -> CGImage {
    var cur = img
    while cur.width / 2 >= size { cur = resize(cur, cur.width / 2) }
    if cur.width != size { cur = resize(cur, size) }
    return cur
}

// Layout (top-left origin; converted when drawing)
let margin: CGFloat = 80, colW: CGFloat = 1024, colGap: CGFloat = 80
let header: CGFloat = 130, bandTitle: CGFloat = 80, smallRowTop: CGFloat = 40, smallRowH: CGFloat = 128
let bandH: CGFloat = bandTitle + colW + smallRowTop + smallRowH + 90
let n = CGFloat(inputs.count)
let W = margin * 2 + n * colW + (n - 1) * colGap
let H = header + bandH * 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx

func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: H - y - h, width: w, height: h) }

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: x, y: H - y - sz.height))
}

func drawImage(_ img: CGImage, _ rect: NSRect, nearest: Bool = false) {
    gctx.imageInterpolation = nearest ? .none : .high
    let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    ns.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

let masters = inputs.map(loadCG)
let small: [[Int: CGImage]] = masters.map { m in
    var d: [Int: CGImage] = [:]
    for s in [128, 32, 16] { d[s] = downscale(m, to: s) }
    return d
}

// header
NSColor(white: 0.97, alpha: 1).setFill(); r(0, 0, W, header).fill()
text("WasThat app icon: variants", margin, 34, size: 46, color: NSColor(white: 0.12, alpha: 1), weight: .bold)
text("1024 px at 1:1, then 128 / 32 / 16 px at true size, then 32 px x4 and 16 px x8 (nearest-neighbour).",
     margin + 640, 50, size: 24, color: NSColor(white: 0.4, alpha: 1))

let bands: [(String, NSColor, NSColor)] = [
    ("Light desktop", NSColor(srgbRed: 0.925, green: 0.93, blue: 0.945, alpha: 1), NSColor(white: 0.15, alpha: 1)),
    ("Dark desktop", NSColor(srgbRed: 0.11, green: 0.11, blue: 0.125, alpha: 1), NSColor(white: 0.9, alpha: 1)),
]

for (bi, band) in bands.enumerated() {
    let top = header + CGFloat(bi) * bandH
    band.1.setFill(); r(0, top, W, bandH).fill()
    text(band.0, margin, top + 22, size: 30, color: band.2.withAlphaComponent(0.6), weight: .semibold)
    for (i, m) in masters.enumerated() {
        let x = margin + CGFloat(i) * (colW + colGap)
        text(labels[i], x + colW - 220, top + 22, size: 30, color: band.2, weight: .bold)
        drawImage(m, r(x, top + bandTitle, colW, colW))
        let y = top + bandTitle + colW + smallRowTop
        var cx = x + 40
        let items: [(String, CGImage, CGFloat, Bool)] = [
            ("128", small[i][128]!, 128, false),
            ("32", small[i][32]!, 32, false),
            ("16", small[i][16]!, 16, false),
            ("32 x4", small[i][32]!, 128, true),
            ("16 x8", small[i][16]!, 128, true),
        ]
        for (label, img, size, nearest) in items {
            let iy = y + (smallRowH - size) / 2
            drawImage(img, r(cx, iy, size, size), nearest: nearest)
            text(label, cx, y + smallRowH + 14, size: 22, color: band.2.withAlphaComponent(0.65))
            cx += max(size, 60) + 70
        }
    }
}

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(W))x\(Int(H)))")
