// SPDX-License-Identifier: GPL-3.0-only
#include "Playback.h"
#include <mutex>
#include <thread>

namespace {
constexpr int HostEdit = 101, CodeEdit = 102, HevcBox = 103, ConnectButton = 104, Shortcut = 105, Resolution = 106;
constexpr UINT StatusUpdate = WM_APP + 1, SessionEnded = WM_APP + 2;
constexpr wchar_t ClassName[] = L"BetterCastPortableReceiver";

struct Monitor {
    RECT rect{};
    UINT width = 0, height = 0, refresh = 0;
    bool preferred = false;
};

Monitor monitorFor(HWND window) {
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), reinterpret_cast<MONITORINFO*>(&info)))
        throw std::runtime_error("Could not identify the Windows monitor.");
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode))
        throw std::runtime_error("Could not read the Windows monitor's active mode.");
    Monitor result{info.rcMonitor, mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency};
    UINT32 paths = 0, modes = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &paths, &modes) != ERROR_SUCCESS) return result;
    std::vector<DISPLAYCONFIG_PATH_INFO> topology(paths);
    std::vector<DISPLAYCONFIG_MODE_INFO> details(modes);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &paths, topology.data(), &modes, details.data(), nullptr) != ERROR_SUCCESS)
        return result;
    for (UINT32 i = 0; i < paths; ++i) {
        const auto& path = topology[i];
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source),
                         path.sourceInfo.adapterId, path.sourceInfo.id};
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
            _wcsicmp(source.viewGdiDeviceName, info.szDevice) != 0) continue;
        DISPLAYCONFIG_TARGET_PREFERRED_MODE native{};
        native.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_PREFERRED_MODE, sizeof(native),
                         path.targetInfo.adapterId, path.targetInfo.id};
        if (DisplayConfigGetDeviceInfo(&native.header) == ERROR_SUCCESS && native.width && native.height) {
            result.width = native.width;
            result.height = native.height;
            result.preferred = true;
            if (path.targetInfo.rotation == DISPLAYCONFIG_ROTATION_ROTATE90 ||
                path.targetInfo.rotation == DISPLAYCONFIG_ROTATION_ROTATE270) std::swap(result.width, result.height);
        }
        break;
    }
    return result;
}

std::wstring wide(const std::string& message) {
    if (message.empty()) return {};
    const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, message.data(), int(message.size()), nullptr, 0);
    if (length <= 0) return L"Invalid status message.";
    std::wstring output(length, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, message.data(), int(message.size()), output.data(), length);
    return output;
}

std::wstring field(HWND window, int id) {
    const auto control = GetDlgItem(window, id);
    std::wstring text(GetWindowTextLengthW(control) + 1, L'\0');
    text.resize(GetWindowTextW(control, text.data(), int(text.size())));
    return text;
}

struct WinsockRuntime {
    WinsockRuntime() {
        WSADATA info{};
        if (WSAStartup(MAKEWORD(2, 2), &info) != 0) throw std::runtime_error("Could not initialize Winsock.");
    }
    ~WinsockRuntime() { WSACleanup(); }
};

struct Session {
    HWND window = nullptr;
    HWND status = nullptr;
    HWND overlay = nullptr;
    HINSTANCE instance = nullptr;
    std::vector<HWND> fields;
    std::thread worker;
    std::atomic<bool> stop{false};
    std::mutex messageLock;
    std::wstring message;
    WINDOWPLACEMENT placement{};
    bool closeOnFinish = false;
    bool traceEnabled = false;
    bool showMetrics = false;
    bool receivedVideo = false;
    int exitKey = 0;

    void report(std::wstring text, UINT kind = StatusUpdate) {
        {
            std::lock_guard<std::mutex> lock(messageLock);
            message = std::move(text);
        }
        PostMessageW(window, kind, 0, 0);
    }

    std::wstring currentMessage() {
        std::lock_guard<std::mutex> lock(messageLock);
        return message;
    }

    void receive(std::wstring ip, Bytes secret, UINT width, UINT height, bool hevc) {
        std::wstring traceNotice;
        try {
            SessionTrace trace(traceEnabled, width, height, hevc);
            if (trace.enabled()) traceNotice = L"  Trace: " + trace.path.filename().wstring();
            trace.record("connect");
            WinsockRuntime sockets;
            MediaRuntime media;
            Playback playback(window, width, height, hevc, trace);
            Connection connection(stop);
            connection.dial(ip);
            auto transcript = connection.read(32, Clock::now() + 5s);
            Bytes clientNonce(32);
            cryptoCheck(BCryptGenRandom(nullptr, clientNonce.data(), ULONG(clientNonce.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG));
            transcript.insert(transcript.end(), clientNonce.begin(), clientNonce.end());
            AesGcm sender(sessionKey(secret, transcript, 1));
            AesGcm receiver(sessionKey(secret, transcript, 2));
            SecureZeroMemory(secret.data(), secret.size());
            Bytes hello;
            appendU32(hello, width);
            appendU32(hello, height);
            hello.push_back(hevc ? 2 : 1);
            Bytes empty;
            auto sealed = sender.crypt(hello, 0, empty, true);
            clientNonce.insert(clientNonce.end(), sealed.begin(), sealed.end());
            connection.write(clientNonce);
            report(L"Waiting for approval on the Mac…");
            bool approved = false;
            uint64_t sequence = 0, frames = 0, bytes = 0;
            FrameCounts counts;
            auto stats = Clock::now();
            auto deadline = stats + 40s;
            while (!stop) {
                auto header = connection.read(4, deadline);
                const auto length = readU32(header.data());
                if (length < 17 || length > MaxPacket || sequence >= UINT32_MAX)
                    throw std::runtime_error("Invalid encrypted packet length or sequence.");
                auto ciphertext = connection.read(length, deadline);
                const auto packetAt = trace.enabled() ? traceTime() : 0;
                auto plain = receiver.crypt(ciphertext, sequence++, header, false);
                if (plain[0] == 3 && plain.size() <= 513)
                    throw std::runtime_error(std::string(plain.begin() + 1, plain.end()));
                if (!approved && plain[0] == 4 && plain.size() == 1) {
                    approved = true;
                    trace.record("approved");
                    stats = Clock::now();
                    report(L"Approved. Waiting for the first frame…");
                } else if (approved && plain[0] == 1) {
                    ++frames;
                    bytes += plain.size() - 1;
                    const auto pts = videoPTS(plain);
                    trace.record("tcp_read", pts, 0, packetAt);
                    trace.record("rx", pts, int64_t(plain.size() - 1));
                    const auto frame = playback.decode(plain, pts);
                    if (frame.presented > 0 && !receivedVideo) {
                        receivedVideo = true;
                        PostMessageW(window, StatusUpdate, 1, 0);
                    }
                    counts.add(frame);
                } else if (!approved || plain[0] != 2 || plain.size() != 1) {
                    throw std::runtime_error("Invalid packet type for this session.");
                }
                const auto now = Clock::now();
                if (approved) deadline = now + 8s;
                const auto seconds = std::chrono::duration<double>(now - stats).count();
                if (approved && seconds >= 1) {
                    wchar_t line[256];
                    swprintf_s(line, L"RX %.1f · Decode %.1f · Present %.1f FPS · %.2f Mb/s · %ls",
                               frames / seconds, counts.decoded / seconds, counts.presented / seconds,
                               bytes * 8.0 / seconds / 1e6,
                               wide(playback.outputPath()).c_str());
                    report(line);
                    stats = now;
                    frames = bytes = 0;
                    counts = {};
                }
            }
            trace.record("stopped");
        } catch (const std::exception& error) {
            SecureZeroMemory(secret.data(), secret.size());
            report((stop ? L"Disconnected." : wide(error.what())) + traceNotice, SessionEnded);
            return;
        }
        report(L"Disconnected." + traceNotice, SessionEnded);
    }

    HWND control(const wchar_t* type, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id = 0) {
        auto handle = CreateWindowExW(0, type, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                                      window, reinterpret_cast<HMENU>(INT_PTR(id)), instance, nullptr);
        SendMessageW(handle, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
        return handle;
    }

    void init() {
        fields.push_back(control(L"STATIC", L"Mac LAN IPv4 address", 0, 20, 20, 155, 24));
        fields.push_back(control(L"EDIT", L"", WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL, 180, 18, 270, 26, HostEdit));
        SendMessageW(fields.back(), EM_SETLIMITTEXT, 15, 0);
        fields.push_back(control(L"STATIC", L"One-time pairing code", 0, 20, 58, 155, 24));
        fields.push_back(control(L"EDIT", L"", WS_TABSTOP | WS_BORDER | ES_PASSWORD | ES_AUTOHSCROLL,
                                 180, 56, 270, 26, CodeEdit));
        SendMessageW(fields.back(), EM_SETLIMITTEXT, 32, 0);
        fields.push_back(control(L"BUTTON", L"Request HEVC (if available)", BS_AUTOCHECKBOX | WS_TABSTOP,
                                 20, 96, 260, 24, HevcBox));
        fields.push_back(control(L"STATIC", L"Fullscreen exit shortcut", 0, 20, 134, 155, 24));
        auto shortcut = control(L"COMBOBOX", L"", WS_TABSTOP | CBS_DROPDOWNLIST, 180, 132, 175, 120, Shortcut);
        fields.push_back(shortcut);
        for (auto label : {L"Esc", L"Ctrl + Shift + Q", L"Alt + Shift + Q"})
            SendMessageW(shortcut, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label));
        SendMessageW(shortcut, CB_SETCURSEL, 0, 0);
        fields.push_back(control(L"STATIC", L"Stream size", 0, 20, 170, 155, 24));
        auto resolution = control(L"COMBOBOX", L"", WS_TABSTOP | CBS_DROPDOWNLIST, 180, 168, 175, 120, Resolution);
        fields.push_back(resolution);
        for (auto label : {L"Native (up to 4K)", L"Cap at 1440p", L"Cap at 1080p"})
            SendMessageW(resolution, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label));
        SendMessageW(resolution, CB_SETCURSEL, 0, 0);
        fields.push_back(control(L"BUTTON", L"Connect", WS_TABSTOP, 362, 168, 88, 28, ConnectButton));
        status = control(L"STATIC", L"Move this window onto the target monitor before connecting.", 0, 20, 210, 430, 64);
        fields.push_back(status);
        overlay = control(L"STATIC", L"", SS_CENTER, 12, 12, 570, 30);
        ShowWindow(overlay, SW_HIDE);
    }

    void connect() {
        if (worker.joinable()) return;
        try {
            const auto monitor = monitorFor(window);
            const auto choice = SendDlgItemMessageW(window, Resolution, CB_GETCURSEL, 0, 0);
            const double maxWide = choice == 2 ? 1920.0 : choice == 1 ? 2560.0 : 3840.0;
            const double maxShort = choice == 2 ? 1080.0 : choice == 1 ? 1440.0 : 2160.0;
            const double scale = (std::min)({1.0, maxWide / std::max(monitor.width, monitor.height),
                                            maxShort / std::min(monitor.width, monitor.height)});
            const UINT width = UINT(monitor.width * scale) & ~1u;
            const UINT height = UINT(monitor.height * scale) & ~1u;
            if (width < 320 || height < 320) throw std::runtime_error("Display mode is too small.");
            auto ip = field(window, HostEdit);
            auto code = field(window, CodeEdit);
            auto secret = pairingSecret(code);
            SecureZeroMemory(code.data(), code.size() * sizeof(wchar_t));
            SetDlgItemTextW(window, CodeEdit, L"");
            const bool hevc = IsDlgButtonChecked(window, HevcBox) == BST_CHECKED;
            exitKey = int(SendDlgItemMessageW(window, Shortcut, CB_GETCURSEL, 0, 0));
            showMetrics = false;
            receivedVideo = false;
            stop = false;
            placement.length = sizeof(placement);
            GetWindowPlacement(window, &placement);
            for (const auto field : fields) ShowWindow(field, SW_HIDE);
            SetWindowLongPtrW(window, GWL_STYLE, WS_POPUP | WS_VISIBLE);
            SetWindowPos(window, HWND_TOP, monitor.rect.left, monitor.rect.top, monitor.rect.right - monitor.rect.left,
                         monitor.rect.bottom - monitor.rect.top, SWP_FRAMECHANGED);
            SetFocus(window);
            wchar_t line[256];
            swprintf_s(line, L"%u × %u @ %u Hz (%ls) · requesting %u × %u · F2 for metrics",
                       monitor.width, monitor.height, monitor.refresh,
                       monitor.preferred ? L"preferred pixels / active refresh" : L"active mode",
                       width, height);
            SetWindowTextW(overlay, line);
            ShowWindow(overlay, SW_SHOW);
            worker = std::thread([this, ip = std::move(ip), secret = std::move(secret), width, height, hevc]() mutable {
                receive(std::move(ip), std::move(secret), width, height, hevc);
            });
        } catch (const std::exception& error) {
            restore(wide(error.what()));
        }
    }

    void restore(const std::wstring& text) {
        ShowWindow(overlay, SW_HIDE);
        if (placement.length != 0) {
            SetWindowLongPtrW(window, GWL_STYLE, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE);
            SetWindowPlacement(window, &placement);
            SetWindowPos(window, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
            placement.length = 0;
            for (const auto field : fields) ShowWindow(field, SW_SHOW);
        }
        SetWindowTextW(status, text.c_str());
    }
};

LRESULT CALLBACK windowProc(HWND window, UINT event, WPARAM wParam, LPARAM lParam) {
    auto* session = reinterpret_cast<Session*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (event == WM_NCCREATE) {
        session = static_cast<Session*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
        session->window = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(session));
    }
    if (!session) return DefWindowProcW(window, event, wParam, lParam);
    switch (event) {
    case WM_CREATE: session->init(); return 0;
    case WM_COMMAND:
        if (LOWORD(wParam) == ConnectButton && HIWORD(wParam) == BN_CLICKED) session->connect();
        return 0;
    case StatusUpdate:
        if (wParam == 1 && !session->showMetrics) ShowWindow(session->overlay, SW_HIDE);
        SetWindowTextW(session->overlay, session->currentMessage().c_str());
        return 0;
    case SessionEnded:
        session->worker.join();
        if (session->closeOnFinish) DestroyWindow(window);
        else session->restore(session->currentMessage());
        return 0;
    case WM_DISPLAYCHANGE:
        if (session->worker.joinable()) session->stop = true;
        break;
    case WM_SYSKEYDOWN:
    case WM_KEYDOWN:
        if (session->worker.joinable()) {
            const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
            const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
            const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
            if ((session->exitKey == 0 && wParam == VK_ESCAPE) ||
                (wParam == 'Q' && shift && ((session->exitKey == 1 && ctrl && !alt) ||
                                           (session->exitKey == 2 && alt && !ctrl)))) {
                session->stop = true;
                return 0;
            }
            if (wParam == VK_F2) {
                session->showMetrics = !session->showMetrics;
                ShowWindow(session->overlay, session->showMetrics ? SW_SHOW : SW_HIDE);
                return 0;
            }
        }
        break;
    case WM_CLOSE:
        if (session->worker.joinable()) {
            session->closeOnFinish = true;
            session->stop = true;
        } else {
            DestroyWindow(window);
        }
        return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, event, wParam, lParam);
}

int selfTest(HWND window) {
    try {
        WinsockRuntime sockets;
        MediaRuntime media;
        if (!createDecoder(false) || !GetDlgItem(window, ConnectButton)) return 10;
        const auto monitor = monitorFor(window);
        if (!monitor.width || !monitor.height) return 11;
        Bytes secret = pairingSecret(L"000102030405060708090a0b0c0d0e0f");
        Bytes transcript(64);
        for (size_t i = 0; i < transcript.size(); ++i) transcript[i] = uint8_t(i);
        AesGcm gcm(sessionKey(secret, transcript, 2));
        Bytes plain{2};
        Bytes header{0, 0, 0, 17};
        // Cross-platform known-answer vector. See docs/portable.md.
        const Bytes expected{0xc8, 0xad, 0xe4, 0x6f, 0x51, 0xb5, 0x02, 0x40, 0x93,
                             0xbc, 0x41, 0xef, 0x49, 0xd1, 0x73, 0x3b, 0xc4};
        auto ciphertext = gcm.crypt(plain, 0, header, true);
        if (ciphertext != expected || gcm.crypt(ciphertext, 0, header, false) != plain) return 12;
        ciphertext.back() ^= 1;
        bool rejected = false;
        try { gcm.crypt(ciphertext, 0, header, false); } catch (const std::runtime_error&) { rejected = true; }
        return rejected ? 0 : 13;
    } catch (const std::exception& error) {
        OutputDebugStringW(wide(error.what()).c_str());
        return 14;
    }
}
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR args, int show) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW cls{};
    cls.hInstance = instance;
    cls.lpfnWndProc = windowProc;
    cls.lpszClassName = ClassName;
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&cls)) return 1;
    Session session;
    session.instance = instance;
    session.traceEnabled = std::wstring(args) == L"--trace";
    auto window = CreateWindowExW(0, ClassName, L"BetterCast Portable Receiver",
                                  WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
                                  CW_USEDEFAULT, CW_USEDEFAULT, 495, 320, nullptr, nullptr, instance, &session);
    if (!window) return 2;
    if (std::wstring(args) == L"--self-test") {
        ShowWindow(window, SW_SHOWNORMAL);
        UpdateWindow(window);
        const int result = selfTest(window);
        DestroyWindow(window);
        return result;
    }
    ShowWindow(window, show);
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        if (!session.worker.joinable() && IsDialogMessageW(window, &message)) continue;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return int(message.wParam);
}
