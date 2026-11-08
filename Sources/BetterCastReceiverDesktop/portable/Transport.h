// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>
#include <bcrypt.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

using Bytes = std::vector<uint8_t>;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr uint32_t MaxPacket = 8 * 1024 * 1024;

inline uint32_t readU32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

inline void appendU32(Bytes& bytes, uint32_t n) {
    for (int shift = 24; shift >= 0; shift -= 8) bytes.push_back(uint8_t(n >> shift));
}

inline Bytes pairingSecret(const std::wstring& code) {
    if (code.size() != 32) throw std::runtime_error("Enter the 32 hex digits shown on the Mac.");
    auto digit = [](wchar_t c) -> uint8_t {
        if (c >= L'0' && c <= L'9') return uint8_t(c - L'0');
        if (c >= L'a' && c <= L'f') return uint8_t(c - L'a' + 10);
        if (c >= L'A' && c <= L'F') return uint8_t(c - L'A' + 10);
        throw std::runtime_error("The pairing code contains a non-hex character.");
    };
    Bytes secret(16);
    for (size_t i = 0; i < secret.size(); ++i) secret[i] = uint8_t(digit(code[i * 2]) << 4 | digit(code[i * 2 + 1]));
    return secret;
}

inline void cryptoCheck(NTSTATUS status) {
    if (status < 0) throw std::runtime_error("Pairing encryption or authentication failed.");
}

struct CryptoProvider {
    BCRYPT_ALG_HANDLE handle = nullptr;
    explicit CryptoProvider(LPCWSTR algorithm, ULONG flags = 0) {
        cryptoCheck(BCryptOpenAlgorithmProvider(&handle, algorithm, nullptr, flags));
    }
    ~CryptoProvider() { BCryptCloseAlgorithmProvider(handle, 0); }
    CryptoProvider(const CryptoProvider&) = delete;
};

inline Bytes sessionKey(Bytes& secret, const Bytes& transcript, uint8_t direction) {
    const std::string label = "BetterCast Portable v1";
    Bytes message(label.begin(), label.end());
    message.insert(message.end(), transcript.begin(), transcript.end());
    message.push_back(direction);
    Bytes result(32);
    CryptoProvider sha(BCRYPT_SHA256_ALGORITHM, BCRYPT_ALG_HANDLE_HMAC_FLAG);
    cryptoCheck(BCryptHash(sha.handle, secret.data(), ULONG(secret.size()), message.data(), ULONG(message.size()),
                          result.data(), ULONG(result.size())));
    return result;
}

class AesGcm {
public:
    explicit AesGcm(Bytes secret) {
        const auto mode = BCRYPT_CHAIN_MODE_GCM;
        cryptoCheck(BCryptSetProperty(provider.handle, BCRYPT_CHAINING_MODE,
                                     reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(mode)),
                                     sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
        const auto status = BCryptGenerateSymmetricKey(provider.handle, &key, nullptr, 0,
                                                       secret.data(), ULONG(secret.size()), 0);
        SecureZeroMemory(secret.data(), secret.size());
        cryptoCheck(status);
    }
    ~AesGcm() { BCryptDestroyKey(key); }
    AesGcm(const AesGcm&) = delete;

    Bytes crypt(Bytes& input, uint64_t sequence, Bytes& aad, bool encrypt) {
        constexpr ULONG TagSize = 16;
        if (!encrypt && input.size() <= TagSize) throw std::runtime_error("Truncated encrypted packet.");
        const auto size = ULONG(input.size() - (encrypt ? 0 : TagSize));
        Bytes result(size + (encrypt ? TagSize : 0));
        std::array<uint8_t, 12> nonce{};
        for (size_t i = 0; i < 8; ++i) nonce[11 - i] = uint8_t(sequence >> (i * 8));

        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = nonce.data();
        info.cbNonce = ULONG(nonce.size());
        info.pbAuthData = aad.empty() ? nullptr : aad.data();
        info.cbAuthData = ULONG(aad.size());
        info.pbTag = (encrypt ? result.data() : input.data()) + size;
        info.cbTag = TagSize;
        ULONG written = 0;
        const auto operation = encrypt ? BCryptEncrypt : BCryptDecrypt;
        cryptoCheck(operation(key, input.data(), size, &info, nullptr, 0, result.data(), size, &written, 0));
        if (written != size) throw std::runtime_error("Invalid encryption output length.");
        return result;
    }

private:
    CryptoProvider provider{BCRYPT_AES_ALGORITHM};
    BCRYPT_KEY_HANDLE key = nullptr;
};

class Connection {
public:
    explicit Connection(const std::atomic<bool>& cancelled) : stop(cancelled) {}
    ~Connection() { if (socket != INVALID_SOCKET) closesocket(socket); }
    Connection(const Connection&) = delete;

    void dial(const std::wstring& ip) {
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(51823);
        if (InetPtonW(AF_INET, ip.c_str(), &address.sin_addr) != 1)
            throw std::runtime_error("Enter the Mac's LAN IPv4 address.");
        socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        u_long nonblocking = 1;
        BOOL noDelay = TRUE;
        if (socket == INVALID_SOCKET || ioctlsocket(socket, FIONBIO, &nonblocking) == SOCKET_ERROR ||
            setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<char*>(&noDelay), sizeof(noDelay)) == SOCKET_ERROR)
            throw std::runtime_error("Could not open the TCP socket.");
        if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) return;
        if (WSAGetLastError() != WSAEWOULDBLOCK)
            throw std::runtime_error("Direct connection failed. Check the address and Mac listener.");
        ready(true, Clock::now() + 5s);
        int error = 0;
        int size = sizeof(error);
        if (getsockopt(socket, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &size) != 0 || error)
            throw std::runtime_error("Direct connection failed. Check the address and Mac listener.");
    }

    Bytes read(size_t size, Clock::time_point deadline) {
        Bytes bytes(size);
        transfer(bytes, false, deadline);
        return bytes;
    }

    void write(Bytes& bytes) { transfer(bytes, true, Clock::now() + 5s); }

private:
    SOCKET socket = INVALID_SOCKET;
    const std::atomic<bool>& stop;

    void ready(bool write, Clock::time_point deadline) {
        while (!stop) {
            if (Clock::now() >= deadline)
                throw std::runtime_error("Direct connection timed out. Check the Mac and network.");
            fd_set fds, errors;
            FD_ZERO(&fds);
            FD_ZERO(&errors);
            FD_SET(socket, &fds);
            FD_SET(socket, &errors);
            timeval timeout{0, 100000};
            const int count = select(0, write ? nullptr : &fds, write ? &fds : nullptr, &errors, &timeout);
            if (count == SOCKET_ERROR) throw std::runtime_error("Socket wait failed.");
            if (count > 0) return;
        }
        throw std::runtime_error("Disconnected.");
    }

    void transfer(Bytes& bytes, bool write, Clock::time_point deadline) {
        size_t offset = 0;
        while (offset < bytes.size()) {
            ready(write, deadline);
            auto* start = reinterpret_cast<char*>(bytes.data() + offset);
            const int size = int(bytes.size() - offset);
            const int count = write ? send(socket, start, size, 0) : recv(socket, start, size, 0);
            if (count == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) continue;
            if (count <= 0) throw std::runtime_error("The Mac closed the direct connection.");
            offset += size_t(count);
        }
    }
};

inline LONGLONG videoPTS(const Bytes& video) {
    if (video.size() < 14 || video[0] != 1) throw std::runtime_error("Truncated video access unit.");
    uint64_t pts = 0;
    for (int i = 0; i < 8; ++i) pts |= uint64_t(video[i + 1]) << (8 * i);
    return LONGLONG(pts / 100);
}

// Preserve BetterCast Mac sender's [8-byte little-endian ns PTS][4-byte BE length][NAL] payload.
// Media Foundation consumes Annex B. Replace each length in place, without copying the access unit.
inline void annexB(Bytes& video) {
    size_t offset = 9;
    while (offset < video.size()) {
        if (video.size() - offset < 4) throw std::runtime_error("Truncated NAL header.");
        const size_t length = readU32(video.data() + offset);
        if (length == 0 || length > video.size() - offset - 4)
            throw std::runtime_error("Invalid NAL length.");
        video[offset] = video[offset + 1] = video[offset + 2] = 0;
        video[offset + 3] = 1;
        offset += 4 + length;
    }
}
