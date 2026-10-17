#include "offscreen_context.h"
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <OpenGLES/EAGL.h>
#include <OpenGLES/ES3/gl.h>
#else
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#endif
#include <algorithm>

namespace aetherkiri::xsystem4 {
    struct OffscreenContext::Impl {
#if TARGET_OS_IPHONE
        EAGLContext *context = nil;
#else
        CGLContextObj context = nullptr;
#endif
        GLuint fbo = 0, color = 0, depth = 0;
        uint32_t width = 0, height = 0;
    };
    OffscreenContext::OffscreenContext() : impl_(std::make_unique<Impl>()) {}
    OffscreenContext::~OffscreenContext() {
        if(!impl_->context)
            return;
        glDeleteFramebuffers(1, &impl_->fbo);
        glDeleteTextures(1, &impl_->color);
        glDeleteRenderbuffers(1, &impl_->depth);
#if TARGET_OS_IPHONE
        [EAGLContext setCurrentContext:nil];
        impl_->context = nil;
#else
        CGLSetCurrentContext(nullptr);
        CGLDestroyContext(impl_->context);
#endif
    }
    bool OffscreenContext::initialize(uint32_t width, uint32_t height,
                                      std::string &error) {
        if(impl_->context && impl_->width == width && impl_->height == height)
            return true;
        if(!impl_->context) {
#if TARGET_OS_IPHONE
            impl_->context =
                [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
            if(!impl_->context ||
               ![EAGLContext setCurrentContext:impl_->context]) {
                error = "Could not create an OpenGL ES 3 context";
                return false;
            }
#else
            const CGLPixelFormatAttribute attributes[] = {
                kCGLPFAOpenGLProfile,
                (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
                kCGLPFAAccelerated, (CGLPixelFormatAttribute)0
            };
            CGLPixelFormatObj format = nullptr;
            GLint count = 0;
            CGLError result = CGLChoosePixelFormat(attributes, &format, &count);
            if(result == kCGLNoError && format)
                result = CGLCreateContext(format, nullptr, &impl_->context);
            if(format)
                CGLDestroyPixelFormat(format);
            if(result != kCGLNoError || !impl_->context ||
               CGLSetCurrentContext(impl_->context) != kCGLNoError) {
                error = "Could not create a native offscreen OpenGL context";
                return false;
            }
#endif
        }
        glDeleteFramebuffers(1, &impl_->fbo);
        glDeleteTextures(1, &impl_->color);
        glDeleteRenderbuffers(1, &impl_->depth);
        impl_->width = width;
        impl_->height = height;
        glGenTextures(1, &impl_->color);
        glBindTexture(GL_TEXTURE_2D, impl_->color);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glGenRenderbuffers(1, &impl_->depth);
        glBindRenderbuffer(GL_RENDERBUFFER, impl_->depth);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width,
                              height);
        glGenFramebuffers(1, &impl_->fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, impl_->fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, impl_->color, 0);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                  GL_RENDERBUFFER, impl_->depth);
        if(glCheckFramebufferStatus(GL_FRAMEBUFFER) !=
           GL_FRAMEBUFFER_COMPLETE) {
            error = "The native offscreen framebuffer is incomplete";
            return false;
        }
        return true;
    }
    unsigned OffscreenContext::framebuffer() const { return impl_->fbo; }
    bool OffscreenContext::read(std::vector<uint8_t> &rgba,
                                std::string &error) {
        const size_t stride = size_t(impl_->width) * 4;
        rgba.resize(stride * impl_->height);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, impl_->width, impl_->height, GL_RGBA,
                     GL_UNSIGNED_BYTE, rgba.data());
        if(glGetError() != GL_NO_ERROR) {
            error = "Could not read the native framebuffer";
            return false;
        }
        for(uint32_t y = 0; y < impl_->height / 2; y++) {
            auto a = rgba.begin() + y * stride;
            auto b = rgba.begin() + (impl_->height - y - 1) * stride;
            std::swap_ranges(a, a + stride, b);
        }
        return true;
    }
} // namespace aetherkiri::xsystem4
