// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "Transport.h"
#include <filesystem>
#include <fstream>

inline int64_t traceTime() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
}

class SessionTrace {
public:
    explicit SessionTrace(bool enabled, UINT width, UINT height, bool hevc) {
        if (!enabled) return;
        const auto filename = L"BetterCastPortable-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
                              std::to_wstring(traceTime()) + L".csv";
        path = std::filesystem::temp_directory_path() / filename;
        output.open(path);
        if (!output) throw std::runtime_error("Could not create the receiver trace in the temporary folder.");
        output << "# commit=" PORTABLE_BUILD_COMMIT " mode=" << width << 'x' << height
               << " codec=" << (hevc ? "hevc" : "h264") << '\n'
               << "event,pts_100ns,time_ns,value\n";
    }

    void record(const char* event, LONGLONG pts = 0, int64_t value = 0, int64_t time = 0) {
        if (!output.is_open()) return;
        if (rows == 100000) {
            output << "trace_truncated,0," << traceTime() << ",0\n";
            ++rows;
        }
        if (rows > 100000) return;
        ++rows;
        if (time == 0) time = traceTime();
        output << event << ',' << pts << ',' << time << ',' << value << '\n';
    }

    bool enabled() const { return output.is_open(); }
    std::filesystem::path path;

private:
    std::ofstream output;
    size_t rows = 0;
};
