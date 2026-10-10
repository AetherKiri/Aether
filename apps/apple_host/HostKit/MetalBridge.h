#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
// Internal frame ownership, independent of the public engine ABI. The lease
// keeps a frame stable across redraws and retains it through GPU completion.
@interface AetherMetalFrameLease : NSObject
@property(nonatomic, readonly, nullable) id<MTLTexture> texture;
@property(nonatomic, readonly) BOOL valid;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t serial;
// The render session validates queue/generation and owns submission.
- (BOOL)submitCommand:(id<MTLCommandBuffer>)command;
@end
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
// Internal native ownership boundary; zero indicates an already active session.
uint64_t AetherMetalBridgeBeginSession(void);
AetherMetalFrameLease * _Nullable AetherMetalBridgeAcquireFrame(uint64_t generation, uint64_t token, uint64_t serial);
AetherMetalFrameLease * _Nullable AetherMetalBridgeAcquirePublishedFrame(uint64_t generation);
void AetherMetalBridgeFramePublished(uint64_t token, uint32_t width,
                                     uint32_t height, uint64_t serial);
// Producers must be stopped. Retired tokens remain releasable, never presentable.
BOOL AetherMetalBridgeEndSession(uint64_t generation);
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
