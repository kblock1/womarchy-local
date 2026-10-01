// bench-faults: count page faults and time for N direct 1080p glTexSubImage2D calls (d3d12).
// build: cc -O2 bench-faults.c -o bench-faults -lEGL -lGLESv2
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void faults(long* minor, long* major) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    *minor = ru.ru_minflt;
    *major = ru.ru_majflt;
}

int main(int argc, char** argv) {
    int        n   = argc > 1 ? atoi(argv[1]) : 3;
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    eglInitialize(dpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
    EGLContext ctx    = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    const int W = 1920, H = 1080;
    uint8_t*  src = malloc((size_t)W * H * 4);
    memset(src, 0x44, (size_t)W * H * 4);
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
    glFinish();
    for (int i = 0; i < n; i++) {
        long   mi0, ma0, mi1, ma1;
        faults(&mi0, &ma0);
        double t = now_ms();
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, src);
        double t1 = now_ms();
        glFinish();
        faults(&mi1, &ma1);
        printf("upload %d: call %.1f ms, +finish %.1f ms, minor faults %ld, major %ld\n", i, t1 - t, now_ms() - t, mi1 - mi0, ma1 - ma0);
    }
    return 0;
}
