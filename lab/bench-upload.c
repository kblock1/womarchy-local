// bench-upload: which glTexSubImage2D variant is slow on Mesa d3d12 (WSL)?
// Mimics Hyprland's shm texture path (BGRA, GL_UNPACK_ROW_LENGTH, sub-rects) vs. plain RGBA.
// build: cc -O2 bench-upload.c -o bench-upload -lEGL -lGLESv2
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

static void run(const char* name, int w, int h, GLint internal, GLenum fmt, int storage, int rowlen, int subw, int subh, int iters) {
    int      stride = rowlen ? rowlen : w;
    uint8_t* px     = malloc((size_t)stride * h * 4);
    memset(px, 0x7f, (size_t)stride * h * 4);
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    if (storage)
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);
    else
        glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, fmt, GL_UNSIGNED_BYTE, NULL);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (rowlen)
        glPixelStorei(GL_UNPACK_ROW_LENGTH, rowlen);
    glFinish();
    double t0 = now_ms();
    for (int i = 0; i < iters; i++) {
        px[i % 64] = (uint8_t)i;
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, subw, subh, fmt, GL_UNSIGNED_BYTE, px);
    }
    glFinish();
    double dt = (now_ms() - t0) / iters;
    printf("%-44s %5dx%-5d %8.2f ms  %6.2f GB/s  (err 0x%x)\n", name, subw, subh, dt, (double)subw * subh * 4 / dt / 1e6, glGetError());
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glDeleteTextures(1, &tex);
    free(px);
}

int main(void) {
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    eglInitialize(dpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
    EGLContext ctx    = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    const int W = 640, H = 690, N = 30;
    run("RGBA8 storage + RGBA", W, H, 0, GL_RGBA, 1, 0, W, H, N);
    run("RGBA teximage + RGBA", W, H, GL_RGBA, GL_RGBA, 0, 0, W, H, N);
    run("BGRA teximage + BGRA (Hyprland shm)", W, H, GL_BGRA_EXT, GL_BGRA_EXT, 0, 0, W, H, N);
    run("BGRA + BGRA + ROW_LENGTH=w", W, H, GL_BGRA_EXT, GL_BGRA_EXT, 0, W, W, H, N);
    run("BGRA + BGRA + ROW_LENGTH=w+16", W, H, GL_BGRA_EXT, GL_BGRA_EXT, 0, W + 16, W, H, N);
    run("RGBA8 storage + BGRA upload", W, H, 0, GL_BGRA_EXT, 1, 0, W, H, N);
    run("BGRA + BGRA 1080p", 1920, 1080, GL_BGRA_EXT, GL_BGRA_EXT, 0, 0, 1920, 1080, 10);
    run("RGBA8 storage + RGBA 1080p", 1920, 1080, 0, GL_RGBA, 1, 0, 1920, 1080, 10);
    return 0;
}
