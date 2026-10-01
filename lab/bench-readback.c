// bench-readback: measure the costs that bound a DRM-less compositor on WSL2:
//   - GPU->CPU readback of a full output frame (sync glReadPixels and async PBO)
//   - CPU->GPU upload of a full client shm buffer (glTexSubImage2D)
//   - a representative blur-like composition pass (N fullscreen textured quads)
// Uses EGL_PLATFORM_SURFACELESS_MESA (no DRM device needed); run with GALLIUM_DRIVER=d3d12.
// build: cc -O2 bench-readback.c -o bench-readback -lEGL -lGLESv2
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static GLuint mkprog(void) {
    const char* vs = "#version 300 es\nlayout(location=0) in vec2 p; out vec2 uv; void main(){uv=p*0.5+0.5; gl_Position=vec4(p,0,1);}";
    const char* fs = "#version 300 es\nprecision highp float; in vec2 uv; uniform sampler2D t; out vec4 o;"
                     "void main(){vec4 s=vec4(0); for(int i=-4;i<=4;i++) s+=texture(t,uv+vec2(float(i)/1920.0,0)); o=s/9.0;}";
    GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER), p = glCreateProgram();
    glShaderSource(v, 1, &vs, NULL); glCompileShader(v);
    glShaderSource(f, 1, &fs, NULL); glCompileShader(f);
    glAttachShader(p, v); glAttachShader(p, f); glLinkProgram(p);
    GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { char log[1024]; glGetProgramInfoLog(p, 1024, NULL, log); printf("link failed: %s\n", log); }
    return p;
}

static void bench(int w, int h, int iters) {
    size_t bytes = (size_t)w * h * 4;
    uint8_t* cpu = malloc(bytes);
    memset(cpu, 0x80, bytes);
    GLuint tex[2], fbo[2];
    glGenTextures(2, tex); glGenFramebuffers(2, fbo);
    for (int i = 0; i < 2; i++) {
        glBindTexture(GL_TEXTURE_2D, tex[i]);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[i], 0);
    }
    // 1) upload (client shm -> texture)
    glBindTexture(GL_TEXTURE_2D, tex[0]);
    glFinish();
    double t0 = now_ms();
    for (int i = 0; i < iters; i++) {
        cpu[i] = (uint8_t)i;
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, cpu);
    }
    glFinish();
    double up = (now_ms() - t0) / iters;

    // 2) composition: 6 blur-ish fullscreen passes ping-ponging
    GLuint prog = mkprog();
    glUseProgram(prog);
    float quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    GLuint vbo, vao;
    glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glViewport(0, 0, w, h);
    glFinish();
    t0 = now_ms();
    for (int i = 0; i < iters; i++)
        for (int pass = 0; pass < 6; pass++) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbo[(pass + 1) & 1]);
            glBindTexture(GL_TEXTURE_2D, tex[pass & 1]);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
    glFinish();
    double comp = (now_ms() - t0) / iters;

    // 3) sync readback
    glBindFramebuffer(GL_FRAMEBUFFER, fbo[0]);
    t0 = now_ms();
    for (int i = 0; i < iters; i++) {
        glClearColor(i & 1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, cpu);
    }
    double rb = (now_ms() - t0) / iters;

    // 4) async PBO readback (double-buffered), measure CPU-side time per frame incl. map+memcpy
    GLuint pbo[2];
    glGenBuffers(2, pbo);
    for (int i = 0; i < 2; i++) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[i]);
        glBufferData(GL_PIXEL_PACK_BUFFER, bytes, NULL, GL_STREAM_READ);
    }
    t0 = now_ms();
    for (int i = 0; i < iters + 1; i++) {
        if (i < iters) {
            glClearColor(0, i & 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[i & 1]);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, 0);
        }
        if (i > 0) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[(i - 1) & 1]);
            void* p = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, bytes, GL_MAP_READ_BIT);
            if (p) memcpy(cpu, p, bytes);
            glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
    }
    double pb = (now_ms() - t0) / iters;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    // 5) partial damage readback (a 400x300 region, typical terminal/cursor-blink damage)
    t0 = now_ms();
    for (int i = 0; i < iters; i++) {
        glClearColor(0, 0, i & 1, 1); glClear(GL_COLOR_BUFFER_BIT);
        glReadPixels(100, 100, 400, 300, GL_RGBA, GL_UNSIGNED_BYTE, cpu);
    }
    double rbd = (now_ms() - t0) / iters;

    printf("%4dx%-4d  upload %6.2f ms (%5.2f GB/s) | 6-pass blur comp %6.2f ms | readback sync %6.2f ms (%5.2f GB/s) | PBO async %6.2f ms | damage 400x300 %5.2f ms\n",
           w, h, up, bytes / up / 1e6, comp, rb, bytes / rb / 1e6, pb, rbd);
    glDeleteTextures(2, tex); glDeleteFramebuffers(2, fbo); glDeleteBuffers(2, pbo);
    free(cpu);
}

int main(void) {
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (!eglInitialize(dpy, NULL, NULL)) { printf("eglInitialize failed\n"); return 1; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
    EGLContext ctx    = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) { printf("context failed\n"); return 1; }
    printf("GL_RENDERER: %s | %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    bench(1920, 1080, 60);
    bench(2560, 1440, 60);
    bench(3840, 2160, 40);
    return 0;
}
