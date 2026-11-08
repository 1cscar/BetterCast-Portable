// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

@MainActor
final class MotionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private var timer: Timer?

    init(screen: NSScreen, onUpdate: @escaping () -> Void) {
        let frame = screen.frame.insetBy(dx: 100, dy: 100)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "BetterCast moving test window"
        window.setFrame(frame, display: true)
        let view = NSView(frame: frame)
        view.wantsLayer = true
        window.contentView = view
        super.init()
        window.delegate = self
        window.orderFrontRegardless()
        let colors: [NSColor] = [.red, .blue, .green, .white]
        var frameIndex = 0
        let end = DispatchTime.now().uptimeNanoseconds + 72_000_000_000
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak view] timer in
            guard let view, DispatchTime.now().uptimeNanoseconds < end else { timer.invalidate(); return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.backgroundColor = colors[frameIndex % colors.count].cgColor
            CATransaction.commit()
            frameIndex += 1
            onUpdate()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) { stop() }
}
