#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "../HostKit/MetalBridge.h"
#include "engine_gpu_bridge.h"
#include <array>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cassert>
#include <cstdio>
#include <vector>
#include <thread>

// Registration is exercised without loading the full engine/provider closure.
static TVPGodotGpuBridgeCallbacks bridge;
static TVPGodotGpuBatchCallbacks batch;
static TVPGodotGpuExternalTextureCallbacks external;
extern "C" void TVPGodotGpuBridgeRegister(const TVPGodotGpuBridgeCallbacks *p) { bridge=*p; }
extern "C" void TVPGodotGpuBatchRegister(const TVPGodotGpuBatchCallbacks *p) { batch=*p; }
extern "C" void TVPGodotGpuExternalTextureRegister(const TVPGodotGpuExternalTextureCallbacks *p) { external=*p; }
using Pixel=std::array<uint8_t,4>;
static Pixel ReadPixel(uint64_t texture) {
    Pixel p{}; assert(bridge.read_rgba(texture,p.data(),p.size(),4)); return p;
}
static uint64_t Make(Pixel pixel) { return bridge.create_rgba(1,1,pixel.data(),4); }
static void Benchmark1080p() {
    // Component benchmark: eight full-frame blends plus immutable frame copy.
    // Includes allocation, encoding, submission and GPU completion, not engine
    // tick or MTKView presentation. This cannot satisfy the complete-frame G1 gate.
    tTVPRect rect(0,0,1920,1080);
    uint64_t dst=bridge.create_rgba(1920,1080,nullptr,0);
    uint64_t src=bridge.create_rgba(1920,1080,nullptr,0);
    assert(dst&&src);
    assert(bridge.clear_rgba(src,0x80c83264,&rect));
    for (bool batched : {false,true}) {
        std::vector<double> milliseconds;
        for (int frame=0;frame<70;++frame) {
            auto start=std::chrono::steady_clock::now();
            uint64_t scope=batched?batch.begin_batch():0;
            assert(bridge.clear_rgba(dst,0xff102030,&rect));
            for(int layer=0;layer<8;++layer)
                assert(bridge.blend_rect(dst,src,&rect,&rect,2,192,0));
            if(batched)assert(batch.end_batch(scope));
            auto snapshot=AetherMetalBridgeCopyTexture(dst);assert(snapshot);
            double elapsed=std::chrono::duration<double,std::milli>(
                std::chrono::steady_clock::now()-start).count();
            if(frame>=10)milliseconds.push_back(elapsed);
        }
        std::sort(milliseconds.begin(),milliseconds.end());
        printf("BENCH bridge-only 1920x1080 clear+8-alpha-blends+GPU-snapshot "
            "batch=%s samples=60 warmup=10 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f\n",
            batched?"on":"off",milliseconds[29],milliseconds[56],milliseconds.back());
    }
    bridge.release_texture(dst);bridge.release_texture(src);
}
static void BenchmarkReadback(bool drawing=false) {
    using Clock=std::chrono::steady_clock;
    std::vector<uint8_t> pixels(1920*1080*4);
    tTVPRect rect(0,0,1920,1080);
    uint64_t texture=bridge.create_rgba(1920,1080,nullptr,0);assert(texture);
    assert(bridge.clear_rgba(texture,0xff332211,&rect));
    uint64_t source=bridge.create_rgba(1920,1080,nullptr,0);assert(source);
    assert(bridge.clear_rgba(source,0x80c83264,&rect));
    auto draw=[&]() {
        if(!drawing)return uint64_t(0);
        uint64_t scope=batch.begin_batch();
        assert(bridge.clear_rgba(texture,0xff332211,&rect));
        for(int layer=0;layer<8;++layer)assert(bridge.blend_rect(texture,source,&rect,&rect,2,192,0));
        return scope;
    };
    std::vector<double> sync,submit,total;
    unsigned pending=0;
    auto elapsed=[](Clock::time_point start) {
        return std::chrono::duration<double,std::milli>(Clock::now()-start).count();
    };
    for(int frame=0;frame<70;++frame) {
        uint64_t scope=draw();auto start=Clock::now();
        assert(bridge.read_rgba(texture,pixels.data(),pixels.size(),1920*4));
        double synchronous=elapsed(start);
        if(scope)assert(batch.end_batch(scope));
        auto expected=pixels;
        scope=draw();
        start=Clock::now();uint64_t request=bridge.begin_read_rgba(texture);assert(request);
        double submission=elapsed(start);bool ready=false;
        while(!ready) {
            assert(elapsed(start)<5000);
            assert(bridge.poll_read_rgba(request,pixels.data(),pixels.size(),1920*4,&ready));
            if(!ready) { ++pending;std::this_thread::yield(); }
        }
        double completion=elapsed(start);
        assert(pixels==expected);
        if(!drawing)for(size_t i=0;i<pixels.size();i+=4)
            assert(pixels[i]==0x11&&pixels[i+1]==0x22&&pixels[i+2]==0x33&&pixels[i+3]==255);
        bridge.discard_read_rgba(request);
        if(scope)assert(batch.end_batch(scope));
        if(frame>=10) {sync.push_back(synchronous);submit.push_back(submission);total.push_back(completion);}
    }
    for(auto item : {std::make_pair("sync",&sync),std::make_pair("async-submit",&submit),std::make_pair("async-total",&total)}) {
        auto &values=*item.second;std::sort(values.begin(),values.end());
        printf("BENCH readback 1920x1080 drawing=%s %s samples=60 warmup=10 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f\n",
            drawing?"8-blends":"none",item.first,values[29],values[56],values.back());
    }
    printf("BENCH readback pending_polls=%u (includes warmup)\n",pending);
    bridge.release_texture(texture);bridge.release_texture(source);
}
static void BenchmarkSnapshotSubmission() {
    tTVPRect rect(0,0,1920,1080);
    uint64_t dst=bridge.create_rgba(1920,1080,nullptr,0);
    uint64_t src=bridge.create_rgba(1920,1080,nullptr,0);assert(dst&&src);
    assert(bridge.clear_rgba(src,0x80c83264,&rect));
    std::array<std::vector<double>,2> measurements;
    std::vector<uint8_t> reference(1920*1080*4),pixels(reference.size());
    for(int frame=0;frame<70;++frame)for(int index=0;index<2;++index) {
        // Alternate order to reduce temperature/order bias within one run.
        int mode=(index+frame)%2;
        auto start=std::chrono::steady_clock::now();
        uint64_t scope=batch.begin_batch();
        assert(bridge.clear_rgba(dst,0xff102030,&rect));
        for(int layer=0;layer<8;++layer)assert(bridge.blend_rect(dst,src,&rect,&rect,2,192,0));
        if(mode==0)assert(batch.end_batch(scope));
        auto image=AetherMetalBridgeCopyTexture(dst);assert(image);
        if(mode==1)assert(batch.end_batch(scope));
        double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        if(frame>=10)measurements[mode].push_back(ms);
        // Validation is outside the timed region.
        [image getBytes:pixels.data() bytesPerRow:1920*4 fromRegion:MTLRegionMake2D(0,0,1920,1080) mipmapLevel:0];
        if(frame==0&&index==0)reference=pixels;
        else assert(pixels==reference);
    }
    for(int mode=0;mode<2;++mode) {
        auto &values=measurements[mode];std::sort(values.begin(),values.end());
        printf("BENCH snapshot 1920x1080 clear+8-blends mode=%s samples=60 warmup=10 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f\n",
            mode?"combined":"separate",values[29],values[56],values.back());
    }
    bridge.release_texture(dst);bridge.release_texture(src);
}
int main(int argc,char **argv) { @autoreleasepool {
    NSError *error=nil;
    auto initialQueue=AetherMetalBridgeCommandQueue();assert(initialQueue);
    if (!AetherMetalBridgeInitialize(&error)) { NSLog(@"%@",error);return 1; }
    assert(initialQueue==AetherMetalBridgeCommandQueue());
    assert(bridge.create_rgba&&bridge.blend_rect3&&external.import_apple_pixel_buffer);
    tTVPRect one(0,0,1,1);
    uint64_t dst=Make({20,80,140,100}),src=Make({200,40,60,128});
    assert(bridge.blend_rect(dst,src,&one,&one,1,255,0));
    assert((ReadPixel(dst)==Pixel{109,60,100,100}));
    Pixel original{20,80,140,100};
    assert(bridge.update_rgba(dst,original.data(),4,&one));
    assert(bridge.blend_rect(dst,src,&one,&one,2,255,0));
    assert((ReadPixel(dst)==Pixel{148,51,82,178}));
    assert(bridge.clear_rgba(dst,0xff563412,&one));
    assert((ReadPixel(dst)==Pixel{0x12,0x34,0x56,255}));
    assert(bridge.clear_rgba(dst,0xffffff00,&one));
    assert((ReadPixel(dst)==Pixel{0,255,255,255})); // Engine-packed cyan stays cyan.
    assert(!bridge.blend_rect(dst,src,&one,&one,6,255,0)); // Reserved rect mode: explicit fallback.
    assert(!bridge.blend_rect(dst,src,&one,&one,999,255,0));
    assert(bridge.blend_rect(dst,src,&one,&one,20,255,0));
    assert((ReadPixel(dst)==Pixel{200,40,60,128}));
    assert(bridge.blend_rect(dst,dst,&one,&one,29,255,0));
    assert((ReadPixel(dst)==Pixel{100,20,30,128}));
    assert(bridge.blend_rect(dst,dst,&one,&one,30,255,0));
    assert((ReadPixel(dst)==Pixel{199,39,59,128}));
    assert(bridge.blend_rect(dst,dst,&one,&one,18,75,0));
    assert(ReadPixel(dst)[3]==75);
    // Multi-source modes: opacity endpoints and threshold masks.
    uint64_t second=Make({1,2,3,0}),rule=Make({255,0,0,255});
    assert(bridge.blend_rect2(dst,src,second,&one,&one,&one,4,0,0));
    assert((ReadPixel(dst)==Pixel{200,40,60,0}));
    assert(bridge.blend_rect2(dst,src,second,&one,&one,&one,21,255,0));
    assert((ReadPixel(dst)==Pixel{200,40,60,0}));
    for (uint32_t mode : {12u,13u,14u}) {
        assert(bridge.blend_rect3(dst,src,second,rule,&one,&one,&one,&one,mode,128,8));
        assert((ReadPixel(dst)==Pixel{200,40,60,128}));
    }
    // Full-image padded stride and offset region update leave other pixels intact.
    std::array<uint8_t,24> padded{1,2,3,255,4,5,6,255,0,0,0,0,
                                 7,8,9,255,10,11,12,255,0,0,0,0};
    uint64_t regionTarget=bridge.create_rgba(2,2,nullptr,0);
    tTVPRect lowerRight(1,1,2,2);
    assert(bridge.update_rgba(regionTarget,padded.data(),12,&lowerRight));
    std::array<uint8_t,16> regionPixels{};
    assert(bridge.read_rgba(regionTarget,regionPixels.data(),16,8));
    for(int i=0;i<12;++i)assert(regionPixels[i]==0);
    assert(regionPixels[12]==10&&regionPixels[13]==11&&regionPixels[14]==12&&regionPixels[15]==255);
    bridge.release_texture(regionTarget);
    // Invalid dimensions/stride/capacity must not issue out-of-bounds GPU access.
    tTVPRect bad(-1,0,1,1);
    assert(!bridge.copy_rect(dst,src,&bad,&one));
    Pixel tooSmall{};assert(!bridge.read_rgba(dst,tooSmall.data(),3,4));
    assert(!bridge.update_rgba(dst,original.data(),3,&one));
    assert(bridge.create_rgba(0,1,nullptr,0)==0);
    // Overlapping in-place copy takes a snapshot rather than reading modified texels.
    std::array<uint8_t,16> row{10,0,0,255,20,0,0,255,30,0,0,255,40,0,0,255};
    uint64_t line=bridge.create_rgba(4,1,row.data(),16);
    tTVPRect left(0,0,3,1),right(1,0,4,1);
    assert(bridge.copy_rect(line,line,&right,&left));
    assert(bridge.read_rgba(line,row.data(),row.size(),16));
    assert(row[0]==10&&row[4]==10&&row[8]==20&&row[12]==30);
    // Read request remains a stable snapshot after update and source release.
    uint64_t request=bridge.begin_read_rgba(src);assert(request);
    Pixel invalidOutput{};bool invalidReady=true;
    assert(!bridge.poll_read_rgba(request,invalidOutput.data(),3,4,&invalidReady)&&!invalidReady);
    assert(!bridge.poll_read_rgba(request,nullptr,4,4,&invalidReady)&&!invalidReady);
    assert(!bridge.poll_read_rgba(request,invalidOutput.data(),4,3,&invalidReady)&&!invalidReady);
    assert(!bridge.poll_read_rgba(request,invalidOutput.data(),4,4,nullptr));
    bridge.clear_rgba(src,0xff000000,&one);bridge.release_texture(src);
    Pixel snapshot{};bool ready=false;
    for (int attempt=0;attempt<10000 && !ready;++attempt) {
        assert(bridge.poll_read_rgba(request,snapshot.data(),snapshot.size(),4,&ready));
        if (!ready) std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    assert(ready);
    assert((snapshot==Pixel{200,40,60,128}));
    // Completion consumes the request, matching the engine's CPU readback owner.
    ready=false;snapshot.fill(0);
    assert(!bridge.poll_read_rgba(request,snapshot.data(),4,4,&ready)&&!ready);
    bridge.discard_read_rgba(request);
    assert(!bridge.poll_read_rgba(request,snapshot.data(),snapshot.size(),4,&ready)&&!ready);
    // Discard before completion is safe: Metal retains encoded resources.
    uint64_t abandoned=bridge.begin_read_rgba(dst);assert(abandoned);
    bridge.discard_read_rgba(abandoned);bridge.discard_read_rgba(abandoned);
    assert(!bridge.poll_read_rgba(abandoned,snapshot.data(),4,4,&ready)&&!ready);
    // Nested batch scopes validate token ordering.
    uint64_t outer=batch.begin_batch(),inner=batch.begin_batch();
    assert(!batch.end_batch(outer));assert(batch.end_batch(inner));assert(batch.end_batch(outer));
    assert(!batch.end_batch(outer));
    // Readback submits prior batch writes in order without ending the scope.
    outer=batch.begin_batch();
    assert(bridge.clear_rgba(dst,0xff665544,&one));
    uint64_t batchedRead=bridge.begin_read_rgba(dst);assert(batchedRead);
    assert(bridge.clear_rgba(dst,0xff998877,&one));
    assert(batch.end_batch(outer));
    ready=false;
    for(int attempt=0;attempt<10000&&!ready;++attempt) {
        assert(bridge.poll_read_rgba(batchedRead,snapshot.data(),4,4,&ready));
        if(!ready)std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    assert(ready&&(snapshot==Pixel{0x44,0x55,0x66,255}));
    assert((ReadPixel(dst)==Pixel{0x77,0x88,0x99,255}));
    bridge.discard_read_rgba(batchedRead);
    outer=batch.begin_batch();
    assert(bridge.clear_rgba(dst,0xffccbbaa,&one));
    auto batchSnapshot=AetherMetalBridgeCopyTexture(dst);assert(batchSnapshot);
    assert(bridge.clear_rgba(dst,0xff332211,&one));
    assert(batch.end_batch(outer));
    Pixel copied{};
    [batchSnapshot getBytes:copied.data() bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    assert((copied==Pixel{0xaa,0xbb,0xcc,255}));
    assert((ReadPixel(dst)==Pixel{0x11,0x22,0x33,255}));
    auto queuedSnapshot=AetherMetalBridgeCopyPresentationTexture(dst);assert(queuedSnapshot);
    assert(AetherMetalBridgeDrain());
    assert([AetherMetalBridgeDiagnostics() containsString:@"async_inflight=0"]);
    auto queue=AetherMetalBridgeCommandQueue();assert(queue);
    auto fence=[queue commandBuffer];[fence commit];[fence waitUntilCompleted];
    assert(fence.status==MTLCommandBufferStatusCompleted);
    [queuedSnapshot getBytes:copied.data() bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    assert((copied==Pixel{0x11,0x22,0x33,255}));
    // Encoded work observes preceding operations inside a nested batch.
    outer=batch.begin_batch();inner=batch.begin_batch();
    assert(bridge.clear_rgba(dst,0xff332211,&one));
    assert(bridge.copy_rect(second,dst,&one,&one));
    assert(bridge.clear_rgba(dst,0xff665544,&one));
    assert(batch.end_batch(inner));assert(batch.end_batch(outer));
    assert((ReadPixel(second)==Pixel{0x11,0x22,0x33,255}));
    assert((ReadPixel(dst)==Pixel{0x44,0x55,0x66,255}));
    // Mosaic samples original block centres, including clipped edge blocks.
    std::array<uint8_t,16> mosaic{10,0,0,255,20,0,0,255,30,0,0,255,40,0,0,255};
    uint64_t m=bridge.create_rgba(4,1,mosaic.data(),16);tTVPRect full(0,0,4,1);
    assert(bridge.mosaic_rects(m,&full,1,2,1));assert(bridge.read_rgba(m,mosaic.data(),16,16));
    assert(mosaic[0]==20&&mosaic[4]==20&&mosaic[8]==40&&mosaic[12]==40);
    // Triangle copy and mask polarity. The square uses two triangles.
    std::array<uint8_t,16> solid{200,40,60,255,200,40,60,255,200,40,60,255,200,40,60,255};
    uint64_t source=bridge.create_rgba(2,2,solid.data(),8),target=bridge.create_rgba(2,2,nullptr,0);
    uint64_t mask=bridge.create_rgba(2,2,nullptr,0);tTVPRect square(0,0,2,2);
    tTVPPointD points[]={{0,0},{2,0},{0,2},{2,0},{0,2},{2,2}};
    assert(bridge.copy_triangles(target,source,2,&square,points,points));
    std::array<uint8_t,16> result{};assert(bridge.read_rgba(target,result.data(),16,8));assert(result==solid);
    bridge.clear_rgba(target,0,&square);
    assert(bridge.draw_triangles(target,source,2,&square,points,points,1,0));
    assert(bridge.read_rgba(target,result.data(),16,8));assert(result==solid);
    bridge.clear_rgba(target,0,&square);
    assert(bridge.draw_masked_triangles(target,source,mask,2,&square,points,points,points,1,0,true));
    assert(bridge.read_rgba(target,result.data(),16,8));for(auto value:result)assert(value==0);
    assert(bridge.draw_masked_triangles(target,source,mask,2,&square,points,points,points,1,0,false));
    assert(bridge.read_rgba(target,result.data(),16,8));assert(result==solid);
    // External IOSurface import: BGRA sampling/readback converts channels correctly.
    CVPixelBufferRef pixel=nullptr;
    NSDictionary *attributes=@{(NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    assert(CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes,&pixel)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pixel,0);
    auto *bytes=(uint8_t *)CVPixelBufferGetBaseAddress(pixel);size_t stride=CVPixelBufferGetBytesPerRow(pixel);
    for (int y=0;y<2;++y)for(int x=0;x<2;++x) {
        auto *p=bytes+y*stride+x*4;p[0]=60;p[1]=40;p[2]=200;p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(pixel,0);
    uint64_t imported=external.import_apple_pixel_buffer(pixel,2,2);assert(imported);
    CFRelease(pixel); // Bridge retains its own owner.
    assert(external.prepare_for_native_write(imported));assert(external.publish_native_write(imported));
    assert(bridge.read_rgba(imported,result.data(),16,8));assert(result==solid);
    assert(bridge.copy_rect(target,imported,&square,&square));
    assert(bridge.read_rgba(target,result.data(),16,8));assert(result==solid);
    outer=batch.begin_batch();
    assert(bridge.copy_rect(target,imported,&square,&square));
    bridge.release_texture(imported); // Owner must survive unsubmitted commands.
    assert(batch.end_batch(outer));
    assert(bridge.read_rgba(target,result.data(),16,8));assert(result==solid);
    auto immutable=AetherMetalBridgeCopyTexture(target);assert(immutable);
    assert(external.import_android_hardware_buffer(nullptr,2,2)==0);
    for(uint64_t token:{dst,second,rule,line,m,source,target,mask,imported})bridge.release_texture(token);
    assert(!bridge.read_rgba(dst,result.data(),16,8));
    if(argc>1&&std::strcmp(argv[1],"--benchmark")==0)Benchmark1080p();
    if(argc>1&&std::strcmp(argv[1],"--readback-benchmark")==0)BenchmarkReadback();
    if(argc>1&&std::strcmp(argv[1],"--batched-readback-benchmark")==0)BenchmarkReadback(true);
    if(argc>1&&std::strcmp(argv[1],"--snapshot-benchmark")==0)BenchmarkSnapshotSubmission();
    printf("PASS: Metal kernels, exact alpha arithmetic, clear, conversion, multi-source, bounds, overlap, read snapshots, batch, mosaic, triangles, IOSurface ownership\n%s\n",AetherMetalBridgeDiagnostics().UTF8String);
} }
