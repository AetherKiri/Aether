#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Process-wide engine callback table. Initialize before creating/opening an
// engine; callbacks and token ownership remain installed for process lifetime.
BOOL AetherMetalBridgeInitialize(NSError **error);
// Returns an immutable GPU snapshot suitable for another presentation queue.
id<MTLTexture> _Nullable AetherMetalBridgeCopyTexture(uint64_t token);
BOOL AetherMetalBridgeReadTexture(uint64_t token, void *pixels, size_t capacity, uint32_t stride);
NSString *AetherMetalBridgeDiagnostics(void);

NS_ASSUME_NONNULL_END
