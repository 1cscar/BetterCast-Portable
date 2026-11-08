cmake_minimum_required(VERSION 3.20)
project(BetterCastPortableReceiver LANGUAGES CXX RC)

add_executable(BetterCastPortableReceiver WIN32 main.cpp)
target_compile_features(BetterCastPortableReceiver PRIVATE cxx_std_17)
target_compile_definitions(BetterCastPortableReceiver PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
target_compile_options(BetterCastPortableReceiver PRIVATE /W4 /utf-8 /permissive-)
set_target_properties(BetterCastPortableReceiver PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
target_link_libraries(BetterCastPortableReceiver PRIVATE
    ws2_32 bcrypt ole32 user32 gdi32 d3d11 dxgi mf mfplat mfuuid wmcodecdspuuid)
target_link_options(BetterCastPortableReceiver PRIVATE
    /MANIFEST:EMBED "/MANIFESTINPUT:${CMAKE_CURRENT_SOURCE_DIR}/receiver.manifest")
