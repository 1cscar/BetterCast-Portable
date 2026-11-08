# G0 · BetterCast Portable upstream audit

Baseline `768de0c01575ad56435ddec911f597a955fe6bbc` (`v24`). Full, non-shallow clone with 193 commits on `upstream/main`. Verified with `git rev-list --count upstream/main`, `git rev-parse --is-shallow-repository`, and `git diff --exit-code upstream/main -- LICENSE`.

| Upstream area | What the code does | Portable disposition |
| --- | --- | --- |
| `BetterCastSender/VirtualDisplay` and `VirtualDisplayManager.swift` | Creates an independent WindowServer display with pixel and point modes, then releases the display object to remove it. | Reuse. The CoreGraphics classes are private. Resolve/check at runtime and verify an online non-mirrored display with the requested pixel mode. macOS 13 is a build floor, and individual OS builds require testing. |
| `BetterCastSender/ScreenRecorder.swift` | ScreenCaptureKit per-display output, optional legacy physical capture, main-display fallback and a repeated-frame pump. | Reuse with strict display selection, no legacy route, no frame pump, and only complete screen samples. Keep upstream defaults for existing callers. |
| `BetterCastSender/VideoEncoder.swift` | VideoToolbox real-time H.264/HEVC with no B-frame reordering, AVCC/HVCC NAL lengths, parameter sets on keyframes, and little-endian nanosecond PTS. Can skip captures before encoding when sends back up. | Reuse with hardware required, 60 FPS configured, and actual capture/output counts. Backpressure counts and real FPS must be reported separately. |
| `BetterCastReceiverDesktop/NetworkListener.cpp`, `VideoDecoder.cpp`, `VideoWindow.cpp` | TCP length + type + PTS framing, separate UDP fragment path, FFmpeg decoder, Qt/OpenGL renderer, keyboard/mouse input channel. | Port the Mac video payload, length bounds, and fullscreen behavior to a receiver-only Win32 target. Use Media Foundation/D3D11 and an outbound socket. Omit input, audio, ADB, Bonjour, Qt, FFmpeg, VDD and NSIS from this build. |
| `BetterCastSender/BetterCastSenderApp.swift` | Bonjour/AWDL and LAN/ADB connection policies, adaptive bitrate, remote input dispatch, per-connection teardown. | Isolate the Portable listener and approval flow. Preserve local Mac input through WindowServer. Existing discovery and transport do not supply Internet rendezvous, authenticated encryption, or Workspace Handoff. |
| `.github/workflows/build-windows-receiver.yml` | Packages a Qt/FFmpeg build, ADB and the optional Sender/VDD stack. The NSIS installer can require elevation. | Separate Windows SDK build for Portable with a static C/C++ runtime and `asInvoker`; test from a clean directory. |

The root `LICENSE` is GPLv3. Preserve the original history, notices and license, including the Apache-2.0 file headers in the virtual-display wrapper and the attribution in the class-dump headers. Ship corresponding buildable source, build scripts and the GPLv3 text with any distributed build. The Portable targets use system APIs and do not bundle Sparkle, Qt, FFmpeg or the Windows display driver.

## Network decision for G1

- Public Nostr relays can carry rendezvous messages with application-level authenticated encryption and expiry. They do not establish network reachability. Relay metadata, retention, abuse limits, endpoint availability and interoperability need a separate G3 evaluation.
- STUN and ICE discover candidate addresses and test actual reachability. WebRTC is one way to use ICE and includes encryption/congestion handling. No TURN means some NAT/firewall combinations will fail. Compare direct connections with equivalent encoders, queue depth, resolution, and loss conditions before choosing the media transport.
- BetterCast's TCP is a usable direct baseline. It needs a reachable Host and retransmission can delay subsequent frames. Upstream UDP fragmentation/keyframe recovery is a starting point for measurement, with authenticated packets, paced sends, MTU sizing, and bounded reassembly still needed. In G1, the Windows receiver dials out so it does not need an inbound firewall exception. G1 does not perform NAT traversal.

Workspace Handoff requires separate measurement of window recovery on each supported macOS build. G1 stops capture and removes the display, letting WindowServer rehome its windows. It does not invoke private Spaces APIs or claim that fullscreen, minimized or special windows are recovered to a new Space.
