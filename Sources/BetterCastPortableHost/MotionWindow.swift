// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

@MainActor
private final class MotionView: NSView {
    private var frameNumber = 0
    private let trace: SessionTrace?

    init(frame: NSRect, trace: SessionTrace?) {
        self.trace = trace
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let begin = DispatchTime.now().uptimeNanoseconds
        let hue = CGFloat((frameNumber * 17) % 360) / 360
        NSColor(calibratedHue: hue, saturation: 0.9, brightness: 0.75, alpha: 1).setFill()
        bounds.fill()
        let label = NSAttributedString(string: "BetterCast · \(frameNumber)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        label.draw(at: NSPoint(x: 24, y: bounds.midY))
        let end = DispatchTime.now().uptimeNanoseconds
        trace?.record("motion", 0, frameNumber, at: end)
        trace?.record("draw_duration", 0, Int(end - begin), at: end)
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
    private var stopDisplayLink: (() -> Void)?
    private var drawNext: (() -> Void)?
    private let trace: SessionTrace?
    private let useDisplayLink: Bool
    private let end = DispatchTime.now().uptimeNanoseconds + 72_000_000_000

    init(screen: NSScreen, useDisplayLink: Bool = false, metalMotion: Bool = false, trace: SessionTrace? = nil) {
        self.trace = trace
        self.useDisplayLink = useDisplayLink
        let frame = screen.frame.insetBy(dx: 100, dy: 100)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "BetterCast moving test window"
        window.setFrame(frame, display: true)
        if metalMotion {
            guard let view = try? MetalMotionView(frame: frame, scale: screen.backingScaleFactor, trace: trace) else {
                preconditionFailure("Could not initialize the Metal motion experiment")
            }
            window.contentView = view
            drawNext = { [weak view] in view?.advance() }
        } else {
            let view = MotionView(frame: frame, trace: trace)
            window.contentView = view
            drawNext = { [weak view] in view?.advance() }
        }
        super.init()
        window.delegate = self
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Measure BetterCast display motion")
        window.orderFrontRegardless()
        if #available(macOS 14.0, *), trace != nil || useDisplayLink {
            let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            stopDisplayLink = { link.invalidate() }
            if useDisplayLink { return }
        }
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advance() {
        if DispatchTime.now().uptimeNanoseconds >= end { stop(); return }
        trace?.record("motion_tick")
        drawNext?()
    }

    @available(macOS 14.0, *)
    @objc private func displayTick(_ link: CADisplayLink) {
        let expected = UInt64(link.timestamp * 1e9)
        trace?.record("display_tick", 0, Int(link.targetTimestamp * 1e9), at: expected)
        trace?.record("display_callback")
        if useDisplayLink { advance() }
    }

    func stop() {
        stopDisplayLink?()
        stopDisplayLink = nil
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func windowWillClose(_ notification: Notification) { stop() }
}
