// SPDX-License-Identifier: GPL-3.0-only
import CoreMedia
import CoreVideo

/// Overrides are supplied by the local performance harness, not the pairing protocol.
struct PortablePerformance {
    var capture = PortableCaptureSettings()
    var encoder = PortableEncoderSettings()
    var keyframeSeconds = 2.0
    var useDisplayLink = false
    var metalMotion = false

    init(experiment: String = "default") {
        switch experiment {
        case "headroom": capture.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        case "uncapped": capture.minimumFrameInterval = .zero
        case "depth5": capture.queueDepth = 5
        case "depth8": capture.queueDepth = 8
        case "bgra": capture.pixelFormat = kCVPixelFormatType_32BGRA
        case "display-link": useDisplayLink = true
        case "metal-motion": useDisplayLink = true; metalMotion = true
        case "low-latency": encoder.lowLatencyRateControl = true
        case "delay0": encoder.maxFrameDelay = 0
        case "speed": encoder.prioritizeSpeed = true
        case "realtime-off": encoder.realTime = false
        case "reorder": encoder.allowReordering = true
        case "gop1": keyframeSeconds = 1
        case "default": break
        default: preconditionFailure("Unknown performance experiment: \(experiment)")
        }
    }

    var description: String {
        "interval=\(capture.minimumFrameInterval.value)/\(capture.minimumFrameInterval.timescale) depth=\(capture.queueDepth) format=\(capture.pixelFormat) low_latency=\(encoder.lowLatencyRateControl) realtime=\(encoder.realTime) reorder=\(encoder.allowReordering) delay=\(encoder.maxFrameDelay) speed=\(encoder.prioritizeSpeed) gop=\(keyframeSeconds) display_link_source=\(useDisplayLink) metal_source=\(metalMotion)"
    }
}
