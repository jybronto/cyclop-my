import AppKit
import SwiftUI

/// Hands scroll-wheel and trackpad scrolling over a view to a closure, as a
/// vertical delta in points — positive meaning the content should move down,
/// the way `NSEvent.scrollingDeltaY` already reads with the user's natural
/// scrolling setting applied.
///
/// A local event monitor rather than a view overriding `scrollWheel(with:)`:
/// a view only receives scrolling if it wins the hit test, and winning the hit
/// test would also take the clicks meant for whatever sits on top. This one
/// sits in the background, takes no clicks, and only listens.
struct ScrollWheelReader: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread, inside event dispatch.
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            // Trackpads report points; a mouse wheel reports lines, which need
            // scaling up or one notch would barely move the text.
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
            if dy != 0 { onScroll(dy) }
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
