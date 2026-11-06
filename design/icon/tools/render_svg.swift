// render_svg.swift: render SVG files to PNG using WebKit (full SVG support:
// filters, masks, gradients). NSImage's built-in SVG loader ignores filters,
// so drop shadows would be lost with it.
//
// Build:  swiftc -O render_svg.swift -o .build/render_svg
// Usage:  render_svg <in.svg> <out.png> <sizePx> [<in.svg> <out.png> <sizePx> ...]
//
// The SVG is laid out at sizePx CSS pixels and snapshotted at the screen's
// backing scale (2x on Retina), then resampled to exactly sizePx, so edges are
// supersampled. The PNG keeps its alpha channel.

import AppKit
import WebKit

struct Job { let input: URL; let output: URL; let size: Int }

var jobs: [Job] = []
let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count >= 3, argv.count % 3 == 0 else {
    FileHandle.standardError.write("usage: render_svg <in.svg> <out.png> <sizePx> [...]\n".data(using: .utf8)!)
    exit(2)
}
for i in stride(from: 0, to: argv.count, by: 3) {
    guard let s = Int(argv[i + 2]), s > 0 else { fatalError("bad size \(argv[i + 2])") }
    jobs.append(Job(input: URL(fileURLWithPath: argv[i]), output: URL(fileURLWithPath: argv[i + 1]), size: s))
}

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    var queue: [Job]
    var current: Job?
    let web: WKWebView
    let window: NSWindow

    init(jobs: [Job]) {
        queue = jobs
        let maxSize = jobs.map(\.size).max() ?? 1024
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: maxSize, height: maxSize),
                        configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: maxSize, height: maxSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    func next() {
        guard !queue.isEmpty else { exit(0) }
        let job = queue.removeFirst()
        current = job
        guard let svg = try? String(contentsOf: job.input, encoding: .utf8) else {
            fatalError("cannot read \(job.input.path)")
        }
        web.setFrameSize(NSSize(width: job.size, height: job.size))
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        svg{display:block;width:\(job.size)px;height:\(job.size)px}
        </style></head><body>\(svg)</body></html>
        """
        web.loadHTMLString(html, baseURL: job.input.deletingLastPathComponent())
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.snapshot()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fatalError("navigation failed: \(error)")
    }

    func snapshot() {
        guard let job = current else { return }
        let conf = WKSnapshotConfiguration()
        conf.rect = NSRect(x: 0, y: 0, width: job.size, height: job.size)
        conf.snapshotWidth = NSNumber(value: job.size)
        conf.afterScreenUpdates = true
        web.takeSnapshot(with: conf) { image, error in
            guard let image else { fatalError("snapshot failed: \(String(describing: error))") }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: job.size, pixelsHigh: job.size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: job.size, height: job.size)
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            ctx.imageInterpolation = .high
            NSGraphicsContext.current = ctx
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: job.size, height: job.size).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: job.size, height: job.size))
            NSGraphicsContext.restoreGraphicsState()
            let data = rep.representation(using: .png, properties: [:])!
            try! FileManager.default.createDirectory(at: job.output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try! data.write(to: job.output)
            print("rendered \(job.output.lastPathComponent) (\(job.size)px)")
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = MainActor.assumeIsolated { Renderer(jobs: jobs) }
MainActor.assumeIsolated { renderer.next() }
app.run()
