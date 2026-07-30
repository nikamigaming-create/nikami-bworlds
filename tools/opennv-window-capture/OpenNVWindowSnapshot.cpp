// Exact-title Windows.Graphics.Capture diagnostic for OpenNV proof recording.
//
// The tool observes a visible top-level window and never activates it, sends
// input, or changes its z-order. It exists to verify that a GPU-composed OpenMW
// frame is obtainable when legacy GDI window capture produces a black surface.

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace
{
    struct Arguments
    {
        std::wstring title;
        std::wstring output;
        DWORD timeoutMs = 10000;
    };

    struct SharedResult
    {
        std::mutex mutex;
        std::condition_variable condition;
        bool complete = false;
        std::string error;
    };

    std::wstring widen(std::string_view value)
    {
        if (value.empty())
            return {};
        const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (length <= 0)
            throw std::runtime_error("Unable to decode a UTF-8 command-line value.");
        std::wstring result(static_cast<std::size_t>(length), L'\0');
        if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length) != length)
            throw std::runtime_error("Unable to decode a UTF-8 command-line value.");
        return result;
    }

    std::string narrow(std::wstring_view value)
    {
        if (value.empty())
            return {};
        const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
        if (length <= 0)
            return "<unprintable Windows error>";
        std::string result(static_cast<std::size_t>(length), '\0');
        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length, nullptr, nullptr);
        return result;
    }

    Arguments parseArguments(int argc, char** argv)
    {
        Arguments result;
        for (int index = 1; index < argc; ++index)
        {
            const std::string argument = argv[index];
            auto readValue = [&](std::string_view name) {
                if (++index >= argc)
                    throw std::runtime_error("Missing value for " + std::string(name) + ".");
                return widen(argv[index]);
            };
            if (argument == "--title")
                result.title = readValue(argument);
            else if (argument == "--output")
                result.output = readValue(argument);
            else if (argument == "--timeout-ms")
            {
                const auto value = readValue(argument);
                const auto milliseconds = std::stoul(value);
                if (milliseconds == 0 || milliseconds > 60000)
                    throw std::runtime_error("--timeout-ms must be between 1 and 60000.");
                result.timeoutMs = static_cast<DWORD>(milliseconds);
            }
            else
                throw std::runtime_error("Unknown argument: " + argument);
        }
        if (result.title.empty() || result.output.empty())
            throw std::runtime_error("Usage: OpenNVWindowSnapshot --title <exact title> --output <new .bmp path> [--timeout-ms <1..60000>]");
        if (GetFileAttributesW(result.output.c_str()) != INVALID_FILE_ATTRIBUTES)
            throw std::runtime_error("Refusing to overwrite existing output: " + narrow(result.output));
        return result;
    }

    struct FindWindowContext
    {
        std::wstring_view title;
        HWND result = nullptr;
    };

    BOOL CALLBACK findWindowCallback(HWND window, LPARAM parameter)
    {
        auto& context = *reinterpret_cast<FindWindowContext*>(parameter);
        if (!IsWindowVisible(window) || IsIconic(window) || GetWindow(window, GW_OWNER) != nullptr)
            return TRUE;
        const int length = GetWindowTextLengthW(window);
        if (length <= 0)
            return TRUE;
        std::wstring actual(static_cast<std::size_t>(length), L'\0');
        if (GetWindowTextW(window, actual.data(), length + 1) != length)
            return TRUE;
        if (actual == context.title)
        {
            context.result = window;
            return FALSE;
        }
        return TRUE;
    }

    HWND findVisibleExactTitleWindow(std::wstring_view title)
    {
        FindWindowContext context{ title };
        EnumWindows(findWindowCallback, reinterpret_cast<LPARAM>(&context));
        if (context.result == nullptr)
            throw std::runtime_error("No visible, unminimized top-level window matches the requested exact title: " + narrow(title));
        return context.result;
    }

    IDirect3DDevice createDirect3DDevice(com_ptr<ID3D11Device>& device, com_ptr<ID3D11DeviceContext>& context)
    {
        constexpr UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        D3D_FEATURE_LEVEL featureLevel{};
        check_hresult(D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            flags,
            nullptr,
            0,
            D3D11_SDK_VERSION,
            device.put(),
            &featureLevel,
            context.put()));
        com_ptr<IDXGIDevice> dxgiDevice;
        device.as(dxgiDevice);
        com_ptr<IInspectable> inspectable;
        check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.get(), inspectable.put()));
        return inspectable.as<IDirect3DDevice>();
    }

    GraphicsCaptureItem createItemForWindow(HWND window)
    {
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        check_hresult(interop->CreateForWindow(
            window,
            guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(),
            put_abi(item)));
        return item;
    }

    void writeBmp(
        ID3D11Device* device,
        ID3D11DeviceContext* context,
        ID3D11Texture2D* source,
        const std::wstring& output)
    {
        D3D11_TEXTURE2D_DESC description{};
        source->GetDesc(&description);
        if (description.Format != DXGI_FORMAT_B8G8R8A8_UNORM && description.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
            throw std::runtime_error("The captured frame did not use the expected BGRA format.");

        D3D11_TEXTURE2D_DESC stagingDescription = description;
        stagingDescription.Usage = D3D11_USAGE_STAGING;
        stagingDescription.BindFlags = 0;
        stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        stagingDescription.MiscFlags = 0;
        stagingDescription.MiscFlags &= ~D3D11_RESOURCE_MISC_GDI_COMPATIBLE;
        com_ptr<ID3D11Texture2D> staging;
        check_hresult(device->CreateTexture2D(&stagingDescription, nullptr, staging.put()));
        context->CopyResource(staging.get(), source);

        D3D11_MAPPED_SUBRESOURCE mapped{};
        check_hresult(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
        struct MapGuard
        {
            ID3D11DeviceContext* context;
            ID3D11Texture2D* texture;
            ~MapGuard() { context->Unmap(texture, 0); }
        } guard{ context, staging.get() };

        BITMAPFILEHEADER fileHeader{};
        BITMAPINFOHEADER infoHeader{};
        infoHeader.biSize = sizeof(infoHeader);
        infoHeader.biWidth = static_cast<LONG>(description.Width);
        infoHeader.biHeight = -static_cast<LONG>(description.Height); // top-down BGRA rows
        infoHeader.biPlanes = 1;
        infoHeader.biBitCount = 32;
        infoHeader.biCompression = BI_RGB;
        infoHeader.biSizeImage = description.Width * description.Height * 4;
        fileHeader.bfType = 0x4D42; // BM
        fileHeader.bfOffBits = sizeof(fileHeader) + sizeof(infoHeader);
        fileHeader.bfSize = fileHeader.bfOffBits + infoHeader.biSizeImage;

        std::ofstream file(output, std::ios::binary | std::ios::out | std::ios::trunc);
        if (!file)
            throw std::runtime_error("Unable to create output bitmap: " + narrow(output));
        file.write(reinterpret_cast<const char*>(&fileHeader), sizeof(fileHeader));
        file.write(reinterpret_cast<const char*>(&infoHeader), sizeof(infoHeader));
        const auto* row = static_cast<const std::uint8_t*>(mapped.pData);
        const std::size_t rowBytes = static_cast<std::size_t>(description.Width) * 4;
        for (UINT y = 0; y < description.Height; ++y)
        {
            file.write(reinterpret_cast<const char*>(row), static_cast<std::streamsize>(rowBytes));
            row += mapped.RowPitch;
        }
        if (!file)
            throw std::runtime_error("Unable to write output bitmap: " + narrow(output));
    }

    void captureSnapshot(const Arguments& arguments)
    {
        const HWND window = findVisibleExactTitleWindow(arguments.title);
        com_ptr<ID3D11Device> device;
        com_ptr<ID3D11DeviceContext> context;
        const auto direct3DDevice = createDirect3DDevice(device, context);
        const auto item = createItemForWindow(window);
        const auto size = item.Size();
        if (size.Width <= 0 || size.Height <= 0)
            throw std::runtime_error("The requested window has no capturable content size.");

        auto framePool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            direct3DDevice,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            size);
        auto session = framePool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled(false);

        SharedResult result;
        auto frameArrived = framePool.FrameArrived(auto_revoke, [&](auto const& sender, auto const&) {
            std::unique_lock lock(result.mutex);
            if (result.complete)
                return;
            try
            {
                const auto frame = sender.TryGetNextFrame();
                const auto surface = frame.Surface();
                const auto access = surface.as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
                com_ptr<ID3D11Texture2D> texture;
                check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
                writeBmp(device.get(), context.get(), texture.get(), arguments.output);
            }
            catch (const hresult_error& error)
            {
                result.error = "Windows.Graphics.Capture failed: " + narrow(error.message().c_str());
            }
            catch (const std::exception& error)
            {
                result.error = error.what();
            }
            result.complete = true;
            lock.unlock();
            result.condition.notify_one();
        });
        session.StartCapture();

        std::unique_lock lock(result.mutex);
        if (!result.condition.wait_for(lock, std::chrono::milliseconds(arguments.timeoutMs), [&] { return result.complete; }))
            throw std::runtime_error("Timed out waiting for a Windows.Graphics.Capture frame.");
        if (!result.error.empty())
            throw std::runtime_error(result.error);
    }
}

int main(int argc, char** argv)
{
    try
    {
        init_apartment(apartment_type::multi_threaded);
        const auto arguments = parseArguments(argc, argv);
        captureSnapshot(arguments);
        std::cout << "status=pass method=windows-graphics-capture-exact-title title=" << narrow(arguments.title) << '\n';
        return 0;
    }
    catch (const hresult_error& error)
    {
        std::cerr << "status=fail error=" << narrow(error.message().c_str()) << '\n';
    }
    catch (const std::exception& error)
    {
        std::cerr << "status=fail error=" << error.what() << '\n';
    }
    return 1;
}
