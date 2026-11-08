// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "SessionTrace.h"
#include <d3d11_4.h>
#include <dxgi1_3.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>

using Microsoft::WRL::ComPtr;

inline void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        char code[16];
        std::snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(result));
        throw std::runtime_error(std::string(operation) + " (" + code + ")");
    }
}

struct MediaRuntime {
    MediaRuntime() {
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM initialization failed");
        const auto result = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        if (FAILED(result)) CoUninitialize();
        check(result, "Media Foundation unavailable. Windows Media Features must already be present");
    }
    ~MediaRuntime() { MFShutdown(); CoUninitialize(); }
};

inline ComPtr<IMFTransform> createDecoder(bool hevc) {
    ComPtr<IMFTransform> decoder;
    if (!hevc) {
        check(CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&decoder)),
              "Windows H.264 decoder unavailable");
        return decoder;
    }
    MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_HEVC};
    IMFActivate** choices = nullptr;
    UINT32 count = 0;
    check(MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                    &input, nullptr, &choices, &count), "Could not enumerate HEVC decoders");
    for (UINT32 i = 0; i < count; ++i) {
        if (!decoder) choices[i]->ActivateObject(IID_PPV_ARGS(&decoder));
        choices[i]->Release();
    }
    CoTaskMemFree(choices);
    if (!decoder) throw std::runtime_error("No compatible HEVC decoder. Reconnect using H.264.");
    return decoder;
}

struct FrameCounts {
    uint64_t decoded = 0;
    uint64_t presented = 0;
    void add(FrameCounts counts) { decoded += counts.decoded; presented += counts.presented; }
};

class Playback {
public:
    Playback(HWND window, UINT width, UINT height, bool hevc, SessionTrace& trace)
        : expectedWidth(width), expectedHeight(height), trace(trace), decoder(createDecoder(hevc)) {
        check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                               nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context),
              "A Direct3D 11 video-capable graphics device is required");
        check(device.As(&videoDevice), "D3D11 video device unavailable");
        check(context.As(&videoContext), "D3D11 video context unavailable");
        ComPtr<ID3D11Multithread> multithread;
        if (SUCCEEDED(context.As(&multithread))) multithread->SetMultithreadProtected(TRUE);

        ComPtr<IDXGIDevice1> dxgi;
        check(device.As(&dxgi), "DXGI device unavailable");
        check(dxgi->SetMaximumFrameLatency(1), "Could not limit presentation queue");
        ComPtr<IDXGIAdapter> adapter;
        check(dxgi->GetAdapter(&adapter), "DXGI adapter unavailable");
        DXGI_ADAPTER_DESC adapterDesc{};
        if (SUCCEEDED(adapter->GetDesc(&adapterDesc))) {
            trace.record("gpu_vendor_id", 0, adapterDesc.VendorId);
            trace.record("gpu_device_id", 0, adapterDesc.DeviceId);
        }
        ComPtr<IDXGIFactory2> factory;
        check(adapter->GetParent(IID_PPV_ARGS(&factory)), "DXGI factory unavailable");
        RECT client{};
        GetClientRect(window, &client);
        outputWidth = client.right;
        outputHeight = client.bottom;
        DXGI_SWAP_CHAIN_DESC1 swap{};
        swap.Width = outputWidth;
        swap.Height = outputHeight;
        swap.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        swap.SampleDesc.Count = 1;
        swap.BufferCount = 2;
        swap.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swap.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        check(factory->CreateSwapChainForHwnd(device.Get(), window, &swap, nullptr, nullptr, &chain),
              "Could not create the presentation surface");
        factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
        check(chain->GetBuffer(0, IID_PPV_ARGS(&backBuffer)), "Could not get the presentation buffer");

        ComPtr<IMFAttributes> attributes;
        if (SUCCEEDED(decoder->GetAttributes(&attributes))) {
            attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
            UINT32 aware = 0;
            if (SUCCEEDED(attributes->GetUINT32(MF_SA_D3D11_AWARE, &aware)) && aware) {
                UINT token = 0;
                if (SUCCEEDED(MFCreateDXGIDeviceManager(&token, &manager)) &&
                    SUCCEEDED(manager->ResetDevice(device.Get(), token))) {
                    decoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(manager.Get()));
                }
            }
        }
        ComPtr<IMFMediaType> input;
        check(MFCreateMediaType(&input), "Could not create decoder input type");
        check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "Could not set video input");
        check(input->SetGUID(MF_MT_SUBTYPE, hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264), "Could not set codec");
        check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height), "Could not set video dimensions");
        check(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, 60, 1), "Could not set target frame rate");
        check(decoder->SetInputType(0, input.Get(), 0), "Decoder rejected the requested video mode");
        selectOutput();
        check(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0), "Could not start decoder");
        check(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), "Could not start video stream");
    }

    FrameCounts decode(Bytes& video, LONGLONG pts) {
        annexB(video);
        const DWORD size = DWORD(video.size() - 9);
        ComPtr<IMFSample> input;
        ComPtr<IMFMediaBuffer> buffer;
        check(MFCreateSample(&input), "Could not create video sample");
        check(MFCreateMemoryBuffer(size, &buffer), "Could not allocate compressed video buffer");
        BYTE* bytes = nullptr;
        check(buffer->Lock(&bytes, nullptr, nullptr), "Could not lock compressed video buffer");
        std::memcpy(bytes, video.data() + 9, size);
        buffer->Unlock();
        check(buffer->SetCurrentLength(size), "Could not set compressed video length");
        check(input->AddBuffer(buffer.Get()), "Could not attach compressed video");
        check(input->SetSampleTime(pts), "Could not set video timestamp");

        FrameCounts counts;
        auto result = decoder->ProcessInput(0, input.Get(), 0);
        if (result == MF_E_NOTACCEPTING) {
            counts.add(drain());
            result = decoder->ProcessInput(0, input.Get(), 0);
        }
        check(result, "Decoder rejected a video access unit");
        counts.add(drain());
        return counts;
    }

    const char* outputPath() const { return surfacePath ? "DXGI surfaces" : "NV12 upload"; }

private:
    UINT expectedWidth, expectedHeight, outputWidth = 0, outputHeight = 0;
    UINT decodedWidth = 0, decodedHeight = 0;
    bool surfacePath = false;
    SessionTrace& trace;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VideoDevice> videoDevice;
    ComPtr<ID3D11VideoContext> videoContext;
    ComPtr<IDXGISwapChain1> chain;
    ComPtr<ID3D11Texture2D> backBuffer, upload;
    ComPtr<ID3D11VideoProcessorEnumerator> processorEnum;
    ComPtr<ID3D11VideoProcessor> processor;
    ComPtr<ID3D11VideoProcessorOutputView> outputView;
    ComPtr<IMFDXGIDeviceManager> manager;
    ComPtr<IMFTransform> decoder;
    MFT_OUTPUT_STREAM_INFO outputInfo{};
    Bytes uploadBytes;

    void selectOutput() {
        for (DWORD i = 0;; ++i) {
            ComPtr<IMFMediaType> type;
            check(decoder->GetOutputAvailableType(0, i, &type), "Decoder has no NV12 output type");
            GUID format{};
            if (SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &format)) && format == MFVideoFormat_NV12 &&
                SUCCEEDED(decoder->SetOutputType(0, type.Get(), 0))) {
                check(decoder->GetOutputStreamInfo(0, &outputInfo), "Could not read decoder buffer requirements");
                check(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &decodedWidth, &decodedHeight),
                      "Missing decoded dimensions");
                if (decodedWidth < expectedWidth || decodedHeight < expectedHeight ||
                    decodedWidth > expectedWidth + 64 || decodedHeight > expectedHeight + 64)
                    throw std::runtime_error("Decoded dimensions do not match the approved display mode.");
                setupProcessor();
                return;
            }
        }
    }

    void setupProcessor() {
        D3D11_VIDEO_PROCESSOR_CONTENT_DESC description{};
        description.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
        description.InputFrameRate = {60, 1};
        description.OutputFrameRate = {60, 1};
        description.InputWidth = decodedWidth;
        description.InputHeight = decodedHeight;
        description.OutputWidth = outputWidth;
        description.OutputHeight = outputHeight;
        description.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
        outputView.Reset();
        processor.Reset();
        processorEnum.Reset();
        upload.Reset();
        check(videoDevice->CreateVideoProcessorEnumerator(&description, &processorEnum), "D3D11 video mode unsupported");
        check(videoDevice->CreateVideoProcessor(processorEnum.Get(), 0, &processor), "Could not create video processor");
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC view{};
        view.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        check(videoDevice->CreateVideoProcessorOutputView(backBuffer.Get(), processorEnum.Get(), &view, &outputView),
              "Could not create video output view");
        const double scale = (std::min)(double(outputWidth) / expectedWidth, double(outputHeight) / expectedHeight);
        const LONG width = LONG(expectedWidth * scale), height = LONG(expectedHeight * scale);
        const LONG left = (LONG(outputWidth) - width) / 2, top = (LONG(outputHeight) - height) / 2;
        const RECT source{0, 0, LONG(expectedWidth), LONG(expectedHeight)};
        const RECT target{left, top, left + width, top + height};
        videoContext->VideoProcessorSetStreamSourceRect(processor.Get(), 0, TRUE, &source);
        videoContext->VideoProcessorSetStreamDestRect(processor.Get(), 0, TRUE, &target);
        videoContext->VideoProcessorSetStreamAutoProcessingMode(processor.Get(), 0, FALSE);
    }

    FrameCounts drain() {
        FrameCounts counts;
        for (;;) {
            ComPtr<IMFSample> allocated;
            if (!(outputInfo.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES))) {
                ComPtr<IMFMediaBuffer> buffer;
                check(MFCreateSample(&allocated), "Could not create decoder output sample");
                check(MFCreateAlignedMemoryBuffer(outputInfo.cbSize, outputInfo.cbAlignment ? outputInfo.cbAlignment - 1 : 0,
                                                  &buffer), "Could not allocate decoder output");
                check(allocated->AddBuffer(buffer.Get()), "Could not attach decoder output buffer");
            }
            MFT_OUTPUT_DATA_BUFFER output{};
            output.pSample = allocated.Get();
            DWORD flags = 0;
            const auto result = decoder->ProcessOutput(0, 1, &output, &flags);
            ComPtr<IMFCollection> events;
            events.Attach(output.pEvents);
            ComPtr<IMFSample> sample = allocated;
            if (output.pSample != allocated.Get()) sample.Attach(output.pSample);
            if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return counts;
            if (result == MF_E_TRANSFORM_STREAM_CHANGE) { selectOutput(); continue; }
            check(result, "Decoding failed");
            if (output.dwStatus == MFT_OUTPUT_DATA_BUFFER_NO_SAMPLE) return counts;
            if (!sample) throw std::runtime_error("Decoder returned no video sample.");
            LONGLONG pts = 0;
            if (trace.enabled() && FAILED(sample->GetSampleTime(&pts))) pts = 0;
            trace.record("decoded", pts);
            ++counts.decoded;
            if (present(sample.Get(), pts)) ++counts.presented;
        }
    }

    void uploadNV12(IMFMediaBuffer* buffer) {
        if (!upload) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = decodedWidth;
            desc.Height = decodedHeight;
            desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
            desc.Format = DXGI_FORMAT_NV12;
            check(device->CreateTexture2D(&desc, nullptr, &upload), "Could not allocate NV12 upload surface");
        }
        const DWORD required = decodedWidth * decodedHeight * 3 / 2;
        ComPtr<IMF2DBuffer> surface;
        if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&surface)))) {
            DWORD size = 0;
            check(surface->GetContiguousLength(&size), "Could not read decoded surface size");
            if (size != required) throw std::runtime_error("Unexpected NV12 surface layout.");
            uploadBytes.resize(size);
            check(surface->ContiguousCopyTo(uploadBytes.data(), size), "Could not copy decoded surface");
            context->UpdateSubresource(upload.Get(), 0, nullptr, uploadBytes.data(), decodedWidth, 0);
        } else {
            BYTE* bytes = nullptr;
            DWORD size = 0;
            check(buffer->Lock(&bytes, nullptr, &size), "Could not map decoded video");
            if (size == required) context->UpdateSubresource(upload.Get(), 0, nullptr, bytes, decodedWidth, 0);
            buffer->Unlock();
            if (size != required) throw std::runtime_error("Unexpected NV12 memory layout.");
        }
    }

    bool present(IMFSample* sample, LONGLONG pts) {
        ComPtr<IMFMediaBuffer> buffer;
        check(sample->GetBufferByIndex(0, &buffer), "Could not get decoded buffer");
        ComPtr<IMFDXGIBuffer> dxgi;
        ComPtr<ID3D11Texture2D> texture;
        UINT subresource = 0;
        surfacePath = SUCCEEDED(buffer.As(&dxgi));
        if (surfacePath) {
            check(dxgi->GetResource(IID_PPV_ARGS(&texture)), "Could not get decoded texture");
            check(dxgi->GetSubresourceIndex(&subresource), "Could not get decoded texture slice");
        } else {
            uploadNV12(buffer.Get());
            texture = upload;
        }
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC view{};
        view.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        view.Texture2D.ArraySlice = subresource;
        ComPtr<ID3D11VideoProcessorInputView> input;
        check(videoDevice->CreateVideoProcessorInputView(texture.Get(), processorEnum.Get(), &view, &input),
              "Could not create decoded texture view");
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE;
        stream.pInputSurface = input.Get();
        check(videoContext->VideoProcessorBlt(processor.Get(), outputView.Get(), 0, 1, &stream), "Video render failed");
        const auto result = chain->Present(0, 0);
        trace.record(result == S_OK ? "present" : "present_other", pts, static_cast<uint32_t>(result));
        check(result, "Video presentation failed");
        return result == S_OK;
    }
};
