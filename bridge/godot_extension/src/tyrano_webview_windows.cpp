#include "tyrano_webview.h"

#include "tyrano_host_script.h"

#include <WebView2.h>
#include <windows.h>
#include <wrl.h>


#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

constexpr wchar_t kOrigin[] = L"https://game.aether-tyrano.invalid/";
constexpr char kOriginUtf8[] = "https://game.aether-tyrano.invalid/";
constexpr uint64_t kMaxStorageBytes = 64 * 1024 * 1024;

std::wstring Widen(const std::string &value) {
    if (value.empty()) return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (length <= 0) return {};
    std::wstring result(length, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), result.data(), length);
    return result;
}

std::string Narrow(const wchar_t *value) {
    if (!value || !*value) return {};
    const int length = WideCharToMultiByte(CP_UTF8, 0, value, -1,
        nullptr, 0, nullptr, nullptr);
    if (length <= 1) return {};
    std::string result(length - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), length,
        nullptr, nullptr);
    return result;
}

#undef ReadFile

std::string Quote(const std::string &value) {
    std::string result = "\"";
    constexpr char hex[] = "0123456789abcdef";
    for (const unsigned char c : value) {
        switch (c) {
        case '\"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (c < 0x20) {
                result += "\\u00";
                result += hex[c >> 4];
                result += hex[c & 15];
            } else {
                result += static_cast<char>(c);
            }
        }
    }
    return result + "\"";
}

std::string ErrorMessage(const std::string &context, HRESULT hr) {
    wchar_t *message = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, static_cast<DWORD>(hr), 0,
        reinterpret_cast<wchar_t *>(&message), 0, nullptr);
    std::string detail = length && message ? Narrow(message) : "";
    if (message) LocalFree(message);
    while (!detail.empty() && (detail.back() == '\r' || detail.back() == '\n' ||
                                 detail.back() == ' ')) {
        detail.pop_back();
    }
    std::ostringstream result;
    result << context;
    if (!detail.empty()) result << ": " << detail;
    result << " (0x" << std::hex << static_cast<uint32_t>(hr) << ")";
    return result.str();
}

bool ReadStorageFile(const fs::path &path, std::string &data, std::string &error) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) {
        error = "Could not read game storage";
        return false;
    }
    const auto size = input.tellg();
    if (size < 0 || static_cast<uint64_t>(size) > kMaxStorageBytes) {
        error = "Game storage is too large";
        return false;
    }
    data.resize(static_cast<size_t>(size));
    input.seekg(0);
    if (!data.empty()) input.read(data.data(), data.size());
    if (!input) {
        error = "Could not read game storage";
        return false;
    }
    return true;
}

bool ParseString(const std::string &json, size_t &at, std::string &value) {
    if (at >= json.size() || json[at++] != '"') return false;
    value.clear();
    while (at < json.size()) {
        const unsigned char c = json[at++];
        if (c == '"') return true;
        if (c < 0x20) return false;
        if (c != '\\') { value += static_cast<char>(c); continue; }
        if (at >= json.size()) return false;
        const char escaped = json[at++];
        if (escaped == 'u') {
            if (at + 4 > json.size()) return false;
            uint32_t code = 0;
            for (int i = 0; i < 4; ++i) {
                const char h = json[at++];
                code <<= 4;
                if (h >= '0' && h <= '9') code += h - '0';
                else if (h >= 'a' && h <= 'f') code += h - 'a' + 10;
                else if (h >= 'A' && h <= 'F') code += h - 'A' + 10;
                else return false;
            }
            if (code >= 0xd800 && code <= 0xdbff && at + 6 <= json.size() &&
                json[at] == '\\' && json[at + 1] == 'u') {
                at += 2;
                uint32_t low = 0;
                for (int i = 0; i < 4; ++i) {
                    const char h = json[at++];
                    low <<= 4;
                    if (h >= '0' && h <= '9') low += h - '0';
                    else if (h >= 'a' && h <= 'f') low += h - 'a' + 10;
                    else if (h >= 'A' && h <= 'F') low += h - 'A' + 10;
                    else return false;
                }
                if (low < 0xdc00 || low > 0xdfff) return false;
                code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
            }
            if (code >= 0xd800 && code <= 0xdfff) return false;
            if (code < 0x80) value += static_cast<char>(code);
            else if (code < 0x800) {
                value += static_cast<char>(0xc0 | (code >> 6));
                value += static_cast<char>(0x80 | (code & 63));
            } else if (code < 0x10000) {
                value += static_cast<char>(0xe0 | (code >> 12));
                value += static_cast<char>(0x80 | ((code >> 6) & 63));
                value += static_cast<char>(0x80 | (code & 63));
            } else {
                value += static_cast<char>(0xf0 | (code >> 18));
                value += static_cast<char>(0x80 | ((code >> 12) & 63));
                value += static_cast<char>(0x80 | ((code >> 6) & 63));
                value += static_cast<char>(0x80 | (code & 63));
            }
            continue;
        }
        switch (escaped) {
        case '"': case '\\': case '/': value += escaped; break;
        case 'b': value += '\b'; break;
        case 'f': value += '\f'; break;
        case 'n': value += '\n'; break;
        case 'r': value += '\r'; break;
        case 't': value += '\t'; break;
        default: return false;
        }
    }
    return false;
}

bool ValidateStorage(const std::string &json, std::string &canonical,
                     std::string &error) {
    size_t at = 0;
    canonical = "{";
    size_t count = 0;
    auto whitespace = [&]() {
        while (at < json.size() && (json[at] == ' ' || json[at] == '\t' ||
               json[at] == '\r' || json[at] == '\n')) ++at;
    };
    whitespace();
    if (at >= json.size() || json[at++] != '{') goto invalid;
    whitespace();
    if (at < json.size() && json[at] == '}') ++at;
    else for (;;) {
        std::string key, value;
        if (!ParseString(json, at, key)) goto invalid;
        whitespace();
        if (at >= json.size() || json[at++] != ':') goto invalid;
        whitespace();
        if (!ParseString(json, at, value)) goto invalid;
        if (++count > 1024) goto invalid;
        if (count > 1) canonical += ',';
        canonical += Quote(key) + ":" + Quote(value);
        whitespace();
        if (at < json.size() && json[at] == ',') { ++at; whitespace(); continue; }
        if (at < json.size() && json[at] == '}') { ++at; break; }
        goto invalid;
    }
    whitespace();
    if (at != json.size()) goto invalid;
    canonical += '}';
    return true;
invalid:
    error = "Game storage is invalid; the original file was preserved";
    return false;
}

std::string PercentEncode(const std::string &value) {
    constexpr char hex[] = "0123456789ABCDEF";
    std::string result;
    for (const unsigned char c : value) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
            c == '~') {
            result += static_cast<char>(c);
        } else {
            result += '%';
            result += hex[c >> 4];
            result += hex[c & 15];
        }
    }
    return result;
}

bool PercentDecode(const std::string &value, std::string &decoded) {
    auto digit = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    decoded.clear();
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] != '%') {
            decoded += value[i];
            continue;
        }
        if (i + 2 >= value.size()) return false;
        const int high = digit(value[i + 1]);
        const int low = digit(value[i + 2]);
        if (high < 0 || low < 0) return false;
        const char c = static_cast<char>((high << 4) | low);
        if (c == '\0') return false;
        decoded += c;
        i += 2;
    }
    return true;
}

bool InsideRoot(const fs::path &root, const fs::path &candidate) {
    std::wstring prefix = root.native();
    if (!prefix.empty() && prefix.back() != L'\\' && prefix.back() != L'/')
        prefix += L'\\';
    const std::wstring &path = candidate.native();
    return path.size() > prefix.size() &&
        CompareStringOrdinal(prefix.data(), static_cast<int>(prefix.size()),
            path.data(), static_cast<int>(prefix.size()), TRUE) == CSTR_EQUAL;
}

std::wstring MimeType(const fs::path &path) {
    std::wstring extension = path.extension().wstring();
    for (wchar_t &c : extension) c = towlower(c);
    if (extension == L".html" || extension == L".htm")
        return L"text/html; charset=utf-8";
    if (extension == L".js" || extension == L".mjs")
        return L"application/javascript; charset=utf-8";
    if (extension == L".css") return L"text/css; charset=utf-8";
    if (extension == L".json") return L"application/json; charset=utf-8";
    if (extension == L".ks" || extension == L".tjs" || extension == L".txt")
        return L"text/plain; charset=utf-8";
    if (extension == L".png") return L"image/png";
    if (extension == L".jpg" || extension == L".jpeg") return L"image/jpeg";
    if (extension == L".gif") return L"image/gif";
    if (extension == L".webp") return L"image/webp";
    if (extension == L".svg") return L"image/svg+xml";
    if (extension == L".ico") return L"image/x-icon";
    if (extension == L".mp3") return L"audio/mpeg";
    if (extension == L".ogg" || extension == L".opus") return L"audio/ogg";
    if (extension == L".wav") return L"audio/wav";
    if (extension == L".m4a" || extension == L".aac") return L"audio/mp4";
    if (extension == L".mp4" || extension == L".m4v") return L"video/mp4";
    if (extension == L".webm") return L"video/webm";
    if (extension == L".woff") return L"font/woff";
    if (extension == L".woff2") return L"font/woff2";
    if (extension == L".ttf") return L"font/ttf";
    if (extension == L".otf") return L"font/otf";
    if (extension == L".wasm") return L"application/wasm";
    return L"application/octet-stream";
}

class FileRangeStream final : public IStream {
public:
    FileRangeStream(HANDLE file, uint64_t start, uint64_t length) :
        file_(file), start_(start), length_(length) {}
    ~FileRangeStream() { if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        if (iid == IID_IUnknown || iid == IID_ISequentialStream || iid == IID_IStream) {
            *object = static_cast<IStream *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG result = InterlockedDecrement(&references_);
        if (!result) delete this;
        return result;
    }
    HRESULT STDMETHODCALLTYPE Read(void *buffer, ULONG bytes, ULONG *read) override {
        if (read) *read = 0;
        if (!buffer && bytes) return STG_E_INVALIDPOINTER;
        const ULONG wanted = static_cast<ULONG>(std::min<uint64_t>(bytes, length_ - position_));
        DWORD count = 0;
        if (wanted && (!ReadFile(file_, buffer, wanted, &count, nullptr)))
            return HRESULT_FROM_WIN32(GetLastError());
        position_ += count;
        if (read) *read = count;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Write(const void *, ULONG, ULONG *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER offset, DWORD origin,
                                   ULARGE_INTEGER *new_position) override {
        int64_t base = 0;
        if (origin == STREAM_SEEK_CUR) base = static_cast<int64_t>(position_);
        else if (origin == STREAM_SEEK_END) base = static_cast<int64_t>(length_);
        else if (origin != STREAM_SEEK_SET) return STG_E_INVALIDPARAMETER;
        const int64_t next = base + offset.QuadPart;
        if (next < 0 || static_cast<uint64_t>(next) > length_)
            return STG_E_INVALIDFUNCTION;
        LARGE_INTEGER target;
        target.QuadPart = static_cast<LONGLONG>(start_ + next);
        if (!SetFilePointerEx(file_, target, nullptr, FILE_BEGIN))
            return HRESULT_FROM_WIN32(GetLastError());
        position_ = static_cast<uint64_t>(next);
        if (new_position) new_position->QuadPart = position_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE CopyTo(IStream *, ULARGE_INTEGER, ULARGE_INTEGER *,
                                     ULARGE_INTEGER *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Revert() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Stat(STATSTG *stat, DWORD) override {
        if (!stat) return STG_E_INVALIDPOINTER;
        ZeroMemory(stat, sizeof(*stat));
        stat->type = STGTY_STREAM;
        stat->cbSize.QuadPart = length_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Clone(IStream **) override { return E_NOTIMPL; }

private:
    HANDLE file_ = INVALID_HANDLE_VALUE;
    LONG references_ = 1;
    uint64_t start_ = 0;
    uint64_t length_ = 0;
    uint64_t position_ = 0;
};

struct Host {
    HWND window = nullptr;
    fs::path root;
    fs::path storage;
    std::string url;
    std::string storage_json = "{}";
    std::string initial_script;
    std::deque<std::string> events;
    EventRegistrationToken message_token{};
    bool closed = false;
    bool opening = true;
    bool paused = false;
    bool controls = false;
    ComPtr<ICoreWebView2Environment> environment;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    EventRegistrationToken resource_token{};
    EventRegistrationToken navigation_token{};
    EventRegistrationToken dialog_token{};
    EventRegistrationToken completed_token{};
    EventRegistrationToken new_window_token{};
    EventRegistrationToken process_failed_token{};

    ~Host() {
        if (webview) {
            webview->remove_WebMessageReceived(message_token);
            webview->remove_WebResourceRequested(resource_token);
            webview->remove_NavigationStarting(navigation_token);
            webview->remove_ScriptDialogOpening(dialog_token);
            webview->remove_NavigationCompleted(completed_token);
            webview->remove_NewWindowRequested(new_window_token);
            webview->remove_ProcessFailed(process_failed_token);
        }
        if (controller) controller->Close();
        webview.Reset();
        controller.Reset();
        environment.Reset();
    }

    void Push(const std::string &type, const std::string &json_value) {
        if (closed) return;
        if (events.size() >= 128) events.pop_front();
        events.push_back("{\"type\":" + Quote(type) + ",\"value\":" + json_value + "}");
    }

    void Fail(const std::string &context, HRESULT hr) {
        Push("error", Quote(ErrorMessage(context, hr)));
    }

    void ApplyState() {
        if (closed || !webview) return;
        const std::string script =
            "window.AetherTyranoHost?.pause(" + std::string(paused ? "true" : "false") +
            ");window.AetherTyranoHost?.controls(" + (controls ? "true" : "false") + ")";
        webview->ExecuteScript(Widen(script).c_str(),
            Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                [](HRESULT, LPCWSTR) -> HRESULT { return S_OK; }).Get());
    }

    std::string Persist(const std::string &json) {
        std::string canonical;
        std::string error;
        if (json.size() > kMaxStorageBytes ||
            !ValidateStorage(json, canonical, error))
            return error.empty() ? "Game storage is too large" : error;
        std::error_code ec;
        const fs::path temporary = storage.parent_path() /
            (storage.filename().wstring() + L".tmp-" + std::to_wstring(GetCurrentProcessId()));
        {
            std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
            output.write(canonical.data(), canonical.size());
            output.flush();
            if (!output) {
                output.close();
                DeleteFileW(temporary.c_str());
                return "Could not persist game storage";
            }
        }
        if (!MoveFileExW(temporary.c_str(), storage.c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            error = ErrorMessage("Could not persist game storage",
                HRESULT_FROM_WIN32(GetLastError()));
            DeleteFileW(temporary.c_str());
            return error;
        }
        storage_json = canonical;
        Push("storage_saved", "true");
        return {};
    }

    void Respond(ICoreWebView2WebResourceRequestedEventArgs *args, IStream *stream,
                 int status, const std::wstring &reason,
                 const std::wstring &headers) {
        ComPtr<ICoreWebView2WebResourceResponse> response;
        const HRESULT hr = environment->CreateWebResourceResponse(
            stream, status, reason.c_str(), headers.c_str(), &response);
        if (SUCCEEDED(hr)) args->put_Response(response.Get());
        if (stream) stream->Release();
    }

    void EmptyResponse(ICoreWebView2WebResourceRequestedEventArgs *args,
                       int status, const std::wstring &reason,
                       const std::wstring &extra = L"") {
        Respond(args, nullptr, status, reason,
            L"Content-Length: 0\r\nCache-Control: no-store\r\n" + extra);
    }

    void ResourceRequested(ICoreWebView2WebResourceRequestedEventArgs *args) {
        ComPtr<ICoreWebView2WebResourceRequest> request;
        if (FAILED(args->get_Request(&request)) || !request) return;
        wchar_t *uri_value = nullptr;
        wchar_t *method_value = nullptr;
        request->get_Uri(&uri_value);
        request->get_Method(&method_value);
        const std::wstring uri = uri_value ? uri_value : L"";
        const std::wstring method = method_value ? method_value : L"GET";
        CoTaskMemFree(uri_value);
        CoTaskMemFree(method_value);
        if (uri.rfind(kOrigin, 0) != 0) {
            EmptyResponse(args, 403, L"Forbidden");
            return;
        }
        if (method != L"GET" && method != L"HEAD") {
            EmptyResponse(args, 405, L"Method Not Allowed");
            return;
        }
        const std::string encoded = Narrow(uri.c_str() + wcslen(kOrigin));
        const size_t query = encoded.find_first_of("?#");
        std::string relative;
        if (!PercentDecode(encoded.substr(0, query), relative)) {
            EmptyResponse(args, 403, L"Forbidden");
            return;
        }
        std::error_code ec;
        const fs::path file = fs::weakly_canonical(root / fs::path(Widen(relative)), ec);
        if (ec || (!InsideRoot(root, file) && file != root)) {
            EmptyResponse(args, 403, L"Forbidden");
            return;
        }
        if (!fs::is_regular_file(file, ec) || ec) {
            EmptyResponse(args, 404, L"Not Found");
            return;
        }
        HANDLE handle = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ,
            nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (handle == INVALID_HANDLE_VALUE) {
            EmptyResponse(args, 404, L"Not Found");
            return;
        }
        LARGE_INTEGER size{};
        if (!GetFileSizeEx(handle, &size) || size.QuadPart < 0) {
            CloseHandle(handle);
            EmptyResponse(args, 404, L"Not Found");
            return;
        }
        const uint64_t total = static_cast<uint64_t>(size.QuadPart);
        uint64_t start = 0;
        uint64_t end = total;
        int status = 200;
        std::wstring range;
        ComPtr<ICoreWebView2HttpRequestHeaders> request_headers;
        if (SUCCEEDED(request->get_Headers(&request_headers)) && request_headers) {
            wchar_t *value = nullptr;
            if (SUCCEEDED(request_headers->GetHeader(L"Range", &value)) && value) {
                range = value;
                CoTaskMemFree(value);
            }
        }
        if (range.rfind(L"bytes=", 0) == 0) {
            const std::wstring spec = range.substr(6);
            const size_t dash = spec.find(L'-');
            auto number = [](const std::wstring &text, uint64_t &result) {
                if (text.empty() || text.size() > 20 ||
                    text.find_first_not_of(L"0123456789") != std::wstring::npos)
                    return false;
                result = 0;
                for (const wchar_t c : text) {
                    const unsigned digit = c - L'0';
                    if (result > (UINT64_MAX - digit) / 10) return false;
                    result = result * 10 + digit;
                }
                return true;
            };
            uint64_t first = 0, last = 0;
            const bool has_first = dash != std::wstring::npos && dash > 0;
            const bool has_last = dash != std::wstring::npos && dash + 1 < spec.size();
            const bool valid = dash != std::wstring::npos &&
                spec.find(L',') == std::wstring::npos &&
                spec.find(L'-', dash + 1) == std::wstring::npos &&
                (has_first || has_last) &&
                (!has_first || number(spec.substr(0, dash), first)) &&
                (!has_last || number(spec.substr(dash + 1), last));
            if (!valid) {
                status = 416;
            } else if (has_first) {
                start = first;
                end = has_last && last != UINT64_MAX ? std::min<uint64_t>(total, last + 1) : total;
                status = start < end && start < total ? 206 : 416;
            } else {
                start = total > last ? total - last : 0;
                end = total;
                status = last > 0 && start < end ? 206 : 416;
            }
        }
        if (status == 416) {
            CloseHandle(handle);
            EmptyResponse(args, status, L"Range Not Satisfiable",
                L"Content-Range: bytes */" + std::to_wstring(total) + L"\r\n");
            return;
        }
        const uint64_t length = end - start;
        LARGE_INTEGER offset;
        offset.QuadPart = static_cast<LONGLONG>(start);
        if (!SetFilePointerEx(handle, offset, nullptr, FILE_BEGIN)) {
            CloseHandle(handle);
            EmptyResponse(args, 404, L"Not Found");
            return;
        }
        std::wstring headers = L"Content-Type: " + MimeType(file) +
            L"\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *"
            L"\r\nAccept-Ranges: bytes\r\nContent-Length: " + std::to_wstring(length) + L"\r\n";
        if (status == 206) {
            headers += L"Content-Range: bytes " + std::to_wstring(start) + L"-" +
                std::to_wstring(end - 1) + L"/" + std::to_wstring(total) + L"\r\n";
        }
        IStream *stream = method == L"HEAD" ? nullptr : new FileRangeStream(handle, start, length);
        if (method == L"HEAD") CloseHandle(handle);
        Respond(args, stream, status, status == 206 ? L"Partial Content" : L"OK", headers);
    }

    HRESULT ScriptDialog(ICoreWebView2ScriptDialogOpeningEventArgs *args) {
        COREWEBVIEW2_SCRIPT_DIALOG_KIND kind;
        if (FAILED(args->get_Kind(&kind)) || kind != COREWEBVIEW2_SCRIPT_DIALOG_KIND_PROMPT)
            return S_OK;
        wchar_t *uri_value = nullptr;
        wchar_t *message_value = nullptr;
        wchar_t *default_value = nullptr;
        args->get_Uri(&uri_value);
        args->get_Message(&message_value);
        args->get_DefaultText(&default_value);
        const std::wstring uri = uri_value ? uri_value : L"";
        const std::wstring message = message_value ? message_value : L"";
        const std::string text = default_value ? Narrow(default_value) : "";
        CoTaskMemFree(uri_value);
        CoTaskMemFree(message_value);
        CoTaskMemFree(default_value);
        if (uri.rfind(kOrigin, 0) != 0) return S_OK;
        if (message == L"__AETHER_TYRANO_STORAGE_READ__") {
            const std::wstring value = Widen(storage_json);
            args->put_ResultText(value.c_str());
            return args->Accept();
        }
        if (message == L"__AETHER_TYRANO_STORAGE__") {
            const std::string error = Persist(text);
            if (error.empty()) return args->Accept();
            args->put_ResultText(Widen(error).c_str());
            return args->Accept();
        }
        if (message != L"__AETHER_TYRANO_EVENT__") return S_OK;
        const std::string prefix = "{\"type\":";
        if (text.rfind(prefix, 0) == 0) {
            size_t at = prefix.size();
            std::string name;
            if (ParseString(text, at, name) &&
                (name == "ready" || name == "log" || name == "close")) {
                events.push_back(text);
                while (events.size() > 128) events.pop_front();
                if (name == "ready") ApplyState();
            }
        }
        return args->Accept();
    }

    void FinishOpening() { opening = false; }

    void Initialize(ComPtr<ICoreWebView2Environment> created_environment) {
        if (closed) { FinishOpening(); return; }
        environment = created_environment;
        auto handler = Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [this](HRESULT result, ICoreWebView2Controller *created_controller) -> HRESULT {
                if (closed) { FinishOpening(); return S_OK; }
                if (FAILED(result) || !created_controller) {
                    opening = false;
                    Fail("Could not create the WebView2 controller", result);
                    return S_OK;
                }
                controller = created_controller;
                if (FAILED(controller->get_CoreWebView2(&webview)) || !webview) {
                    opening = false;
                    Push("error", Quote("Could not access the WebView2 browser"));
                    return S_OK;
                }
                ComPtr<ICoreWebView2Settings> settings;
                webview->get_Settings(&settings);
                if (settings) {
                    settings->put_IsScriptEnabled(TRUE);
                    settings->put_AreDefaultScriptDialogsEnabled(TRUE);
                    settings->put_AreDefaultContextMenusEnabled(FALSE);
                    settings->put_AreDevToolsEnabled(FALSE);
                    settings->put_IsStatusBarEnabled(FALSE);
                    settings->put_IsZoomControlEnabled(FALSE);
                }
                webview->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
                webview->add_WebResourceRequested(
                    Callback<ICoreWebView2WebResourceRequestedEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) -> HRESULT {
                            if (!closed) ResourceRequested(args);
                            return S_OK;
                        }).Get(), &resource_token);
                webview->add_NavigationStarting(
                    Callback<ICoreWebView2NavigationStartingEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                            wchar_t *value = nullptr;
                            args->get_Uri(&value);
                            const std::wstring uri = value ? value : L"";
                            CoTaskMemFree(value);
                            if (uri.rfind(kOrigin, 0) != 0 && uri != L"about:blank") {
                                args->put_Cancel(TRUE);
                                Push("log", Quote("External page navigation is unavailable in this prototype"));
                            }
                            return S_OK;
                        }).Get(), &navigation_token);
                webview->add_WebMessageReceived(
                    Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                            wchar_t *source_value = nullptr;
                            wchar_t *json_value = nullptr;
                            args->get_Source(&source_value);
                            args->get_WebMessageAsJson(&json_value);
                            const std::wstring source = source_value ? source_value : L"";
                            const std::string json = json_value ? Narrow(json_value) : "";
                            CoTaskMemFree(source_value);
                            CoTaskMemFree(json_value);
                            if (closed || source.rfind(kOrigin, 0) != 0) return S_OK;
                            const std::string prefix = "{\"type\":";
                            if (json.rfind(prefix, 0) != 0) return S_OK;
                            size_t at = prefix.size();
                            std::string name;
                            if (!ParseString(json, at, name)) return S_OK;
                            if (name == "storage_sync") {
                                const size_t marker = json.find(",\"value\":", at);
                                if (marker == std::string::npos) return S_OK;
                                at = marker + 9;
                                std::string snapshot;
                                if (ParseString(json, at, snapshot)) Persist(snapshot);
                                return S_OK;
                            }
                            if (name != "ready" && name != "log" && name != "close") return S_OK;
                            events.push_back(json);
                            while (events.size() > 128) events.pop_front();
                            if (name == "ready") ApplyState();
                            return S_OK;
                        }).Get(), &message_token);
                webview->add_ScriptDialogOpening(
                    Callback<ICoreWebView2ScriptDialogOpeningEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2ScriptDialogOpeningEventArgs *args) -> HRESULT {
                            return closed ? S_OK : ScriptDialog(args);
                        }).Get(), &dialog_token);
                webview->add_NavigationCompleted(
                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                            BOOL success = FALSE;
                            args->get_IsSuccess(&success);
                            if (success) Push("document_loaded", "true");
                            else {
                                COREWEBVIEW2_WEB_ERROR_STATUS status;
                                args->get_WebErrorStatus(&status);
                                if (status != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED)
                                    Push("error", Quote("The TyranoScript page failed to load"));
                            }
                            return S_OK;
                        }).Get(), &completed_token);
                webview->add_NewWindowRequested(
                    Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                        [](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
                            args->put_Handled(TRUE);
                            return S_OK;
                        }).Get(), &new_window_token);
                webview->add_ProcessFailed(
                    Callback<ICoreWebView2ProcessFailedEventHandler>(
                        [this](ICoreWebView2 *, ICoreWebView2ProcessFailedEventArgs *) -> HRESULT {
                            Push("error", Quote("The TyranoScript web process stopped"));
                            return S_OK;
                        }).Get(), &process_failed_token);
                const HRESULT script_result = webview->AddScriptToExecuteOnDocumentCreated(
                    Widen(initial_script).c_str(), nullptr);
                if (FAILED(script_result)) {
                    opening = false;
                    Fail("Could not install the TyranoScript host", script_result);
                    return S_OK;
                }
                RECT bounds{0, 0, 1, 1};
                controller->put_Bounds(bounds);
                controller->put_IsVisible(TRUE);
                const HRESULT navigation_result = webview->Navigate(Widen(url).c_str());
                opening = false;
                if (FAILED(navigation_result)) Fail("Could not open the TyranoScript page", navigation_result);
                return S_OK;
            });
        ComPtr<ICoreWebView2Environment10> environment10;
        if (SUCCEEDED(environment->QueryInterface(IID_PPV_ARGS(&environment10)))) {
            ComPtr<ICoreWebView2ControllerOptions> options;
            if (SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&options))) {
                options->put_IsInPrivateModeEnabled(FALSE);
                environment10->CreateCoreWebView2ControllerWithOptions(window, options.Get(), handler.Get());
                return;
            }
        }
        environment->CreateCoreWebView2Controller(window, handler.Get());
    }
};

void Destroy(Host *host) {
    if (!host) return;
    host->closed = true;
    // WebView2 completion handlers capture this object. They are guaranteed to
    // run when asynchronous creation finishes, including after a Godot close.
    // Keep the small host state until those completions have released it; all
    // browser resources and native handlers are detached immediately here.
    if (host->webview) {
        host->webview->remove_WebMessageReceived(host->message_token);
        host->webview->remove_WebResourceRequested(host->resource_token);
        host->webview->remove_NavigationStarting(host->navigation_token);
        host->webview->remove_ScriptDialogOpening(host->dialog_token);
        host->webview->remove_NavigationCompleted(host->completed_token);
        host->webview->remove_NewWindowRequested(host->new_window_token);
        host->webview->remove_ProcessFailed(host->process_failed_token);
        host->webview->Stop();
    }
    if (host->controller) host->controller->Close();
    host->webview.Reset();
    host->controller.Reset();
    host->environment.Reset();
}

} // namespace

extern "C" void *aether_tyrano_open(uint64_t native_window, const char *entry_path,
                                    const char *storage_path, char **out_error) {
    if (out_error) *out_error = nullptr;
    auto fail = [&](const std::string &message) -> void * {
        if (out_error) *out_error = _strdup(message.c_str());
        return nullptr;
    };
    if (!native_window || !entry_path || !storage_path)
        return fail("A native UI-thread window and game path are required");
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE)
        return fail(ErrorMessage("Could not initialize COM", com_result));
    auto *host = new Host();
    host->window = reinterpret_cast<HWND>(native_window);
    std::error_code ec;
    const fs::path entry = fs::canonical(fs::path(Widen(entry_path)), ec);
    if (ec || !fs::is_regular_file(entry, ec)) {
        delete host;
        return fail("TyranoScript index.html was not found");
    }
    host->root = entry.parent_path();
    host->storage = fs::absolute(fs::path(Widen(storage_path)), ec);
    if (ec) { delete host; return fail("The game storage path is invalid"); }
    fs::create_directories(host->storage.parent_path(), ec);
    if (ec) { delete host; return fail("Could not create the game storage folder"); }
    if (fs::exists(host->storage, ec)) {
        std::string json;
        std::string error;
        if (!ReadStorageFile(host->storage, json, error) ||
            !ValidateStorage(json, host->storage_json, error)) {
            delete host;
            return fail(error);
        }
    }
    host->initial_script = kAetherTyranoHostScript;
    const std::string marker = "__AETHER_STORAGE__";
    const size_t replacement = host->initial_script.find(marker);
    if (replacement == std::string::npos) { delete host; return fail("The TyranoScript host script is invalid"); }
    host->initial_script.replace(replacement, marker.size(), host->storage_json);
    host->initial_script =
        "window.addEventListener('error',e=>window.chrome?.webview?.postMessage({type:'log',value:e.message+' @ '+e.filename+':'+e.lineno+':'+e.colno}));" +
        host->initial_script;
    host->url = kOriginUtf8 + PercentEncode(Narrow(entry.filename().c_str()));
    const fs::path profile = host->storage.parent_path() / L"webview2";
    fs::create_directories(profile, ec);
    if (ec) { delete host; return fail("Could not create the WebView2 profile folder"); }
    auto environment_handler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [host](HRESULT result, ICoreWebView2Environment *environment) -> HRESULT {
            if (host->closed) { host->FinishOpening(); return S_OK; }
            if (FAILED(result) || !environment) {
                host->opening = false;
                host->Fail("Could not create WebView2; install the Microsoft Edge WebView2 Runtime", result);
                return S_OK;
            }
            host->Initialize(environment);
            return S_OK;
        });
    const HRESULT result = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, profile.c_str(), nullptr, environment_handler.Get());
    if (FAILED(result)) {
        delete host;
        return fail(ErrorMessage("Could not start WebView2; install the Microsoft Edge WebView2 Runtime", result));
    }
    return host;
}

extern "C" void aether_tyrano_close(void *handle) { Destroy(static_cast<Host *>(handle)); }

extern "C" void aether_tyrano_rect(void *handle, double x, double y,
                                   double width, double height) {
    auto *host = static_cast<Host *>(handle);
    if (!host || host->closed || !host->controller || !host->window) return;
    RECT client{};
    GetClientRect(host->window, &client);
    RECT bounds{
        static_cast<LONG>(x * client.right),
        static_cast<LONG>(y * client.bottom),
        static_cast<LONG>((x + width) * client.right),
        static_cast<LONG>((y + height) * client.bottom),
    };
    host->controller->put_Bounds(bounds);
}

extern "C" void aether_tyrano_pause(void *handle, bool paused) {
    auto *host = static_cast<Host *>(handle);
    if (!host || host->closed) return;
    host->paused = paused;
    host->ApplyState();
}

extern "C" void aether_tyrano_controls(void *handle, bool visible) {
    auto *host = static_cast<Host *>(handle);
    if (!host || host->closed) return;
    host->controls = visible;
    host->ApplyState();
}

extern "C" void aether_tyrano_evaluate(void *handle, const char *script) {
    auto *host = static_cast<Host *>(handle);
    if (!host || host->closed || !host->webview || !script) return;
    host->webview->ExecuteScript(Widen(script).c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [host](HRESULT result, LPCWSTR json) -> HRESULT {
                if (host->closed) return S_OK;
                if (FAILED(result)) host->Fail("evaluation_error", result);
                else host->Push("evaluation", json && *json ? Narrow(json) : "null");
                return S_OK;
            }).Get());
}

extern "C" char *aether_tyrano_poll(void *handle) {
    auto *host = static_cast<Host *>(handle);
    if (!host || host->closed || host->events.empty()) return nullptr;
    const std::string event = host->events.front();
    host->events.pop_front();
    return _strdup(event.c_str());
}

extern "C" void aether_tyrano_free_string(char *value) { free(value); }
