#import "MobileMetalPresenter.h"
#include <cstdlib>
#include <cstring>

@implementation AetherMobileMetalPresenter {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
    AetherMetalFrameLease *_lease;
    BOOL _stopped;
}
- (instancetype)initWithError:(NSError **)error {
    if (!(self=[super init])) return nil;
    _queue=AetherMetalBridgeCommandQueue();
    if (!_queue) return nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct V { float4 position [[position]]; float2 uv; };\n"
      "vertex V mobile_vertex(uint i [[vertex_id]]) {\n"
      "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
      "V v; v.position=float4(p[i],0,1); v.uv=float2((p[i].x+1)*0.5,(1-p[i].y)*0.5); return v; }\n"
      "fragment float4 mobile_fragment(V v [[stage_in]],texture2d<float> t [[texture(0)]]) {\n"
      "constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);return t.sample(s,v.uv);}\n";
    id<MTLLibrary> library=[_queue.device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction=[library newFunctionWithName:@"mobile_vertex"];
    descriptor.fragmentFunction=[library newFunctionWithName:@"mobile_fragment"];
    descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    _pipeline=[_queue.device newRenderPipelineStateWithDescriptor:descriptor error:error];
    if (!_pipeline) return nil;
    _view=[[MTKView alloc] initWithFrame:CGRectZero device:_queue.device];
    _view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;
    _view.clearColor=MTLClearColorMake(0,0,0,1);
    _view.framebufferOnly=YES; _view.paused=YES; _view.enableSetNeedsDisplay=NO;
    _view.autoResizeDrawable=YES; _view.userInteractionEnabled=NO; _view.delegate=self;
    return self;
}
- (void)presentFrame:(AetherMetalFrameLease *)frame {
    if (_stopped) return;
    if (frame) { _lease=frame; _texture=frame.texture; }
#if DEBUG
    const char *inject=std::getenv("AETHER_IOS_FAIL_PRESENTATION");
    if (frame && inject && std::strcmp(inject,"1")==0) {
        _lastError=@"Injected mobile presentation failure"; return;
    }
#endif
    [_view draw];
}
- (void)drawInMTKView:(MTKView *)view {
    if (_stopped || !_texture || !view.window || view.hidden ||
        view.window.windowScene.activationState!=UISceneActivationStateForegroundActive ||
        view.drawableSize.width<1 || view.drawableSize.height<1) return;
    id<CAMetalDrawable> drawable=view.currentDrawable;
    MTLRenderPassDescriptor *pass=view.currentRenderPassDescriptor;
    if (!drawable || !pass) return; // Keep the latest lease for a later drawable.
    id<MTLCommandBuffer> command=_lease ? AetherMetalBridgePresentationCommand() : [_queue commandBuffer];
    if (!command) { _lastError=@"Unable to acquire presentation command"; return; }
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { _lastError=@"Unable to encode presentation"; return; }
    double scale=MIN((double)drawable.texture.width/_texture.width,(double)drawable.texture.height/_texture.height);
    double width=_texture.width*scale,height=_texture.height*scale;
    [encoder setViewport:MTLViewport{(drawable.texture.width-width)/2,(drawable.texture.height-height)/2,width,height,0,1}];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentTexture:_texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding]; [command presentDrawable:drawable];
    __weak AetherMobileMetalPresenter *weakSelf=self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status!=MTLCommandBufferStatusCompleted) {
            NSString *message=completed.error.localizedDescription ?: @"Metal command failed";
            dispatch_async(dispatch_get_main_queue(), ^{
                AetherMobileMetalPresenter *owner=weakSelf;
                if (owner && !owner->_stopped) owner->_lastError=message;
            });
        }
    }];
    if (_lease) {
        if (![_lease submitCommand:command]) { _lastError=@"Frame lease submission rejected"; return; }
        _lease=nil; // Completion retains it; permit next engine write without detach.
    } else [command commit];
    ++_submittedFrames;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // The next display-link tick redraws the retained texture at the new fit.
}
- (void)stop {
    _stopped=YES; _view.delegate=nil; _lease=nil; _texture=nil;
}
- (void)dealloc { [self stop]; }
@end
