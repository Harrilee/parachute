import AppKit
import SwiftUI

/// A native drag surface above the map. Window buttons and the map-style control
/// retain their own hit targets; dragging the surface never reaches MapKit.
struct WindowDragRegion: NSViewRepresentable {
    @Binding var isHovered: Bool
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> DragSurface {
        let view = DragSurface()
        view.hoverChanged = { isHovered = $0 }
        view.heightChanged = { height = $0 }
        return view
    }

    func updateNSView(_ nsView: DragSurface, context: Context) {
        nsView.hoverChanged = { isHovered = $0 }
        nsView.heightChanged = { height = $0 }
        nsView.scheduleHeightMeasurement()
    }

    static func dismantleNSView(_ nsView: DragSurface, coordinator: ()) {
        nsView.hoverChanged = nil
        nsView.heightChanged = nil
        nsView.stopObservingWindow()
    }

    final class DragSurface: NSView {
        var hoverChanged: ((Bool) -> Void)?
        var heightChanged: ((CGFloat) -> Void)?
        private var hoverTracking: NSTrackingArea?
        private var windowObservers: [NSObjectProtocol] = []
        private var measurementQueued = false
        private var lastHeight: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservingWindow()
            if let window {
                let notifications: [Notification.Name] = [
                    NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                    NSWindow.didChangeScreenNotification, NSWindow.didEnterFullScreenNotification,
                    NSWindow.didExitFullScreenNotification,
                ]
                windowObservers = notifications.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.scheduleHeightMeasurement()
                    }
                }
            }
            scheduleHeightMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleHeightMeasurement()
        }

        func stopObservingWindow() {
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers.removeAll()
        }

        deinit {
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        }

        func scheduleHeightMeasurement() {
            guard !measurementQueued else { return }
            measurementQueued = true
            // Avoid changing SwiftUI state during updateNSView/layout, and measure after AppKit layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementQueued = false
                let measured = self.measuredHeight()
                guard self.lastHeight == nil || abs((self.lastHeight ?? 0) - measured) > 0.25 else { return }
                self.lastHeight = measured
                self.heightChanged?(measured)
            }
        }

        func measuredHeight() -> CGFloat {
            let fallback: CGFloat = 32
            guard let window, let closeButton = window.standardWindowButton(.closeButton),
                  !closeButton.isHiddenOrHasHiddenAncestor else { return fallback }
            // NSView nil conversion gives window-base coordinates; screen conversion lets us
            // measure the gap to the actual window frame, including its titlebar.
            let buttonRect = window.convertToScreen(closeButton.convert(closeButton.bounds, to: nil))
            let diameter = buttonRect.height
            let topGap = window.frame.maxY - buttonRect.maxY
            // Full-screen transitions can temporarily move/hide native controls outside the frame.
            guard diameter.isFinite, topGap.isFinite, diameter > 0, topGap >= 0, topGap <= 64 else { return fallback }
            return diameter + 2 * topGap
        }
        override var isOpaque: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(tracking)
            hoverTracking = tracking
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), local.x >= 80, local.x < bounds.width - 68 else { return nil }
            return self
        }

        override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

        override func resetCursorRects() {
            addCursorRect(NSRect(x: 80, y: 0, width: max(0, bounds.width - 148), height: bounds.height), cursor: .arrow)
        }

        override func mouseDown(with event: NSEvent) {
            hoverChanged?(true)
            window?.performDrag(with: event)
            if let window {
                hoverChanged?(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
            }
        }
    }
}
