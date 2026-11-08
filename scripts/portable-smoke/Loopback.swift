// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import QuartzCore

@main
struct LocalSmoke {
    @MainActor static func until(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<120 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("FAIL timeout: \(description)")
        exit(1)
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await run() }
        app.run()
    }

    @MainActor static func run() async {
        let args = CommandLine.arguments
        let width = Int(args[1])!, height = Int(args[2])!, codec = UInt8(args[3])!
        guard CGPreflightScreenCaptureAccess() else { print("FAIL Screen Recording denied"); exit(1) }
        let host = PortableHost()
        let initial = Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        host.pair()
        await until("host listening") { !host.code.isEmpty }
        let code = host.code
        let secret = Data(stride(from: 0, to: code.count, by: 2).map {
            let i = code.index(code.startIndex, offsetBy: $0)
            return UInt8(code[i..<code.index(i, offsetBy: 2)], radix: 16)!
        })
        let output = Pipe()
        let client = Process()
        client.executableURL = URL(fileURLWithPath: args[4])
        client.arguments = [args[5], String(width), String(height), String(codec)]
        client.standardInput = output
        try! client.run()
        output.fileHandleForWriting.write(secret)
        try? output.fileHandleForWriting.close()
        await until("authenticated approval request") { !host.request.isEmpty }
        precondition(host.code.isEmpty)
        precondition(initial.count == NSScreen.screens.count, "Display created before approval")
        host.approve()
        func extended() -> NSScreen? {
            NSScreen.screens.first { screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                return !initial.contains(id) && CGDisplayIsInMirrorSet(id) == 0
            }
        }
        await until("new independent virtual display (host: \(host.status))") { extended() != nil }
        let screen = extended()!
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let frame = screen.frame.insetBy(dx: 100, dy: 100)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BetterCast real extension smoke"
        window.setFrame(frame, display: true)
        let view = NSView(frame: frame)
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        precondition(window.screen == screen, "Test window is outside virtual display")
        let colors: [NSColor] = [.red, .blue, .green, .white]
        var frameIndex = 0
        let animation = Timer.scheduledTimer(withTimeInterval: 1/60.0, repeats: true) { _ in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.backgroundColor = colors[frameIndex % colors.count].cgColor
            CATransaction.commit()
            frameIndex += 1
        }
        for _ in 0..<400 {
            if !client.isRunning { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        animation.invalidate()
        if client.isRunning { client.terminate(); print("FAIL loopback timed out"); exit(1) }
        guard client.terminationStatus == 0 else { print("FAIL loopback receiver exited \(client.terminationStatus)"); exit(1) }
        await until("virtual display removal") { CGDisplayIsOnline(id) != 1 && !host.busy }
        await until("window rehomed") {
            guard let screen = window.screen,
                  let destination = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return false }
            return initial.contains(destination) && screen.visibleFrame.intersects(window.frame)
        }
        precondition(window.isVisible, "Window became invisible after disconnect")
        print("PASS independent \(width)x\(height) codec=\(codec); approval precedes display; TCP close removed display; visible window rehomed")
        window.close()
        exit(0)
    }
}
