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

    var description: String {
        switch self {
        case let .snapshotFailed(name): "WebKit returned no image for \(name)"
        case let .encodeFailed(name): "could not encode \(name) as PNG"
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

@MainActor
final class Exporter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func render(html: String, baseURL: URL, width: Double, height: Double, scale: Double) async throws -> Data {
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        // Web fonts and images settle after `didFinish`; one more frame is enough for local files.
        _ = try await webView.evaluateJavaScript("document.fonts.ready.then(() => true)")
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: width, height: height)
        snapshot.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: snapshot)
        return try png(from: image, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale))
    }

    /// Redraws the snapshot into a bitmap of exactly the requested pixel size, so the output is 2x
    /// whether or not the Mac running this has a Retina display.
    private func png(from image: NSImage, pixelsWide: Int, pixelsHigh: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw ExportError.encodeFailed("bitmap") }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let sRGB = bitmap.converting(to: .sRGB, renderingIntent: .default),
              let data = sRGB.representation(using: .png, properties: [:]) else {
            throw ExportError.encodeFailed("bitmap")
        }
        return data
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
        for (name, board) in manifest.boards.sorted(by: { $0.key < $1.key })
        where requested.isEmpty || requested.contains(name) {
            let sourceURL = design.appendingPathComponent(board.source)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for theme in board.themes.isEmpty ? [nil] : board.themes {
                let fileName = theme.map { "\(name)-\($0).png" } ?? "\(name).png"
                let data = try await exporter.render(
                    html: staticPage(source, theme: theme),
                    baseURL: sourceURL.deletingLastPathComponent(),
                    width: board.width,
                    height: board.height,
                    scale: manifest.scale
                )
                try data.write(to: output.appendingPathComponent(fileName), options: .atomic)
                print("wrote Design/Reference/\(fileName)")
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
