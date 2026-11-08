import SwiftUI

@main
struct BetterCastPortableHostApp: App {
    @StateObject private var host = PortableHost()

    var body: some Scene {
        WindowGroup("BetterCast Portable Host") {
            VStack(alignment: .leading, spacing: 14) {
                Text(host.status).font(.headline)
                if !host.code.isEmpty {
                    Text(host.code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    Text("Enter this code and this Mac’s LAN IPv4 address in the receiver.")
                }
                if !host.request.isEmpty {
                    Text(host.request)
                    HStack {
                        Button("Approve extension") { host.approve() }
                        Button("Decline") { host.deny() }
                    }
                }
                if !host.metrics.isEmpty { Text(host.metrics).monospacedDigit() }
                HStack {
                    Button("Generate pairing code") { host.pair() }.disabled(host.busy)
                    Button("Stop") { host.stop() }.disabled(!host.busy)
                }
            }
            .padding(24)
            .frame(minWidth: 540, minHeight: 170)
            .onDisappear { host.stop() }
        }
    }
}
