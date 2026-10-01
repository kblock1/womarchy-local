// bench-pbo: is the WSL 3.0.1 upload slowdown a per-mapping page-fault cost?
// Compare first vs repeated writes into a persistently mapped GL buffer (d3d12 upload heap),
// and glTexSubImage2D sourced from that PBO (GPU copy) vs. from client memory.
// build: cc -O2 bench-pbo.c -o bench-pbo -lEGL -lGLESv2
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
    PFNGLBUFFERSTORAGEEXTPROC glBufferStorageEXT_ = (PFNGLBUFFERSTORAGEEXTPROC)eglGetProcAddress("glBufferStorageEXT");
    printf("GL_RENDERER: %s  buffer_storage: %s\n", glGetString(GL_RENDERER), glBufferStorageEXT_ ? "yes" : "no");

    const int W = 1920, H = 1080;
    const size_t SZ = (size_t)W * H * 4;
    uint8_t* src = malloc(SZ);
    memset(src, 0x55, SZ);

    GLuint pbo;
    glGenBuffers(1, &pbo);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
    glBufferStorageEXT_(GL_PIXEL_UNPACK_BUFFER, SZ, NULL, GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT);
    uint8_t* map = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, SZ, GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT);
    printf("persistent map: %p (err 0x%x)\n", (void*)map, glGetError());
    if (!map)
        return 1;
    for (int pass = 0; pass < 4; pass++) {
        double t = now_ms();
        memcpy(map, src, SZ);
        double dt = now_ms() - t;
        printf("memcpy 1080p into mapped upload buffer, pass %d: %8.2f ms (%.2f GB/s)\n", pass + 1, dt, SZ / dt / 1e6);
    }

    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
    glFinish();
    for (int pass = 0; pass < 3; pass++) {
        double t = now_ms();
        memcpy(map, src, SZ);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, 0); // from PBO
        glFinish();
        double dt = now_ms() - t;
        printf("PBO upload 1080p (memcpy + GPU copy), pass %d: %8.2f ms\n", pass + 1, dt);
    }
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    double t = now_ms();
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, src);
    glFinish();
    printf("direct glTexSubImage2D 1080p (for comparison): %8.2f ms\n", now_ms() - t);
    return 0;
}
