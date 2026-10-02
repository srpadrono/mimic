#!/usr/bin/env swift
// Renders every design artboard in Design/Canvas to a 2x PNG in Design/Reference.
//
// Usage: swift Scripts/export_design_references.swift [board ...]
//
// The artboards are design-canvas pages whose only template hole is `{{theme}}`. Each one is made
// static (the theme filled in, the canvas runtime's scripts removed) and drawn by WebKit, the engine
// that ships SF Pro, so a reference image is set in the same typeface the app is. Section crops are
// taken from these images at the rectangles Design/Reference/sections.json names; nothing is cropped
// here.
//
// The images are rasterised at a true device scale of 2, whatever display the Mac has. Upscaling a 1x
// render is not the same thing: WebKit lays a page out for its device scale, so at 1x a 0.5 px border
// rounds to a whole point and shifts what follows it, and the upscale then draws every hairline 2
// device pixels wide. The web view's device scale is overridden instead (WebKit's
// `_setOverrideDeviceScaleFactor:`), the snapshot is taken at that scale without resampling, and a
// probe page with a 0.5 px line is checked before any board is written. If the override is missing
// and the display is not already at the manifest's scale, the script stops instead of writing
// upscaled images.
//
// Run it on a Mac whenever an artboard changes, and commit the images it writes.

import AppKit
import Foundation
import WebKit

struct Manifest: Decodable {
    struct Board: Decodable {
        let source: String
        let width: Double
        let height: Double
        let themes: [String?]
    }

    let scale: Double
    let boards: [String: Board]
}

enum ExportError: Error, CustomStringConvertible {
    case snapshotFailed(String)
    case encodeFailed(String)
    case scaleUnavailable(display: Double, wanted: Double)
    case wrongScale(String)

    var description: String {
        switch self {
        case let .snapshotFailed(name): "WebKit returned no image for \(name)"
        case let .encodeFailed(name): "could not encode \(name) as PNG"
        case let .scaleUnavailable(display, wanted):
            "this WebKit has no device-scale override (_setOverrideDeviceScaleFactor:) and the display "
                + "renders at \(display)x, so the references can't be drawn at a true \(wanted)x. "
                + "Run the exporter on a Mac whose main display is Retina, or on a macOS whose WebKit "
                + "still has the override. No images were written."
        case let .wrongScale(detail): "the render is not at a true device scale: \(detail). No images were written."
        }
    }
}

/// Fills in the theme and strips the canvas runtime, leaving plain HTML and CSS.
func staticPage(_ source: String, theme: String?) -> String {
    var page = source.replacingOccurrences(of: "{{theme}}", with: theme ?? "")
    for pattern in [#"<script src="\./support\.js"></script>\n?"#, #"<script type="text/x-dc"[\s\S]*?</script>\n?"#] {
        page = page.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return page
}

/// WebKit's device-scale override. It is SPI on `WKWebView` (WKWebViewPrivate.h:
/// `@property (setter=_setOverrideDeviceScaleFactor:) CGFloat _overrideDeviceScaleFactor`), so it
/// is reached through the Objective-C runtime, and only after checking the web view answers both
/// selectors. Key-value coding would also reach it (`overrideDeviceScaleFactor` resolves to the
/// `_set…` setter), but a missing key there raises an Objective-C exception Swift can't catch.
@MainActor
enum DeviceScaleOverride {
    /// Sets the override and reads it back. Returns false when the SPI is missing or didn't take.
    static func apply(_ scale: CGFloat, to webView: WKWebView) -> Bool {
        let setter = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        let getter = NSSelectorFromString("_overrideDeviceScaleFactor")
        guard webView.responds(to: setter), webView.responds(to: getter) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        let set = unsafeBitCast(webView.method(for: setter), to: Setter.self)
        let get = unsafeBitCast(webView.method(for: getter), to: Getter.self)
        set(webView, setter, scale)
        return get(webView, getter) == scale
    }
}

@MainActor
final class Exporter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    /// Draws a page at `scale` device pixels per point and returns an image of exactly
    /// `width * scale` by `height * scale` pixels, taken from WebKit without resampling.
    func render(html: String, baseURL: URL?, width: Double, height: Double, scale: Double) async throws -> CGImage {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        webView.navigationDelegate = self
        // Hosted in a window so layout and fonts resolve exactly as they would on screen.
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        // Before the page loads, so it is laid out for the scale it will be drawn at.
        if !DeviceScaleOverride.apply(CGFloat(scale), to: webView) {
            let display = Double(window.backingScaleFactor)
            guard display == scale else { throw ExportError.scaleUnavailable(display: display, wanted: scale) }
            // A display already at the wanted scale needs no override.
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        // Web fonts and images settle after `didFinish`; one more frame is enough for local files.
        // `evaluateJavaScript` cannot hand back a Promise; `callAsyncJavaScript` awaits it.
        let ratio = try await webView.callAsyncJavaScript(
            "await document.fonts.ready; return window.devicePixelRatio;",
            arguments: [:],
            contentWorld: .page
        )
        guard let devicePixelRatio = (ratio as? NSNumber)?.doubleValue, devicePixelRatio == scale else {
            throw ExportError.wrongScale("the page reports devicePixelRatio \(String(describing: ratio)), not \(scale)")
        }
        try await Task.sleep(for: .milliseconds(200))

        let wantedWidth = Int((width * scale).rounded())
        let wantedHeight = Int((height * scale).rounded())
        // WebKit sizes a snapshot as `snapshotWidth` points at the page's device scale. Start with
        // the page's own width; if this WebKit leaves the device scale out of snapshots, ask for the
        // missing factor through `snapshotWidth`, which WebKit paints at (not an upscale of the
        // bitmap). Either way the result must come back at exactly the wanted pixel size.
        var image = try await snapshot(webView, width: width, height: height, snapshotWidth: nil)
        if image.width != wantedWidth, image.width > 0 {
            let factor = Double(wantedWidth) / Double(image.width)
            image = try await snapshot(webView, width: width, height: height, snapshotWidth: width * factor)
        }
        guard image.width == wantedWidth, image.height == wantedHeight else {
            throw ExportError.wrongScale(
                "WebKit returned \(image.width)x\(image.height) px for a \(Int(width))x\(Int(height)) pt page, "
                    + "not \(wantedWidth)x\(wantedHeight)"
            )
        }
        return image
    }

    private func snapshot(_ webView: WKWebView, width: Double, height: Double, snapshotWidth: Double?) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.afterScreenUpdates = true
        if let snapshotWidth {
            configuration.snapshotWidth = NSNumber(value: snapshotWidth)
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        // The representation with the most pixels is the one WebKit drew; asking the NSImage for a
        // CGImage without a rep could hand back one fitted to the main display instead.
        let representation = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        guard let cgImage = representation?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.snapshotFailed("snapshot")
        }
        return cgImage
    }

    /// Encodes the image as sRGB PNG, tagged with its size in points. Colour is converted; pixels
    /// are not resampled.
    func png(from image: CGImage, pointsWide: Double, pointsHigh: Double) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let sRGB = bitmap.converting(to: .sRGB, renderingIntent: .default) else {
            throw ExportError.encodeFailed("bitmap")
        }
        sRGB.size = NSSize(width: pointsWide, height: pointsHigh)
        guard sRGB.pixelsWide == image.width, sRGB.pixelsHigh == image.height,
              let data = sRGB.representation(using: .png, properties: [:]) else {
            throw ExportError.encodeFailed("bitmap")
        }
        return data
    }

    /// Renders a probe page and fails unless it came out at a true `scale`: a 0.5 px black line on
    /// white must fill exactly one device row (at 2x) with untouched rows on either side. A 1x render
    /// upscaled to 2x draws it over two rows, or blurs it into its neighbours.
    func verifyTrueScale(_ scale: Double) async throws {
        let line = 1 / scale
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:#fff}
        #line{position:absolute;left:4px;top:4px;width:12px;height:\(line)px;background:#000}
        </style></head><body><div id="line"></div></body></html>
        """
        let image = try await render(html: html, baseURL: nil, width: 20, height: 10, scale: scale)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Darkest value in each pixel row (row 0 at the top), sampled across the line's middle.
        let columns = Int(8 * scale)..<Int(12 * scale)
        let darkest: [CGFloat] = (0..<bitmap.pixelsHigh).map { y in
            columns.map { x in
                bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericGray)?.whiteComponent ?? 1
            }.min() ?? 1
        }
        let lineRow = Int(4 * scale)
        let inked = darkest.indices.filter { darkest[$0] < 0.5 }
        let touched = darkest.indices.filter { darkest[$0] < 0.95 }
        guard inked == [lineRow], touched == [lineRow] else {
            throw ExportError.wrongScale(
                "a \(line) px line should fill only device row \(lineRow); rows inked: \(inked), rows touched: \(touched)"
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
func run() async -> Int32 {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let design = root.appendingPathComponent("Design")
    let output = design.appendingPathComponent("Reference")
    let requested = Set(CommandLine.arguments.dropFirst())
    do {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: output.appendingPathComponent("sections.json"))
        )
        let exporter = Exporter()
        // Before any board is written, so a wrong scale never replaces a good reference.
        try await exporter.verifyTrueScale(manifest.scale)
        for (name, board) in manifest.boards.sorted(by: { $0.key < $1.key })
        where requested.isEmpty || requested.contains(name) {
            let sourceURL = design.appendingPathComponent(board.source)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for theme in board.themes.isEmpty ? [nil] : board.themes {
                let fileName = theme.map { "\(name)-\($0).png" } ?? "\(name).png"
                let image = try await exporter.render(
                    html: staticPage(source, theme: theme),
                    baseURL: sourceURL.deletingLastPathComponent(),
                    width: board.width,
                    height: board.height,
                    scale: manifest.scale
                )
                let data = try exporter.png(from: image, pointsWide: board.width, pointsHigh: board.height)
                try data.write(to: output.appendingPathComponent(fileName), options: .atomic)
                print("wrote Design/Reference/\(fileName) (\(image.width)x\(image.height) px)")
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("export_design_references: \(error)\n".utf8))
        return 1
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    exit(await run())
}
application.run()
