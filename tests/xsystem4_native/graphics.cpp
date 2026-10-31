#include "offscreen_context.h"
#include <array>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
extern "C" {
#include "system4/cg.h"
#include "gfx/gfx.h"
#include "gfx/private.h"
}

namespace {
void Require(bool condition, const char *message) {
    if(!condition)
        throw std::runtime_error(message);
}

GLuint Compile(GLenum type, const char *source) {
#ifdef USE_GLES
    const char *preamble = "#version 300 es\nprecision highp float;\n";
#else
    const char *preamble = "#version 140\n";
#endif
    const char *sources[] = { preamble, source };
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 2, sources, nullptr);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if(!compiled) {
        char log[4096]{};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        throw std::runtime_error(log);
    }
    return shader;
}

Shader Program(bool textured) {
    // The fill path deliberately has no UV input. A driver may similarly
    // remove the unused UV input from the runtime's real fill shader.
    GLuint vertex = Compile(GL_VERTEX_SHADER, textured ? R"(
        in vec4 vertex_pos;
        in vec2 vertex_uv;
        out vec2 uv;
        void main() { gl_Position = vertex_pos; uv = vertex_uv; }
    )" : R"(
        in vec4 vertex_pos;
        void main() { gl_Position = vertex_pos; }
    )");
    GLuint fragment = Compile(GL_FRAGMENT_SHADER, textured ? R"(
        uniform sampler2D tex;
        in vec2 uv;
        out vec4 color;
        void main() { color = texture(tex, uv); }
    )" : R"(
        out vec4 color;
        void main() { color = vec4(1.0, 0.5, 0.25, 1.0); }
    )");
    Shader result{};
    result.program = glCreateProgram();
    glAttachShader(result.program, vertex);
    glAttachShader(result.program, fragment);
    glLinkProgram(result.program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(result.program, GL_LINK_STATUS, &linked);
    Require(linked, "Could not link the graphics contract shader");
    result.vertex_pos = glGetAttribLocation(result.program, "vertex_pos");
    result.vertex_uv = glGetAttribLocation(result.program, "vertex_uv");
    Require(result.vertex_pos >= 0, "Position must remain active");
    Require(textured ? result.vertex_uv >= 0 : result.vertex_uv == -1,
            "Unexpected UV attribute activity");
    return result;
}

void VerifyFrame(aetherkiri::xsystem4::OffscreenContext &context,
                 const std::array<uint8_t, 4> &expected) {
    std::vector<uint8_t> pixels;
    std::string error;
    if(!context.read(pixels, error))
        throw std::runtime_error(error);
    Require(pixels.size() == 8 * 8 * 4, "Unexpected frame dimensions");
    for(size_t offset = 0; offset < pixels.size(); offset += 4)
        for(size_t channel = 0; channel < 4; ++channel) {
            const int delta = int(pixels[offset + channel]) - expected[channel];
            Require(delta >= -1 && delta <= 1, "Incorrect rendered pixel");
        }
}
} // namespace

int main() {
    try {
        aetherkiri::xsystem4::OffscreenContext context;
        std::string error;
        if(!context.initialize(8, 8, error))
            throw std::runtime_error(error);
        std::printf("Graphics contract renderer: %s\n", glGetString(GL_RENDERER));
        const gfx_vertex vertices[] = {
            {-1, -1, 0, 1, 0, 0}, {1, -1, 0, 1, 1, 0},
            {-1, 1, 0, 1, 0, 1}, {1, 1, 0, 1, 1, 1}
        };
        const GLuint indices[] = {0, 1, 3, 2};
        glGenVertexArrays(1, &sdl.gl.vao);
        glBindVertexArray(sdl.gl.vao);
        glGenBuffers(1, &sdl.gl.vbo);
        glBindBuffer(GL_ARRAY_BUFFER, sdl.gl.vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        glGenBuffers(1, &sdl.gl.quad_vbo);
        glBindBuffer(GL_ARRAY_BUFFER, sdl.gl.quad_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        glGenBuffers(1, &sdl.gl.rect_ibo);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sdl.gl.rect_ibo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
        glBindVertexArray(0);
        glViewport(0, 0, 8, 8);
        Shader fill = Program(false), textured = Program(true);
        GLuint texture = 0;
        const std::array<uint8_t, 4> texel = {32, 96, 224, 255};
        glGenTextures(1, &texture);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, texel.data());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        Require(glGetError() == GL_NO_ERROR, "Graphics setup failed");
        // Reuse the same production VAO across missing/active/missing UV
        // inputs and both vertex buffers, as fades and sprite draws do.
        for(auto shape : {GFX_RECTANGLE, GFX_QUADRILATERAL}) {
            for(Shader *shader : {&fill, &textured, &fill}) {
                glClearColor(0, 0, 0, 1);
                glClear(GL_COLOR_BUFFER_BIT);
                glUseProgram(shader->program);
                if(shader == &textured)
                    glUniform1i(glGetUniformLocation(shader->program, "tex"), 0);
                gfx_render_job job{};
                job.shader = shader;
                job.shape = shape;
                gfx_run_job(&job);
                // Do not clear GL errors before the real presentation read.
                VerifyFrame(context, shader == &fill
                                         ? std::array<uint8_t, 4>{255, 128, 64, 255}
                                         : texel);
            }
        }
        glDeleteProgram(fill.program);
        glDeleteProgram(textured.program);
        glDeleteTextures(1, &texture);
        glDeleteBuffers(1, &sdl.gl.vbo);
        glDeleteBuffers(1, &sdl.gl.quad_vbo);
        glDeleteBuffers(1, &sdl.gl.rect_ibo);
        glDeleteVertexArrays(1, &sdl.gl.vao);
        sdl = {};
        Require(glGetError() == GL_NO_ERROR, "Graphics cleanup failed");
        std::puts("XSYSTEM4_GRAPHICS_CONTRACT_OK");
        return 0;
    } catch(const std::exception &error) {
        std::fprintf(stderr, "Graphics contract failed: %s\n", error.what());
        return 1;
    }
}
