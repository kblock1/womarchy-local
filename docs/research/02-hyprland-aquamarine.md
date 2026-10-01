# 02 — Hyprland + aquamarine on WSL2: requirements, failure points, patch options

Status: research report, 2026-09-30. Scope: what Hyprland and its backend library aquamarine need from the graphics stack, why they fail on WSL2, and the smallest changes that would let them run there with GPU acceleration.

Target environment (verified by the user on the target machine): WSL 2.7.10, kernel `6.18.33.2-microsoft-standard-WSL2`, NVIDIA RTX 5070. There is no `/dev/dri`; the GPU is reachable only through `/dev/dxg`, via Mesa `d3d12` (Gallium, sw/drisw winsys) and `dzn` (Vulkan). `vgem` is available as a module (`CONFIG_DRM_VGEM=m`). VKMS, UDMABUF and virtio-gpu are not available. WSLg runs Weston 9 with an RDP backend.

## 0. Sources and versions

| Source | Revision | Notes |
|---|---|---|
| hyprwm/aquamarine | `04bfb7db7ef7d5b2cc6860623396c606ef015e96` (2026-09-29, "drm: guard backend in log"), branch `main`; latest release **v0.15.1** (2026-09-17) | cloned at `upstream/aquamarine` (`--depth 50`) |
| hyprwm/Hyprland | `ce2167a232eb0af1bb3c0a9dddf85cab1bc38aae` (2026-09-30, "config/lua: add hl.get_devices()"), branch `main` (`VERSION` = 0.56.0); latest release **v0.56.2** (2026-08-05) | cloned at `upstream/Hyprland` (`--depth 50`); submodules were not needed |
| Mesa | `cec59b299704edc442d930ea9e06ab2edcf5ad7b` (2026-09-30, 26.3.0-devel) | sparse and shallow scratch checkout, not kept in the repo. Paths below are relative to the Mesa tree: https://gitlab.freedesktop.org/mesa/mesa/-/tree/main |
| microsoft/weston-mirror (the WSLg compositor) | branch `working` @ `7fbf69314f8a74450c265650232f66f59a4e0630` (2026-09-11) | individual files fetched |
| Linux | `v6.18` `drivers/gpu/drm/{vgem/vgem_drv.c,drm_ioctl.c,drm_dumb_buffers.c}` | fetched from torvalds/linux |
| UjinT34/Hyprland branch `vulkan` (PR #13272) | head as of 2026-09-30 | `src/render/vulkan/Device.cpp` fetched |

hyprutils and hyprgraphics were not needed to answer the questions.

Upstream contribution note: the hyprwm repos ship an `AGENTS.md`/`CLAUDE.md` that points to an AI-usage policy (https://github.com/hyprwm/.github/blob/main/policies/AI_USAGE.md). If any of these patches are proposed upstream, humans should open the issues and PRs, following that policy.

---

## 1. TL;DR

- **Hard requirement chain today.** Every Hyprland output frame is rendered into an aquamarine swapchain buffer. That buffer must be a dmabuf, and it must be importable into EGL with `EGL_EXT_image_dma_buf_import`. Hyprland wraps it as an `EGLImage`, then a `GL_RENDERBUFFER`, then an FBO. aquamarine only has dmabuf allocators: GBM, plus DRM dumb for cursors. It creates the GBM allocator only from a backend that exposes a DRM fd. The headless backend exposes none. A DRM fd is therefore mandatory.
- **What WSL2 fails on, in order:**
  1. `CBackend::start()` finds no backend with a DRM fd and aborts: "Cannot open backend: no allocator available".
  2. Nested inside WSLg, the Wayland backend dies on version-mismatched binds (Weston 9 advertises `wl_compositor` v4, `xdg_wm_base` v1 and `wl_seat` v7, while aquamarine binds v6/v6/v9). It would then stop anyway on the missing `zwp_linux_dmabuf_v1`.
  3. Hyprland's EGL setup (`CHyprOpenGLImpl` constructor) would `RASSERT` because `openRenderNode(-1)` fails.
- **vgem + llvmpipe (approach a) is close but not unmodified.**
  - The DRM backend rejects vgem, even with `AQ_NO_KMS_REQUIREMENT=1`, because `DRM_CAP_CRTC_IN_VBLANK_EVENT` returns `EOPNOTSUPP` on non-KMS drivers.
  - The headless backend has no fd.
  - aquamarine always reopens the render node, but Mesa's `kms_swrast` needs the primary node for `CREATE_DUMB`.
  - About 40–80 lines in aquamarine fix this. After that, Hyprland needs no changes, as long as `GALLIUM_DRIVER=llvmpipe` and `GBM_ALWAYS_SOFTWARE=1` are set for the compositor.
  - The result is pure CPU compositing. That is less bad than it sounds, because Omarchy's defaults disable blur and shadows and use no rounding.
- **vgem + d3d12 (approach b) does not work.**
  - Mesa `d3d12` does not report `caps.dmabuf`. So `EGL_EXT_image_dma_buf_import` is absent, GBM falls back to dumb BOs (and `gbm_bo_get_fd` returns -1), and Hyprland cannot create a render target.
  - Fixing it would need a Mesa patch that emulates dmabuf with copies. That is hacky and unlikely to be accepted upstream.
- **Recommended: approach (c), a "no-DRM" GPU mode.**
  - Hyprland renders with `d3d12` on the software EGL device (GPU-accelerated, no dmabuf) into plain GL FBO textures.
  - Only damaged regions are read back into shm buffers from a new aquamarine shm allocator.
  - The frames go to a sink:
    - first, headless output + wayvnc, or a wl_shm Wayland backend into WSLg;
    - later, a dedicated "stream" backend to a Windows viewer.
  - Estimated patch size: aquamarine ≈300–450 LOC plus an optional stream backend of ≈800–1200 LOC; Hyprland ≈300–450 LOC.
- **Approach (d), Hyprland nested in WSLg, is (c) plus the wl_shm Wayland backend and a bind-version clamp.** It is the fastest way to see a GPU-composited desktop in a Windows window. It inherits WSLg limits: it goes through Weston/pixman and RDP, and Windows captures the Super key.
- **Approach (e), Vulkan, is not an option today.**
  - Hyprland's Vulkan renderer is a draft PR (#13272). It hard-requires `VK_EXT_external_memory_dma_buf` and `VK_EXT_image_drm_format_modifier`.
  - `dzn` has neither. It is Vulkan 1.2, exports only OPAQUE_FD memory, and its Linux WSI is software-only.

---

## 2. Hard requirements, at a glance

| Requirement | Where enforced | Satisfiable on stock WSL2? |
|---|---|---|
| A backend exposing a DRM fd, so aquamarine can build a GBM allocator | `aquamarine/src/backend/Backend.cpp:162-179` (`CBackend::start`) | No. Headless returns -1, DRM needs KMS, and Wayland needs the parent's dmabuf main device. |
| GBM device with PRIME export | `aquamarine/src/allocator/GBM.cpp:331-350` (`CGBMAllocator::create`) | Only via vgem, and only with the primary node plus `kms_swrast` and llvmpipe. |
| Output buffers are dmabufs, imported as `EGLImage` → renderbuffer | `Hyprland/src/render/gl/GLRenderbuffer.cpp:34-66`, `OpenGL.cpp:627-679` | No with d3d12 (no dmabuf caps); yes with llvmpipe on vgem. |
| EGL: `EGL_EXT_platform_device` (or `KHR_platform_gbm`), `EGL_KHR_no_config_context`, surfaceless make-current, `eglCreateSyncKHR`, `eglDupNativeFenceFDANDROID` and `eglWaitSyncKHR` resolvable via `eglGetProcAddress` | `OpenGL.cpp:297-366` | Yes (Mesa resolves these procs even if the display lacks the extension). |
| A DRM fd to select the EGL device or open GBM | `OpenGL.cpp:340-366`, `openRenderNode()` `OpenGL.cpp:124-155` | No. With fd -1 it asserts: "Couldn't open a gbm fd". |
| GLES ≥ 3.0 (3.2 preferred, 3.0 fallback), `GL_EXT_texture_format_BGRA8888` | `OpenGL.cpp:208-229`, `:382` | Yes. d3d12 offers ESSL 3.10, so Hyprland uses its 3.0 fallback; llvmpipe offers GLES 3.2. |
| Explicit sync (optional) | `EGL_ANDROID_native_fence_sync` (`OpenGL.cpp:394-397`); `DRM_CAP_SYNCOBJ_TIMELINE` (`Compositor.cpp:364-384`) | No, but optional. It falls back to implicit sync (`glFlush`, or `glFinish` for software renderers). |
| dmabuf for clients (linux-dmabuf, wl_drm) | `ProtocolManager.cpp:253-261`, `LinuxDMABUF.cpp:442-535` | Optional. Hyprland skips both globals if EGL reports no dmabuf formats or there is no DRM device. |

---

## 3. aquamarine in detail

### 3.1 Backend selection and start

- `include/aquamarine/backend/Backend.hpp:26-31` defines `eBackendType { AQ_BACKEND_WAYLAND, AQ_BACKEND_DRM, AQ_BACKEND_HEADLESS, AQ_BACKEND_NULL }`.
  - There are four backends: DRM, Wayland, Headless and Null.
  - There is no shm, VNC or RDP backend.
- Request modes (`:42-55`): `MANDATORY`, `IF_AVAILABLE`, `FALLBACK`.
  - `FALLBACK` gets no special handling anywhere in `src/`: `CBackend::start` just starts every implementation.
  - So a FALLBACK Wayland backend is always attempted whenever `wl_display_connect(nullptr)` succeeds, and it will under WSLg, because `WAYLAND_DISPLAY` is set.
- There is no backend-selection environment variable. The consumer chooses the backend list.
- Hyprland hard-codes the list in `Hyprland/src/Compositor.cpp:314-326`:
  - HEADLESS (MANDATORY),
  - DRM (IF_AVAILABLE),
  - WAYLAND (FALLBACK).
- `CBackend::create()` (`Backend.cpp:60-110`) instantiates each backend. DRM goes through `CDRMBackend::attempt()` and may return several GPUs.
- `CBackend::start()` (`Backend.cpp:121-192`) runs these steps in order:
  1. It calls `impl->start()` on each backend. A failing MANDATORY backend aborts the start.
  2. It erases implementations with no poll fds (except Null).
  3. It creates the allocator. Lines 162-174 are marked "TODO: obviously change this when (if) we add different allocators": the first implementation with `drmFD() >= 0` gets `reopenDRMNode(fd)` and then `CGBMAllocator::create`.
  4. Lines 176-179: if there is no allocator and the first implementation is not `AQ_BACKEND_NULL`, it logs "Cannot open backend: no allocator available" and returns false. Hyprland then calls `throwError("CBackend::create() failed!")` (`Compositor.cpp:336-343`).
  5. It calls `onReady()` on every backend. The Wayland and headless backends create their swapchains here or in `createOutput`.
- `reopenDRMNode(int drmFD, bool allowRenderNode = true)` (`Backend.cpp:330-387`), copied from wlroots:
  - If the fd is DRM master, it tries an empty `drmModeCreateLease`. On `EINVAL`/`EOPNOTSUPP` it falls back to opening by name.
  - It then prefers the **render node** (`drmGetRenderDeviceNameFromFd`) and falls back to the primary node.
  - It uses `drmGetMagic`/`drmAuthMagic` if it reopened a primary node while master.
  - This matters for vgem: see §5.1.

### 3.2 Per-backend DRM-fd acquisition

| Backend | File | DRM fd | Allocator | Notes |
|---|---|---|---|---|
| **DRM** | `src/backend/drm/DRM.cpp` | The GPU's primary node, opened through a libseat session (`CSession::attempt`, `Session.cpp:294ff`). The render node is resolved via `resolveMatchingRenderNode`. | `CGBMAllocator` on the reopened node, plus `CDRMDumbAllocator` for CPU cursors (`DRM.cpp:288`, `:372`) | `scanGPUs()` (`:122-257`) enumerates udev DRM cards and keeps only KMS devices (`CSessionDevice::openIfKMS`, `Session.cpp:287-292`, bypassable with `AQ_NO_KMS_REQUIREMENT=1`). `checkFeatures()` (`:712-771`) **requires** `DRM_CAP_PRIME` import, `DRM_CAP_CRTC_IN_VBLANK_EVENT`, `DRM_CAP_TIMESTAMP_MONOTONIC` and `DRM_CLIENT_CAP_UNIVERSAL_PLANES`. `initResources()` (`:775ff`) requires `drmModeGetResources`. Multi-GPU uses the blitter `CDRMRenderer` (`drm/Renderer.cpp`, its own EGL/GBM). |
| **Wayland** | `src/backend/Wayland.cpp` | Taken from the parent compositor's `zwp_linux_dmabuf_v1` v4 default feedback `main_device` (`initDmabuf()`, `:376-475`). The render node is preferred, else the primary node (`:388-423`), then opened with `open()` (`:464-472`). `drmFD()` and `drmRenderNodeFD()` both return it (`:159-166`). | the global `primaryAllocator` (GBM) | See §3.6. |
| **Headless** | `src/backend/Headless.cpp` | **Always -1** (`:133-139`) | the global `primaryAllocator` | Outputs are 1920x1080@60 by default (`createOutput`, `:187-208`). `commit()` immediately emits `present` (`:27-34`). Frames are paced by a timerfd at the mode's refresh rate (`scheduleFrame`, `:56-105`). There is no cursor (`getCursorFormats` returns `{}`). Render formats: if a DRM backend is present, its renderable formats; otherwise a hard-coded list of 8-bit formats (modifier `INVALID`) and 10-bit formats (`LINEAR`) (`:157-181`). |
| **Null** | `src/backend/Null.cpp` | -1 | none | `createOutput` returns false. It is the only backend that `start()` allows to run with no allocator, and only when it is the first implementation (`Backend.cpp:176`). Hyprland only references it in `SystemInfo.cpp`. |

### 3.3 Allocators

- `include/aquamarine/allocator/Allocator.hpp`: `eAllocatorType { AQ_ALLOCATOR_TYPE_GBM, AQ_ALLOCATOR_TYPE_DRM_DUMB }`. **There is no shm or memfd allocator.**
- **GBM**: `src/allocator/GBM.cpp`.
  - `CGBMAllocator::create` (`:331-350`) requires `drmGetCap(DRM_CAP_PRIME) & DRM_PRIME_CAP_EXPORT`, then calls `gbm_create_device(fd)` (`:352`).
  - The `CGBMBuffer` constructor (`:64-255`):
    - picks a format (`guessFormatFrom`);
    - filters modifiers against the backend's render and renderable formats;
    - uses `gbm_bo_create_with_modifiers2`, or `gbm_bo_create` with `GBM_BO_USE_RENDERING|SCANOUT` when there are no explicit modifiers (the headless 8-bit case);
    - exports one fd per plane (`gbm_bo_get_fd_for_plane`, `:228-241`);
    - reports buffer type `BUFFER_TYPE_DMABUF`;
    - supports `beginDataPtr` via `gbm_bo_map`.
- **DRM dumb**: `src/allocator/DRMDumb.cpp:113-136`. It requires the **primary node** and `DRM_CAP_DUMB_BUFFER`, which is KMS-only in the kernel (`drm_ioctl.c` `drm_getcap`). Buffers are dumb BOs with a PRIME fd, reported as `BUFFER_TYPE_DMABUF` with `BUFFER_CAPABILITY_DATAPTR`. It is used only for DRM CPU cursors.

### 3.4 Swapchain

`src/allocator/Swapchain.cpp`:

- `reconfigure()` (`:22ff`) allocates `length` buffers from the allocator. When the format is `INVALID`, it takes the format from `buffers.at(0)->dmabuf().format` (`:55`). This is a dmabuf assumption, and an shm allocator would need a small fix here.
- `next(int* age)` (`:62ff`) is a plain rotation and always reports `age = length`.
- `rollback()` exists.
- Hyprland sets `length = 3` and `scanout = true` (`Monitor.cpp` `CMonitorState::updateSwapchain`, `:2622-2646`).

### 3.5 Buffer types

`include/aquamarine/buffer/Buffer.hpp`:

- `eBufferType { DMABUF, SHM, MISC }`.
- `SDMABUFAttrs` holds `{size, format, modifier, planes, offsets[4], strides[4], fds[4]}`.
- `SSHMAttrs` holds `{fd, format, size, stride, offset}`.
- `IBuffer` has `dmabuf()`, `shm()`, `beginDataPtr()`/`endDataPtr()`, `caps()` (`DATAPTR`), `isSynchronous()`, and lock/backend-pin tracking.

The shm plumbing already exists in the interface. Hyprland's own client `wl_shm` buffers use it. No aquamarine allocator produces shm buffers, though.

### 3.6 How the Wayland backend presents to its parent

- `CWaylandBackend::start()` (`Wayland.cpp:97-157`) binds at **fixed versions**, regardless of what the parent advertises:
  - `wl_seat` v9 (`:121`)
  - `xdg_wm_base` v6 (`:125`)
  - `wl_compositor` v6 (`:129`)
  - `wl_shm` v1 (`:132`)
  - `zwp_linux_dmabuf_v1` v4 (`:136`)
- Required globals (`:147-150`): xdg, compositor, seat, **dmabuf** (and dmabuf init must not fail), and shm. If any is missing, it logs "Wayland backend cannot start: Missing protocols".
- Upstream history: issue hyprwm/aquamarine#398 (2026-09) documents the fixed-version bind aborting under a wlroots parent that advertises `xdg_wm_base` v5. The fix, PR #427 ("clamp registry bind versions", 2026-09-28), was **closed unmerged**, and HEAD still binds fixed versions.
- `initDmabuf()` (`:376-475`) takes the DRM node from the default feedback's `main_device`. If the parent sends no main device, `drmState.fd` stays -1, and `CBackend::start` then fails because there is no allocator.
- Output buffers: `CWaylandBuffer` (`:898-917`) **always** builds a `zwp_linux_buffer_params_v1` from `buffer->dmabuf()` and calls `create_immed`. **There is no `wl_shm` path for output frames.**
- Cursor: `setCursor` (`:780-861`) **does** have a `wl_shm` path. It copies into a new shm file and creates a `wl_shm_pool` and `wl_buffer`, and falls back to dmabuf.
- Frame loop: `commit()` (`:651-738`) does attach, then `damage_buffer(0,0,INT32_MAX,INT32_MAX)` (always full damage), then a frame callback, then commit, then flush. `onFrameDone` emits `present` and `frame`.
- Open issues:
  - #348: a nested output stops presenting after the first frame. It is an open frame-loop bug.
  - **#228: "Wayland backend, support Shared memory buffers (not just dmabuf)"** (2025-12-29, open, no maintainer reply). This is the natural upstream anchor for an shm allocator and wl_shm output buffers.

### 3.7 Environment variables

The complete list found in `src/`. Most are documented in `docs/env.md` and on the wiki's "Environment variables" page.

| Var | Effect | Where |
|---|---|---|
| `AQ_DRM_DEVICES=/dev/dri/cardA:/dev/dri/cardB` | Explicit ordered GPU list; the first is primary. It only filters udev-enumerated KMS devices. | `DRM.cpp:203` |
| `AQ_NO_ATOMIC=1` | Use legacy KMS | `DRM.cpp:751` |
| `AQ_MGPU_NO_EXPLICIT=1` | No explicit fences on multi-GPU blits | `DRM.cpp:2454`, `:2699` |
| `AQ_NO_MODIFIERS=1` | Disable ADDFB2 modifiers | `DRM.cpp:745` |
| `AQ_FORCE_LINEAR_BLIT=0` | Disable forced LINEAR on multi-GPU buffers (it is on unless explicitly `0`) | `GBM.cpp:143` |
| `AQ_NO_KMS_REQUIREMENT=1` | `openIfKMS` accepts non-KMS DRM devices (headless GPUs) | `Session.cpp:289` |
| `AQ_LIBINPUT_NO_PLUGINS=1` | Do not load libinput plugins | `Session.cpp:355` |
| `AQ_TRACE=1` | Trace logging | `utils/Shared.cpp:14` |

Related Hyprland variables: `HYPRLAND_EGL_NO_MODIFIERS`, `HYPRLAND_TRACE`, `HYPRLAND_NO_CRASHREPORTER`, `HYPRLAND_NO_RT`. **Hyprland has no software or no-DRM switch.**

---

## 4. Hyprland rendering in detail

### 4.1 Initialisation order

1. `CCompositor` creates and starts the aquamarine backend (`Compositor.cpp:314-343`).
2. It records `m_drm.fd = m_aqBackend->drmFD()` and `m_drmRenderNode.fd = drmRenderNodeFD()` (`:358-362`).
3. It probes syncobj support with `drmGetCap(DRM_CAP_SYNCOBJ_TIMELINE)` on both fds (`:364-384`).
4. `STAGE_BASICINIT` (`:699-703`) creates `g_pHyprOpenGL = makeUnique<CHyprOpenGLImpl>()`, then `g_pHyprRenderer = makeUnique<CHyprGLRenderer>()`.

### 4.2 Renderer abstraction

- `src/render/Renderer.hpp:67-70` defines `enum eType { RT_GL = 1, RT_VK = 2 }` in the new `IHyprRenderer` interface.
- Only `CHyprGLRenderer` (`GLRenderer.cpp`) exists on `main`. **There is no Vulkan renderer in main** as of 2026-09-30 (see §8e).
- GL work lives in `CHyprOpenGLImpl` (`OpenGL.cpp`, ~2.7k LOC).

### 4.3 EGL platform and extensions

`CHyprOpenGLImpl::CHyprOpenGLImpl()` (`OpenGL.cpp:297-416`):

- It picks `m_drmFD`: the render node fd if ≥0, else the display fd.
- `loadGLProc` (`:76-83`) **aborts** if `eglGetProcAddress` returns NULL for any of:
  - `glEGLImageTargetRenderbufferStorageOES`
  - `eglCreateImageKHR`, `eglDestroyImageKHR`
  - `eglQueryDmaBufFormatsEXT`, `eglQueryDmaBufModifiersEXT`
  - `glEGLImageTargetTexture2DOES`
  - `eglDebugMessageControlKHR`
  - `eglGetPlatformDisplayEXT`
  - `eglCreateSyncKHR`, `eglDestroySyncKHR`
  - `eglDupNativeFenceFDANDROID`
  - `eglWaitSyncKHR`

  Mesa returns these pointers even when the display lacks the extension, so this does not block WSL.
- It calls `RASSERT(eglBindAPI(EGL_OPENGL_ES_API))`.
- **Platform choice** (`:340-366`):
  - If `EXT_platform_device` is present, it calls `eglDeviceFromDRMFD(m_drmFD)` (`:254-295`). This matches `EGL_DRM_DEVICE_FILE_EXT` against `drmGetDevice(fd)` node names, then calls `initEGL(false)`, which uses `EGL_PLATFORM_DEVICE_EXT`.
  - Otherwise it uses `KHR_platform_gbm`: `openRenderNode(m_drmFD)` (`:124-155`), then `gbm_create_device`, then `initEGL(true)`.
  - `RASSERT`s: "Couldn't open a gbm fd", "Couldn't open a gbm device", "EGL does not support KHR_platform_gbm or EXT_platform_device".
- There is **no surfaceless or software-device path**. With `m_drmFD == -1`:
  1. `drmGetDevice(-1)` fails, so the device lookup fails.
  2. `openRenderNode(-1)` returns -1.
  3. **`RASSERT(false, "Couldn't open a gbm fd")` aborts.**
- `initEGL()` (`:160-243`):
  - calls `eglInitialize` and `RASSERT`s on failure (it does **not** retry GBM if the device platform fails);
  - optionally uses `IMG_context_priority` (high), `EXT_create_context_robustness`, `KHR_context_flush_control`;
  - creates the context with `EGL_NO_CONFIG_KHR`, so it needs `EGL_KHR_no_config_context`;
  - asks for **GLES 3.2 and falls back to 3.0** (`:208-229`);
  - calls `eglMakeCurrent(EGL_NO_SURFACE, EGL_NO_SURFACE)`, so it needs surfaceless contexts.
- GL requirements:
  - `RASSERT(GL_EXT_texture_format_BGRA8888)` (`:382`).
  - It warns if `GL_EXT_read_format_bgra` or `EXT_image_dma_buf_import(_modifiers)` is missing (`:385-387`).
  - FP16 buffers need `GL_EXT_color_buffer_half_float` and the `ABGR16161616F` dmabuf format.
- Shaders are GLSL ES 3.00 with includes preprocessed by glslang. One variant is 3.20 (`tex320.vert`), and `ext.frag` needs `GL_OES_EGL_image_external_essl3`. A GLES 3.0 context is enough.
- `initDRMFormats()` (`:522-624`): if `EXT_image_dma_buf_import` is missing, it returns early ("DMABufs will not work"). `m_drmFormats` stays empty, and Hyprland then skips linux-dmabuf and wl_drm (`ProtocolManager.cpp:258-261`).

### 4.4 Output render targets

- `IHyprRenderer::beginRender` (`Renderer.cpp:1745-1810`):
  1. `m_currentBuffer = pMonitor->m_output->swapchain->next(&age)` (`:1772`);
  2. `initRenderBuffer(...)` calls `getOrCreateRenderbuffer` (`Renderer.cpp:3097-3110`, cached per `IBuffer`);
  3. `CHyprGLRenderer::getOrCreateRenderbufferInternal` (`GLRenderer.cpp:196-199`) returns `makeShared<CGLRenderbuffer>(buffer, fmt)`.
- `CGLRenderbuffer` (`gl/GLRenderbuffer.cpp:34-66`) does `createEGLImage(buffer->dmabuf())`, then `glEGLImageTargetRenderbufferStorageOES`, then attaches the renderbuffer to an FBO.
  - If the buffer is not a dmabuf, it logs "rb: createEGLImage failed" and is not `good()`.
  - `beginRender` then logs "failed to start a render pass ... no RBO" and **nothing is rendered**.
- `createEGLImage` (`OpenGL.cpp:627-679`) builds `EGL_LINUX_DMA_BUF_EXT` attributes (up to 4 planes, with modifiers) and sets `EGL_IMAGE_PRESERVED_KHR`.
- Everything else (the monitor work buffers, blur, mirror, snapshots) is a **plain GL texture FBO**: `CGLFramebuffer::internalAlloc` (`gl/GLFramebuffer.cpp:16ff`) uses `glTexImage2D` and `glFramebufferTexture2D`. Only the final swapchain target needs a dmabuf.
- The `IRenderbuffer` interface (`Renderbuffer.hpp`: `bind()`, `unbind()`, `getFB()`) is a clean place to add a non-dmabuf, shm-backed implementation.

### 4.5 Client buffer import

- `IHyprRenderer::createTexture(SP<IBuffer>)` (`Renderer.cpp:905-929`):
  - dmabuf buffers go through `createEGLImage`, then `CGLTexture(attrs, image)` (`GLTexture.cpp:67-94`, `glEGLImageTargetTexture2DOES`);
  - otherwise, **shm** buffers go through `beginDataPtr`, then `CGLTexture(drmFormat, pixels, stride, ...)` (`GLTexture.cpp:32-65`, `glTexImage2D` with `GL_UNPACK_ROW_LENGTH_EXT`).
- Later updates call `CGLTexture::update` (`:122-166`), which does per-damage-rect `glTexSubImage2D`.
- `wl_shm` buffers are synchronous, so they are copied and released early (`protocols/core/Compositor.cpp:667-701`).
- **wl_shm clients work without any dmabuf support.**
- Single-pixel buffers are also handled.

### 4.6 Synchronisation

- `explicitSyncSupported()` is `EGL_ANDROID_native_fence_sync` (`OpenGL.cpp:2531`).
- `CEGLSync::create` (`:2630ff`) is used by `CHyprGLRenderer::endRender` (`GLRenderer.cpp:149-189`) to hand an in-fence to the output.
- Without explicit sync (`GLRenderer.cpp:133-147`):
  - it uses `glFinish()` if `isSoftware()` (or NVIDIA with anti-flicker enabled), otherwise `glFlush()`;
  - it releases buffers immediately.
- `isSoftware()` is set from the `GL_RENDERER` string: `llvmpipe`, `softpipe` or `Software Rasterizer`, matched case-insensitively (`GLRenderer.cpp:48-59`, commit 4bb6844, 2026-09-27, on main only).
- The `wp_linux_drm_syncobj` protocol is only created for DRM backends with timeline syncobj (`ProtocolManager.cpp:239-256`).
- vgem has no `DRIVER_SYNCOBJ*`, and there is no DRM device at all in no-DRM mode. In both cases the syncobj protocol is not created, which is fine.

### 4.7 Behaviour with `drmFD < 0`

- aquamarine never gets that far (§3.1).
- If it did:
  - `IHyprRenderer` construction tolerates it (`Renderer.cpp:95-140`, "No primary DRM driver information found");
  - `LinuxDMABUF` removes its own global ("failed to get drm dev, disabling linux dmabuf", `LinuxDMABUF.cpp:446-450`);
  - `Monitor::isMultiGPU` returns false (`Monitor.cpp:2193-2224`);
  - **but `CHyprOpenGLImpl` aborts (§4.3)**.
- Hyprland has **no software-rendering or "no dmabuf" fallback for output targets**. It only has:
  - the implicit-sync fallback;
  - the llvmpipe `glFinish` quirk;
  - skipping the dmabuf globals when EGL has no dmabuf import.

### 4.8 Headless outputs

- `hyprctl output create headless [NAME]` (`ipc/s1/Commands.cpp:1730-1760`) calls `impl->createOutput(name)` on the headless backend (it also supports `wayland` and `auto`).
- `CFallbackStateKeeper` (`state/FallbackState.cpp:100-116`) creates an internal "FALLBACK" headless output when there are no monitors. It is marked unsafe, and a real headless output replaces it.
- Headless outputs render exactly like DRM outputs, into swapchain dmabufs. `commit()` just emits `present`, so frames are only visible through screencopy.
- The mode can be set with a `monitor` rule (custom mode). A good launch recipe is `exec-once = hyprctl output create headless WSL-1` plus a monitor rule for `WSL-1`.

### 4.9 Streaming-relevant protocols

These are all advertised unconditionally (`ProtocolManager.cpp`):

- `zwlr_screencopy_manager_v1` v3 (`:229`)
- `hyprland_toplevel_export_manager_v1` v2 (`:230`)
- `ext_image_capture_source` (output and toplevel), plus `ext_image_copy_capture_manager_v1` v1 (`:231-232`)
- `zwp_virtual_keyboard_manager_v1` v1 (`:193`), `zwlr_virtual_pointer_manager_v1` v2 (`:194`)
- `hyprland_input_capture_manager_v1` v2
- `zwlr_output_manager_v1` v4, `zwlr_output_power_manager_v1`

Screencopy into shm uses `CScreenshareFrame::copyShm` (`managers/screenshare/ScreenshareFrame.cpp:430ff`). It calls `CGLFramebuffer::readPixels` (`gl/GLFramebuffer.cpp:152-265`), a synchronous `glReadPixels` done **per damage rect**. dmabuf screencopy (`copyDmabuf`, `:397ff`) renders into the client dmabuf. So wayvnc-style capture works with pure shm.

---

## 5. Mesa and kernel facts that decide the vgem and d3d12 options

### 5.1 vgem (Linux 6.18)

- `drivers/gpu/drm/vgem/vgem_drv.c`:
  - `driver_features = DRIVER_GEM | DRIVER_RENDER`, so it has a primary node (`card0`) and a render node (`renderD128`);
  - no `DRIVER_MODESET`, and no `DRIVER_SYNCOBJ` or `DRIVER_SYNCOBJ_TIMELINE`;
  - `DRM_GEM_SHMEM_DRIVER_OPS` provides dumb-create and mmap;
  - `map_wc = true`.
- `drm_ioctl.c`:
  - `DRM_CAP_PRIME` always returns `IMPORT|EXPORT` (`drm_getcap`, `:246-248`);
  - `DRM_CAP_DUMB_BUFFER` and `DRM_CAP_CRTC_IN_VBLANK_EVENT` return `-EOPNOTSUPP` for non-modeset drivers (`:257-262`);
  - `DRM_IOCTL_MODE_CREATE_DUMB`, `MAP_DUMB` and `DESTROY_DUMB` have flags `0` (`:688-690`). They are **not `DRM_RENDER_ALLOW`**, so dumb buffers can only be created and mapped on `card0`;
  - PRIME handle and fd conversion is render-allowed (`:660-661`).
- Consequences:
  - The aquamarine DRM backend rejects vgem, even with `AQ_NO_KMS_REQUIREMENT=1`: `checkFeatures()` fails on `CRTC_IN_VBLANK_EVENT`, and `initResources()` would fail on `drmModeGetResources`.
  - `reopenDRMNode(..., allowRenderNode=true)` would pick `renderD128`. The empty-lease trick returns `EOPNOTSUPP` on non-modeset drivers and falls back to the render node. On that node, Mesa `kms_swrast` gets `EACCES` on `CREATE_DUMB`.

### 5.2 Mesa software paths (`kms_swrast`, `swrast`) and who gets picked

- `src/gallium/auxiliary/target-helpers/sw_helper.h:73-98` `sw_screen_create_vk()` tries, in order:
  1. `$GALLIUM_DRIVER`;
  2. **`d3d12`**, unless `LIBGL_ALWAYS_SOFTWARE` is set;
  3. `llvmpipe`;
  4. `softpipe`.
  
  So on WSL, **any** software-winsys screen (`swrast`/drisw, `kms_swrast`, device or surfaceless software device, Wayland `wl_shm` clients) becomes **d3d12 on the GPU by default**. If `GALLIUM_DRIVER` is set and fails, no other driver is tried.
- `kms_swrast` = `pipe_loader_sw_probe_kms()` with `kms_dri_create_winsys(fd)` (`pipe-loader/pipe_loader_sw.c:213-245`). The winsys (`winsys/sw/kms-dri/kms_dri_sw_winsys.c`):
  - allocates display targets with `DRM_IOCTL_MODE_CREATE_DUMB` (`:164-223`);
  - maps them with `MODE_MAP_DUMB` (`:340-379`) (primary node only);
  - exports with `drmPrimeHandleToFD` (`:513-544`).
- GBM on an unknown DRM driver (`src/gbm/backends/dri/gbm_dri.c`):
  1. `dri_screen_create()` uses `loader_get_driver_for_fd()`, which returns `vgem`. That fails (`pipe_loader_drm.c:177-179`: "vgem is a virtual device; don't try using it with kmsro").
  2. It retries with `zink`.
  3. Then `dri_screen_create_sw()` tries `kms_swrast`, then `swrast` (`:249-320`, `:1229-1236`). `GBM_ALWAYS_SOFTWARE=1` jumps straight to this step.
- Export capability matters:
  - `has_dmabuf_export` comes from `pscreen->caps.dmabuf` (`:1244-1247`). If it is false, `gbm_bo_create` falls back to `create_dumb()` (`:902-903`, `:826-880`). That path only allows SCANOUT XRGB/XBGR8888 or CURSOR ARGB8888.
  - **`gbm_bo_get_fd` returns -1 for such dumb BOs** (`:449-453`, `bo->image == NULL`).
- **llvmpipe** with the kms winsys advertises `caps.dmabuf = IMPORT|EXPORT` (`llvmpipe/lp_screen.c:201-202`, because `winsys->get_fd` exists). Resources with `DISPLAY_TARGET|SCANOUT|SHARED` go to winsys dumb buffers (`lp_texture.c:317-321`). Import mmaps the dmabuf fd (`import_memory_fd`) and wraps it with `displaytarget_create_mapped`, which only needs render-allowed PRIME ioctls (`lp_texture.c:724-830`). The result:
  - GBM on `card0` works;
  - EGL import works on either node;
  - native fence fds need `/dev/udmabuf` (`lp_fence.c:315-345`), which WSL lacks, so **no `EGL_ANDROID_native_fence_sync`** and Hyprland takes the implicit `glFinish` path.
- **d3d12** (`drivers/d3d12/`):
  - `caps.dmabuf` is never set, so the EGL display lacks `EXT_image_dma_buf_import` (`egl_dri2.c:649-651`, `:737-744`) and GBM uses dumb BOs.
  - It only creates winsys display targets for `PIPE_BIND_DISPLAY_TARGET` (`d3d12_resource.cpp:417-437`). Present copies happen in `d3d12_flush_frontbuffer` (`d3d12_screen.cpp:692ff`), a GPU readback into the display target.
  - `resource_get_handle(FD)` returns a **D3D12 NT shared handle fd** (`CreateSharedHandle`, `:865-895`), not a dmabuf. `resource_from_handle(FD)` calls `OpenSharedHandle` (`:575-662`). These fds are only useful between d3d12 and dzn processes; see §8 "future".
  - `essl_feature_level = 310` (`d3d12_screen.cpp:291`), so GLES 3.1 at most, and Hyprland takes its 3.0 fallback.
  - It has no native fence fd.
  - Adapter choice uses `MESA_D3D12_DEFAULT_ADAPTER_NAME` (`d3d12_dxcore_screen.cpp:77`). The `GL_RENDERER` string is "D3D12 (<adapter>)".
- **EGL retry chain** (`egl/main/eglapi.c:678-712`). If the first `Initialize` fails:
  1. If `GALLIUM_DRIVER` is unset, it retries with Zink.
  2. Then it retries with `ForceSoftware = TRUE`.
  
  On the **device platform** (`egl/drivers/dri2/platform_device.c:218-300`), `ForceSoftware` with a `vgem` or `virtio_gpu` device switches to `kms_swrast` on the **primary node** ("NEEDS EXTENSION: falling back to kms_swrast"). The software EGL device (always the first in the list, `egldevice.c:124-143`, `:455-470`) uses `swrast` (drisw) and therefore **d3d12**. Surfaceless (`platform_surfaceless.c:224-300`) has the same vgem logic. The Zink retry on a vgem fd can land on **dzn**: `zink_screen.c:1847-1860` picks the only physical device when `VK_EXT_physical_device_drm` is missing. **Setting `GALLIUM_DRIVER` explicitly avoids that surprise.**
- **Wayland clients** (`platform_wayland.c:2675ff`, `:3215ff`, `:3298ff`):
  - `dri2_initialize_wayland_drm` needs `wl_drm` or linux-dmabuf plus a known driver.
  - Otherwise, after the retry chain, `dri2_initialize_wayland_swrast` uses `wl_shm` with `swrast`, which is d3d12. This is exactly what WSLg clients do today: render on the GPU, read back into `wl_shm`.
- **dzn** (`src/microsoft/vulkan/dzn_device.c`):
  - `DZN_API_VERSION` is 1.2;
  - it offers `KHR_external_memory_fd` with **OPAQUE_FD only** (`:64-69`, `:1469`, `:1723`);
  - it has **no** `EXT_external_memory_dma_buf`, `EXT_image_drm_format_modifier` or `EXT_physical_device_drm`;
  - `EXT_external_memory_host` is Windows-only (`:148-150`);
  - WSI is initialised with `sw_device = true` on Linux (`dzn_wsi.c:91-101`).
- Arch's mesa build uses `-D gallium-drivers=all` (so d3d12 is included) and `microsoft-experimental` Vulkan, packaged as `vulkan-dzn` (`upstream/arch-pkg-mesa/PKGBUILD:254`, `:267`, `:343-346`).

### 5.3 WSLg's Weston (verified from source, and matches clarenceb's empirical `AQ_TRACE` dump)

- It is Weston `9.0.0` (`meson.build:3`).
- The RDP backend only calls `pixman_renderer_init` (`libweston/backend-rdp/rdp.c:2237`).
- `linux_dmabuf_setup()` is called only by the drm, headless, wayland and x11 backends. **So `zwp_linux_dmabuf_v1` is not advertised, and neither is `wl_drm`.**
- Global versions:
  - `wl_compositor` **v4** (`libweston/compositor.c:7491`)
  - `wl_seat` **v7** (`libweston/input.c:3428-3430`)
  - `xdg_wm_base` **v1** (`libweston-desktop/xdg-shell.c:47`, `:1495`)
- wl_shm formats: XRGB8888, ARGB8888, RGB565 (`pixman-renderer.c:657-665`, `:915`).
- The full global list captured empirically is in `upstream/clarenceb_omarchy-wsl2/docs/12-wayland-on-wsl2.md` §3a.

---

## 6. Exact failure points on stock WSL2 today

These are listed in execution order, with the code that trips.

1. **DRM backend, when it is attempted.**
   - `CSession::attempt` needs libseat. With no seatd or logind seat, it fails ("Failed to open a session").
   - Even with `LIBSEAT_BACKEND=noop` or seatd, `scanGPUs()` finds no DRM cards.
   - With vgem loaded, `openIfKMS` rejects it. `AQ_NO_KMS_REQUIREMENT=1` gets past that, but `checkFeatures()` then fails on `DRM_CAP_CRTC_IN_VBLANK_EVENT` (`DRM.cpp:727-730`).
   - This is non-fatal because the backend is `IF_AVAILABLE`.
2. **Wayland backend under WSLg (FALLBACK, always attempted).**
   - Binding `wl_compositor` v6, `xdg_wm_base` v6 and `wl_seat` v9 against v4/v1/v7 makes libwayland-server post `invalid version for global` and disconnect the client.
   - Even after a version clamp, `!waylandState.dmabuf` triggers "Missing protocols" (`Wayland.cpp:147-150`).
   - This is non-fatal.
3. **Allocator (fatal).** Only headless survives, and its `drmFD()` is -1. "Cannot open backend: no allocator available" (`Backend.cpp:176-179`), then Hyprland throws "CBackend::create() failed!" (`Compositor.cpp:336-343`).
4. *(Only if 3 is patched.)* **Hyprland EGL (fatal).**
   - With a DRM fd of -1: `RASSERT "Couldn't open a gbm fd"` (`OpenGL.cpp:354-356`).
   - With vgem but no `GALLIUM_DRIVER`: the device platform eventually lands on kms_swrast with **d3d12**, which has no dmabuf import.
5. *(Only if 4 is patched.)* **Render targets (functional failure).** `CGLRenderbuffer` needs a dmabuf `EGLImage` (`GLRenderbuffer.cpp:35-40`). With d3d12, or with non-dmabuf buffers, this gives "failed to start a render pass ... no RBO" and every frame is dropped.
6. *(Nested, if 2–5 are patched.)* **Output buffers to the parent.** `CWaylandBuffer` is dmabuf-only (`Wayland.cpp:898-917`), and WSLg accepts only `wl_shm`.

---

## 7. Prior art, community, and maintainer stance

- **Maintainer (vaxerski) on WSL and Windows:**
  - "no". Issue hyprwm/Hyprland#3479, "May I ask if there is a way to run Hyprland in wsl", 2023-10-03: https://github.com/hyprwm/Hyprland/issues/3479
  - "it is a stupid question. No." Discussion #4333, Windows(OS), 2024-01-02: https://github.com/hyprwm/Hyprland/discussions/4333
  - In the same thread, yavko (2024-05-03): "wsl does not provide DRM drivers", and Hyprland needs hardware acceleration and DRM, which is why Sway works and Hyprland does not.
  - Expect no upstream interest in WSL-specific code. Generic pieces (shm allocator, version clamp, no-DRM EGL init) are more defensible upstream.
- **Wiki:** "Running In a VM — YMMV, this is not officially supported". It recommends virgl with `gl.enable=yes` (hyprland-wiki `content/getting-started/installation.md:467-519`). The environment-variables page documents `AQ_NO_KMS_REQUIREMENT` ("Disable KMS requirement for starting on headless GPUs").
- **aquamarine #228** (open, 2025-12-29), "Wayland backend, support Shared memory buffers (not just dmabuf)", from the Local Desktop (Android/Smithay) maintainer. There is no reply yet. https://github.com/hyprwm/aquamarine/issues/228
- **aquamarine #398 / PR #427**: fixed-version binds abort nesting. The clamp PR was closed unmerged on 2026-09-28. https://github.com/hyprwm/aquamarine/issues/398, https://github.com/hyprwm/aquamarine/pull/427
- **aquamarine #348** (open): the nested Wayland output stops after its first frame. https://github.com/hyprwm/aquamarine/issues/348
- **Hyprland #16343** (merged 2026-09-27): detect software rendering from `GL_RENDERER`, for simpledrm + llvmpipe. Omarchy backports it in https://github.com/omacom/omarchy-pkgs/pull/649. Hyprland #16077 covers hardware-cursor-triggered full re-renders hurting VMs.
- **Vulkan renderer:** draft PR https://github.com/hyprwm/Hyprland/pull/13272 (UjinT34, opened 2026-02-14, last updated 2026-05-30; 63 files, +6357). The author says "only basic things works". vaxerski asked for simpler internal state. It requires `VK_EXT_external_memory_dma_buf` and `VK_EXT_image_drm_format_modifier` (`src/render/vulkan/Device.cpp:25-37` on the `vulkan` branch).
- **Omarchy VMware PR** https://github.com/omacom/omarchy/pull/11911: on vmwgfx, forcing clients to `LIBGL_ALWAYS_SOFTWARE=1` makes llvmpipe render to `wl_shm`. This is the same "clients on wl_shm" pattern we would use.
- **clarenceb/omarchy-wsl2** (`upstream/clarenceb_omarchy-wsl2/docs/12-wayland-on-wsl2.md`, 2026-08-30) is an empirical record of every failure in §6.
  - With a VKMS-enabled kernel, Hyprland got as far as "wayvnc attached", then failed with `gbm_bo_create` NULL under `GBM_ALWAYS_SOFTWARE=1`.
  - Most likely cause, from §5.2: `kms_swrast` picked **d3d12**, which has no dmabuf export. That leads to dumb BOs, which are not exportable. They did not pin `GALLIUM_DRIVER=llvmpipe`.
  - They settled on sway + pixman.
- **sharpninja/omarchy-wslg** (`upstream/sharpninja_omarchy-wslg`, 2026-09-23) is a working **external bridge** for unmodified Hyprland (`src/bridge.c`):
  - a fake parent compositor that advertises `zwp_linux_dmabuf_v1` v4 with `main_device` = VKMS `card0` (custom kernel `…-omarchy-vkms1`);
  - it mmaps Hyprland's dmabufs and copies them into `wl_shm` slots for WSLg;
  - it clamps its own binds to the parent (`:1344-1357`);
  - it runs Hyprland with `GBM_ALWAYS_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` (`:1409-1413`).
  
  This is approach (a) + (d) with CPU compositing, and it needs a custom kernel. With stock **vgem** instead of VKMS it would hit the render-node problem (§5.1), because aquamarine prefers `renderD128`.

---

## 8. Candidate approaches

Legend: LOC counts are rough counts of new or changed lines. "Perf" means steady-state cost per output frame and per client frame.

### (a) vgem + Mesa GBM via `kms_swrast` + `GALLIUM_DRIVER=llvmpipe` (CPU compositing)

**Does it work unmodified? No.** It fails at §6.3:
- Headless has no fd.
- The DRM backend rejects vgem (§5.1).
- The Wayland backend needs a parent that advertises a vgem `main_device`. Even then, `reopenDRMNode()` would move GBM onto `renderD128`, where `CREATE_DUMB` gets `EACCES`.

**Minimal patch (aquamarine only, ≈40–80 LOC):**
- Add an opt-in variable, e.g. `AQ_HEADLESS_DRM_DEVICE=/dev/dri/card0` (or reuse `AQ_DRM_DEVICES` when there is no KMS device).
- `CHeadlessBackend` opens it. `drmFD()` returns the card fd and `drmRenderNodeFD()` returns -1, so Hyprland's EGL also uses the primary node.
- `CBackend::start` calls `reopenDRMNode(fd, /*allowRenderNode=*/false)` for this case (`Backend.cpp:165`).

With that:
- GBM (with `GBM_ALWAYS_SOFTWARE=1`) → `kms_swrast` → llvmpipe → dumb BOs on `card0` → PRIME fds ✓.
- Hyprland EGL device platform on vgem:
  1. the "vgem" attempt fails;
  2. Zink is skipped because `GALLIUM_DRIVER` is set;
  3. `ForceSoftware` → `kms_swrast` on `card0` → llvmpipe ✓, with `EXT_image_dma_buf_import` ✓ and no native fence, so the `glFinish` path.
- Hyprland needs **no changes**.

Alternatively, run Hyprland under a sharpninja-style bridge using the Wayland backend. That still needs the same `allowRenderNode=false` tweak for vgem.

Operational needs:
- `modprobe vgem` (root);
- a udev rule or ACL for `/dev/dri/card0`;
- `GALLIUM_DRIVER=llvmpipe` **and** `GBM_ALWAYS_SOFTWARE=1`, **for the compositor process only**. `GBM_ALWAYS_SOFTWARE=1` is required:
  - GBM's own fallback chain (`gbm_dri.c:284-300`) tries **Zink** after the "vgem" driver fails, and that attempt is *not* gated by `GALLIUM_DRIVER`.
  - With `vulkan-dzn` as the only ICD, Zink can bind to dzn (`zink_screen.c:1851-1857`).
  - That would give a GBM device without dmabuf export, then dumb BOs, then fd -1.
- clients should get `GALLIUM_DRIVER=d3d12`, otherwise they inherit llvmpipe or hit the Zink-on-dzn retry;
- unset `WAYLAND_DISPLAY` before starting, to stop the FALLBACK nested attempt.

Clients: Hyprland will advertise linux-dmabuf with the vgem device as `main_device` (`LinuxDMABUF.cpp:442-535`) and llvmpipe formats. Mesa clients fail the "vgem" driver and fall to `wl_shm` + d3d12 (GPU, with readback). Chromium, GTK4 and similar should also end up on shm or software paths. **Test this.**

Sink:
- the headless output + wayvnc (`ext-image-copy-capture` or `wlr-screencopy`, dmabuf or shm), or
- a bridge into WSLg.

The output buffer already lives in shmem-backed vgem pages, so a sink can mmap it with zero copies.

Perf:
- The compositor runs entirely on the CPU. llvmpipe threads composite the damaged regions, and texture "upload" of shm client buffers is a memcpy.
- Omarchy's defaults make this much cheaper than for stock Hyprland (`upstream/omarchy/default/hypr/looknfeel.lua`: `rounding = 0`, `shadow.enabled = false`, `blur.enabled = false`, workspace animations off, window pop-in and fade animations on). Most work is textured blits.
- Expect fine behaviour at 1080p to 1440p for typical desktop damage.
- Expect noticeable CPU load and possible sub-60 FPS for full-screen animations and video at 4K.
- It adds `glFinish` on every frame.
- Apps still render on the GPU with d3d12.

**Verdict:** the cheapest bring-up path, useful for validating Omarchy userland and as a fallback. It does not deliver GPU-accelerated composition.

### (b) Same as (a) but with `GALLIUM_DRIVER=d3d12` through `kms_swrast`

**Plausible? No, not without Mesa work.**
- `kms_swrast` really does pick d3d12 by default in WSL (`sw_helper.h:78-80`).
- But d3d12 reports no `caps.dmabuf`. As a result:
  1. GBM `has_dmabuf_export` is false, so it uses `create_dumb`, and `gbm_bo_get_fd` returns -1. aquamarine fails with "Failed to query fd for plane", or gets `bo null` for modifier or 10-bit requests (this matches clarenceb's log).
  2. Hyprland's EGL display has no `EXT_image_dma_buf_import`. `initDRMFormats` bails, `createEGLImage` fails, and no render target can be created.
- d3d12 on WSL can only share **D3D12 NT-handle fds**, which are not dmabufs (`d3d12_resource.cpp:865-895`).

To make (b) work, Mesa's d3d12 would need "dmabuf emulation":
- `resource_from_handle(FD)` for kms-winsys dumb buffers would create a GPU resource plus a winsys display target;
- the display target would be uploaded before sampling and read back after rendering, at flush or fence time;
- and `caps.dmabuf` would be advertised.

That is ≈300–600 LOC in `drivers/d3d12/d3d12_resource.cpp` and `d3d12_screen.cpp`, with hard synchronisation semantics: when is a dmabuf "dirty"? It also changes client behaviour, because clients would start using linux-dmabuf. Upstream acceptance is unlikely.

Perf, if done: GPU compositing plus hidden full-buffer copies on every use. That is strictly worse than (c).

**Verdict: reject.**

### (c) Patch aquamarine + Hyprland for a "no-DRM" mode (recommended core)

Design:
- **EGL:** when there is no DRM fd, Hyprland uses the **software EGL device** (`EGL_MESA_device_software`, always Mesa's first `EGLDevice`) or `EGL_PLATFORM_SURFACELESS_MESA`. Mesa takes `swrast`/drisw and then `sw_screen_create`, which gives **d3d12 on the RTX 5070**.
  - Pin `GALLIUM_DRIVER=d3d12`, and optionally `MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA`.
  - The result is GPU composition without dmabuf.
  - `GL_EXT_texture_format_BGRA8888` and GLES 3.0 are available.
  - There is no native fence, so Hyprland takes the implicit path.
- **Allocator:** aquamarine gets a `CShmAllocator`:
  - memfd + `ftruncate` + `mmap`;
  - `BUFFER_TYPE_SHM`, `caps = DATAPTR`;
  - `shm()` returns `{fd, format, size, stride}`;
  - `beginDataPtr()` returns the mapping.
  
  `CBackend::start` uses it as `primaryAllocator` when no backend has a DRM fd. This can be opt-in (e.g. `AQ_ALLOW_NO_DRM=1`) or automatic.
- **Render targets:** Hyprland gets a new `CGLShmRenderbuffer`, chosen in `getOrCreateRenderbufferInternal` when `!buffer->dmabuf().success && buffer->shm().success`.
  - It owns a GL texture FBO (one per swapchain buffer, so buffer-age damage stays valid).
  - At end of frame, it **reads back only the damaged rects** into the shm mapping. v1 uses synchronous `glReadPixels` with `GL_PACK_ROW_LENGTH` and BGRA. v2 uses an async PBO ring with `glFenceSync`, plus a worker thread or deferred commit.
  - The hook goes in `CHyprGLRenderer::endRender` (`GLRenderer.cpp:119-131`), before `state->setBuffer(m_currentBuffer)`.
- **Sinks**, in increasing effort:
  1. **Headless + wayvnc (or any `ext-image-copy-capture` client).** No sink code. Note that screencopy performs its own damage-limited `glReadPixels` (`ScreenshareFrame::copyShm`). A variant of `CGLShmRenderbuffer` could skip its own readback when the output is headless and nobody consumes it, leaving readback to the capture client only.
  2. **Wayland backend into WSLg**: approach (d) below.
  3. **A new aquamarine "stream" backend.** It would:
     - publish committed shm buffers plus `state->damage` over a transport to a Windows viewer (hvsocket/AF_VSOCK, loopback TCP, or the WSLg shared-memory mechanism; see the WSLg research report);
     - pace frames from the viewer's present acknowledgements (backpressure);
     - create `IKeyboard`/`IPointer` devices from viewer input;
     - resize outputs from the viewer window.
     
     A new `eBackendType` would need small Hyprland touches (`StringUtils::backendStr`, `SystemInfo`, and `hyprctl output create`).

Files and classes to change:

| Repo | File / class | Change | ≈LOC |
|---|---|---|---|
| aquamarine | `include/aquamarine/allocator/Shm.hpp`, `src/allocator/Shm.cpp` (**new**: `CShmAllocator`, `CShmBuffer`) | memfd buffers, `shm()`/`beginDataPtr()`, `AQ_ALLOCATOR_TYPE_SHM` | 150–200 |
| aquamarine | `include/aquamarine/allocator/Allocator.hpp` | add `AQ_ALLOCATOR_TYPE_SHM` | 2 |
| aquamarine | `src/backend/Backend.cpp` `CBackend::start` (`:162-179`) | fall back to `CShmAllocator` when no backend has a DRM fd (env-gated) | 15–25 |
| aquamarine | `src/allocator/Swapchain.cpp:55` | format fallback via `shm().format` | 3–5 |
| aquamarine | `src/backend/Headless.cpp` | nothing required. Optionally return only 8-bit formats when using shm. | 0–10 |
| aquamarine (for d) | `src/backend/Wayland.cpp` `start` (`:114-150`) | bind `min(advertised, supported)`; make `zwp_linux_dmabuf_v1` optional when `wl_shm` exists | 25–40 |
| aquamarine (for d) | `CWaylandBuffer` ctor (`:898-917`); `getRenderFormats` (`:477-483`) | if `buffer->shm().success`, create a `wl_shm_pool` + `wl_buffer` from the memfd; report shm formats when there is no dmabuf | 80–120 |
| aquamarine (stream sink) | `include/aquamarine/backend/Stream.hpp`, `src/backend/Stream.cpp` (**new**) | output commit → transport; input devices; resize; frame pacing | 800–1200 |
| Hyprland | `src/render/OpenGL.cpp` ctor (`:297-366`) | if `m_drmFD < 0`, select the EGL device with `EGL_MESA_device_software` (or the surfaceless platform) → `initEGL(false)`; skip GBM | 30–50 |
| Hyprland | `src/render/gl/GLShmRenderbuffer.{hpp,cpp}` (**new**), `GLRenderer.cpp:196-199`, `:119-131` | FBO + texture render target; damage-limited readback (sync, then async PBO) | 150–250 |
| Hyprland | `src/output/Monitor.cpp:2590` `ensureBufferPresent`, and misc | treat shm buffers as valid (avoid needless re-attach); log and sysinfo tweaks | 10–30 |
| Hyprland (stream sink) | `helpers/string/StringUtils.hpp`, `helpers/SystemInfo.cpp`, `ipc/s1/Commands.cpp:1739-1750` | recognise the new backend type | 15–25 |

Totals:
- Core (c): aquamarine ≈170–230 LOC; Hyprland ≈190–330 LOC.
- Adding (d): +105–160 in aquamarine.
- Adding the stream backend: +800–1200 in aquamarine, +15–25 in Hyprland, plus a Windows viewer (≈1.5–3k LOC; D3D11/DComp swapchain, input capture, transport).

Perf (c):
- Compositing runs on the GPU through d3d12. Command translation and GPU-PV submission add some CPU overhead and latency. Blur, animations and any future effects cost the GPU, not the CPU.
- Per output frame, readback is **proportional to damage**. Full-frame BGRA sizes: 1080p = 8.3 MB, 1440p = 14.7 MB, 4K = 33.2 MB. At 60 Hz full-motion that is 0.5, 0.9 and 2.0 GB/s.
  - Sync `glReadPixels` stalls the main loop until the GPU finishes. Expect ~1–5 ms for full frames; **measure on WSL**.
  - An async PBO ring removes the stall and adds one frame of latency.
- Per client frame, the cost is unchanged from WSLg today (d3d12 client readback into `wl_shm`), plus Hyprland's damage-limited `glTexSubImage2D` upload.
- Transport cost depends on the sink.

**Verdict:** the best balance of efficiency and maintainability. It needs no kernel module, no custom kernel and no Mesa patch. It gives true GPU composition. The patches are generic enough to keep as a small fork patch-queue, and possibly to upstream the aquamarine half (shm allocator and version clamp; see #228).

### (d) Hyprland nested in WSLg (Wayland backend)

What fails today (§6): version-mismatched binds, a required `zwp_linux_dmabuf_v1`, no `main_device` so no allocator, the Hyprland EGL assert, dmabuf-only render targets, and dmabuf-only `CWaylandBuffer`.

Minimal fix = core (c) + the two Wayland-backend rows. After that, Hyprland renders on d3d12, reads back into memfd shm, and sends it to WSLg with `wl_surface.attach(wl_shm buffer)`.

Also:
- Set `cursor:no_hardware_cursors = 1`. The hardware cursor path renders through `CGLRenderbuffer` into cursor swapchain buffers, which are not dmabufs.
- Consider re-validating the frame-loop bug #348.
- Nested outputs are named `WAYLAND-N`.
- Weston sends 0x0 configures, and aquamarine then defaults to 1280x720 (`Wayland.cpp:553-562`).

Perf: (c) plus WSLg's cost. That is a Weston pixman copy into the RAIL surface, RDP shared-memory transfer, and Windows DWM composition. It is fine for 1080p-class windows. Full-screen 4K at 60 fps through WSLg is heavy.

UX limits:
- Windows intercepts Win-key chords; Omarchy uses SUPER heavily.
- There is no pointer lock (Weston 9 rdprail).
- It is a single window.

**Verdict:** the quickest way to see a GPU-composited Omarchy desktop on Windows, and a good developer loop. It is not the end state. Patch size: aquamarine ≈275–390 LOC, Hyprland ≈190–330 LOC.

### (e) Vulkan route

- Hyprland main has only `RT_VK` as an enum placeholder.
- PR #13272 is a draft (last activity 2026-05-30, "only basic things works"). It requires `VK_EXT_external_memory_dma_buf`, `VK_EXT_queue_family_foreign` and `VK_EXT_image_drm_format_modifier`.
- dzn is Vulkan 1.2 with OPAQUE_FD-only external memory, no drm-format-modifier or dma-buf extensions, and software WSI, so it would be rejected.
- Even if the renderer lands, WSL would need the same non-dmabuf output targets and readback as (c). Vulkan would make async readback cleaner (`vkCmdCopyImageToBuffer` into HOST_VISIBLE memory plus timeline semaphores), but that is not enough to justify waiting.
- Zink-on-dzn as a GL provider is strictly worse than the native d3d12 Gallium driver.

**Verdict: not viable now.** Revisit only if the Vulkan renderer merges **and** it grows a no-dmabuf path.

### Future (not part of the recommended set): GPU-resident client sharing

d3d12 on WSL can export and import D3D12 NT-handle fds (`d3d12_resource.cpp:575-662`, `:865-895`). A custom Wayland protocol, or a Mesa Wayland-platform extension, could let d3d12 clients pass those fds to a d3d12 Hyprland. That would remove the client-side readback and the compositor upload. It is a Mesa + Wayland + Hyprland project with high complexity. Park it until (c) is measured.

---

## 9. Recommendation and patch-set outline

Ranking:

1. **(c) no-DRM GPU mode.** Core: aquamarine ≈170–230 LOC, Hyprland ≈190–330 LOC. It then needs a sink:
   - **(c-i) headless + wayvnc**: no extra code;
   - **(d) WSLg wl_shm**: +105–160 LOC in aquamarine;
   - **stream backend**: +800–1200 LOC plus the Windows viewer.
2. **(a) vgem + llvmpipe.** About 40–80 LOC in aquamarine, no Hyprland changes, and it needs `modprobe vgem`. Use it for fast bring-up and as a fallback. It gives CPU composition, which is acceptable at ≤1440p with Omarchy's flat style.
3. **(d)** = (c) + the WSLg sink. Development convenience only.
4. **(b)**: reject, because it needs an invasive Mesa d3d12 dmabuf-emulation patch.
5. **(e)**: not available.

Proposed patch queue (`womarchy/patches/`):

- **aquamarine**
  1. `0001-wayland-clamp-bind-versions.patch`: `min(advertised, supported)`. Re-proposes the idea of #427.
  2. `0002-allocator-add-shm-allocator.patch`: `CShmAllocator` and `CShmBuffer`, plus `AQ_ALLOCATOR_TYPE_SHM`.
  3. `0003-backend-shm-allocator-fallback.patch`: `CBackend::start` fallback (env `AQ_ALLOW_NO_DRM=1`), and the `Swapchain` format fallback.
  4. `0004-wayland-wl_shm-output-buffers.patch`: dmabuf optional, and `CWaylandBuffer` via `wl_shm_pool` (the #228 ask).
  5. *(bring-up only)* `0005-headless-explicit-drm-device.patch`: `AQ_HEADLESS_DRM_DEVICE`, reopened on the primary node, for approach (a).
  6. *(phase 3)* `0006-backend-stream.patch`: a new stream/remote backend.
- **Hyprland**
  1. `0001-render-egl-init-without-drm.patch`: software `EGLDevice` or surfaceless when `m_drmFD < 0`.
  2. `0002-render-shm-renderbuffer.patch`: `CGLShmRenderbuffer` with damage-limited sync readback.
  3. `0003-render-async-readback.patch`: PBO ring + `glFenceSync`, and a deferred output commit or worker thread.
  4. `0004-misc-no-drm-guards.patch`: `ensureBufferPresent`, sysinfo, and backend-type strings.

Runtime recipe for (c):

```sh
# compositor
env -u WAYLAND_DISPLAY -u DISPLAY \
    GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
    AQ_ALLOW_NO_DRM=1 Hyprland
# config: exec-once = hyprctl output create headless WSL-1 ; monitor rule for WSL-1
#         cursor:no_hardware_cursors = 1
# clients (set via hl.env in the Hyprland config)
GALLIUM_DRIVER=d3d12   # skips the Zink-on-dzn retry in Mesa's eglInitialize
```

Runtime recipe for (a):

```sh
sudo modprobe vgem && sudo chgrp video /dev/dri/card0 && sudo chmod 660 /dev/dri/card0
env -u WAYLAND_DISPLAY GALLIUM_DRIVER=llvmpipe GBM_ALWAYS_SOFTWARE=1 \
    AQ_HEADLESS_DRM_DEVICE=/dev/dri/card0 Hyprland
# clients: GALLIUM_DRIVER=d3d12
```

Test plan and measurements to take first:

1. Confirm the Mesa EGL behaviour on the target:
   - `eglinfo -B -p device` and `-p surfaceless` should show the d3d12 renderer and no `EGL_EXT_image_dma_buf_import`;
   - with vgem and `GALLIUM_DRIVER=llvmpipe`, the device platform should show llvmpipe with dmabuf import and export.
2. Microbenchmark d3d12 `glReadPixels`, sync vs PBO, at 1080p, 1440p and 4K on WSL 2.7.10.
3. Microbenchmark `glTexSubImage2D` for shm uploads.
4. Check that Chromium, Firefox, GTK4 (GL and Vulkan renderers) and Qt6 fall back to `wl_shm` cleanly when linux-dmabuf is absent (c), or when it points at vgem (a).
5. Check wayvnc against Hyprland headless with `ext-image-copy-capture` over shm, including virtual keyboard and pointer injection.
