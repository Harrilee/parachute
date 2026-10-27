import AppKit
import SwiftUI

/// Compiled only with NATIVE_QA=1; captures this application's views, not the desktop.
@MainActor
enum NativeQA {
    private static var previewWindow: NSWindow?

    /// Background launches may suppress the SwiftUI Window scene. This fallback is
    /// exclusively for isolated preview screenshots and never starts device polling.
    private static func ensurePreviewWindow(arguments: [String]) -> NSWindow? {
        if let existing = NSApp.windows.first(where: { $0.contentView != nil }) {
            if !existing.isVisible { existing.orderBack(nil) }
            return existing
        }
        guard arguments.contains("--preview"), arguments.contains("--snapshot") else { return nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Parachute QA Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 520)
        window.contentView = NSHostingView(rootView: ContentView()
            .environmentObject(LanguageStore())
            .environmentObject(DeviceService()))
        previewWindow = window
        window.center()
        window.orderBack(nil)
        return window
    }

    static func start() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) else { return }
        let destination = arguments[flag + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let window = arguments.contains("--preview")
                ? ensurePreviewWindow(arguments: arguments)
                : NSApp.windows.first(where: { $0.contentView != nil })
            if arguments.contains("--small") {
                window?.setContentSize(NSSize(width: 740, height: 520))
            }
            if arguments.contains("--foreground-snapshot") {
                // MapKit suspends rendering while fully occluded. This opt-in
                // presents only the fixture window, without activating the app.
                window?.orderFrontRegardless()
            }
            window?.contentView?.layoutSubtreeIfNeeded()
            if let window {
                try? String(window.windowNumber).write(toFile: destination + ".window-number.txt",
                                                      atomically: true, encoding: .utf8)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let debug = NSApp.windows.map { "\(type(of: $0)): \($0.title), visible=\($0.isVisible), frame=\($0.frame), view=\(String(describing: $0.contentView)), sheet=\($0.attachedSheet != nil)" }.joined(separator: "\n")
            try? debug.write(toFile: destination + ".debug.txt", atomically: true, encoding: .utf8)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("Snapshot failed: no visible view\n", stderr)
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: destination))
                print("Snapshot: \(destination), window: \(window.frame.size)")
            }
            let windows = NSApp.windows.map { "\(type(of: $0)): \($0.title), visible=\($0.isVisible), frame=\($0.frame), sheet=\($0.attachedSheet != nil)" }.joined(separator: "\n")
            try? windows.write(toFile: destination + ".txt", atomically: true, encoding: .utf8)
            for (index, panel) in NSApp.windows.filter({ $0.isVisible && $0 !== window }).enumerated() {
                if let panelView = panel.contentView?.superview ?? panel.contentView, let bitmap = panelView.bitmapImageRepForCachingDisplay(in: panelView.bounds) {
                    panelView.cacheDisplay(in: panelView.bounds, to: bitmap)
                    if let bytes = bitmap.representation(using: .png, properties: [:]) {
                        try? bytes.write(to: URL(fileURLWithPath: destination.replacingOccurrences(of: ".png", with: "-panel\(index).png")))
                    }
                }
            }
            // Capture modal sheet separately when present.
            if let sheet = window.attachedSheet, let sheetView = sheet.contentView,
               let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
                sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
                if let data = sheetRep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: destination.replacingOccurrences(of: ".png", with: "-sheet.png")))
                }
            }
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }
}
