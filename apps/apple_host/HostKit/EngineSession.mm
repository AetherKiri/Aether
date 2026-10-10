#import "EngineSession.h"

#include "engine_api.h"

#include <vector>

namespace {

NSError *EngineError(engine_handle_t handle, NSString *fallback) {
    NSString *message = fallback;
    if (handle != nullptr) {
        const char *last = engine_get_last_error(handle);
        if (last != nullptr && last[0] != '\0') {
            message = [NSString stringWithUTF8String:last];
        }
    }
    return [NSError errorWithDomain:@"AetherEngineSession"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

}  // namespace

@implementation AetherEngineSession {
    engine_handle_t _handle;
    std::vector<uint8_t> _frameBuffer;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _handle = nullptr;
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)initializeWithWritablePath:(NSString *)writablePath
                         cachePath:(NSString *)cachePath
                             error:(NSError **)error {
    if (_handle != nullptr) {
        return YES;
    }
    engine_create_desc_t desc{};
    desc.struct_size = sizeof(desc);
    desc.api_version = ENGINE_API_VERSION;
    desc.writable_path_utf8 = writablePath.fileSystemRepresentation;
    desc.cache_path_utf8 = cachePath.fileSystemRepresentation;

    engine_handle_t handle = nullptr;
    const engine_result_t result = engine_create(&desc, &handle);
    if (result != ENGINE_RESULT_OK || handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(handle, @"engine_create failed");
        }
        return NO;
    }
    _handle = handle;
    return YES;
}

- (BOOL)setOption:(NSString *)key value:(NSString *)value error:(NSError **)error {
    if (_handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(nullptr, @"engine is not initialized");
        }
        return NO;
    }
    engine_option_t option{};
    option.key_utf8 = key.UTF8String;
    option.value_utf8 = value.UTF8String;
    const engine_result_t result = engine_set_option(_handle, &option);
    if (result != ENGINE_RESULT_OK) {
        if (error != nullptr) {
            *error = EngineError(_handle, @"engine_set_option failed");
        }
        return NO;
    }
    return YES;
}

- (uint32_t)engineAPIVersion {
    return ENGINE_API_VERSION;
}

- (BOOL)openGameAtPath:(NSString *)gamePath error:(NSError **)error {
    if (_handle == nullptr) {
        if (error != nullptr) {
            *error = EngineError(nullptr, @"engine is not initialized");
        }
        return NO;
    }
    const engine_result_t result =
        engine_open_game(_handle, gamePath.fileSystemRepresentation, nullptr);
    if (result != ENGINE_RESULT_OK) {
        if (error != nullptr) {
            *error = EngineError(_handle, @"engine_open_game failed");
        }
        return NO;
    }
    return YES;
}

- (uint32_t)startupState {
    if (_handle == nullptr) {
        return ENGINE_STARTUP_STATE_IDLE;
    }
    uint32_t state = ENGINE_STARTUP_STATE_IDLE;
    if (engine_get_startup_state(_handle, &state) != ENGINE_RESULT_OK) {
        return ENGINE_STARTUP_STATE_IDLE;
    }
    return state;
}

- (void)tickWithDeltaMS:(uint32_t)deltaMS {
    if (_handle == nullptr) {
        return;
    }
    engine_tick(_handle, deltaMS);
}

- (void)pollPlatformRequests:(void (^)(NSString *, NSString *))handler {
    if (_handle == nullptr) {
        return;
    }
    char operation[256] = {0};
    char argument[4096] = {0};
    for (size_t count = 0; count < 256; ++count) {
        uint32_t available = 0;
        const engine_result_t result = engine_poll_platform_request(
            _handle, operation, sizeof(operation), argument, sizeof(argument),
            &available);
        if (result != ENGINE_RESULT_OK || available == 0) {
            return;
        }
        handler([NSString stringWithUTF8String:operation],
                [NSString stringWithUTF8String:argument]);
    }
}

- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED {
    if (_handle == nullptr) {
        return nil;
    }
    engine_frame_desc_t desc{};
    desc.struct_size = sizeof(desc);
    if (engine_get_frame_desc(_handle, &desc) != ENGINE_RESULT_OK ||
        desc.width == 0 || desc.height == 0 ||
        desc.pixel_format != ENGINE_PIXEL_FORMAT_RGBA8888) {
        return nil;
    }
    const size_t byteCount =
        static_cast<size_t>(desc.stride_bytes) * desc.height;
    if (_frameBuffer.size() != byteCount) {
        _frameBuffer.resize(byteCount);
    }
    if (engine_read_frame_rgba(_handle, _frameBuffer.data(), _frameBuffer.size()) !=
        ENGINE_RESULT_OK) {
        return nil;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == nullptr) {
        return nil;
    }
    CGContextRef context = CGBitmapContextCreate(
        _frameBuffer.data(), desc.width, desc.height, 8, desc.stride_bytes,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(colorSpace);
    if (context == nullptr) {
        return nil;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

- (void)shutdown {
    if (_handle != nullptr) {
        engine_destroy(_handle);
        _handle = nullptr;
    }
}

@end
