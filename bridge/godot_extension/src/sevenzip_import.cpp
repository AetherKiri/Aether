#include "sevenzip_import.h"

#if defined(AETHERKIRI_WITH_7ZIP_SDK)

#include <7zip/Archive/IArchive.h>
#include <7zip/Common/FileStreams.h>
#include <Common/MyCom.h>
#include <Common/StringConvert.h>
#include <7zip/IPassword.h>
#include <Windows/PropVariant.h>
#include <Windows/PropVariantConv.h>

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace godot {
namespace {
namespace fs = std::filesystem;

constexpr UInt32 kAllItems = static_cast<UInt32>(-1);
constexpr UInt64 kMaxOutputBytes = 32ull * 1024ull * 1024ull * 1024ull;

// These entry points are supplied by the statically linked 7-Zip archive
// bundle.  They are the same ABI used by 7z.dll, but no DLL is loaded here.
extern "C" HRESULT CreateArchiver(const GUID *, const GUID *, void **);
extern "C" HRESULT GetNumberOfFormats(UInt32 *);
extern "C" HRESULT GetHandlerProperty2(UInt32, PROPID, PROPVARIANT *);

struct Passwords {
    std::vector<UString> values;
};

Passwords ReadPasswords(const std::string &db, const std::string &explicit_password) {
    Passwords result;
    auto add = [&result](const UString &password) {
        for (const UString &existing : result.values) {
            if (existing == password) return;
        }
        result.values.push_back(password);
    };
    if (!explicit_password.empty()) {
        add(MultiByteToUnicodeString(explicit_password.c_str(), CP_UTF8));
    }
    if (!db.empty()) {
        std::ifstream stream(db, std::ios::binary);
        std::string line;
        while (std::getline(stream, line)) {
            while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
                line.pop_back();
            if (!line.empty()) add(MultiByteToUnicodeString(line.c_str(), CP_UTF8));
        }
    }
    // Empty passwords are valid and are deliberately tried before the
    // small compatibility list.  The list covers common game distributions
    // without making a password-protected archive an unbounded brute-force
    // operation.
    add(UString());
    static const char *const common[] = {
        "123456", "123456789", "password", "galgame", "www", "game", "secret"};
    for (const char *candidate : common)
        add(MultiByteToUnicodeString(candidate, CP_UTF8));
    return result;
}

bool SafePath(const UString &raw, fs::path &relative) {
    if (raw.IsEmpty()) return false;
    const AString utf8_value = UnicodeStringToMultiByte(raw, CP_UTF8);
    const std::string utf8 = utf8_value.Ptr();
    std::string normalized = utf8;
    std::replace(normalized.begin(), normalized.end(), '\\', '/');
    const fs::path raw_path = fs::u8path(normalized);
    for (const fs::path &part : raw_path) {
        if (part == "..") return false;
    }
    relative = raw_path.lexically_normal();
    if (relative.empty() || relative.is_absolute() || relative.has_root_name() ||
        relative.has_root_directory()) return false;
    for (const fs::path &part : relative) {
        if (part == ".." || part == ".") return false;
    }
    return true;
}

FString SdkPath(const std::string &utf8) {
    return us2fs(MultiByteToUnicodeString(utf8.c_str(), CP_UTF8));
}

class OpenCallback final : public IArchiveOpenCallback,
                           public IArchiveOpenVolumeCallback,
                           public ICryptoGetTextPassword,
                           public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, IArchiveOpenVolumeCallback,
                        ICryptoGetTextPassword)
public:
    OpenCallback(const UString &password, const std::string &input_path)
        : password_(password),
          input_directory_(fs::u8path(input_path).parent_path()) {}

    UString password_;

private:
    fs::path input_directory_;
};

Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *)) {
    return S_OK;
}

Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) {
    return S_OK;
}

Z7_COM7F_IMF(OpenCallback::GetProperty(PROPID, PROPVARIANT *value)) {
    if (value == nullptr) return E_INVALIDARG;
    NWindows::NCOM::PropVariant_Clear(value);
    return S_OK;
}

Z7_COM7F_IMF(OpenCallback::GetStream(const wchar_t *name, IInStream **stream)) {
    if (name == nullptr || stream == nullptr) return E_INVALIDARG;
    *stream = nullptr;
    fs::path volume_name;
    if (!SafePath(UString(name), volume_name)) return E_INVALIDARG;
    const fs::path volume_path = input_directory_ / volume_name;
    auto *file_spec = new CInFileStream;
    CMyComPtr<IInStream> file(file_spec);
    if (!file_spec->Open(SdkPath(volume_path.u8string()))) return S_FALSE;
    *stream = file.Detach();
    return S_OK;
}

Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *password)) {
    return StringToBstr(password_, password);
}

class ExtractCallback final : public IArchiveExtractCallback,
                              public ICryptoGetTextPassword,
                              public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)

public:
    ExtractCallback(IInArchive *archive, const fs::path &root,
                    const UString &password)
        : archive_(archive), root_(root), password_(password) {}

    ~ExtractCallback() { CloseOutput(); }

    bool password_error = false;
    bool data_error = false;
    UInt64 output_bytes = 0;

private:
    CMyComPtr<IInArchive> archive_;
    fs::path root_;
    UString password_;
    COutFileStream *out_file_ = nullptr;
    CMyComPtr<ISequentialOutStream> out_stream_;

    void CloseOutput() {
        if (out_file_ != nullptr) {
            if (out_file_->ProcessedSize > kMaxOutputBytes - output_bytes)
                data_error = true;
            else
                output_bytes += out_file_->ProcessedSize;
            out_file_->Close();
            out_file_ = nullptr;
        }
        out_stream_.Release();
    }
};

Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *)) { return S_OK; }

Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index,
                                        ISequentialOutStream **out_stream,
                                        Int32 ask_mode)) {
    *out_stream = nullptr;
    CloseOutput();
    if (ask_mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;

    NWindows::NCOM::CPropVariant path_prop;
    RINOK(archive_->GetProperty(index, kpidPath, &path_prop));
    if (path_prop.vt != VT_BSTR) return S_OK;
    fs::path relative;
    if (!SafePath(path_prop.bstrVal, relative)) return E_INVALIDARG;

    NWindows::NCOM::CPropVariant dir_prop;
    RINOK(archive_->GetProperty(index, kpidIsDir, &dir_prop));
    const bool is_dir = dir_prop.vt == VT_BOOL && VARIANT_BOOLToBool(dir_prop.boolVal);
    const fs::path target = root_ / relative;
    if (is_dir) {
        std::error_code ec;
        fs::create_directories(target, ec);
        return ec ? E_FAIL : S_OK;
    }

    NWindows::NCOM::CPropVariant size_prop;
    RINOK(archive_->GetProperty(index, kpidSize, &size_prop));
    UInt64 declared_size = 0;
    if (ConvertPropVariantToUInt64(size_prop, declared_size) &&
        declared_size > kMaxOutputBytes - output_bytes)
        return E_FAIL;
    std::error_code ec;
    fs::create_directories(target.parent_path(), ec);
    if (ec) return E_FAIL;
    out_file_ = new COutFileStream;
    CMyComPtr<ISequentialOutStream> local(out_file_);
    if (!out_file_->Create_ALWAYS(SdkPath(target.u8string()))) {
        out_file_ = nullptr;
        return E_FAIL;
    }
    out_stream_ = local;
    *out_stream = local.Detach();
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 operation_result)) {
    if (operation_result == NArchive::NExtract::NOperationResult::kWrongPassword)
        password_error = true;
    else if (operation_result != NArchive::NExtract::NOperationResult::kOK)
        data_error = true;
    CloseOutput();
    return S_OK;
}

Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *password)) {
    return StringToBstr(password_, password);
}

bool TryFormat(const std::string &input, const fs::path &output,
               const UString &password, std::string &error) {
    UInt32 formats = 0;
    if (GetNumberOfFormats(&formats) != S_OK) {
        error = "7-Zip SDK did not expose archive formats";
        return false;
    }
    const FString sdk_input = SdkPath(input);
    for (UInt32 format = 0; format < formats; ++format) {
        NWindows::NCOM::CPropVariant class_prop;
        if (GetHandlerProperty2(format, NArchive::NHandlerPropID::kClassID,
                                &class_prop) != S_OK ||
            class_prop.vt != VT_BSTR ||
            SysStringByteLen(class_prop.bstrVal) != sizeof(GUID)) {
            continue;
        }
        GUID class_id = *reinterpret_cast<const GUID *>(class_prop.bstrVal);
        CMyComPtr<IInArchive> archive;
        if (CreateArchiver(&class_id, &IID_IInArchive,
                           reinterpret_cast<void **>(&archive)) != S_OK)
            continue;
        auto *file_spec = new CInFileStream;
        CMyComPtr<IInStream> file(file_spec);
        if (!file_spec->Open(sdk_input)) continue;
        auto *open_spec = new OpenCallback(password, input);
        CMyComPtr<IArchiveOpenCallback> open(open_spec);
        const UInt64 scan_limit = 1ull << 23;
        if (archive->Open(file, &scan_limit, open) != S_OK) continue;
        UInt32 item_count = 0;
        if (archive->GetNumberOfItems(&item_count) != S_OK) continue;
        UInt64 total_size = 0;
        bool paths_are_safe = true;
        for (UInt32 index = 0; index < item_count; ++index) {
            NWindows::NCOM::CPropVariant path_prop;
            if (archive->GetProperty(index, kpidPath, &path_prop) != S_OK ||
                path_prop.vt != VT_BSTR) {
                paths_are_safe = false;
                break;
            }
            fs::path relative;
            if (!SafePath(path_prop.bstrVal, relative)) {
                paths_are_safe = false;
                break;
            }
            NWindows::NCOM::CPropVariant size_prop;
            UInt64 item_size = 0;
            if (archive->GetProperty(index, kpidSize, &size_prop) != S_OK ||
                (ConvertPropVariantToUInt64(size_prop, item_size) &&
                 (item_size > kMaxOutputBytes - total_size))) {
                paths_are_safe = false;
                break;
            }
            total_size += item_size;
        }
        if (!paths_are_safe) {
            error = "archive contains an unsafe path or exceeds the output limit";
            archive->Close();
            continue;
        }
        std::error_code ec;
        if (fs::exists(output, ec)) {
            error = "archive output path already exists";
            archive->Close();
            return false;
        }
        fs::create_directories(output, ec);
        if (ec) {
            error = "cannot create archive output directory";
            return false;
        }
        auto *extract_spec = new ExtractCallback(archive, output, password);
        CMyComPtr<IArchiveExtractCallback> extract(extract_spec);
        const HRESULT result = archive->Extract(nullptr, kAllItems, 0, extract);
        archive->Close();
        if (result == S_OK && !extract_spec->password_error &&
            !extract_spec->data_error) {
            return true;
        }
        fs::remove_all(output, ec);
        if (!extract_spec->password_error)
            error = "7-Zip SDK reported an extraction error";
    }
    return false;
}

bool IsNestedArchive(const fs::path &path) {
    std::string extension = path.extension().u8string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    static const char *const supported[] = {
        ".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz", ".cab"};
    for (const char *candidate : supported) {
        if (extension == candidate) return true;
    }
    return false;
}

bool RunSevenZipImportDepth(const std::string &input_path,
                            const fs::path &output,
                            const std::string &password_db,
                            const std::string &password,
                            uint32_t depth,
                            std::string &error);

void ExtractNestedArchives(const fs::path &root,
                           const std::string &password_db,
                           const std::string &password,
                           uint32_t depth,
                           std::string &error) {
    if (depth >= 8) return;
    std::error_code ec;
    std::vector<fs::path> nested;
    for (fs::recursive_directory_iterator it(root, ec), end; it != end && !ec;
         it.increment(ec)) {
        if (it->is_regular_file(ec) && IsNestedArchive(it->path()))
            nested.push_back(it->path());
    }
    for (const fs::path &archive : nested) {
        const fs::path destination = archive.parent_path() /
            (archive.stem().u8string() + ".aether-extracted");
        std::string nested_error;
        if (RunSevenZipImportDepth(archive.u8string(), destination, password_db,
                                   password, depth + 1, nested_error)) {
            fs::remove(archive, ec);
        } else if (!nested_error.empty()) {
            error = nested_error;
        }
    }
}

bool RunSevenZipImportDepth(const std::string &input_path,
                            const fs::path &output,
                            const std::string &password_db,
                            const std::string &password,
                            uint32_t depth,
                            std::string &error) {
    if (depth >= 8) {
        error = "archive nesting depth exceeded";
        return false;
    }
    const Passwords passwords = ReadPasswords(password_db, password);
    std::error_code ec;
    if (fs::exists(output, ec)) {
        error = "archive output path already exists";
        return false;
    }
    for (size_t index = 0; index < passwords.values.size(); ++index) {
        const fs::path attempt = output.parent_path() /
            (output.filename().u8string() + ".7zip-attempt-" + std::to_string(index));
        fs::remove_all(attempt, ec);
        if (!TryFormat(input_path, attempt, passwords.values[index], error)) {
            fs::remove_all(attempt, ec);
            continue;
        }
        ExtractNestedArchives(attempt, password_db, password, depth + 1, error);
        fs::rename(attempt, output, ec);
        if (!ec) return true;
        error = "unable to finalize extracted archive";
        fs::remove_all(attempt, ec);
        return false;
    }
    if (error.empty()) error = "7-Zip SDK could not recognize or extract the archive";
    return false;
}

} // namespace

bool RunSevenZipImport(const std::string &input_path, const std::string &output_path,
                       const std::string &password_db, const std::string &password,
                       std::string &error) {
    return RunSevenZipImportDepth(input_path, fs::u8path(output_path), password_db,
                                  password, 0, error);
}

} // namespace godot

#endif
