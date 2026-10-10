#import "MetalBridge.h"
#import <CoreVideo/CoreVideo.h>
#include "engine_gpu_bridge.h"
#include "MetalBridgeShaders.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <chrono>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
struct ExternalOwner {
    CVPixelBufferRef pixel = nullptr;
    CVMetalTextureRef wrapper = nullptr;
    ~ExternalOwner() {
        if (wrapper) CFRelease(wrapper);
        if (pixel) CFRelease(pixel);
    }
};
struct Record {
    id<MTLTexture> texture;
    std::shared_ptr<ExternalOwner> external;
};
struct ReadRequest {
    id<MTLTexture> texture;
    id<MTLCommandBuffer> command;
    bool accounted = false;
};
struct State {
    std::recursive_mutex mutex;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> library;
    id<MTLCommandBuffer> pending;
    std::thread::id pendingThread;
    CVMetalTextureCacheRef cache = nullptr;
    std::map<std::string, id<MTLComputePipelineState>> pipelines;
    std::map<uint64_t, Record> textures;
    std::map<uint64_t, ReadRequest> reads;
    uint64_t next = 1, operations = 0, failures = 0;
    uint64_t readsBegun=0, readsPending=0, readsCompleted=0, readsCancelled=0;
    uint64_t presentationSnapshots=0;
    double presentationSnapshotMS=0, presentationSnapshotMaxMS=0;
    NSString *lastError = @"";
    ~State() { if (cache) CFRelease(cache); }
};
State &S() { static State state; return state; }
using Lock = std::lock_guard<std::recursive_mutex>;
using Params = std::array<int32_t, 12>;
thread_local std::vector<uint64_t> batches;

bool Finish(id<MTLCommandBuffer> command) {
    if (!command) return false;
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        ++S().failures;
        S().lastError = command.error.localizedDescription ?: @"Metal command did not complete";
        return false;
    }
    ++S().operations;
    return true;
}
bool FlushPending() {
    id<MTLCommandBuffer> command = S().pending;
    S().pending = nil;
    return command ? Finish(command) : true;
}
id<MTLCommandBuffer> WorkCommand() {
    if (S().pending && (batches.empty() || S().pendingThread != std::this_thread::get_id())) {
        if (!FlushPending()) return nil;
    }
    if (batches.empty()) return [S().queue commandBuffer];
    if (!S().pending) {
        S().pending = [S().queue commandBuffer];
        S().pendingThread = std::this_thread::get_id();
    }
    return S().pending;
}
bool SubmitWork(id<MTLCommandBuffer> command) {
    // Batch callbacks promise ordered encoding; completion is checked at the
    // outer end, readback, CPU write or presentation snapshot boundary.
    if (!command) return false;
    return command == S().pending ? true : Finish(command);
}
id<MTLTexture> Texture(uint64_t token) {
    auto found = S().textures.find(token);
    return found == S().textures.end() ? nil : found->second.texture;
}
id<MTLTexture> Allocate(uint32_t width, uint32_t height, MTLPixelFormat format = MTLPixelFormatRGBA8Unorm) {
    if (!width || !height || width > 16384 || height > 16384) return nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [S().device newTextureWithDescriptor:desc];
}
id<MTLTexture> Snapshot(id<MTLTexture> source) {
    if (!source) return nil;
    id<MTLTexture> copy = Allocate((uint32_t)source.width, (uint32_t)source.height, source.pixelFormat);
    if (!copy) return nil;
    // Append the copy after pending writes, avoiding a separate submit/wait.
    // The bridge mutex excludes concurrent encoding during this boundary.
    id<MTLCommandBuffer> command = S().pending ?: [S().queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!encoder) return nil;
    [encoder copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(source.width, source.height, 1) toTexture:copy
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];
    if (command == S().pending) S().pending = nil;
    return Finish(command) ? copy : nil;
}
bool Valid(id<MTLTexture> texture, const tTVPRect *r) {
    return texture && r && r->left >= 0 && r->top >= 0 &&
        r->right > r->left && r->bottom > r->top &&
        r->right <= (int)texture.width && r->bottom <= (int)texture.height;
}
tTVPRect Clipped(id<MTLTexture> texture, const tTVPRect *r) {
    if (!texture) return tTVPRect(0, 0, 0, 0);
    return r ? tTVPRect(std::clamp(r->left, 0, (int)texture.width),
        std::clamp(r->top, 0, (int)texture.height),
        std::clamp(r->right, 0, (int)texture.width),
        std::clamp(r->bottom, 0, (int)texture.height)) :
        tTVPRect(0, 0, (int)texture.width, (int)texture.height);
}
bool Compute(const char *kernel, Params p,
             std::initializer_list<std::pair<unsigned, id<MTLTexture>>> textures,
             const std::vector<float> &vertices = {}) {
    auto found = S().pipelines.find(kernel);
    if (found == S().pipelines.end() || p[4] <= 0 || p[5] <= 0) return false;
    for (auto item : textures) if (!item.second) return false;
    id<MTLCommandBuffer> command = WorkCommand();
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    [encoder setComputePipelineState:found->second];
    for (auto item : textures) [encoder setTexture:item.second atIndex:item.first];
    [encoder setBytes:p.data() length:sizeof(p) atIndex:1];
    id<MTLBuffer> buffer = nil;
    if (!vertices.empty()) {
        buffer = [S().device newBufferWithBytes:vertices.data() length:vertices.size() * sizeof(float)
            options:MTLResourceStorageModeShared];
        if (!buffer) { [encoder endEncoding]; return false; }
        [encoder setBuffer:buffer offset:0 atIndex:0];
    }
    [encoder dispatchThreads:MTLSizeMake(p[4], p[5], 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding];
    return SubmitWork(command);
}
Params RectParams(const tTVPRect &dst, const tTVPRect &src, uint32_t mode, int opacity, uint32_t color) {
    return {dst.left, dst.top, src.left, src.top, dst.get_width(), dst.get_height(),
        (int32_t)mode, std::clamp(opacity, 0, 255), (int32_t)(color & 255),
        (int32_t)((color >> 8) & 255), (int32_t)((color >> 16) & 255), (int32_t)(color >> 24)};
}
uint64_t Create(uint32_t width, uint32_t height, const void *pixels, uint32_t stride) {
    Lock lock(S().mutex);
    if (pixels && stride < (uint64_t)width * 4) return 0;
    id<MTLTexture> texture = Allocate(width, height);
    if (!texture) return 0;
    @autoreleasepool {
        if (pixels) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
                withBytes:pixels bytesPerRow:stride];
        } else {
            // Creation must have defined transparent contents.
            std::vector<uint8_t> zeros((size_t)width * 4, 0);
            for (uint32_t y = 0; y < height; ++y)
                [texture replaceRegion:MTLRegionMake2D(0, y, width, 1) mipmapLevel:0
                    withBytes:zeros.data() bytesPerRow:width * 4];
        }
    }
    uint64_t token = S().next++;
    S().textures.emplace(token, Record{texture, {}});
    return token;
}
void Release(uint64_t token) {
    Lock lock(S().mutex);
    auto found = S().textures.find(token);
    if (found == S().textures.end()) return;
    // Metal retains encoded textures; keep the CVPixelBuffer wrapper alive too
    // until batched work using its IOSurface completes.
    auto owner = found->second.external;
    if (owner && S().pending) {
        [S().pending addCompletedHandler:^(id<MTLCommandBuffer>) { (void)owner; }];
    }
    S().textures.erase(found);
}
bool Update(uint64_t token, const void *pixels, uint32_t stride, const tTVPRect *rect) {
    Lock lock(S().mutex);
    id<MTLTexture> texture = Texture(token);
    if (!texture || !pixels || stride < texture.width * 4 || !FlushPending()) return false;
    tTVPRect region = Clipped(texture, rect);
    if (region.is_empty()) return true;
    const uint8_t *start = (const uint8_t *)pixels + (size_t)region.top * stride + (size_t)region.left * 4;
    [texture replaceRegion:MTLRegionMake2D(region.left, region.top, region.get_width(), region.get_height())
        mipmapLevel:0 withBytes:start bytesPerRow:stride];
    return true;
}
bool Clear(uint64_t token, uint32_t argb, const tTVPRect *rect) {
    Lock lock(S().mutex);
    id<MTLTexture> texture = Texture(token);
    if (!texture) return false;
    tTVPRect region = Clipped(texture, rect);
    if (region.is_empty()) return true;
    // Despite the ABI parameter name, the engine converts script AARRGGBB
    // to AABBGGRR before ClearGpu. Match the reference bridge byte-for-byte.
    uint32_t rgba = argb;
    return Compute("Blend", RectParams(region, region, 5, 255, rgba), {{0, texture}, {1, texture}});
}
bool Copy(uint64_t dst, uint64_t src, const tTVPRect *dr, const tTVPRect *sr) {
    Lock lock(S().mutex);
    id<MTLTexture> d = Texture(dst), s = Texture(src);
    if (!Valid(d, dr) || !Valid(s, sr) || dr->get_width() != sr->get_width() || dr->get_height() != sr->get_height()) return false;
    if (d == s) s = Snapshot(s);
    if (!s) return false;
    id<MTLCommandBuffer> command = WorkCommand();
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!encoder) return false;
    // Imported BGRA textures require channel-aware compute, not a raw-format blit.
    if (s.pixelFormat != d.pixelFormat) {
        [encoder endEncoding];
        return Compute("Blend", RectParams(*dr, *sr, 20, 255, 0), {{0,s},{1,d}});
    }
    [encoder copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sr->left,sr->top,0)
        sourceSize:MTLSizeMake(sr->get_width(),sr->get_height(),1) toTexture:d destinationSlice:0
        destinationLevel:0 destinationOrigin:MTLOriginMake(dr->left,dr->top,0)];
    [encoder endEncoding];
    return SubmitWork(command);
}
bool Blend(uint64_t dst, uint64_t src, const tTVPRect *dr, const tTVPRect *sr, uint32_t mode, int opacity, uint32_t color) {
    Lock lock(S().mutex);
    id<MTLTexture> d = Texture(dst), s = Texture(src);
    if (!Valid(d, dr) || !Valid(s, sr)) return false;
    // Modes implemented by separate multi-source kernels must never silently succeed here.
    if (mode == 4 || mode == 6 || mode == 9 || (mode >= 12 && mode <= 14) || mode == 21 || mode == 22 || mode < 1 || mode > 31) return false;
    Params p = RectParams(*dr, *sr, mode, opacity, color);
    if (mode == 29 || mode == 30) {
        if (d != s) return false;
        return Compute("AlphaConvert", p, {{0, d}});
    }
    if (d == s) s = Snapshot(s);
    if (!s) return false;
    if (mode == 26) {
        if (dr->get_width() != sr->get_width() || dr->get_height() != sr->get_height()) return false;
        p[7] = std::clamp(opacity, 0, 64); p[8] = std::min(color & 255u, 64u);
    } else if (dr->get_width() != sr->get_width() || dr->get_height() != sr->get_height()) {
        p[8] = sr->get_width(); p[9] = sr->get_height(); p[10] = 1;
        // Scaled src dimensions occupy the colour payload in the legacy ABI.
        if (mode == 19 || mode == 23 || mode == 5) return false;
    }
    return Compute(mode == 7 ? "AlphaBlendA" : "Blend", p, {{0, s}, {1, d}});
}
bool Blend2(uint64_t dst, uint64_t src1, uint64_t src2, const tTVPRect *dr,
            const tTVPRect *r1, const tTVPRect *r2, uint32_t mode, int opacity, uint32_t) {
    Lock lock(S().mutex);
    id<MTLTexture> d = Texture(dst), a = Texture(src1), b = Texture(src2);
    if (!Valid(d,dr) || !Valid(a,r1) || !Valid(b,r2) ||
        dr->get_width()!=r1->get_width() || dr->get_height()!=r1->get_height() ||
        dr->get_width()!=r2->get_width() || dr->get_height()!=r2->get_height() ||
        (mode != 4 && mode != 9 && mode != 21 && mode != 22)) return false;
    if (d == a) a = Snapshot(a);
    if (d == b) b = Snapshot(b);
    Params p = RectParams(*dr,*r1,mode,opacity,0); p[8]=r2->left; p[9]=r2->top;
    return Compute("Blend2",p,{{0,a},{1,b},{2,d}});
}
bool Blend3(uint64_t dst, uint64_t src1, uint64_t src2, uint64_t src3,
            const tTVPRect *dr, const tTVPRect *r1, const tTVPRect *r2, const tTVPRect *r3,
            uint32_t mode, int opacity, uint32_t color) {
    Lock lock(S().mutex);
    id<MTLTexture> d=Texture(dst),a=Texture(src1),b=Texture(src2),c=Texture(src3);
    if (!Valid(d,dr)||!Valid(a,r1)||!Valid(b,r2)||!Valid(c,r3)||mode<12||mode>14) return false;
    for (auto r : {r1,r2,r3}) if (dr->get_width()!=r->get_width()||dr->get_height()!=r->get_height()) return false;
    if (d==a) a=Snapshot(a); if (d==b) b=Snapshot(b); if (d==c) c=Snapshot(c);
    Params p=RectParams(*dr,*r1,mode|((color&0xffffu)<<16),opacity,0);
    p[8]=r2->left;p[9]=r2->top;p[10]=r3->left;p[11]=r3->top;
    return Compute("Blend3",p,{{0,a},{1,b},{2,c},{3,d}});
}

bool Triangles(uint64_t dst, uint64_t src, uint64_t mask, uint32_t count,
    const tTVPRect *clip, const tTVPPointD *dp, const tTVPPointD *sp, const tTVPPointD *mp,
    float opacity, uint32_t flags, bool inverted, bool copy) {
    Lock lock(S().mutex);
    id<MTLTexture> d=Texture(dst),s=Texture(src),m=mask ? Texture(mask) : nil;
    if (!d||!s||!clip||!dp||!sp||!count||count>64||!std::isfinite(opacity)||(mask&&(!m||!mp))) return false;
    tTVPRect region=Clipped(d,clip);
    if (region.is_empty()) return true;
    if (d==s) s=Snapshot(s); if (d==m) m=Snapshot(m);
    if (!s || (mask&&!m)) return false;
    std::vector<float> vertices; vertices.reserve(count*(mask?22:16));
    for (uint32_t tri=0;tri<count;++tri) {
        float left=INFINITY,top=INFINITY,right=-INFINITY,bottom=-INFINITY;
        for (uint32_t v=0;v<3;++v) {
            uint32_t i=tri*3+v;
            if (!std::isfinite(dp[i].x)||!std::isfinite(dp[i].y)||!std::isfinite(sp[i].x)||!std::isfinite(sp[i].y)) return false;
            vertices.insert(vertices.end(),{(float)dp[i].x,(float)dp[i].y,(float)sp[i].x,(float)sp[i].y});
            if (mask) {
                if (!std::isfinite(mp[i].x)||!std::isfinite(mp[i].y)) return false;
                vertices.insert(vertices.end(),{(float)mp[i].x,(float)mp[i].y});
            }
            left=std::min(left,(float)dp[i].x);top=std::min(top,(float)dp[i].y);
            right=std::max(right,(float)dp[i].x);bottom=std::max(bottom,(float)dp[i].y);
        }
        vertices.insert(vertices.end(),{left-0.25f,top-0.25f,right+0.25f,bottom+0.25f});
    }
    Params p={region.left,region.top,(int32_t)d.width,(int32_t)d.height,
        region.get_width(),region.get_height(),(int32_t)count,
        (int32_t)std::round(std::clamp(opacity,0.f,1.f)*255.f),
        (int32_t)s.width,(int32_t)s.height,
        (int32_t)(mask ? ((flags&0xffffu)|(inverted?0x10000u:0u)) : flags),0};
    // Match the native-character detail path of the reference bridge.
    if (!mask && (flags & TVP_GODOT_GPU_TRIANGLE_SOURCE_PREMULTIPLIED)) p[10]|=0x40000000u;
    return mask ? Compute("DrawMaskedTriangles",p,{{1,s},{2,m},{3,d}},vertices) :
        Compute(copy?"CopyTriangles":"DrawTriangles",p,{{1,s},{2,d}},vertices);
}
bool CopyTriangles(uint64_t d,uint64_t s,uint32_t n,const tTVPRect *c,const tTVPPointD *dp,const tTVPPointD *sp) {
    return Triangles(d,s,0,n,c,dp,sp,nullptr,1,0,false,true);
}
bool DrawTriangles(uint64_t d,uint64_t s,uint32_t n,const tTVPRect *c,const tTVPPointD *dp,const tTVPPointD *sp,float o,uint32_t flags) {
    return Triangles(d,s,0,n,c,dp,sp,nullptr,o,flags,false,false);
}
bool Masked(uint64_t d,uint64_t s,uint64_t m,uint32_t n,const tTVPRect *c,const tTVPPointD *dp,const tTVPPointD *sp,const tTVPPointD *mp,float o,uint32_t flags,bool inverted) {
    if (!m) return false;
    return Triangles(d,s,m,n,c,dp,sp,mp,o,flags,inverted,false);
}
bool Mosaic(uint64_t token,const tTVPRect *rects,uint32_t count,uint32_t bx,uint32_t by) {
    Lock lock(S().mutex); id<MTLTexture> d=Texture(token);
    if (!d||!rects||!count||count>65536||(bx<=1&&by<=1)||bx>INT32_MAX||by>INT32_MAX) return false;
    std::vector<float> data;
    for (uint32_t i=0;i<count;++i) {
        tTVPRect r=Clipped(d,&rects[i]);
        if (!r.is_empty()) data.insert(data.end(),{(float)r.left,(float)r.top,(float)r.get_width(),(float)r.get_height()});
    }
    if (data.empty()) return false;
    Params p={0,0,0,0,(int32_t)d.width,(int32_t)d.height,(int32_t)(data.size()/4),0,
        (int32_t)std::max(bx,1u),(int32_t)std::max(by,1u),0,0};
    return Compute("Mosaic",p,{{1,Snapshot(d)},{2,d}},data);
}
bool ReadTexture(id<MTLTexture> texture,void *out,size_t capacity,uint32_t stride) {
    if (!texture||!out||stride<texture.width*4||capacity<(size_t)stride*texture.height || !FlushPending()) return false;
    // CPU-accessible ordinary bridge textures; imported IOSurfaces are first
    // snapshotted into shared storage to avoid assuming their storage mode.
    [texture getBytes:out bytesPerRow:stride fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];
    if (texture.pixelFormat==MTLPixelFormatBGRA8Unorm) {
        for (NSUInteger y=0;y<texture.height;++y) for (NSUInteger x=0;x<texture.width;++x) {
            uint8_t *p=(uint8_t *)out+y*stride+x*4; std::swap(p[0],p[2]);
        }
    }
    return true;
}
bool Read(uint64_t token,void *out,size_t capacity,uint32_t stride) {
    Lock lock(S().mutex);id<MTLTexture> t=Texture(token);
    if (!t) return false;
    auto record=S().textures.find(token);
    return ReadTexture(record->second.external?Snapshot(t):t,out,capacity,stride);
}
uint64_t BeginRead(uint64_t token) {
    Lock lock(S().mutex);
    id<MTLTexture> source=Texture(token);
    if (!source) return 0;
    // A pending batch belongs to its encoding thread. Append the snapshot to
    // that buffer so prior writes stay ordered without a CPU completion wait.
    if (S().pending && S().pendingThread!=std::this_thread::get_id()) return 0;
    id<MTLTexture> snapshot=Allocate((uint32_t)source.width,(uint32_t)source.height,source.pixelFormat);
    if (!snapshot) return 0;
    id<MTLCommandBuffer> command=S().pending ?: [S().queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
    if (!encoder) return 0;
    [encoder copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:snapshot
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [encoder endEncoding];
    if (command==S().pending) S().pending=nil;
    [command commit];
    uint64_t request=S().next++;
    S().reads.emplace(request,ReadRequest{snapshot,command,false});++S().readsBegun;return request;
}
bool PollRead(uint64_t token,void *out,size_t capacity,uint32_t stride,bool *ready) {
    Lock lock(S().mutex);if (!ready) return false;*ready=false;
    auto found=S().reads.find(token);if (found==S().reads.end()) return false;
    auto &request=found->second;
    id<MTLTexture> texture=request.texture;
    // Validate even while pending, so invalid callers cannot appear successful.
    if (!out || stride<texture.width*4 || capacity<(size_t)stride*texture.height) return false;
    if (request.command.status==MTLCommandBufferStatusError) {
        if (!request.accounted) { ++S().failures; request.accounted=true;
            S().lastError=request.command.error.localizedDescription ?: @"Metal readback failed"; }
        return false;
    }
    if (request.command.status!=MTLCommandBufferStatusCompleted) { ++S().readsPending;return true; }
    if (!request.accounted) { ++S().operations; request.accounted=true; }
    // The snapshot has completed independently; do not flush unrelated work.
    [texture getBytes:out bytesPerRow:stride fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];
    if (texture.pixelFormat==MTLPixelFormatBGRA8Unorm) {
        for (NSUInteger y=0;y<texture.height;++y) for (NSUInteger x=0;x<texture.width;++x) {
            uint8_t *p=(uint8_t *)out+y*stride+x*4; std::swap(p[0],p[2]);
        }
    }
    // Match the engine/Godot contract: a ready poll consumes the request.
    S().reads.erase(found);
    ++S().readsCompleted;
    *ready=true;return true;
}
void DiscardRead(uint64_t token) { Lock lock(S().mutex);S().readsCancelled+=S().reads.erase(token); }
bool Flush() { Lock lock(S().mutex); return FlushPending(); }
uint64_t BeginBatch() { Lock lock(S().mutex);uint64_t token=S().next++;batches.push_back(token);return token; }
bool EndBatch(uint64_t token) {
    Lock lock(S().mutex);if (batches.empty()||batches.back()!=token) return false;
    batches.pop_back();return batches.empty() ? Flush() : true;
}
uint64_t ImportApple(void *image,uint32_t width,uint32_t height) {
    Lock lock(S().mutex);if (!image||!S().cache) return 0;
    CVPixelBufferRef pixel=(CVPixelBufferRef)image;
    if (CVPixelBufferGetWidth(pixel)!=width||CVPixelBufferGetHeight(pixel)!=height||
        CVPixelBufferGetPixelFormatType(pixel)!=kCVPixelFormatType_32BGRA) return 0;
    CVMetalTextureRef wrapper=nullptr;
    NSDictionary *attributes=@{(NSString *)kCVMetalTextureUsage:@(MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite)};
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,S().cache,pixel,
        (__bridge CFDictionaryRef)attributes,MTLPixelFormatBGRA8Unorm,width,height,0,&wrapper)!=kCVReturnSuccess) return 0;
    id<MTLTexture> texture=CVMetalTextureGetTexture(wrapper);
    if (!texture) { CFRelease(wrapper);return 0; }
    auto owner=std::make_shared<ExternalOwner>();owner->pixel=(CVPixelBufferRef)CFRetain(pixel);owner->wrapper=wrapper;
    uint64_t token=S().next++;S().textures.emplace(token,Record{texture,owner});return token;
}
bool Prepare(uint64_t token) { Lock lock(S().mutex);return Texture(token)!=nil && Flush(); }
bool Publish(uint64_t token) { Lock lock(S().mutex);return Texture(token)!=nil && Flush(); }
uint64_t ImportAndroid(void *,uint32_t,uint32_t) { return 0; }
} // namespace

BOOL AetherMetalBridgeInitialize(NSError **error) {
    Lock lock(S().mutex);
    if (S().library) return YES;
    S().device=MTLCreateSystemDefaultDevice();S().queue=[S().device newCommandQueue];
    if (!S().device||!S().queue) {
        if (error) *error=[NSError errorWithDomain:@"AetherMetalBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Metal is unavailable"}];
        return NO;
    }
    MTLCompileOptions *options=[MTLCompileOptions new];
    if (@available(macOS 15.0,*)) options.mathMode=MTLMathModeSafe;
    else options.fastMathEnabled=NO;
    NSError *failure=nil;
    id<MTLLibrary> library=[S().device newLibraryWithSource:[NSString stringWithUTF8String:kAppleMetalBridgeShaders] options:options error:&failure];
    if (library) {
        for (NSString *name in library.functionNames) {
            id<MTLComputePipelineState> p=[S().device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&failure];
            if (!p) { library=nil;break; }
            S().pipelines.emplace(std::string(name.UTF8String+6),p); // apple_ prefix
        }
    }
    if (!library) { S().pipelines.clear();if (error) *error=failure;return NO; }
    CVReturn cacheResult=CVMetalTextureCacheCreate(kCFAllocatorDefault,nullptr,S().device,nullptr,&S().cache);
    if (cacheResult!=kCVReturnSuccess) {
        if (error) *error=[NSError errorWithDomain:@"AetherMetalBridge" code:cacheResult userInfo:@{NSLocalizedDescriptionKey:@"CVMetalTextureCache creation failed"}];
        S().pipelines.clear();return NO;
    }
    TVPGodotGpuBridgeCallbacks callbacks={Create,Release,Update,Clear,Copy,CopyTriangles,DrawTriangles,Masked,Mosaic,
        Blend,Blend2,Blend3,Read,BeginRead,PollRead,DiscardRead,Flush};
    TVPGodotGpuBatchCallbacks batch={sizeof(batch),TVP_GODOT_GPU_BATCH_CALLBACKS_ABI_VERSION,BeginBatch,EndBatch};
    TVPGodotGpuExternalTextureCallbacks external={sizeof(external),TVP_GODOT_GPU_EXTERNAL_TEXTURE_CALLBACKS_ABI_VERSION,
        ImportApple,Prepare,ImportAndroid,Publish};
    TVPGodotGpuBridgeRegister(&callbacks);TVPGodotGpuBatchRegister(&batch);TVPGodotGpuExternalTextureRegister(&external);
    S().library=library;return YES;
}
id<MTLTexture> AetherMetalBridgeCopyTexture(uint64_t token) {
    Lock lock(S().mutex);
    auto start=std::chrono::steady_clock::now();
    id<MTLTexture> result=Snapshot(Texture(token));
    double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    ++S().presentationSnapshots;S().presentationSnapshotMS+=elapsed;
    S().presentationSnapshotMaxMS=std::max(S().presentationSnapshotMaxMS,elapsed);
    return result;
}
BOOL AetherMetalBridgeReadTexture(uint64_t token, void *pixels, size_t capacity, uint32_t stride) { return Read(token, pixels, capacity, stride); }
NSString *AetherMetalBridgeDiagnostics() {
    Lock lock(S().mutex);
    return [NSString stringWithFormat:@"Metal bridge textures=%zu reads=%zu commands=%llu failures=%llu error=%@ read_begin=%llu read_pending_polls=%llu read_complete=%llu read_cancel=%llu snapshot_calls=%llu snapshot_total_ms=%.3f snapshot_max_ms=%.3f",
        S().textures.size(),S().reads.size(),S().operations,S().failures,S().lastError,
        S().readsBegun,S().readsPending,S().readsCompleted,S().readsCancelled,
        S().presentationSnapshots,S().presentationSnapshotMS,S().presentationSnapshotMaxMS];
}
