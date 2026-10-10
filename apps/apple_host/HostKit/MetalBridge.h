#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif

// Process-wide engine callback table. Initialize before creating/opening an
// engine; callbacks and token ownership remain installed for process lifetime.
BOOL AetherMetalBridgeInitialize(NSError **error);
// Lazily creates the shared device/queue without compiling engine shaders.
id<MTLCommandQueue> _Nullable AetherMetalBridgeCommandQueue(void);
// Stop producers before draining the shared queue and snapshot callbacks.
BOOL AetherMetalBridgeDrain(void);
// Returns an immutable GPU snapshot suitable for another presentation queue.
id<MTLTexture> _Nullable AetherMetalBridgeCopyTexture(uint64_t token);
// GPU consumers must submit on AetherMetalBridgeCommandQueue; CPU access must
// wait for a subsequent command on that queue to complete.
id<MTLTexture> _Nullable AetherMetalBridgeCopyPresentationTexture(uint64_t token);
BOOL AetherMetalBridgeReadTexture(uint64_t token, void *pixels, size_t capacity, uint32_t stride);
NSString *AetherMetalBridgeDiagnostics(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
