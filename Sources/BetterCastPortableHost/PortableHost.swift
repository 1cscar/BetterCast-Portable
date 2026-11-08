import CoreMedia
import ScreenCaptureKit
import AppKit
import CryptoKit
import Network
import SwiftUI

private let maxFrame = 8 * 1024 * 1024
private let protocolLabel = Data("BetterCast Portable v1".utf8)

private func randomBytes(_ count: Int) -> Data? {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
    }
    return status == errSecSuccess ? data : nil
}

private func key(_ secret: Data, _ transcript: Data, _ direction: UInt8) -> SymmetricKey {
    SymmetricKey(data: HMAC<SHA256>.authenticationCode(
        for: protocolLabel + transcript + Data([direction]), using: SymmetricKey(data: secret)))
}

private func integer(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
    try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
}

private func seal(_ data: Data, key: SymmetricKey, sequence: UInt64) throws -> Data {
    let size = integer(UInt32(data.count + 16))
    let box = try AES.GCM.seal(data, using: key, nonce: nonce(sequence), authenticating: size)
    return size + box.ciphertext + box.tag
}

private final class CaptureCount {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}

private final class Peer {
    let socket: NWConnection
    var serverKey: SymmetricKey?
    var sequence: UInt64 = 0
    var width = 0
    var height = 0
    var codec: StreamCodec = .h264
    var pending = 0
    var lastProgress = DispatchTime.now().uptimeNanoseconds
    var started = DispatchTime.now().uptimeNanoseconds
    var seenVideo = false
    var ending = false
    init(_ socket: NWConnection) { self.socket = socket }
}

final class PortableHost: ObservableObject, VideoEncoderDelegate {
    @Published private(set) var code = ""
    @Published private(set) var status = "Generate a pairing code to listen for one receiver."
    @Published private(set) var request = ""
    @Published private(set) var busy = false
    @Published private(set) var metrics = ""
    private var listener: NWListener?
    private var peer: Peer?
    private var secret: Data?
    private var expires: UInt64 = 0
    private var timer: Timer?
    private var display: VirtualDisplayManager?
    private var recorder: ScreenRecorder?
    private var captureTask: Task<Void, Never>?
    private let traceDirectory: URL?
    private let performance: PortablePerformance
    private var trace: SessionTrace?
    private var motionWindow: MotionWindow?
    @Published private(set) var canShowMotion = false

    private let listenPort: UInt16
    private let pairingSeconds: UInt64
    private let approvalSeconds: UInt64
    private(set) var boundPort: UInt16?

    init(traceDirectory: URL? = nil, listenPort: UInt16 = 51823,
         pairingSeconds: UInt64 = 300, approvalSeconds: UInt64 = 30,
         performance: PortablePerformance = .init()) {
        self.traceDirectory = traceDirectory
        self.listenPort = listenPort
        self.pairingSeconds = pairingSeconds
        self.approvalSeconds = approvalSeconds
        self.performance = performance
    }
    private var encoder: VideoEncoder?
    private var captured = CaptureCount()
    private var encoded = 0
    private var sentBytes = 0
    private var lastTick: UInt64 = 0

    func pair() {
        stop()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            status = "Allow Screen Recording in System Settings, then try again."
            return
        }
        guard let bytes = randomBytes(16) else {
            status = "Could not obtain secure random bytes."
            return
        }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            // A successful local write only hands bytes to TCP. Bound retransmission
            // and idle probes so a silently unplugged receiver can release the display.
            tcp.connectionDropTime = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
            let endpointPort: NWEndpoint.Port = listenPort == 0 ? .any : NWEndpoint.Port(rawValue: listenPort)!
            let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: endpointPort)
            self.listener = listener
            secret = bytes
            expires = DispatchTime.now().uptimeNanoseconds + pairingSeconds * 1_000_000_000
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.code = self.secret?.map { String(format: "%02x", $0) }.joined() ?? ""
                    self.boundPort = listener?.port?.rawValue
                    self.status = "Listening on TCP \(self.boundPort ?? self.listenPort). Code expires in \(self.pairingSeconds) seconds."
                case .failed(let error):
                    self.stop("Could not listen: \(error.localizedDescription)")
                default: break
                }
            }
            listener.start(queue: .main)
            busy = true
            lastTick = DispatchTime.now().uptimeNanoseconds
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            stop("Could not listen: \(error.localizedDescription)")
        }
    }

    private func accept(_ socket: NWConnection) {
        guard peer == nil, secret != nil, DispatchTime.now().uptimeNanoseconds < expires,
              let challenge = randomBytes(32) else { socket.cancel(); return }
        let candidate = Peer(socket)
        peer = candidate
        socket.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.peer === candidate else { return }
            switch state {
            case .ready: self.authenticate(candidate, challenge: challenge)
            case .failed: self.end(candidate, "Direct connection failed.")
            default: break
            }
        }
        socket.start(queue: .main)
    }

    private func authenticate(_ candidate: Peer, challenge: Data) {
        candidate.socket.send(content: challenge, completion: .idempotent)
        // Receiver nonce (32), encrypted width/height/codec (9), authentication tag (16).
        candidate.socket.receive(minimumIncompleteLength: 57, maximumLength: 57) { [weak self, weak candidate] data, _, _, _ in
            guard let self, let candidate, self.peer === candidate else { return }
            guard let data, data.count == 57, let secret = self.secret,
                  DispatchTime.now().uptimeNanoseconds < self.expires else {
                self.end(candidate, "Pairing handshake timed out or was incomplete.")
                return
            }
            let transcript = challenge + data.prefix(32)
            do {
                let box = try AES.GCM.SealedBox(nonce: nonce(0), ciphertext: data[32..<41], tag: data.suffix(16))
                let hello = try AES.GCM.open(box, using: key(secret, transcript, 1))
                self.secret = nil
                self.listener?.cancel()
                self.listener = nil
                self.code = ""
                candidate.serverKey = key(secret, transcript, 2)
                candidate.width = Int(hello.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                candidate.height = Int(hello[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                let codec = hello[8]
                guard (320...3840).contains(candidate.width), (320...3840).contains(candidate.height),
                      candidate.width % 2 == 0, candidate.height % 2 == 0,
                      candidate.width * candidate.height <= 3840 * 2160, codec == 1 || codec == 2 else {
                    self.reject(candidate, "Unsupported dimensions or codec.")
                    return
                }
                candidate.codec = codec == 2 ? .hevc : .h264
                candidate.started = DispatchTime.now().uptimeNanoseconds
                self.request = "\(candidate.socket.endpoint) · \(candidate.width) × \(candidate.height) · \(candidate.codec.displayName)"
                self.status = "Approve the receiver on this Mac."
                // The receiver sends no further data. EOF, errors or unexpected bytes end the session.
                candidate.socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak candidate] _, _, _, _ in
                    if let candidate { self?.end(candidate, "Receiver disconnected. Extension removed.") }
                }
            } catch {
                self.end(candidate, "Pairing authentication failed. Check the code and try again.")
            }
        }
    }

    func approve() {
        guard let peer, !request.isEmpty else { return }
        request = ""
        let width = peer.width
        let height = peer.height
        func makeEncoder(settings: PortableEncoderSettings) -> VideoEncoder {
            VideoEncoder(connectionId: UUID(), width: width, height: height,
                         bitrate: 20_000_000, expectedFPS: 60, keyframeIntervalSeconds: performance.keyframeSeconds,
                         codec: peer.codec, requireHardware: true, portableSettings: settings)
        }

        let preferLowLatency = performance.preferLowLatency4KH264
            && peer.codec == .h264 && width * height >= 3840 * 2160
        var settings = performance.encoder
        settings.logProperties = traceDirectory != nil
        if preferLowLatency { settings.lowLatencyRateControl = true }
        let preferred = makeEncoder(settings: settings)
        let encoder: VideoEncoder
        if preferLowLatency && !preferred.isReady {
            LogManager.shared.log("Portable VT: low-latency H.264 unavailable, using the standard hardware encoder")
            settings.lowLatencyRateControl = false
            encoder = makeEncoder(settings: settings)
        } else {
            encoder = preferred
        }
        let traceSettings = performance.description(using: settings)
        guard encoder.isReady else {
            reject(peer, "No hardware encoder for this codec and size. Try H.264 or a smaller mode.")
            return
        }
        let highResolution = width * height > 2560 * 1440
        let hiDPI = highResolution && width % 4 == 0 && height % 4 == 0
        let density = hiDPI ? 2 : 1
        let native = PixelSize(width: width / density, height: height / density)
        // On some macOS builds a single high-resolution mode does not activate.
        // Add a smaller bootstrap mode, then explicitly require the native mode before capture.
        let modes = highResolution ? [native, PixelSize(width: native.width / 2, height: native.height / 2)] : []
        let display = VirtualDisplayManager(deviceKey: "portable-\(width)x\(height)")
        let displayID = autoreleasepool {
            display.createDisplay(width: width, height: height, ppi: highResolution ? 163 : 110,
                                  hiDPI: hiDPI, name: "BetterCast Portable", refreshRate: 60, pointModes: modes)
        }
        guard let id = displayID, id != CGMainDisplayID() else {
            encoder.invalidate()
            reject(peer, "An independent display at the requested resolution is unavailable.")
            return
        }
        self.display = display
        self.encoder = encoder
        peer.started = DispatchTime.now().uptimeNanoseconds
        status = "Waiting for macOS to activate the independent display."
        Task { @MainActor [weak self, weak peer] in
            // WindowServer registers the new display asynchronously.
            for _ in 0..<30 {
                guard let self, let peer, self.peer === peer, !peer.ending else { return }
                if let mode = self.activateMode(id, width: width, height: height) {
                    print("Portable extension id=\(id) mode=\(mode.pixelWidth)x\(mode.pixelHeight) points=\(mode.width)x\(mode.height) refresh=\(mode.refreshRate) mirror=0")
                    self.startCapture(encoder, peer: peer, displayID: id, refresh: mode.refreshRate, settings: traceSettings)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let peer { self?.reject(peer, "macOS did not activate the requested independent display mode.") }
        }
    }

    private func activateMode(_ id: CGDirectDisplayID, width: Int, height: Int) -> CGDisplayMode? {
        guard CGDisplayIsOnline(id) == 1, CGDisplayIsInMirrorSet(id) == 0 else { return nil }
        let matches: (CGDisplayMode) -> Bool = {
            $0.pixelWidth == width && $0.pixelHeight == height && abs($0.refreshRate - 60) < 0.1
        }
        if let current = CGDisplayCopyDisplayMode(id), matches(current) { return current }
        guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
              let target = modes.first(where: matches) else { return nil }
        if CGDisplaySetDisplayMode(id, target, nil) == .success,
           let current = CGDisplayCopyDisplayMode(id), matches(current) { return current }
        return nil
    }

    private func startCapture(_ encoder: VideoEncoder, peer: Peer, displayID: CGDirectDisplayID, refresh: Double,
                              settings: String) {
        let width = peer.width
        let height = peer.height
        captured = CaptureCount()
        encoded = 0
        sentBytes = 0
        encoder.delegate = self
        let recorder = ScreenRecorder(videoEncoder: encoder, targetDisplayID: displayID, width: width,
                                      height: height, captureFPS: 60, strictDisplayCapture: true)
        recorder.portableSettings = performance.capture
        if let traceDirectory {
            trace = SessionTrace(directory: traceDirectory, width: width, height: height, codec: peer.codec,
                                 refresh: refresh, settings: settings)
            trace?.record("approved")
            canShowMotion = true
        }
        recorder.onCapturedFrame = { [captured] _ in captured.increment() }
        if let trace {
            var describedBuffer = false
            recorder.onPortableSample = { sample, status, attachments, arrived in
                guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    let event = status == .idle ? "idle" : (status == .blank ? "blank" : "capture_other")
                    trace.record(event, 0, status?.rawValue ?? -1, at: arrived)
                    return
                }
                guard let nanos = streamTimestampNanoseconds(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
                let pts = nanos / 100
                let rectCount = (attachments?[.dirtyRects] as? [Any])?.count ?? -1
                trace.record("capture", pts, rectCount, at: arrived)
                if let hostTime = (attachments?[.displayTime] as? NSNumber)?.uint64Value,
                   let time = streamTimestampNanoseconds(CMClockMakeHostTimeFromSystemUnits(hostTime)) {
                    trace.record("sck_display_time", pts, 0, at: time)
                }
                if !describedBuffer {
                    describedBuffer = true
                    print("Portable buffer: \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) fourcc=\(CVPixelBufferGetPixelFormatType(buffer)) planes=\(CVPixelBufferGetPlaneCount(buffer)) iosurface=\(CVPixelBufferGetIOSurface(buffer) != nil)")
                }
            }
            encoder.onPortableTiming = { trace.record($0, $1, $2, at: $3) }
            encoder.onPortableBackpressure = { pts in
                if let nanos = streamTimestampNanoseconds(pts) { trace.record("backpressure", nanos / 100) }
            }
        }
        recorder.onStreamStopped = { [weak self, weak peer] in
            if let peer { self?.reject(peer, "Capture stopped or failed. Check macOS Screen Recording permission.") }
        }
        self.recorder = recorder
        peer.started = DispatchTime.now().uptimeNanoseconds
        status = "Starting \(width) × \(height) at a 60 FPS target. Arrange the display in System Settings."
        send(Data([4]), to: peer)
        captureTask = Task { await recorder.startCapture() }
    }

    @MainActor func showMotion() {
        guard let trace, let id = display?.displayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }) else { return }
        motionWindow?.window.close()
        motionWindow = MotionWindow(screen: screen, useDisplayLink: performance.useDisplayLink,
                                    metalMotion: performance.metalMotion, trace: trace)
        canShowMotion = false
    }

    func deny() {
        if let peer, !request.isEmpty { reject(peer, "The Mac user declined the connection.") }
    }

    private func reject(_ peer: Peer, _ reason: String) {
        guard self.peer === peer, !peer.ending else { return }
        peer.ending = true
        request = ""
        status = reason
        send(Data([3]) + Data(reason.utf8), to: peer) { [weak self, weak peer] _ in
            if let peer { self?.end(peer, reason) }
        }
    }

    private func send(_ plain: Data, to peer: Peer, videoPTS: UInt64 = 0, completion: ((Bool) -> Void)? = nil) {
        guard self.peer === peer, let key = peer.serverKey else { completion?(false); return }
        guard plain.count + 16 <= maxFrame, peer.sequence < UInt64(UInt32.max),
              let packet = try? seal(plain, key: key, sequence: peer.sequence) else {
            end(peer, "Could not encrypt the next packet.")
            completion?(false)
            return
        }
        if videoPTS != 0 { trace?.record("sealed", videoPTS) }
        peer.sequence += 1
        if peer.pending == 0 { peer.lastProgress = DispatchTime.now().uptimeNanoseconds }
        peer.pending += 1
        if videoPTS != 0 { trace?.record("tcp_submit", videoPTS) }
        peer.socket.send(content: packet, completion: .contentProcessed { [weak self, weak peer] error in
            completion?(error == nil)
            guard let self, let peer, self.peer === peer else { return }
            peer.pending -= 1
            peer.lastProgress = DispatchTime.now().uptimeNanoseconds
            if error != nil { self.end(peer, "Direct stream failed. Extension removed.") }
        })
    }

    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        let encodedAt = DispatchTime.now().uptimeNanoseconds
        encoder.sendStarted()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.encoder === encoder, let peer = self.peer, !peer.ending else { encoder.sendFinished(); return }
            self.encoded += 1
            self.sentBytes += data.count
            if !peer.seenVideo {
                peer.seenVideo = true
                self.status = "Streaming \(peer.width) × \(peer.height) · \(peer.codec.displayName) · direct TCP"
            }
            let trace = self.trace
            let pts = trace == nil ? 0 : data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) / 100 }
            trace?.record("encode", pts, data.count, at: encodedAt)
            trace?.record("seal_start", pts)
            self.send(Data([1]) + data, to: peer, videoPTS: pts) { sent in
                trace?.record(sent ? "tcp_processed" : "tcp_error", pts)
                encoder.sendFinished()
            }
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = Double(now - lastTick) / 1e9
        lastTick = now
        if secret != nil && now >= expires { stop("Code expired. Generate a new one."); return }
        guard let peer else { return }
        let age = now - peer.started
        if peer.serverKey == nil, age > 5_000_000_000 { end(peer, "Pairing handshake timed out."); return }
        if !request.isEmpty, age > approvalSeconds * 1_000_000_000 { reject(peer, "Mac approval timed out."); return }
        if peer.pending > 0, now - peer.lastProgress > 5_000_000_000 {
            end(peer, "Direct connection stalled. Extension removed.")
            return
        }
        guard recorder != nil, !peer.ending, let id = display?.displayID else { return }
        guard CGDisplayIsOnline(id) == 1, CGDisplayIsInMirrorSet(id) == 0,
              let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth == peer.width, mode.pixelHeight == peer.height else {
            reject(peer, "Independent display is no longer available.")
            return
        }
        if !peer.seenVideo, age > 8_000_000_000 { reject(peer, "No frames from the extended display."); return }
        if peer.pending == 0 { send(Data([2]), to: peer) }
        metrics = String(format: "Capture %.1f FPS · encode %.1f FPS · video %.2f Mb/s",
                         Double(captured.take()) / interval, Double(encoded) / interval,
                         Double(sentBytes * 8) / interval / 1e6)
        encoded = 0
        sentBytes = 0
        print(metrics)
    }

    private func end(_ peer: Peer, _ message: String) {
        guard self.peer === peer else { return }
        if secret != nil {
            self.peer = nil
            peer.socket.cancel()
            status = message
        } else {
            stop(message)
        }
    }

    func stop(_ message: String = "Stopped. Generate a new code to reconnect.") {
        let oldID = display?.displayID
        let trace = self.trace
        self.trace = nil
        canShowMotion = false
        trace?.record("stop_requested")
        let motion = motionWindow
        Task { @MainActor in motion?.stop() }
        captureTask?.cancel()
        if let recorder {
            recorder.stopCapture(after: captureTask) {
                trace?.record("capture_stopped")
                trace?.save()
            }
        } else {
            encoder?.invalidate()
        }
        captureTask = nil
        recorder = nil
        encoder = nil
        display?.destroyDisplay()
        display = nil
        if let oldID { print("Portable removed display id=\(oldID)") }
        peer?.socket.cancel()
        peer = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        timer?.invalidate()
        timer = nil
        secret = nil
        request = ""
        code = ""
        metrics = ""
        busy = false
        status = message
    }
}
