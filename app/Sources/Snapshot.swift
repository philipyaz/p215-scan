import AppKit
import SwiftUI

/// Headless UI snapshots, used to produce the README screenshots and to eyeball
/// UI changes without a human at the machine:
///
///     P215_SNAPSHOT=outdir P215_SNAPSHOT_IMPORT=a.png:b.png "P215 Scan"
///
/// Imports the given images, renders the main window to `outdir/main.png`
/// (plus `main-pre.png`, see below), opens the first page in the editor and
/// renders it to `outdir/editor.png`, then quits. The window renders itself
/// via `cacheDisplay` — no screen capture, so no permissions are needed and
/// this works over SSH.
///
/// macOS 26 caveat: Liquid Glass hosts one split-view column at a time in a
/// window-server portal surface that `cacheDisplay` cannot see, so that column
/// comes out blank white. On a clean launch the detail grid renders and the
/// sidebar is blank (`main-pre.png`); collapsing and re-expanding the sidebar
/// *sometimes* re-hosts it locally, which the retry loop below fishes for
/// (`main.png`). Sheets are unaffected. P215_SNAPSHOT_LIGHT=1 forces light
/// appearance; P215_SNAPSHOT_DEBUG=1 dumps the view hierarchy.
enum Snapshot {
    @MainActor static func runIfRequested(_ state: AppState) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["P215_SNAPSHOT"] else { return }
        log("starting, out=\(dir)")
        if env["P215_SNAPSHOT_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1.5))          // let the window settle
        if let files = env["P215_SNAPSHOT_IMPORT"] {
            let urls = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            log("importing \(urls.count) file(s)")
            state.importImages(urls: urls)
        }
        try? await Task.sleep(for: .seconds(3))            // thumbnails render async
        write(window: appWindow(), to: "\(dir)/main-pre.png")
        for attempt in 1...3 {
            NSApp.sendAction(Selector(("toggleSidebar:")), to: nil, from: nil)
            try? await Task.sleep(for: .seconds(1.2))
            NSApp.sendAction(Selector(("toggleSidebar:")), to: nil, from: nil)
            try? await Task.sleep(for: .seconds(1.5))
            if let img = rawImage(of: appWindow()), !sidebarBlank(img) {
                log("sidebar rendered on attempt \(attempt)")
                break
            }
            log("sidebar still blank after attempt \(attempt)")
        }
        write(window: appWindow(), to: "\(dir)/main.png")
        if let page = state.visiblePages.first {
            state.editingPage = page
            try? await Task.sleep(for: .seconds(2.5))      // sheet + full-res render
            let sheet = NSApp.windows.last { $0.isVisible && $0 !== appWindow() }
            write(window: sheet ?? appWindow(), to: "\(dir)/editor.png")
        }
        log("done")
        exit(0)
    }

    @MainActor private static func appWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width >= 400 }
            ?? NSApp.windows.first
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("snapshot: \(s)\n".utf8))
    }

    /// Renders the window's frame view — content plus title bar, toolbar and
    /// traffic lights — at the display's backing scale.
    @MainActor private static func rawImage(of window: NSWindow?) -> CGImage? {
        guard let frameView = window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }

    /// A portal-hosted sidebar renders as uniform white; a real render has
    /// grey group boxes and dark labels.
    private static func sidebarBlank(_ img: CGImage) -> Bool {
        guard let crop = img.cropping(to: CGRect(x: 120, y: img.height / 3,
                                                 width: 400, height: img.height / 3)),
              let ctx = CGContext(data: nil, width: crop.width, height: crop.height,
                                  bitsPerComponent: 8, bytesPerRow: 4 * crop.width,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        var nonWhite = 0
        for i in stride(from: 0, to: crop.width * crop.height * 4, by: 4) where data[i] < 245 {
            nonWhite += 1
        }
        return nonWhite < 2000
    }

    @MainActor private static func write(window: NSWindow?, to path: String) {
        if ProcessInfo.processInfo.environment["P215_SNAPSHOT_DEBUG"] != nil,
           let frameView = window?.contentView?.superview {
            dump(frameView, depth: 0)
        }
        guard let img = rawImage(of: window),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else {
            log("no window for \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        log("wrote \(path)")
    }

    @MainActor private static func dump(_ view: NSView, depth: Int) {
        let f = view.frame
        log(String(repeating: "  ", count: depth)
            + "\(type(of: view)) \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
            + (view.isHidden ? " hidden" : ""))
        for sub in view.subviews { dump(sub, depth: depth + 1) }
    }
}
