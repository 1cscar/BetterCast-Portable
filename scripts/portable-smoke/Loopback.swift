// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin

@main
struct LocalSmoke {
    @MainActor static func until(_ description: String, seconds: Int = 8, _ condition: () -> Bool) async {
        for _ in 0..<(seconds * 20) {
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
        let scenario = args[6]
        let directory = args[7]
        guard CGPreflightScreenCaptureAccess() else { print("FAIL Screen Recording denied"); exit(1) }
        let host = PortableHost(traceDirectory: directory.isEmpty ? nil : URL(fileURLWithPath: directory),
                                listenPort: 0, pairingSeconds: scenario == "expired" ? 2 : 300,
                                approvalSeconds: scenario == "approval_timeout" ? 2 : 30,
                                performance: PortablePerformance(experiment: ProcessInfo.processInfo.environment["PORTABLE_EXPERIMENT"] ?? "default"))
        func displayID(_ screen: NSScreen) -> UInt32? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let initial = Set(NSScreen.screens.compactMap(displayID))
        host.pair()
        await until("host listening") { !host.code.isEmpty && host.boundPort != nil }
        let code = host.code
        let port = host.boundPort!
        let secret = Data(stride(from: 0, to: code.count, by: 2).map {
            let i = code.index(code.startIndex, offsetBy: $0)
            return UInt8(code[i..<code.index(i, offsetBy: 2)], radix: 16)!
        })
        if scenario == "expired" {
            await until("pairing code expires") { !host.busy && host.code.isEmpty }
        }
        let output = Pipe()
        let client = Process()
        client.executableURL = URL(fileURLWithPath: args[4])
        client.arguments = [args[5], String(width), String(height), String(codec), String(port), scenario, directory]
        client.standardInput = output
        try! client.run()
        output.fileHandleForWriting.write(secret)
        try? output.fileHandleForWriting.close()

        if ["wrong_code", "expired", "approval_timeout"].contains(scenario) {
            if scenario == "approval_timeout" {
                await until("authenticated approval request") { !host.request.isEmpty }
            }
            await until("client rejected") { !client.isRunning }
            precondition(client.terminationStatus == 0)
            await until("expected Host rejection status") {
                switch scenario {
                case "wrong_code": return host.status.contains("authentication failed") && host.code == code
                case "expired": return host.status.contains("Code expired")
                default: return host.status.contains("approval timed out") && !host.busy
                }
            }
            precondition(Set(NSScreen.screens.compactMap(displayID)) == initial)
            print("PASS \(scenario): no extension created")
            host.stop()
            exit(0)
        }

        await until("authenticated approval request") { !host.request.isEmpty }
        precondition(host.code.isEmpty)
        precondition(Set(NSScreen.screens.compactMap(displayID)) == initial, "Display created before approval")
        host.approve()
        func extended() -> NSScreen? {
            NSScreen.screens.first { screen in
                guard let id = displayID(screen) else { return false }
                return !initial.contains(id) && CGDisplayIsInMirrorSet(id) == 0
            }
        }
        await until("new independent virtual display (host: \(host.status))") { extended() != nil }
        let screen = extended()!
        let id = displayID(screen)!
        let motion: MotionWindow?
        if scenario == "steady" {
            await until("Host diagnostic motion available") { host.canShowMotion }
            host.showMotion()
            motion = nil
        } else {
            motion = MotionWindow(screen: screen)
            precondition(motion?.window.screen == screen, "Test window is outside virtual display")
        }
        if scenario == "host_stop" || scenario == "window_close" {
            await until("video starts") { host.status.hasPrefix("Streaming") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if scenario == "host_stop" { host.stop() }
            else {
                motion?.window.close()
                precondition(motion?.window.isVisible == false && host.busy)
            }
        }
        await until("loopback client finishes", seconds: scenario == "steady" ? 80 : 15) { !client.isRunning }
        guard client.terminationStatus == 0 else { print("FAIL loopback receiver exited \(client.terminationStatus)"); exit(1) }
        await until("virtual display removal") { CGDisplayIsOnline(id) != 1 && !host.busy }
        if let motion, scenario != "window_close" {
            await until("window rehomed") {
                guard let screen = motion.window.screen, let destination = displayID(screen) else { return false }
                return initial.contains(destination) && screen.visibleFrame.intersects(motion.window.frame)
            }
            precondition(motion.window.isVisible, "Window became invisible after disconnect")
            motion.window.close()
        }
        if !directory.isEmpty {
            await until("capture teardown and trace save") {
                (try? FileManager.default.contentsOfDirectory(atPath: directory))?.contains {
                    $0.hasPrefix("host-") && $0.hasSuffix(".csv")
                } == true
            }
        }
        print("PASS \(scenario) independent \(width)x\(height) codec=\(codec); approval and teardown verified")
        exit(0)
    }
}
