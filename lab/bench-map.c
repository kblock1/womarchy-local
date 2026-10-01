// bench-map: isolate what is slow in Mesa d3d12 texture uploads on WSL 3.0.1.
// build: cc -O2 bench-map.c -o bench-map -lEGL -lGLESv2
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
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

int main(void) {
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    eglInitialize(dpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
    EGLContext ctx    = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

    const int    W = 1920, H = 1080;
    const size_t SZ = (size_t)W * H * 4;
    uint8_t*     src = malloc(SZ);
    memset(src, 0x33, SZ);
    GLuint tex, pbo;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
    glGenBuffers(1, &pbo);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    glFinish();

    for (int i = 0; i < 3; i++) {
        double t = now_ms();
        glBufferData(GL_PIXEL_UNPACK_BUFFER, SZ, NULL, GL_STREAM_DRAW);
        double t1 = now_ms();
        uint8_t* p = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, SZ, GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
        double t2 = now_ms();
        memcpy(p, src, SZ);
        double t3 = now_ms();
        glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, 0);
        glFinish();
        printf("PBO orphan+map/frame: alloc %.2f map %.2f memcpy %.2f total %.2f ms\n", t1 - t, t2 - t1, t3 - t2, now_ms() - t);
    }
    for (int i = 0; i < 3; i++) {
        double t = now_ms();
        uint8_t* p = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, SZ, GL_MAP_WRITE_BIT | GL_MAP_UNSYNCHRONIZED_BIT);
        double t2 = now_ms();
        memcpy(p, src, SZ);
        double t3 = now_ms();
        glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, 0);
        glFinish();
        printf("PBO reuse (unsync map): map %.2f memcpy %.2f total %.2f ms\n", t2 - t, t3 - t2, now_ms() - t);
    }
    for (int i = 0; i < 2; i++) {
        double t = now_ms();
        glBufferSubData(GL_PIXEL_UNPACK_BUFFER, 0, SZ, src);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, 0);
        glFinish();
        printf("PBO via glBufferSubData: total %.2f ms\n", now_ms() - t);
    }
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    for (int i = 0; i < 2; i++) {
        double t = now_ms();
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H / 16, GL_RGBA, GL_UNSIGNED_BYTE, src);
        glFinish();
        printf("direct glTexSubImage2D 1920x%d: %.2f ms\n", H / 16, now_ms() - t);
    }
    return 0;
}
