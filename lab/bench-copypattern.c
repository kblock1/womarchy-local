// bench-copypattern: same d3d12 upload-heap mapping, different CPU copy patterns.
// build: cc -O2 bench-copypattern.c -o bench-copypattern -lEGL -lGLESv2
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <immintrin.h>
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

__attribute__((target("avx2"))) static void copy_nt(uint8_t* dst, const uint8_t* src, size_t n) {
    for (size_t i = 0; i + 32 <= n; i += 32)
        _mm256_stream_si256((__m256i*)(dst + i), _mm256_loadu_si256((const __m256i*)(src + i)));
    _mm_sfence();
}

int main(void) {
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    eglInitialize(dpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
    EGLContext ctx    = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    const int    W = 1920, H = 1080, ROW = W * 4;
    const size_t SZ = (size_t)ROW * H;
    uint8_t*     src = aligned_alloc(64, SZ);
    memset(src, 0x21, SZ);
    GLuint pbo;
    glGenBuffers(1, &pbo);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    glBufferData(GL_PIXEL_UNPACK_BUFFER, SZ, NULL, GL_STREAM_DRAW);
    uint8_t* map = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, SZ, GL_MAP_WRITE_BIT);
    memcpy(map, src, SZ); // fault in

    double t = now_ms();
    memcpy(map, src, SZ);
    printf("one 8 MB memcpy:              %8.2f ms\n", now_ms() - t);
    t = now_ms();
    for (int y = 0; y < H; y++)
        memcpy(map + (size_t)y * ROW, src + (size_t)y * ROW, ROW);
    printf("row-by-row memcpy (7680 B):   %8.2f ms\n", now_ms() - t);
    t = now_ms();
    for (int y = 0; y < H; y++)
        copy_nt(map + (size_t)y * ROW, src + (size_t)y * ROW, ROW);
    printf("row-by-row streaming stores:  %8.2f ms\n", now_ms() - t);
    t = now_ms();
    volatile uint32_t* d = (volatile uint32_t*)map;
    for (size_t i = 0; i < SZ / 4 / 16; i++)
        d[i] = (uint32_t)i;
    printf("scalar 4-byte stores (1/16):  %8.2f ms\n", now_ms() - t);
    glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    return 0;
}
