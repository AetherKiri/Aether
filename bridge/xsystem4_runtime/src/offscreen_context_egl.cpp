#include "offscreen_context.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <algorithm>

namespace aetherkiri::xsystem4 {
    struct OffscreenContext::Impl {
        EGLDisplay display = EGL_NO_DISPLAY;
        EGLContext context = EGL_NO_CONTEXT;
        EGLSurface surface = EGL_NO_SURFACE;
        GLuint fbo = 0, color = 0, depth = 0;
        uint32_t width = 0, height = 0;
    };
    OffscreenContext::OffscreenContext() : impl_(std::make_unique<Impl>()) {}
    OffscreenContext::~OffscreenContext() {
        if(impl_->context != EGL_NO_CONTEXT) {
            glDeleteFramebuffers(1, &impl_->fbo);
            glDeleteTextures(1, &impl_->color);
            glDeleteRenderbuffers(1, &impl_->depth);
            eglMakeCurrent(impl_->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                           EGL_NO_CONTEXT);
            eglDestroyContext(impl_->display, impl_->context);
        }
        if(impl_->surface != EGL_NO_SURFACE)
            eglDestroySurface(impl_->display, impl_->surface);
        // EGL_DEFAULT_DISPLAY may also belong to Godot. eglTerminate has no
        // reference count and would invalidate the host's contexts and
        // surfaces.
        eglReleaseThread();
    }
    bool OffscreenContext::initialize(uint32_t width, uint32_t height,
                                      std::string &error) {
        if(impl_->context != EGL_NO_CONTEXT && impl_->width == width &&
           impl_->height == height)
            return true;
        if(impl_->context == EGL_NO_CONTEXT) {
            impl_->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
            if(impl_->display == EGL_NO_DISPLAY ||
               !eglInitialize(impl_->display, nullptr, nullptr)) {
                error = "Could not initialize native EGL";
                return false;
            }
            eglBindAPI(EGL_OPENGL_ES_API);
            const EGLint attributes[] = { EGL_SURFACE_TYPE,
                                          EGL_PBUFFER_BIT,
                                          EGL_RENDERABLE_TYPE,
                                          EGL_OPENGL_ES3_BIT_KHR,
                                          EGL_RED_SIZE,
                                          8,
                                          EGL_GREEN_SIZE,
                                          8,
                                          EGL_BLUE_SIZE,
                                          8,
                                          EGL_ALPHA_SIZE,
                                          8,
                                          EGL_NONE };
            EGLConfig config;
            EGLint count;
            if(!eglChooseConfig(impl_->display, attributes, &config, 1,
                                &count) ||
               !count) {
                error = "No EGL OpenGL ES 3 configuration";
                return false;
            }
            const EGLint surface[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
            impl_->surface =
                eglCreatePbufferSurface(impl_->display, config, surface);
            const EGLint context[] = { EGL_CONTEXT_CLIENT_VERSION, 3,
                                       EGL_NONE };
            impl_->context = eglCreateContext(impl_->display, config,
                                              EGL_NO_CONTEXT, context);
            if(impl_->context == EGL_NO_CONTEXT ||
               !eglMakeCurrent(impl_->display, impl_->surface, impl_->surface,
                               impl_->context)) {
                error = "Could not create the native GLES context";
                return false;
            }
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
            error = "The offscreen framebuffer is incomplete";
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
            auto a = rgba.begin() + y * stride,
                 b = rgba.begin() + (impl_->height - y - 1) * stride;
            std::swap_ranges(a, a + stride, b);
        }
        return true;
    }
} // namespace aetherkiri::xsystem4
