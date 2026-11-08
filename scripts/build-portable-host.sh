#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="${PORTABLE_BUILD_DIR:-.build/portable-host}"
app="$build/BetterCast Portable Host.app"
sender="Sources/BetterCastSender"
mkdir -p "$app/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="$(uname -m)-apple-macosx13.0"
xcrun clang -isysroot "$sdk" -target "$target" -fobjc-arc -c "$sender/VirtualDisplay/VirtualDisplay.m" -o "$build/VirtualDisplay.o"
cat > "$build/module.modulemap" <<MODULE
module VirtualDisplayLib {
    header "$PWD/$sender/VirtualDisplay/VirtualDisplay.h"
    export *
}
MODULE
host="Sources/BetterCastPortableHost"
printf 'let portableBuildCommit = "%s"\n' "$(git rev-parse HEAD)" > "$build/BuildCommit.swift"
entry="$host/PortableHostApp.swift"
binary="$app/Contents/MacOS/BetterCastPortableHost"
case "${1:-}" in
    --loopback|--steady|--faults|--matrix)
        entry="scripts/portable-smoke/Loopback.swift"
        binary="$build/LocalSmoke"
        ;;
esac
xcrun swiftc -sdk "$sdk" -target "$target" -O -I "$build" \
    "$sender"/{Constants,VirtualDisplayManager,ScreenFit,ScreenRecorder,LegacyDisplayCapture,AudioEncoder,VideoEncoder,LogManager}.swift \
    "$host"/{PortableHost,SessionTrace,MotionWindow,MetalMotionView,PortablePerformance}.swift "$build/BuildCommit.swift" "$entry" "$build/VirtualDisplay.o" -o "$binary"
if [[ "$binary" == "$build/LocalSmoke" ]]; then
    python="$(command -v python3)"
    "$python" -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM'
    run_case() {
        local width="$1" height="$2" codec="$3" label="$4" scenario="$5" trace=""
        local experiment="${6:-${PORTABLE_EXPERIMENT:-production}}"
        if [[ "$scenario" == steady ]]; then
            trace="$(mktemp -d "$build/$label.XXXXXX")"
        fi
        PORTABLE_EXPERIMENT="$experiment" "$binary" "$width" "$height" "$codec" "$python" scripts/portable-smoke/receive.py "$scenario" "$trace" \
            2>&1 | tee "$build/$label-loopback.log" || return
        if [[ -n "$trace" ]]; then
            "$python" scripts/portable-smoke/analyze.py "$trace"/host-*.csv "$trace/loopback.csv" --loopback \
                | tee "$trace/summary.txt"
        fi
    }
    if [[ "$1" == --matrix ]]; then
        if [[ "${PORTABLE_MATRIX_RESUME:-0}" != 1 || ! -f "$build/matrix.tsv" ]]; then
            printf 'case\texperiment\tstatus\n' > "$build/matrix.tsv"
        fi
        matched=0
        failures=0
        for row in \
            '1920 1080 1 baseline-1080p default' \
            '1920 1080 1 uncapped-1080p uncapped' \
            '1920 1080 1 display-link-1080p display-link' \
            '1920 1080 1 depth5-1080p depth5' \
            '3840 2160 1 baseline-4k-h264 default' \
            '3840 2160 1 low-latency-4k-h264 low-latency' \
            '3840 2160 2 baseline-4k-hevc default' \
            '2560 1440 1 baseline-1440p default' \
            '1920 1080 1 metal-1080p metal-motion' \
            '1920 1080 1 headroom-1080p headroom' \
            '3840 2160 1 speed-4k-h264 speed' \
            '3840 2160 1 delay0-4k-h264 delay0' \
            '3840 2160 1 depth5-4k-h264 depth5' \
            '3840 2160 1 bgra-4k-h264 bgra' \
            '3840 2160 1 realtime-off-4k-h264 realtime-off' \
            '3840 2160 1 reorder-4k-h264 reorder' \
            '3840 2160 1 gop1-4k-h264 gop1'; do
            read -r width height codec label experiment <<< "$row"
            if [[ -n "${2:-}" && "$2" != "$label" ]]; then continue; fi
            matched=1
            completed="$(printf '%s\t%s\tpass' "$label" "$experiment")"
            if [[ "${PORTABLE_MATRIX_RESUME:-0}" == 1 ]] && /usr/bin/grep -Fxq "$completed" "$build/matrix.tsv"; then continue; fi
            if run_case "$width" "$height" "$codec" "$label" steady "$experiment"; then
                status=pass
            else
                status=failed
                failures=$((failures + 1))
            fi
            printf '%s\t%s\t%s\n' "$label" "$experiment" "$status" | tee -a "$build/matrix.tsv"
        done
        if [[ "$matched" == 0 ]]; then
            printf 'Unknown matrix case: %s\n' "${2:-}" >&2
            exit 2
        fi
        if [[ "$failures" != 0 ]]; then exit 1; fi
    elif [[ "$1" == --faults ]]; then
        for scenario in wrong_code expired approval_timeout host_stop reset window_close; do
            run_case 1920 1080 1 "$scenario" "$scenario"
        done
    else
        scenario=normal
        if [[ "$1" == --steady ]]; then scenario=steady; fi
        for mode in '1920 1080 1 1080p-h264' '2560 1440 1 1440p-h264' '3840 2160 2 4k-hevc' '3840 2160 1 4k-h264'; do
            read -r width height codec label <<< "$mode"
            if [[ -n "${2:-}" && "$2" != "$label" ]]; then continue; fi
            run_case "$width" "$height" "$codec" "$label" "$scenario"
        done
    fi
    exit
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.bettercast.portable.host</string>
<key>CFBundleName</key><string>BetterCast Portable Host</string>
<key>CFBundleExecutable</key><string>BetterCastPortableHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect a paired Windows display on the local network.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
