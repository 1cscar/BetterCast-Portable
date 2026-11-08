// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Events are written by capture, encode, presentation and network callbacks.
final class SessionTrace: @unchecked Sendable {
    private struct Event {
        let kind: String
        let pts: UInt64
        let time: UInt64
        let value: Int
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var omitted = 0
    private let directory: URL
    private let mode: String

    init(directory: URL, width: Int, height: Int, codec: StreamCodec, refresh: Double, settings: String) {
        self.directory = directory
        mode = "\(width)x\(height) codec=\(codec.rawValue) refresh_hz=\(refresh) \(settings)"
    }

    func record(_ kind: String, _ pts: UInt64 = 0, _ value: Int = 0,
                at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            if events.count < 100_000 { events.append(Event(kind: kind, pts: pts, time: time, value: value)) }
            else { omitted += 1 }
        }
    }

    func save() {
        let (snapshot, omitted) = lock.withLock { (events, omitted) }
        let filename = "host-\(UUID().uuidString).csv"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let header = "# commit=\(portableBuildCommit) mode=\(mode) omitted=\(omitted)\nevent,pts_100ns,time_ns,value\n"
            let rows = snapshot.map { "\($0.kind),\($0.pts),\($0.time),\($0.value)\n" }.joined()
            let url = directory.appendingPathComponent(filename)
            try (header + rows).write(to: url, atomically: true, encoding: .utf8)
            print("Portable trace: \(url.path)")
        } catch {
            print("Portable trace write failed: \(error.localizedDescription)")
        }
    }
}
