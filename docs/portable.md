# BetterCast Portable · G1 prototype

BetterCast Portable extends the Mac desktop onto a Windows receiver over a reachable IPv4 connection. The Mac creates a separate WindowServer display, confirms its mode, and captures that display with ScreenCaptureKit. Move your Mac pointer or drag a window across the display boundary using the Mac's mouse or trackpad. Adjust the arrangement in macOS Displays.

## Build

Build the Mac host with Xcode command-line tools. The script uses the local CPU architecture, targets macOS 13 or later, and ad-hoc signs the app for local use.

```sh
./scripts/build-portable-host.sh
open '.build/portable-host/BetterCast Portable Host.app'
```

Build the x64 receiver with Visual Studio C++ and the Windows SDK. The app uses a statically linked C/C++ runtime and the built-in Windows Winsock, CNG, Media Foundation and Direct3D libraries.

```powershell
cmake -S Sources/BetterCastReceiverDesktop/portable -B .build/portable-windows -A x64
cmake --build .build/portable-windows --config Release
```

The executable is `.build/portable-windows/Release/BetterCastPortableReceiver.exe`. The [Windows workflow](../.github/workflows/build-portable-windows.yml) packages the EXE and license notices, inspects its imports and embedded `asInvoker` manifest, and launches its smoke test. Build artifacts are under **Actions → Build Portable Windows Receiver**. Corresponding source is in the same Git commit as each run.

## Run on a reachable LAN

1. Open the Mac host. Generate a pairing code and grant macOS Screen Recording access when prompted. The listener opens TCP port **51823** on the Mac. Allow incoming connections on the Mac if its firewall prompts.
2. Run the single receiver EXE from a user-writable folder on an x64 Windows PC with Media Foundation and a D3D11 video-capable GPU. Move the setup window to the monitor you want to use. Enter the Mac's LAN IPv4 address and the 32 hex digits.
3. Keep the default H.264 for compatibility, or select HEVC if Windows already has a compatible HEVC decoder. Native is the default size up to 4K. The receiver queries the monitor's preferred pixel mode and falls back to its active mode when that query is unavailable. Explicit 1440p and 1080p caps are available for devices that cannot handle the native mode.
4. Click Connect, then approve the request on the Mac. After the first frame, press F2 on Windows to toggle the receive rate, successful DXGI presents, compressed video bitrate and decoded output path. The Mac shows the ScreenCaptureKit and VideoToolbox output rates.
5. To disconnect, use the selected fullscreen shortcut (Esc, Ctrl+Shift+Q or Alt+Shift+Q), close the Windows app, or press Stop on the Mac. The receiver exits fullscreen without changing the Windows display mode. macOS removes the virtual display and rehomes ordinary windows. The next connection needs a new code.

The EXE is unsigned. Execution policies can prevent an unsigned portable application from starting. Windows editions without the existing Media Foundation components and machines without a usable D3D11 video device are outside this prototype's runtime coverage. The Windows keyboard is used locally for pairing, fullscreen exit and diagnostics. The protocol has no remote keyboard/mouse command.

## Protocol v1

The prototype uses a single direct TCP socket with Nagle disabled and no relay. The receiver dials the Mac, so there is no Windows listen port. The pairing secret is 16 random bytes shown as 32 hex characters, valid for 5 minutes and consumed by the first valid request. The Mac gives an authenticated request up to 30 seconds for local approval. Codes and keys are held in process memory.

- Host sends a fresh 32-byte challenge. Receiver sends a fresh 32-byte nonce followed by an AES-256-GCM encrypted 9-byte hello and 16-byte tag. The hello is big-endian uint32 width, uint32 height and codec byte (1 H.264, 2 HEVC).
- Each direction's key is HMAC-SHA-256 with the pairing secret over ASCII `BetterCast Portable v1`, host challenge, receiver nonce and a direction byte (1 receiver hello, 2 host records). The single hello uses an all-zero 12-byte GCM nonce and empty associated data.
- Each host record has a 4-byte big-endian encrypted length (ciphertext and 16-byte tag). This header is associated data. The 12-byte GCM nonce is a zero uint32 and a big-endian uint64 record sequence starting at 0. The receiver authenticates the record before processing its type or contents.
- Record types are video (1), heartbeat (2), terminal error (3, UTF-8 text) and approval (4). Video retains upstream BetterCast's little-endian nanosecond PTS and big-endian length-prefixed AVCC/HVCC NAL units. The receiver converts the lengths to Annex B start codes for Media Foundation. Records are bounded to 8 MiB. The receiver sends no messages after its hello.

The Windows smoke test uses a fixed interoperability vector for a type-2 record at sequence 0, with pairing bytes 0–15 and transcript bytes 0–63. Ciphertext and tag are `c8ade46f51b5024093bc41ef49d1733bc4`. Swift CryptoKit and Windows CNG produce the same bytes, and the Windows test verifies that a modified tag is rejected.

## Reproduce the Mac evidence

Run on an unlocked Mac desktop with Screen Recording permission for the invoking terminal. Python 3 with `cryptography` is needed only for this test.

```sh
./scripts/build-portable-host.sh --loopback
```

The test builds the actual Host engine and runs real WindowServer, ScreenCaptureKit and hardware VideoToolbox. It opens a changing test window on the new display, verifies approval precedes display creation, authenticates actual encoded access units over localhost, checks frame timestamps and NAL lengths, then closes TCP and verifies the display disappears and the test window is visible on an original display. Logs are written under `.build/portable-host/*-loopback.log`. This is a Mac loopback check. The receiver script does not decode or present, and its FPS includes session startup.

## Gate boundaries

- **G0:** [Upstream code and license audit](portable-g0.md).
- **G1:** Both binaries build. CI validates the Windows executable and H.264 transform activation. A Windows PC receiving the live Mac desktop is still required for G1 acceptance, including DXGI presentation and local shortcut behavior.
- **G2:** A 60 FPS capture/encode target is configured without repeat frames. 1080p, 1440p and 4K were exercised on Mac loopback. Sustained 4K/60 on two devices remains unverified. Congestion can skip captures before encode to protect the reference chain. Adaptive bitrate and resolution, end-to-end latency, loss and CPU/GPU measurements remain open.
- **G3–G4:** LAN/direct IPv4 and encrypted pairing are implemented. Public signaling, ICE/NAT traversal, comparative transport benchmarks and automatic reconnection remain open. An unreachable connection fails or times out.
- **G5:** A normal visible test window returned to an existing display on TCP close. Workspace Handoff to a new Space, fullscreen or minimized window behavior, and physical Windows safe-exit validation remain open.
- **G6:** Public source and Windows CI artifacts are available. A security review and a signed public release remain open.
