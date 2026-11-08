// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
private final class MotionView: NSView {
    private var frameNumber = 0
    private let onDraw: () -> Void

    init(frame: NSRect, onDraw: @escaping () -> Void) {
        self.onDraw = onDraw
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let hue = CGFloat((frameNumber * 17) % 360) / 360
        NSColor(calibratedHue: hue, saturation: 0.9, brightness: 0.75, alpha: 1).setFill()
        bounds.fill()
        let label = NSAttributedString(string: "BetterCast · \(frameNumber)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        label.draw(at: NSPoint(x: 24, y: bounds.midY))
        onDraw()
    }

    func advance() {
        frameNumber += 1
        needsDisplay = true
        displayIfNeeded()
    }
}

@MainActor
final class MotionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    init(screen: NSScreen, onUpdate: @escaping () -> Void) {
        let frame = screen.frame.insetBy(dx: 100, dy: 100)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "BetterCast moving test window"
        window.setFrame(frame, display: true)
        let view = MotionView(frame: frame, onDraw: onUpdate)
        window.contentView = view
        super.init()
        window.delegate = self
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Measure BetterCast display motion")
        window.orderFrontRegardless()
        let end = DispatchTime.now().uptimeNanoseconds + 72_000_000_000
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                if DispatchTime.now().uptimeNanoseconds >= end { self.stop(); return }
                view.advance()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func windowWillClose(_ notification: Notification) { stop() }
}
