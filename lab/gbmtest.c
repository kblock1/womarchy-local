// gbmtest: isolate GBM allocation + EGL dmabuf render/readback behaviour on a
// vgem node under Mesa kms_swrast with GALLIUM_DRIVER=llvmpipe|d3d12.
// build: cc -O2 gbmtest.c -o gbmtest -lgbm -lEGL -lGLESv2 -ldrm $(pkg-config --cflags libdrm)
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char** argv) {
    const char* node = argc > 1 ? argv[1] : "/dev/dri/card0";
    int         w = 1920, h = 1080;
    int         fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }
    struct gbm_device* gbm = gbm_create_device(fd);
    printf("gbm backend: %s\n", gbm ? gbm_device_get_backend_name(gbm) : "(null)");

    struct { const char* name; uint32_t flags; } combos[] = {
        {"RENDERING", GBM_BO_USE_RENDERING},
        {"RENDERING|SCANOUT", GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT},
        {"RENDERING|LINEAR", GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR},
        {"LINEAR", GBM_BO_USE_LINEAR},
        {"SCANOUT", GBM_BO_USE_SCANOUT},
        {"0", 0},
    };
    struct gbm_bo* keep = NULL;
    for (unsigned i = 0; i < sizeof(combos) / sizeof(combos[0]); i++) {
        struct gbm_bo* bo = gbm_bo_create(gbm, w, h, GBM_FORMAT_XRGB8888, combos[i].flags);
        printf("gbm_bo_create XR24 flags=%-18s -> %s", combos[i].name, bo ? "OK" : "FAIL");
        if (bo) printf(" stride=%u mod=0x%llx", gbm_bo_get_stride(bo), (unsigned long long)gbm_bo_get_modifier(bo));
        printf("\n");
        if (bo && !keep) keep = bo; else if (bo) gbm_bo_destroy(bo);
    }
    uint64_t mods[] = {DRM_FORMAT_MOD_LINEAR};
    struct gbm_bo* bm = gbm_bo_create_with_modifiers2(gbm, w, h, GBM_FORMAT_XRGB8888, mods, 1, GBM_BO_USE_RENDERING);
    printf("gbm_bo_create_with_modifiers2(LINEAR, RENDERING) -> %s\n", bm ? "OK" : "FAIL");
    if (bm) gbm_bo_destroy(bm);

    // Render-to-dmabuf test: allocate a dumb-backed dmabuf via GBM (if any succeeded) and draw into it via EGLImage.
    if (!keep) { printf("no bo could be allocated; stopping\n"); return 2; }
    int dmabuf = gbm_bo_get_fd(keep);
    printf("dmabuf fd=%d stride=%u\n", dmabuf, gbm_bo_get_stride(keep));

    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    EGLint     maj, min;
    if (!eglInitialize(dpy, &maj, &min)) { printf("eglInitialize failed\n"); return 3; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint     ctxattr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext ctx       = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctxattr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

    EGLint attrs[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_XRGB8888,
                      EGL_DMA_BUF_PLANE0_FD_EXT, dmabuf, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                      EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)gbm_bo_get_stride(keep), EGL_NONE};
    PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR_ = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC glEGLImageTargetRenderbufferStorageOES_ =
        (PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC)eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");
    EGLImageKHR img = eglCreateImageKHR_(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
    printf("eglCreateImage(dmabuf) -> %s (err 0x%x)\n", img != EGL_NO_IMAGE_KHR ? "OK" : "FAIL", eglGetError());
    if (img == EGL_NO_IMAGE_KHR) return 4;

    GLuint rb, fbo;
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glEGLImageTargetRenderbufferStorageOES_(GL_RENDERBUFFER, img);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    printf("FBO status 0x%x\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));

    // Map the BO's memory directly (what a KMS scanout / screencopy consumer would read).
    uint32_t stride = 0;
    void*    map_data = NULL;
    double   total = 0;
    int      frames = 60, ok = 1;
    for (int f = 0; f < frames; f++) {
        float r = (f % 2) ? 1.f : 0.f, g = (f % 2) ? 0.f : 1.f;
        double t0 = now_ms();
        glClearColor(r, g, 0.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        total += now_ms() - t0;
        uint8_t* p = gbm_bo_map(keep, w / 2, h / 2, 1, 1, GBM_BO_TRANSFER_READ, &stride, &map_data);
        if (!p) { printf("gbm_bo_map failed\n"); ok = 0; break; }
        uint32_t px = *(uint32_t*)p; // XRGB little endian: B,G,R,X
        uint32_t expect = (f % 2) ? 0x00ff0000 : 0x0000ff00;
        if (f < 2 || (px & 0x00ffffff) != expect)
            printf("frame %d: dmabuf pixel=0x%08x expect 0x%08x %s\n", f, px, expect, (px & 0x00ffffff) == expect ? "MATCH" : "MISMATCH");
        if ((px & 0x00ffffff) != expect) ok = 0;
        gbm_bo_unmap(keep, map_data);
    }
    printf("render-to-dmabuf coherent across %d frames: %s; avg clear+finish %.3f ms\n", frames, ok ? "YES" : "NO", total / frames);
    return ok ? 0 : 5;
}
