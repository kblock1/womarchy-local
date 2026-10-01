# 04 — Prior art, alternative architectures, and performance/UX trade-offs

*Research date: 2026-09-30. Scope: running Omarchy (Arch + Hyprland) inside WSL2 on Windows 11 as a
full-screen, GPU-accelerated desktop that starts from a Windows prompt, keeps Super (the Win key)
working, and returns to the prompt on exit.*

Legend used throughout:

- **[V]**: verified here by reading source code, configs, or primary docs (file/URL cited).
- **[C]**: claimed by a project or author and not reproduced by us.
- **[E]**: our own estimate. The method is given in §9.1.

---

## 0. TL;DR

1. **No one has run Hyprland in WSL2 with GPU composition.** The one working Hyprland-in-WSLg
   project, [`sharpninja/omarchy-wslg`](https://github.com/sharpninja/omarchy-wslg) (2026-09-23), needs
   three things. It uses a **custom WSL kernel with `vkms` built in**. It runs **Hyprland on
   llvmpipe (CPU)**. It adds a **protocol bridge** that advertises `linux-dmabuf` to Hyprland and
   `memcpy`s each dmabuf frame into `wl_shm` for WSLg. The result is one fullscreen WSLg (RAIL)
   window [C].
   Every other Omarchy-on-WSL project either stops at CLI/TUI or swaps Hyprland for **sway on
   pixman**:
   - [`craigloewen-msft/Omarchy-wsl`](https://github.com/craigloewen-msft/Omarchy-wsl) (the WSL PM's personal repo)
   - [`taufderl/omarchy-wsl`](https://github.com/taufderl/omarchy-wsl)
   - [`clarenceb/omarchy-wsl2`](https://github.com/clarenceb/omarchy-wsl2)
2. **Why stock Hyprland fails [V].** Aquamarine only knows how to allocate buffers through GBM on a
   DRM fd (`src/backend/Backend.cpp`). Its headless backend returns `drmFD() == -1`. Its Wayland
   backend has two separate problems:
   - It requires `zwp_linux_dmabuf_v1`, which WSLg does not advertise.
   - It binds `xdg_wm_base` v6, `wl_compositor` v6 and `wl_seat` v9 unconditionally. WSLg's
     Weston 9.0.0 advertises `xdg_wm_base` **v1** and `wl_compositor` **v4**.

   Nesting therefore also needs a **version clamp**, not only an shm path. Hyprland's GL renderer
   also needs a DRM fd to choose its EGL device (`src/render/OpenGL.cpp`).
3. **The DRM situation in WSL kernels changed [V].**

   | Kernel branch | DRM | vgem | vkms | udmabuf |
   |---|---|---|---|---|
   | `linux-msft-wsl-6.6.y`, x86_64 | `=y` | `=m` | not set | not set |
   | `linux-msft-wsl-6.6.y`, arm64 | `=m` | `=m` | `=m` | `=y` |
   | **`linux-msft-wsl-6.18.y`** (WSL 2.9.x / "3.0.x" packages) | **`CONFIG_DRM` not set** | — | — | — |

   On 6.18 there is **no vgem**, so there is no `/dev/dri/card0` for VA-API either
   ([WSL#41733](https://github.com/microsoft/WSL/issues/41733) shows a user rebuilding with
   `CONFIG_DRM_VGEM=y`). This contradicts the brief's assumption that "vgem ships as a module" on
   current kernels.
4. **The Win key is not forwarded by WSLg's RAIL windows.** The issue has been open since 2022
   ([wslg#672](https://github.com/microsoft/wslg/issues/672),
   [wslg#583](https://github.com/microsoft/wslg/issues/583)).

   Clients that do forward it all use a `WH_KEYBOARD_LL` hook, usually only in fullscreen:
   - mstsc/mstscax `KeyboardHookMode`
   - Moonlight "Capture system keyboard shortcuts" (SDL keyboard grab, which is an LL hook [V])
   - TigerVNC `FullscreenSystemKeys`
   - VMConnect "Use on the virtual machine"
   - Parsec "Immersive mode"

   **None of them can capture Win+L or Ctrl+Alt+Del.** Win+G may still open Game Bar.
   Omarchy binds `SUPER+L`, `SUPER+CTRL+L`, `SUPER+G` and `SUPER+CTRL+ALT+Delete`, so it needs
   rebinds [V].
5. **Transport numbers that bound the design:**
   - Raw BGRA frames are 8.3 MB at 1080p and 33.2 MB at 4K.
   - The upstream hv_sock ceiling is about **1.7–2.0 GB/s with 64–128 KB rings**, and only
     0.46–0.69 GB/s with the 24–32 KB rings WSL uses by default for many listeners
     ([WSL PR #41690](https://github.com/microsoft/WSL/pull/41690) quoting upstream commit
     ac383f58f3c9).
   - Localhost TCP in mirrored mode: WSL→Windows **15.3 Gbit/s**, but Windows→WSL only
     **1.5 Gbit/s** on a single stream. Consomme mode: about **2.4 Gbit/s** in both directions
     ([WSL#40965](https://github.com/microsoft/WSL/issues/40965)).

   Raw 1080p60 (0.5 GB/s) fits over hvsocket. Raw 4K60 (2 GB/s) does not, without damage tracking,
   compression or shared memory.
6. **The d3d12 GPU→CPU readback is the key unknown.** Every design that keeps rendering on the GPU
   has to read the frame back.
   - WSLg's own README admits up to **50 % overhead** at high frame rates.
   - A 2026 report measured Mesa's d3d12 present-readback at **~8 FPS at 640×480** and
     **~2.8 FPS at 1280×720** on an Intel UHD iGPU
     ([wslg#1498](https://github.com/microsoft/wslg/issues/1498)).
   - Older NVIDIA reports reach **118 FPS fullscreen 1080p** (GpuTest Plot3D,
     [wslg disc. #146](https://github.com/microsoft/wslg/discussions/146)).

   **Measure this first** on target hardware, using persistent PBO or staging buffers.
7. **Ranked recommendation (details in §10):**
   1. **(C)** A custom Aquamarine "WSL" backend plus a small native Windows fullscreen viewer
      (hvsocket first, damage-aware, with a shared-memory path later). This is the target
      architecture.
   2. **(A2)** Hyprland nested in WSLg as one fullscreen RAIL window, using a patched Aquamarine
      Wayland backend (wl_shm, version clamp, d3d12 GL and readback). This is the fastest first
      milestone and shares about 70 % of the Linux-side work with C.
   3. **(B1)** Headless Hyprland + [`hypr-rdp`](https://github.com/MuNeNiCK/hypr-rdp) (IronRDP,
      H.264/EGFX) + mstsc fullscreen. It has the best out-of-the-box Win-key, clipboard and audio
      story, but pays encode/decode costs and still needs Hyprland to boot headless.
   4. **(A1/D)** vkms/vgem + llvmpipe (sharpninja-style). Demo and fallback only: CPU-bound, and
      needs a custom kernel.
   5. Sunshine/Moonlight and wayvnc/TigerVNC come after that. Neither is ready for WSL today.

---

## 1. Ground truth that constrains every architecture

### 1.1 What WSLg actually is (verified from source)

Sources: [`microsoft/wslg`](https://github.com/microsoft/wslg) at 6942bb5 (2026-06-24) and
[`microsoft/weston-mirror`](https://github.com/microsoft/weston-mirror) `working` at 7fbf693
(2026-09-10).

- **Weston 9.0.0 fork.**
  - Backend: `rdp-backend.so`. Shell: `rdprail-shell.so`. Xwayland is enabled (`WSLGd/main.cpp`).
  - Advertised globals include `wl_compositor` v4 (`libweston/compositor.c`) and `xdg_wm_base`
    v1 (`WD_XDG_SHELL_PROTOCOL_VERSION 1`), plus `wl_shm`, `wp_viewporter`, `wp_presentation`,
    `zwp_relative_pointer`, `zwp_pointer_constraints` and `wl_data_device_manager` v3.
  - It does **not** advertise `zwp_linux_dmabuf_v1`, `wl_drm`, or any `*data_control*`. The full
    global list is in
    [clarenceb docs/12](https://github.com/clarenceb/omarchy-wsl2/blob/main/docs/12-wayland-on-wsl2.md)
    and [wslg#1512](https://github.com/microsoft/wslg/issues/1512).
- **Pixel transport, RAIL mode ("VAIL").**
  - For each RAIL window, Weston copies the **damage bounding box** of the surface into a
    shared-memory "pool". That pool is a file on a virtio-fs mount tagged `wslg`
    (`/mnt/shared_memory`, backed by Windows section objects).
  - Weston then sends `GFXREDIR` `PresentBuffer` PDUs over an RDP dynamic channel carried on
    **hvsocket** (`libweston/backend-rdp/rdprail.c`).
  - `msrdc.exe` is launched with `/wslgsharedmemorypath:<object dir>` and maps the section.
  - The mechanism is exactly a Looking-Glass-style shared-memory relay, but it is private to WSLg.
  - If SectionFs fails, Weston falls back to `[WARN:COPY MODE]`: uncompressed pixels over RDP
    ([WSL#40618](https://github.com/microsoft/WSL/issues/40618),
    [wslg#1483](https://github.com/microsoft/wslg/issues/1483)).
- **RAIL has no compression path.** `rdprail.c` hard-codes `RDPGFX_CODECID_UNCOMPRESSED` or
  `ALPHA`. Over a real network (xfreerdp) that costs 125–296 Mbit/s and gives a mean
  click-to-repaint of 674 ms, versus 149 ms for xrdp ([wslg#1503](https://github.com/microsoft/wslg/issues/1503)).
  This does not matter inside WSLg, where gfxredir shared memory is used, but it shows why RAIL is
  not a general remoting path.
- **Hidden desktop mode exists [V].** `WSLGd/main.cpp` reads `WSL2_WESTON_SHELL_DESKTOP`, a boolean
  from the `[system-distro-env]` section of `.wslgconfig`. When set, it:
  - runs Weston with `desktop-shell` instead of `rdprail-shell`;
  - launches the client with `wslg_desktop.rdp`, which lacks `remoteapplicationmode`.

  `WSLG_USE_MSTSC=true` swaps `msrdc.exe` for `mstsc.exe`. The
  [WSLg debugging wiki](https://github.com/microsoft/wslg/wiki/WSLg-Configuration-Options-for-Debugging)
  documents an older `WSL2_WESTON_SHELL_OVERRIDE` name.

  In desktop mode, Weston's RDP backend sends frames with **RemoteFX or NSCodec (CPU) bitmap
  updates** (`rdp.c: rdp_peer_refresh_rfx/nsc`), not gfxredir shared memory. The setting is
  **global to all distros**.
- **Useful WSLg knobs:** `WESTON_RDP_MONITOR_REFRESH_RATE` (60/144),
  `WESTON_RDP_HI_DPI_SCALING`, `WESTON_RDP_FRACTIONAL_HI_DPI_SCALING`,
  `WESTON_RDP_DEBUG_DESKTOP_SCALING_FACTOR`, and `WESTON_RDP_SHARED_MEMORY`.
  - [wslg#1321](https://github.com/microsoft/wslg/issues/1321): WSLg picks the *lowest* refresh
    profile.
  - [wslg#1016](https://github.com/microsoft/wslg/issues/1016): the refresh cap is not honoured.
  - sharpninja's "fullscreen" window measured **1536×864** on a 1920×1080 panel, which is 125 %
    scaling. HiDPI scaling must be forced to 1:1, or the nested desktop is upscaled and blurry [C].
- **GPU path for WSLg clients [V].**
  - Mesa's d3d12 driver is created through the *software* winsys helper:
    `sw_helper.h: d3d12_create_dxcore_screen`. The default sw driver order is d3d12, then llvmpipe.
  - Each present does `d3d12_flush_frontbuffer`, then `pipe_texture_map` and `util_copy_rect` into
    a CPU buffer, then `wl_shm` or MIT-SHM
    ([wslg#1498](https://github.com/microsoft/wslg/issues/1498) has the stack trace).
  - Mesa ≥ 24.3 **no longer auto-selects d3d12**. You must set `GALLIUM_DRIVER=d3d12`; the fix is
    pending in [mesa!37469](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/37469)
    ([wslg#1332](https://github.com/microsoft/wslg/issues/1332)).
  - Cross-VM D3D12 shared handles **do not work**. `OpenSharedHandleByName` from a Windows process
    on a resource created in WSL fails with `E_HANDLE`, while Dozen
    `VK_KHR_external_memory_fd` sharing *between Linux processes* works (#1498 experiments).
- **The WSLg README states the readback limitation directly.** "vGPU interops with the Weston
  compositor through system memory... rendered data is copied from VRAM to system memory... and
  uploaded onto the GPU again on the Windows side... at 600fps... overhead can be as high as 50%."

### 1.2 Kernel/DRM availability (verified from `microsoft/WSL2-Linux-Kernel` configs)

| Branch / arch | `CONFIG_DRM` | `DRM_VGEM` | `DRM_VKMS` | `UDMABUF` | `DXGKRNL` |
|---|---|---|---|---|---|
| `linux-msft-wsl-6.6.y` x86_64 | y | **m** | not set | not set | y |
| `linux-msft-wsl-6.6.y` arm64 | m | m | **m** | y | y |
| `linux-msft-wsl-6.18.y` x86_64 (tag 6.18.40.1) | **not set** | — | — | not set | y |
| `linux-msft-wsl-6.18.y` arm64 | **not set** | — | — | y | y |

Consequences:

- **On 6.6 x86_64 kernels:** `modprobe vgem` gives `/dev/dri/card0` (a primary node without KMS)
  and `renderD128`. VA-API d3d12 works through it: Mesa's VA frontend special-cases a `vgem` DRM fd
  (`vl_vgem_drm_screen_create`), per the
  [MS devblog](https://devblogs.microsoft.com/commandline/d3d12-gpu-video-acceleration-in-the-windows-subsystem-for-linux-now-available/).
- **On 6.18 kernels** (WSL 2.9.x and "3.0.x" packages): there is no DRM at all. A custom kernel
  (`.wslconfig kernel=`) is required for vgem or vkms. sharpninja also found that pointing
  `kernelModules=` at a custom `modules.vhdx` broke WSL 2.9.12 networking, so built-in (`=y`) was
  needed [C].
- clarenceb found `vkms.ko` in an arm64 6.18.33.2 kernel [C]. The branch head no longer has it.

### 1.3 What Hyprland/Aquamarine require (verified at aquamarine 04bfb7d, Hyprland ce2167a, both 2026-09-29/30)

- **Allocator:** the primary allocator is GBM, created from the first backend with `drmFD() >= 0`.
  Otherwise Aquamarine logs `"Cannot open backend: no allocator available"`. The DRM-dumb
  allocator is only used for cursors.
- **Headless backend:** `drmFD()` returns `-1`. Headless works only if a DRM backend is also up.
- **Wayland backend:**
  - It requires `xdg_wm_base`, `wl_compositor`, `wl_seat`, `wl_shm` **and** `zwp_linux_dmabuf_v1`
    with default feedback. Otherwise it fails with `"Missing protocols"`.
  - It binds fixed versions: seat 9, xdg_wm_base 6, compositor 6.
- **DRM backend:** `AQ_NO_KMS_REQUIREMENT=1` accepts a DRM device without KMS
  (`Session.cpp: openIfKMS`). `AQ_DRM_DEVICES` selects devices. It still needs libseat.
  A CI project documents the recipe for booting Hyprland 0.56.2 without a real display:
  `AQ_NO_KMS_REQUIREMENT` + a real card (virtio-gpu) + seatd + llvmpipe. The same project notes
  that "aquamarine's headless backend has no allocator of its own... render nodes are rejected"
  ([stubbedev/gelm#66](https://github.com/stubbedev/gelm/issues/66)).
- **Hyprland GL init:** it needs Aquamarine's DRM fd to find either an `EGL_PLATFORM_DEVICE_EXT`
  device that matches the fd, or a GBM device on its render node (`src/render/OpenGL.cpp`).
- **Software rendering:** Hyprland ≥ 0.56 classifies software rendering by the GL renderer string,
  llvmpipe or softpipe (hyprwm/Hyprland#16343, backported in
  [omarchy-pkgs#649](https://github.com/omacom/omarchy-pkgs/pull/649)). A d3d12 renderer string
  would be classified as hardware.
- **Measured software performance:** on an M3 Air (simpledrm + llvmpipe, ~2560×1664) Omarchy
  maintainers estimated **~15 FPS** ("operator estimate, not a benchmark") [C].

---

## 2. Hyprland on WSL/WSLg: prior attempts

| Who / where | Date | What they did | Result |
|---|---|---|---|
| [hyprwm/Hyprland#3479](https://github.com/hyprwm/Hyprland/issues/3479) | 2023-10 | Ran `Hyprland` in WSL2 (kernel 5.15) | Maintainer reply: "no". Closed. |
| [hyprwm/Hyprland disc. #4333](https://github.com/hyprwm/Hyprland/discussions/4333) | 2024-01 → 2024-10 | "Windows(OS)" question | vaxerski: "it is a stupid question. No." Contributors: no DRM, and Hyprland needs HW rendering; sway runs windowed only. |
| [clarenceb/omarchy-wsl2 docs/12](https://github.com/clarenceb/omarchy-wsl2/blob/main/docs/12-wayland-on-wsl2.md) | 2026-08-30 | Systematic attempt: nested (fails, no dmabuf); headless (fails, no allocator); **vkms + seatd + `GBM_ALWAYS_SOFTWARE=1`** | vkms run got to 34 modes, atomic KMS, a GLES 3.0 context and wayvnc attached, then `gbm_bo_create(SCANOUT)` returned NULL (kms_swrast has no PRIME export for scanout) → assert. Shipped **sway + pixman** instead. |
| [**sharpninja/omarchy-wslg**](https://github.com/sharpninja/omarchy-wslg) ("wslg-protocol-bridge") | 2026-09-23 | Custom kernel `6.18.40.1-…-omarchy-vkms1+` with **VKMS built in**; C bridge (`src/bridge.c`, ~1.6 kLOC) is a Wayland *server* for Hyprland (advertises linux-dmabuf, xdg-shell) and a Wayland *client* of WSLg; launches Hyprland with `GBM_ALWAYS_SOFTWARE=1 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`; `mmap`s each dmabuf and `memcpy`s rows into 3 staging `wl_shm` buffers; `--fullscreen` maps it fullscreen on the primary monitor. Launched as `wsl.exe -d Omarchy-Desktop -u omarchy -- …/omarchy-wslg --fullscreen`; closing the window exits the bridge and Hyprland. | **Unmodified Hyprland + Omarchy config running nested in one WSLg window** [C]. Validation is an AI "hostile validator" receipt plus test suite, not a human benchmark. No FPS numbers; CPU-rendered. The README says Win+Enter opens a terminal. That conflicts with wslg#672 and must be verified. |
| [mle98 gist "WSL2 and true kiosk fullscreen experience with niri"](https://gist.github.com/mle98/2deb6e0aa1da3aed70a73dad9c29e8f7) | 2025–26 | Not Hyprland: rebuilt the WSLg system VHD with a patched `rdprail-shell` (Ctrl+Alt+Backspace fullscreen binding) | Shows WSLg can be rebuilt and swapped (`system.vhd`), a heavy maintenance cost. |

There are no YouTube or Reddit reports of Hyprland working in WSL. Searches return only "make
Windows look like Hyprland" videos and "use sway instead" answers.

---

## 3. Omarchy (and omakub) on WSL

| Project | Scope | How | Notes |
|---|---|---|---|
| [craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) (25★, created 2025-10-30, pushed 2026-08-31; [announcement on X, 2026-06-26](https://x.com/craigaloewen/status/2070518686578856168)) | **CLI/TUI only** ("basic flavour") | Built with `wslc` into `Omarchy-Basic.wsl`, pinned to Omarchy v4.0.0; x64 and arm64; ships `omarchy-wsl-install` | By the WSL PM, as a personal project. Upstream breakage: [omarchy#12531](https://github.com/omacom/omarchy/issues/12531) (migration pulls the full desktop package). |
| [taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl) (branch `v1`, 2026-08-28) | Real `omarchy` pacman package and real install scripts; **GUI apps via WSLg RAIL, no Hyprland session** | pacstrap in a container → `.wsl`, `oobe.command` provisioning | [ROADMAP](https://github.com/taufderl/omarchy-wsl/blob/v1/ROADMAP.md): "nested Hyprland under WSLg" is designed but not built. Its plan (`WLR_BACKENDS=wayland`) does not apply to Aquamarine. |
| [clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2) (2026-08-30) | Mode 1 headless CLI; Mode 2 WSLg apps; **Mode 3 sway desktop** nested (3a) or headless + wayvnc + TigerVNC fullscreen (3b, "recommended: SUPER keys work… composites once instead of twice") | sway + `WLR_RENDERER=pixman`, Omarchy keybinds/theme/waybar; `omarchy-wsl-desktop --compositor hyprland` exists only to demonstrate the failure | Feature matrix: no animations/blur, no Xwayland in the session, single output, CPU rendering, no VNC audio, text-only clipboard over VNC. |
| [sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg) | Hyprland desktop | See §2 | Only Hyprland-session prior art. |
| [valorisa/ArchLinux-Omarchy-WSL-Script](https://github.com/valorisa/ArchLinux-Omarchy-WSL-Script) (2025-10) | Script that "installs Hyprland… launch with `hyprland`" | — | Naive: it will hit the failures above. |
| [hypn/omarchy-for-wsl](https://github.com/hypn/omarchy-for-wsl), `marlonangeli/omarchy-wsl` (CLI-only fork, now 404), `bandrada/wslarch` (404) | CLI dotfiles ports | — | — |
| [tvcam/omarchy-theme-wsl](https://gotabs.net/omarchy-wsl-cross-platform-theme-sync) | Syncs 17 Omarchy themes to Windows Terminal, VS Code, Windows accent and wallpaper | Go | Cosmetic. |

**Upstream stance.**

- Omarchy moved to `omacom/omarchy`. [Discussion #473 "wsl?"](https://github.com/basecamp/omarchy/discussions/473)
  (2025-08) got no maintainer or DHH reply. The community advice was "use a Hyper-V VM".
- The [Hyper-V guide #445](https://github.com/basecamp/omarchy/discussions/445) uses `hyperv_fb`
  and `Set-VMVideo`. It reports "much smoother than VirtualBox" with no FPS numbers, and no enhanced
  session, clipboard or audio.
- Hyprland upstream is openly hostile to WSL (§2).
- Omarchy's own plan [`plans/remote.md`](https://github.com/omacom/omarchy/blob/quattro/plans/remote.md)
  (2026-09-23) bets on **Sunshine (wlr-screencopy of a `hyprctl output create headless` output) +
  Moonlight**. It explicitly rejects wayvnc and xrdp chains ("unencrypted-by-default,
  software-encoded, pointer-laggy") and RustDesk (no RemoteDesktop portal in
  xdg-desktop-portal-hyprland). `moonlight-qt` is already preinstalled in Omarchy.

No omakub-on-WSL desktop projects were found. Omakub is Ubuntu/GNOME based and WSL users use it for
the CLI parts only.

---

## 4. Other full Linux desktops inside WSL2

| Approach | Example / source | GPU status | Performance / UX notes |
|---|---|---|---|
| **sway nested in WSLg** (wayland backend, pixman) | [jordankoehn/sway-wsl2](https://github.com/jordankoehn/sway-wsl2) (62★, updated 2026-05); [wslg#101](https://github.com/microsoft/wslg/issues/101); [wslg disc. #67](https://github.com/microsoft/wslg/discussions/67) | CPU composition. Clients can still use d3d12 (readback → shm → sway) | **Multi-monitor works**: one nested output per monitor, `swaymsg create_output`, each output a RAIL window maximised per monitor. Clipboard via `wl-paste --watch` plus a polling service. **Win key: PowerToys remap Win→NumLock (Mod3), RightCtrl→Win.** Crashes after sleep and network changes. Unmounts WSLg's `/tmp/.X11-unix` to run its own Xwayland. |
| **sway headless + wayvnc + TigerVNC fullscreen** | clarenceb Mode 3b | CPU | Super works through TigerVNC's fullscreen LL hook; text-only clipboard; no audio; wayvnc caps at 30 FPS by default (`--max-fps`). |
| **niri (Smithay) winit backend nested in WSLg** | [niri#2307](https://github.com/niri-wm/niri/issues/2307): "works very well… using it full time at work for about 3 weeks"; [niri#2415](https://github.com/niri-wm/niri/issues/2415) (Smithay crash on resize); [niri#2944](https://github.com/niri-wm/niri/issues/2944) (winit lacked linux-dmabuf, fixed in niri PR #3327) | **GPU composition**: Smithay GlesRenderer on EGL-on-Wayland, which is d3d12 when `GALLIUM_DRIVER=d3d12` | This is the **only evidence we found of a GPU-composited nested compositor in WSLg**. [Cookiekira/niri#1](https://github.com/Cookiekira/niri/issues/1) (2026-08-29) plans a GLES→VA-API/D3D12 zero-copy **4K120 streaming backend** for niri-in-WSL; no results yet. |
| **GNOME nested** (`gnome-shell --nested`, or `--devkit` on 26.04) | [tdcosta100 gist](https://gist.github.com/tdcosta100/7def60bccc8ae32cf9cacb41064b1c0f) | Partially GPU with `GALLIUM_DRIVER=d3d12` (breaks some apps) | "No fullscreen support", no clipboard, 3–5 min app launch delays reported on 26.04. |
| **Full desktop replacing Xorg with Xwayland `-fullscreen`** + display manager | [tdcosta100 gist 2](https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912) | d3d12 was unstable (GNOME Shell crashes, Chrome glitches); most users force `LIBGL_ALWAYS_SOFTWARE=1` | Fullscreen through Xwayland; audio needs workarounds; 24.04 detects only one monitor. |
| **KDE Plasma 6 nested** | Comments in the tdcosta100 gist (Feb 2026); [jace479/Win-wayland ("ntKDE")](https://github.com/jace479/Win-wayland), vibe-coded 2026-09 | Unknown | Prototype only. |
| **xrdp + Xorg (xorgxrdp) + XFCE/GNOME, mstsc** | [aliaxam153 guide](https://github.com/aliaxam153/XFCE-GNOME-desktop-on-WSL2-via-RDP-setup-guide); xrdp ≥ 0.10.2 has H.264 (x264/OpenH264) over GFX ([wiki](https://github.com/neutrinolabs/xrdp/wiki/H.264-encoding)) | CPU (glamor needs a render node) | Mature. mstsc fullscreen forwards the Win key. X11 only, so not useful for Hyprland. Hyprland + xrdp (libvnc → wayvnc) exists ([munenick blog](https://www.munenick.me/en/blog/hyprland-rdp/), [omarchy disc. #3350](https://github.com/omacom/omarchy/discussions/3350)) and is fragile. |
| **X servers on Windows** (X410, VcXsrv, GWSL, Cygwin/X, MobaXterm) | [X410 + WSL2 over VSOCK](https://x410.dev/cookbook/wsl/using-x410-with-wsl2/) (WSL2 needs no registry entries; `socat … VSOCK-CONNECT:2:6000`); X410 desktop mode renders with D3D11 | Indirect GLX at best | X11 only, so irrelevant for Hyprland. Shows that a Windows app can accept **hvsocket** from WSL without admin (Hyper-V VMs need `GuestCommunicationServices` registry keys). |
| **WSLg desktop-shell mode** (`WSL2_WESTON_SHELL_DESKTOP=true`) | `WSLGd/main.cpp` [V] | Weston pixman renderer; frames RemoteFX/NSC-encoded on the CPU over hvsocket | One RDP desktop window. With `WSLG_USE_MSTSC=true` and fullscreen, mstsc's default `KeyboardHookMode=2` forwards Win keys. Global to all distros; no gfxredir shared memory. Not seen used by anyone for a nested compositor. |
| **"Azure Linux Desktop" PoC** | [boxofcables, 2026-06-06](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/) | "GPU acceleration" (no detail) | A .NET/WinUI app **hosting the RDP ActiveX control `mstscax.dll`**, connecting to xrdp in a `wslc` container over loopback; `pipewire-module-xrdp` for audio. **Closest existing pattern for a custom Windows launcher/viewer.** The repo ([sirredbeard/azurelinux-desktop](https://github.com/sirredbeard/azurelinux-desktop)) has since pivoted to a bare-metal GNOME image. |
| **KDAB "Wayland on Windows"** | [kdab.com, 2021](https://www.kdab.com/wayland-on-windows/) | llvmpipe | Weston's X11 backend into VcXsrv; historical. |

Note: "WSL 3" articles that claim "near-native GPU passthrough" (e.g.
[XDA](https://www.xda-developers.com/wsl-3-will-finally-let-linux-apps-use-your-gpu-without-the-performance-tax/))
were explicitly denied by the WSL PM: ["there is no such thing as WSL 3!"](https://x.com/craigaloewen/status/2069420597487055276).
Build 2026 shipped WSL *containers* (`wslc`) and the Consomme networking mode.

---

## 5. Streaming a Linux Wayland compositor to a Windows viewer

### 5.1 Servers

| Server | Capture | Encode | Hyprland support | WSL blockers | Notes |
|---|---|---|---|---|---|
| **[hypr-rdp](https://github.com/MuNeNiCK/hypr-rdp)** (Rust, IronRDP; 100★; 2026-03 → 2026-09) | wlr or ext screencopy, **shm double-buffered** with an optional dmabuf zero-copy path [V] | **H.264 AVC420 over EGFX**; VA-API (scans `/dev/dri/renderD*`) with automatic **OpenH264 software fallback**; AVC444 experimental (software) | Native, needs Hyprland ≥ 0.54; creates a headless output sized to the client | VA-API needs a render node (vgem: 6.6 or custom kernel). The shm + OpenH264 path needs no DRM, *but Hyprland itself must boot* | Clipboard (text, images, **files**), PipeWire audio → rdpsnd, TLS/PAM, default 30 FPS (`--fps`). **Best fit for B.** |
| [lamco-rdp-server](https://github.com/lamco-admin/lamco-rdp-server) + the [moerketh fork](https://github.com/moerketh/lamco-rdp-server) | Portal/PipeWire, wlr-direct | AVC420/444, VA-API/NVENC | Hyprland listed | Portal stack | The fork adds **Hyper-V Enhanced Session features: an RDP server on AF_VSOCK** (plus WebSocket and x264). This is prior art for RDP over hvsocket from a Linux guest. |
| KRdp (KDE), gnome-remote-desktop (GNOME 50: VA-API/Vulkan EGFX H.264; [g-r-d!294](https://gitlab.gnome.org/GNOME/gnome-remote-desktop/-/merge_requests/294)) | Compositor-native | HW H.264 | No | Not Hyprland | [KRdp latency work in Plasma 6.8](https://www.phoronix.com/news/KDE-Plasma-6.8-KRDP-Lower-Lat) |
| Weston RDP backend (upstream ≥ 13 has the GL renderer for RDP/VNC/PipeWire, per [Collabora](https://www.collabora.com/news-and-blog/news-and-events/weston-13-release-backends-consolidation.html)) | Weston itself | RemoteFX/NSC | No (it is its own compositor) | GL renderer needs an EGL device | Could host Hyprland *nested*, but that is double composition. |
| **wayvnc** ([v0.10.2, 2026-09-25](https://github.com/any1/wayvnc)) | wlr/ext screencopy (shm OK) | Tight/ZRLE on the CPU; **H.264 only with `--gpu` (VA-API via DRM-PRIME dmabufs)** | Yes (Hyprland has screencopy); 0.10 adds `--desktop` multi-output composition | H.264 path is unusable without DRM | Default 30 FPS cap; maintainer recommends TigerVNC + H.264 ([disc. #287](https://github.com/any1/wayvnc/discussions/287)); text-only clipboard; no audio. |
| **Sunshine** ([docs](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)) | `wlr` = wlr-screencopy **into GBM-allocated dmabufs** (`src/platform/linux/wayland.cpp` [V]); `kms` (needs CRTCs); `x11` (slow) | VA-API (`adapter_name=/dev/dri/renderD*`), NVENC, Vulkan video, software | Omarchy's official remote plan | **wlr capture needs GBM + a render node + linux-dmabuf.** The d3d12 VA driver is reachable only through a vgem fd, and importing guest dmabufs into D3D12 is not supported. The capture path would need patching to shm + upload. | Best latency class, but **no clipboard** in mainline (text sync [declined, #5384](https://github.com/LizardByte/Sunshine/issues/5384); the Apollo fork has it but hosts on Windows only). |
| Parsec | — | — | **Linux cannot host** ([Parsec compatibility](https://support.parsec.app/hc/en-us/articles/32381568346644-Hardware-and-Software-Compatibility)) | — | Not an option. |

**Would Mesa's d3d12 VA-API encoder work with Sunshine?** Not as-is.

1. The VA display must come from a DRM fd. Mesa maps a `vgem` fd to the d3d12 video screen
   ([context.c](https://gitlab.freedesktop.org/mesa/mesa) `vl_vgem_drm_screen_create` [V]). That
   exists only on 6.6 x86 kernels (after `modprobe vgem`) or on custom kernels.
2. Sunshine's wlr path imports GBM dmabufs into VA surfaces. On WSL those would be vgem or llvmpipe
   system-memory buffers that D3D12 cannot alias, so it needs a CPU upload (`vaPutImage` or a
   derived image). hypr-rdp already has the shm-in path.
3. Codec availability is vendor-dependent:
   - H.264/HEVC encode since Mesa 22.2/22.3; AV1 encode since 23.2
     ([Phoronix](https://www.phoronix.com/news/Microsoft-D3D12-AV1-Mesa)).
   - An RX 9070 XT exposes **no** VA profiles in WSL ([WSL#41733](https://github.com/microsoft/WSL/issues/41733)).

### 5.2 Windows clients (fullscreen and Win-key behaviour, see §6)

mstsc/msrdc (RDP; `KeyboardHookMode`), Moonlight-qt (SDL keyboard grab), TigerVNC
(`FullscreenSystemKeys`), and a custom viewer (our own LL hook).

### 5.3 Measured and claimed latency and throughput

| Quantity | Number | Source |
|---|---|---|
| hv_sock raw throughput (64 KB writes) | 460–690 MB/s (Linux writer) and 615–680 MB/s (Windows writer) with 24–32 KB rings; **~1,860 / 1,670 MB/s with 128 KB rings**; ~2,000 / 1,070 MB/s with 64 KB rings | Upstream commit ac383f58f3c9, quoted in [WSL PR #41690](https://github.com/microsoft/WSL/pull/41690) |
| WSL stdio relay over hvsocket | 613 MiB/s (64 KiB buffer) | WSL PR #41603 (cited in #41690) |
| Localhost TCP, WSL 2.9.3, mirrored | WSL→WSL 9.48 Gbit/s; **WSL→Windows 15.3 Gbit/s**; **Windows→WSL 1.5 Gbit/s** (1 stream), 3.9–6.3 Gbit/s (4–8 streams) | [WSL#40965](https://github.com/microsoft/WSL/issues/40965) |
| Localhost TCP, second user | Mirrored 5.86 Gbit/s (WSL→Win) / 0.55 Gbit/s (Win→WSL); **Consomme 2.38 Gbit/s both ways** | Same thread |
| WSLg d3d12 present readback (Intel UHD, Mesa 26.3-dev) | 640×480: 106–153 ms/frame (7–9 FPS); 1280×720: 327–359 ms (~2.8 FPS). A 32-thread copy mitigation reached ~40 FPS at 640×480 and ~7 FPS at 1080p | [wslg#1498](https://github.com/microsoft/wslg/issues/1498) |
| WSLg d3d12, NVIDIA Quadro M1200 (2021) | GpuTest 1920×1080 fullscreen: Plot3D **118 FPS**, FurMark 29 FPS | [wslg disc. #146](https://github.com/microsoft/wslg/discussions/146) |
| WSLg vs native (AMD WX3200) | Unigine Heaven 1080p windowed **17.3 FPS vs 43.4 FPS native** | [Virtualization Review](https://virtualizationreview.com/articles/2022/07/01/wslg-deeper-dive.aspx) |
| WSLg overhead (official) | Up to 50 % at ~600 FPS on a dGPU; "much closer to native" at lower FPS or on an iGPU | [WSLg README](https://github.com/microsoft/wslg#wslg-code-flow) |
| RAIL without shared memory (xfreerdp, network) | 125–296 Mbit/s uncompressed, 674 ms mean click-to-repaint (xrdp: 149 ms) | [wslg#1503](https://github.com/microsoft/wslg/issues/1503) |
| Moonlight/Sunshine on a LAN | 1080p ~142 FPS HEVC: network 1 ms, host processing 2.4/10.3/4.8 ms (min/max/avg), decode 0.05 ms, ~6 ms total claimed | [note.com write-up](https://note.com/cute_agapan9087/n/n5e400bb52235?hl=en) [C] |
| Hyprland on llvmpipe (M3 Air, ~4.3 MP) | ~15 FPS (operator estimate) | [omarchy-pkgs#649](https://github.com/omacom/omarchy-pkgs/pull/649) [C] |

### 5.4 Is there a Looking-Glass-style shared-memory path between WSL and Windows?

- **Looking Glass itself:** the Windows guest's IDD or DXGI capture copies frames into IVSHMEM, and
  the Linux client imports or uploads them. Its timing UI breaks a frame into
  Capture/Post/**Copy**/Hold/Transport/Import stages
  ([`doc/performance.rst`](https://github.com/gnif/LookingGlass)).
  Its keyboard grab is Linux-side (`input:grabKeyboard`, ScrLk escape key). The direction is the
  opposite of ours, but the design (shared memory, no codec, cadence-aware) is what C should emulate.
- **WSL already has the analogue, privately.** WSLg's gfxredir writes pixels into a virtio-fs
  (tag `wslg`) file backed by a Windows section. msrdc opens the section by name from an object
  directory passed on its command line.
  - Users can `mount -t virtiofs -o dax wslg <dir>` but reported being unable to create files
    ([wslg#896](https://github.com/microsoft/wslg/issues/896)).
  - There is no documented API, and the SectionFs path has had lifecycle bugs
    ([openvmm#4274](https://github.com/microsoft/openvmm/issues/4274),
    [wslg#1483](https://github.com/microsoft/wslg/issues/1483)).
  - Reusing it is an **unexplored, undocumented** avenue, and a high-value spike for C.
- **drvfs over virtio-fs** (`virtiofs=true`) now supports `MAP_SHARED` **without DAX**
  ([WSL PR #40426](https://github.com/microsoft/WSL/pull/40426)). That means page-cache writeback,
  not coherent zero-copy shared memory with a Windows mapping, so it is not a frame channel.
- **D3D12 resource handles cannot cross the VM boundary** (#1498 experiment). Zero-copy GPU sharing
  needs Microsoft (DeviceHost/GFXREDIR v2) work.
- **Practical answer today:** hvsocket (≈1.7–2 GB/s ceiling) or TCP loopback, with damage tracking
  and optional compression. Shared memory is a stretch goal.

---

## 6. Windows-key capture

### 6.1 Mechanisms

- **`WH_KEYBOARD_LL`** ([LowLevelKeyboardProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc))
  - Sees keys before the shell. Returning non-zero swallows the key, including `VK_LWIN`/`VK_RWIN`,
    Alt+Tab and Alt+Esc.
  - SDL2's implementation (`WIN_KeyboardHookProc`, used by Moonlight's "Capture system keyboard
    shortcuts") swallows LWIN, RWIN, LMENU, RMENU, LCONTROL, RCONTROL, TAB and ESCAPE while grabbed
    ([SDL source](https://github.com/libsdl-org/SDL/blob/SDL2/src/video/windows/SDL_windowsevents.c) [V]).
- **`RegisterHotKey`** cannot claim hotkeys that the shell already owns (most `Win+…`), and it
  cannot suppress the Start menu on a bare Win press. It is not suitable.
- **Not interceptable by any user-mode hook:**
  - **Ctrl+Alt+Del** (SAS). Moonlight's UI says so explicitly.
  - **Win+L** (lock). Workaround: the `DisableLockWorkstation` policy under
    `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System`, which needs admin and disables
    Win+L everywhere.
  - [PowerToys docs](https://learn.microsoft.com/en-us/windows/powertoys/keyboard-manager): "Win+L
    and Ctrl+Alt+Del cannot be remapped… Win+G often opens the Xbox Game Bar, even when
    reassigned" (disable Game Bar in Settings).

### 6.2 Per-client behaviour

| Client | How it forwards Win | Default |
|---|---|---|
| mstsc / mstscax (RDP ActiveX) | `keyboardhook:i:N` / [`KeyboardHookMode`](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientsecuredsettings-keyboardhookmode): 0 = local, **1 = remote**, 2 = remote only in fullscreen | **2** (fullscreen only). Ctrl+Alt+Del is never redirected (Ctrl+Alt+End instead). |
| Hyper-V VMConnect | Hyper-V Settings → Keyboard → "Use on the virtual machine" / "physical computer" / "only when running full-screen" ([virtual_pc_guy](https://learn.microsoft.com/en-us/archive/blogs/virtual_pc_guy/virtual-machine-connection-key-combinations-with-hyper-v)) | Full-screen only |
| Moonlight-qt | "Capture system keyboard shortcuts" = in fullscreen / always; SDL keyboard grab (LL hook) ([moonlight-qt#527](https://github.com/moonlight-stream/moonlight-qt/issues/527), `app/streaming/input/input.cpp`) | Off unless enabled |
| Parsec | "Immersive Mode" (Keyboard/Mouse/Both, Ctrl+Shift+I) ([Parsec help](https://support.parsec.app/hc/en-us/articles/32381199341716-Parsec-App-for-Windows)) | Off |
| TigerVNC | `FullscreenSystemKeys` (LL hook in `vncviewer/win32.c`); windowed passthrough is a request ([tigervnc#1899](https://github.com/TigerVNC/tigervnc/issues/1899)) | On in fullscreen |
| Looking Glass client | Linux side: `input:grabKeyboard`, `grabKeyboardOnFocus`, `autoCapture`; ScrLk toggles | — |
| **WSLg / msrdc RAIL** | **Not forwarded.** "The Win key is always redirected to Windows" ([wslg#672](https://github.com/microsoft/wslg/issues/672), open since 2022-02; [wslg#583](https://github.com/microsoft/wslg/issues/583)). `wslg.rdp` sets no `keyboardhook`. | Also: global LL-hook apps break WSLg key-up delivery ([wslg#1421](https://github.com/microsoft/wslg/issues/1421)), and PowerToys remaps sometimes stop working in WSLg windows ([PowerToys#33364](https://github.com/microsoft/PowerToys/issues/33364)). |

### 6.3 Remapping Win only when "our" window is focused

- **PowerToys Keyboard Manager**
  - App-specific remapping exists only for **shortcuts** (target by process, e.g. `msrdc.exe`), not
    for single keys. A bare Win→X remap is global.
  - sway-wsl2 uses a global Win→NumLock remap, with Mod3 as the sway modifier.
- **AutoHotkey v2**
  - `#HotIf WinActive("ahk_class RAIL_WINDOW ahk_exe msrdc.exe")` plus `LWin::F24` (or `vkE8`) can
    target WSLg windows ([AHK forum thread](https://www.autohotkey.com/boards/viewtopic.php?t=124784),
    linked from wslg#672).
  - Match on the window title as well, e.g. sharpninja's `aquamarine - WAYLAND-1 (distro)`, so only
    the Hyprland window is affected.
  - The Linux side then maps the substitute key to Super, for example with an XKB snippet:
    `key <FK24> { [ Super_L ] }; modifier_map Mod4 { <FK24> };`, applied through Hyprland
    `input:kb_file`.
- **Risks with msrdc:**
  - msrdc may read raw scancodes or ignore injected (`LLKHF_INJECTED`) events (#33364).
  - Stuck-key and repeat bursts with other global hooks (#1421).
  - Omarchy bindings that use **Win+L**, **Win+G** and **Super+Ctrl+Alt+Delete** remain
    uncapturable or conflicting and must be rebound.
- **A purpose-built viewer (architectures B and C) avoids all of this:** it owns the LL hook while
  it is foreground and fullscreen, and forwards Win as KEY_LEFTMETA directly.

---

## 7. GPU-accelerated Wayland compositors *without* DRM/GBM

| Compositor / library | Buffer and renderer requirements | Works on WSL d3d12 with GPU composition? |
|---|---|---|
| **wlroots** (sway, labwc, river) | Allocator order: GBM only if the backend, renderer **and** `drm_fd >= 0`; otherwise **shm allocator** (no DRM). GLES2 and Vulkan renderers need a DRM render node (autocreate opens one, else falls back to pixman). `WLR_RENDERER_ALLOW_SOFTWARE` gates llvmpipe. | **No GPU**: pixman only (clarenceb, sway-wsl2). |
| **Smithay** (niri, cosmic-comp, anvil) | `winit` and `x11` backends render with GlesRenderer into a host EGL window; no DRM needed. The KMS backend needs DRM. | **Yes (nested)**: niri's winit backend is in daily use in WSL (niri#2307). Presents through the host's readback path. |
| **Weston** (upstream ≥ 13) | GL renderer usable on headless/RDP/VNC/PipeWire backends via EGL (GBM or surfaceless). | Plausible with Mesa surfaceless EGL → drisw → d3d12 (`sw_helper.h` default order d3d12, then llvmpipe [V]). Not tested by anyone we found. |
| **KWin** | Wayland (nested) and virtual backends: EGL with a GBM render node, otherwise QPainter (CPU). | CPU only, as far as we can tell. |
| **Mutter** (headless / devkit) | EGL via render node or surfaceless; X11-nested path via GLX/EGL-X11. | tdcosta100 reports partial d3d12 use via `GALLIUM_DRIVER=d3d12` (unstable). |
| **Hyprland / Aquamarine** | GBM on a DRM fd is mandatory; the renderer picks its EGL device from the DRM fd (§1.3). | **No**, without patches. The fix is to add a non-GBM allocator (shm/memfd) plus an EGL-device/surfaceless renderer path on d3d12, with GPU→CPU readback into the output buffer. |

**Key enabler for A2 and C [V].** On WSL, Mesa's d3d12 driver is a sw-winsys driver. Any EGL display
that ends up on the swrast/drisw loader (surfaceless, or the `EGL_MESA_device_software` device) gets
**hardware** D3D12 when `GALLIUM_DRIVER=d3d12` is set. A compositor can therefore:

1. render into FBO textures on the GPU;
2. read back with PBOs (or a Dozen `vkCmdCopyImageToBuffer` into HOST_CACHED memory);
3. write the result into shm, a socket, or shared memory.

The open question is steady-state readback cost (§0 point 6).

---

## 8. Windows-native hosts for Linux compositor output

- **No native Windows Wayland server exists** that WSL clients can use.
  - Wayland needs fd passing (`SCM_RIGHTS`) and shm, which Win32 AF_UNIX lacks
    ([WSL#5518](https://github.com/microsoft/WSL/issues/5518),
    [wslg#1204 "waypipe on Windows"](https://github.com/microsoft/wslg/issues/1204),
    [Hyprland disc. #4333](https://github.com/hyprwm/Hyprland/discussions/4333)).
  - Waypipe has no Windows endpoint.
- **Patterns that do exist:**
  1. **msrdc/mstsc as the viewer** (WSLg, the Azure Linux Desktop PoC with embedded `mstscax.dll`,
     VMConnect enhanced session). RDP transport over TCP or **hvsocket**: WSLg passes
     `/v:<VmId> /hvsocketserviceid:<port>-FACB-11E6-BD58-64006A7986D3`, and `hvsocketenabled:i:1`
     is in `wslg.rdp`.
  2. **X servers** (X410 over hvsocket, VcXsrv).
  3. **Game-streaming clients** (Moonlight) over TCP/UDP loopback.
  4. **Xpra**: a WSL-over-vsock connection has been requested
     ([xpra#3666](https://github.com/Xpra-org/xpra/issues/3666)); it forwards per-app windows, not
     a desktop.
- **No project was found that presents a Linux compositor's output in a fullscreen D3D11/D3D12
  swapchain with a raw-frame protocol over hvsocket.** That is the gap architecture C fills. The
  closest existing idea is Cookiekira/niri#1 (encode-based, plan only).

---

## 9. Candidate end-to-end architectures

### 9.1 Estimation method [E]

- **Frame sizes (BGRA):** 1080p 8.29 MB; 1440p 14.7 MB; 4K 33.2 MB.
- **Bandwidth needed:** 60 Hz → 0.50 / 0.88 / 1.99 GB/s. 144 Hz → 1.19 / 2.12 / 4.78 GB/s.
- **A "copy"** is a full-frame (or damage-box) pixel transfer between buffers or memory domains.
  The compositor's own render pass and the final DWM composition are not counted.
- **CPU memcpy** at 10–20 GB/s effective: 0.4–0.8 ms at 1080p, 1.7–3.3 ms at 4K.
- **GPU readback on d3d12** is **unknown per GPU**. The range spans roughly 1–5 ms at 1080p for a
  good dGPU (inferred from Plot3D at 118 FPS) to more than 100 ms on some Intel iGPU paths through
  Mesa's present code (#1498).
- **Latency** is input-to-photon at 60 Hz (16.7 ms per frame). "Present" includes one DWM or flip
  interval.

### 9.2 The candidates

**(A) Hyprland nested in WSLg as one fullscreen RAIL window**

- *A0, as-is:* impossible (missing dmabuf, xdg_wm_base and compositor version mismatch).
- *A1, sharpninja bridge:*
  - Needs a custom vkms kernel.
  - Hyprland runs on llvmpipe and renders into vkms dumb buffers exported as dmabuf.
  - The bridge memcpy's the dmabuf into wl_shm, then WSLg VAIL takes over.
- *A2, patched Aquamarine Wayland backend:*
  - Clamps bind versions to what the parent advertises.
  - Accepts a wl_shm-only parent and allocates memfd/shm buffers.
  - Hyprland renders on d3d12 via surfaceless/device EGL, with PBO readback into the shm buffer.
  - Advertises only wl_shm to its own clients.
  - WSLg handles audio (PulseServer), clipboard (partially), DPI and multi-monitor. Multi-monitor
    works as one nested output per monitor, each a RAIL window (the sway-wsl2 technique).

**(B) Hyprland headless + in-guest server + Windows client in fullscreen**

- Prerequisite: Hyprland must boot headless. Options:
  - vkms or vgem custom kernel + `AQ_NO_KMS_REQUIREMENT` + seatd + llvmpipe, or
  - the A2/C allocator and renderer patches.
- *B1:* hypr-rdp (EGFX H.264; VA-API through vgem d3d12, or OpenH264 fallback) → mstsc `/f`, or an
  embedded mstscax with `KeyboardHookMode=1`, over loopback TCP. Optionally an AF_VSOCK listener to
  hvsocket, as in the moerketh fork.
- *B2:* wayvnc → TigerVNC fullscreen.
- *B3:* Sunshine → Moonlight (needs capture and VA patches, §5.1).

**(C) Custom Aquamarine "wsl" backend + custom Windows viewer**

- Linux side, an Aquamarine backend that:
  - allocates memfd buffers;
  - runs Hyprland's GL on d3d12;
  - reads back damage regions asynchronously (double or triple-buffered PBOs);
  - streams damage rectangles over **AF_VSOCK → hvsocket** (later a shared-memory ring);
  - receives input (evdev-like), cursor, output-configuration and clipboard messages on the same
    or a second channel.
- Windows side, one exe:
  - a fullscreen borderless window per output with a flip-model D3D11 swapchain;
  - a `WH_KEYBOARD_LL` hook while foreground, and raw input;
  - Win32 clipboard listener, per-monitor DPI;
  - spawns `wsl.exe -d … start-womarchy` and exits when the session ends.
- Audio goes through WSLg's PulseServer or PipeWire unchanged.

**(D) Software-rendered Hyprland on vgem/vkms**

This is the rendering choice inside A1/B when no GPU path exists.

- vkms (custom kernel) plus a bridge (A1), or vgem card (6.6 kernels, or a custom kernel) plus
  `AQ_NO_KMS_REQUIREMENT` plus a headless output plus a streaming server.
- Note: `kms_swrast` scanout allocation failed for clarenceb on vkms. sharpninja got past it,
  presumably because the bridge's dmabuf path does not request scanout.

**(E) Other ideas**

- *E1: WSLg desktop-shell mode + mstsc fullscreen.* One global `.wslgconfig` switch; mstsc
  fullscreen forwards Win; frames are RemoteFX CPU-encoded over hvsocket; still needs A's Hyprland
  fixes inside. A cheap Win-key experiment.
- *E2: Omarchy in a Hyper-V VM* (community default). Real Hyprland, hyperv_drm + llvmpipe,
  VMConnect Win-key option. **Not WSL.**
- *E3: Omarchy-flavoured non-Hyprland compositor.* sway + pixman (clarenceb) works today. A
  Smithay compositor (niri-style) via winit gets **GPU** composition. Not Hyprland.
- *E4: Aquamarine "RDP-RAIL" backend* that speaks RAIL + GFXREDIR to msrdc and reuses WSLg's VAIL
  shared-memory channel. This is speculative (undocumented, needs SectionFs access) and inherits
  RAIL's Win-key problem.
- *E5: zero-copy client path.* Dozen `VK_KHR_external_memory_fd` works between Linux processes
  (#1498). A compositor-side import could remove the client readback/upload pair for Vulkan
  clients. This is an optimisation for C, not an architecture.

### 9.3 Comparison table [E, except where cited]

| | **A1** bridge + vkms + llvmpipe | **A2** patched AQ Wayland backend, d3d12 | **B1** headless + hypr-rdp + mstsc | **B2** wayvnc + TigerVNC | **B3** Sunshine + Moonlight | **C** custom backend + viewer | **D** sw Hyprland (standalone) | **E1** WSLg desktop-shell + mstsc |
|---|---|---|---|---|---|---|---|---|
| Hyprland renders on | CPU | **GPU** | CPU (D) or GPU (with A2/C patches) | CPU/GPU as B1 | GPU needs dmabuf path | **GPU** | CPU | as A |
| Pixel copies per frame (excluding composite and DWM) | 3: dmabuf→shm, shm→section, section→D3D upload (+2 per GPU client: readback, upload) | 3: readback→shm, shm→section, section→upload (+2 per GPU client) | 2 + encode: screencopy→shm, shm→encoder surface; bitstream is tiny; decode on GPU | 2 + CPU encode | 1–2 + HW encode (if dmabuf) | **2–3**: readback→socket/ring, (kernel ring copy), upload (+2 per GPU client, 0 with E5) | as A1 or B | 2–3 + RemoteFX CPU encode |
| Input→photon latency | 40–90 ms | 25–65 ms | 25–60 ms (GPU) / 45–90 (CPU) | 35–90 ms | 20–45 ms (host 2–10 ms + decode ~0–1 ms measured on LAN) | **15–40 ms** | 45–100 ms | 40–80 ms |
| FPS 1080p | 20–40 | 60 if readback ≤ ~5 ms (dGPU likely; Intel iGPU unknown) | 30 default, 60 feasible (OpenH264 or HW) | ≤30 default, ~60 max | 60–120 | 60–144 (hvsock 1.2 GB/s at 144 Hz fits) | 20–40 (≈15 FPS at 4.3 MP measured on M3) | 15–30 |
| FPS 4K | 5–10 | 20–60 (memory traffic ≈ 4×33 MB per frame) | 30–60 with HW encode only | <20 | 60 with HW encode | 30–60 over hvsock (2 GB/s at 60 Hz is the ceiling; damage helps); 60+ with shared memory | 5–8 | <10 |
| Super/Win key | ✗ (RAIL) → AHK/LL-hook remap to F24 + XKB (fragile) | same as A1 | ✓ `keyboardhook:i:1` (except Win+L, C+A+Del) | ✓ fullscreen | ✓ capture system keys | **✓ own LL hook**, full control | depends on viewer | ✓ in mstsc fullscreen |
| Clipboard | Needs bridge: Win→Linux polling only, focus-stealing ([wslg#1512](https://github.com/microsoft/wslg/issues/1512)) | same | ✓ text/images/files (cliprdr) | text only | ✗ | ✓ custom, event-driven both ways | depends | ✓ WSLg |
| Audio | ✓ WSLg PulseServer | ✓ | ✓ rdpsnd (or WSLg) | ✗ (use WSLg) | ✓ | ✓ WSLg/PipeWire | ✓ WSLg | ✓ |
| Multi-monitor | Possible (one nested output per RAIL window); the bridge is single today | ✓ same technique | RDP multimon possible; hypr-rdp single output (unverified) | wayvnc 0.10 `--desktop` composites | ✗ (one display) | ✓ one viewer window per output | as host path | ✓ |
| Kernel needs | **custom** (vkms) | stock | vgem (6.6) or custom for VA-API; D path needs vkms/vgem | same | vgem + patches | stock | custom on 6.18 | stock |
| Engineering effort | ~1–2 wk (exists) | ~4–8 wk | ~2–4 wk after Hyprland boots | ~1 wk | ~4–8 wk (patch Sunshine capture and VA) | **~10–16 wk** | ~1–2 wk | days (experiment) |
| Maintenance burden | High (custom kernel, bridge, WSLg quirks) | Medium (AQ/Hyprland patch rebase; upstream unlikely to accept WSL-motivated changes) | Medium-low (hypr-rdp maintained) | Low | Medium-high | Medium-high (own backend + viewer; shares AQ API churn) | High | Medium (global WSLg config) |
| Launch/exit UX | ✓ `wsl.exe … --fullscreen` blocks until the window closes | ✓ | Launcher starts the session and runs `mstsc /f`; exit tears down | similar | similar | ✓ best: the viewer owns the lifecycle | — | global side effects |

---

## 10. Ranked recommendation

1. **(C) Custom Aquamarine "wsl" backend + native Windows viewer.** This is the target architecture.
   - It is the only design that meets all of these together:
     - GPU composition;
     - no codec;
     - the fewest copies;
     - 1–2 frames of latency;
     - full Super-key capture (the viewer owns the LL hook);
     - event-driven clipboard in both directions;
     - one window per monitor with per-monitor DPI;
     - a clean "run from prompt, exit to prompt" lifecycle.
   - It works on the stock 6.18 kernel.
   - Start with raw BGRA damage rectangles over AF_VSOCK/hvsocket; 1080p60–144 fits. Add optional
     LZ4/QOI for 4K bursts, or a shared-memory ring if a Windows-accessible section can be
     established (spike on WSLg's SectionFs/`wslg` virtio-fs tag).
2. **(A2) Patched Aquamarine Wayland backend nested in WSLg fullscreen.** Build this first.
   - It produces a GPU-accelerated Hyprland desktop fastest.
   - It gets audio, some clipboard and multi-monitor from WSLg for free.
   - About 70 % of its code carries into C: the shm/memfd allocator, the version-clamped Wayland
     plumbing, the Hyprland non-GBM EGL renderer path, and efficient PBO readback.
   - Weakness: Super-key handling through RAIL (AHK/LL-hook remap, fragile) and WSLg quirks
     (DPI scaling, the refresh-rate cap, input bugs).
3. **(B1) Headless Hyprland + hypr-rdp + mstsc/mstscax fullscreen.** The best batteries-included
   UX: Win key via `keyboardhook:i:1`, clipboard including files, audio, and multi-monitor-capable
   RDP.
   - Costs: H.264 4:2:0 text softness (AVC444 is software-only), about 10–20 ms of
     encode/decode, and hypr-rdp's shm + OpenH264 fallback on 6.18 kernels (VA-API needs vgem).
   - It still needs Hyprland to boot headless, so it depends on D or on the C/A2 patches.
   - A good secondary mode and remote-access story.
4. **(A1 / D) vkms or vgem + llvmpipe.** Use only for an early end-to-end demo of Omarchy (for
   example, reuse sharpninja's bridge). It needs a custom kernel on current WSL, and the CPU
   rendering (~15 FPS at 4.3 MP measured) defeats the "efficient GPU" goal.
5. **(B3) Sunshine + Moonlight.** Upstream Omarchy's chosen remote stack. It has great latency on
   real GPUs but is blocked in WSL: GBM/dmabuf capture, the VA-API DRM path, and no clipboard.
   Revisit if Cookiekira/niri#1-style GLES→VA d3d12 sharing is proven.
6. **(B2) wayvnc + TigerVNC.** Trivial, but CPU encoding, a 30 FPS default, text-only clipboard and
   no audio.
7. **(E1–E3)** These are experiments or fallbacks (E1 for Win-key testing; E3 if Hyprland is
   dropped), not solutions.

### 10.1 Experiments to run before committing (ordered)

1. **d3d12 readback throughput on target GPUs** (NVIDIA/AMD dGPU and an Intel iGPU):
   - `glReadPixels` into persistent mapped PBOs, 3-deep, at 1080p, 1440p and 4K;
   - Dozen image→buffer copy into HOST_CACHED memory;
   - measure first-touch versus steady state;
   - run with `GALLIUM_DRIVER=d3d12`.

   This single number decides A2 and C viability.
2. **hvsocket throughput WSL→Windows** with `SO_SNDBUF` 128 KB–1 MB and 1–8 MB messages, and
   latency for 64 B input messages. Compare against loopback TCP (NAT, mirrored, Consomme).
3. **Win-key behaviour in WSLg:**
   - (a) add `keyboardhook:i:1` to a copy of `wslg.rdp` and `WSLG_USE_MSTSC=true`, observation
     only;
   - (b) an LL-hook helper that injects F24 into a `RAIL_WINDOW`;
   - (c) check whether msrdc honours injected keys, and whether stuck keys appear.
4. **Kernel inventory** on the user's machine (`uname -r`; `vgem` present?). This decides whether
   B1 can use VA-API and whether D needs a custom kernel.
5. **Hyprland boot spike without DRM:** stub Aquamarine's allocator (memfd) plus an EGL
   device/surfaceless renderer on d3d12 with the headless backend. This proves the renderer patch
   shared by A2, B and C.

---

## 11. Open questions and unverified claims

- sharpninja's Win+Enter-in-RAIL claim versus wslg#672. Does current msrdc (1.2.72xx) forward the
  Win key in some mode?
- Whether a Windows process can open WSLg's gfxredir sections, or create its own virtio-fs
  DAX-backed section share, for a C shared-memory path.
- Whether upstream Aquamarine would accept a generic shm allocator for nested and headless use
  (clarenceb lists this as "item 1" that would fix everything). Maintainers have been dismissive of
  WSL, but the feature is WSL-agnostic: CI, VMs without render nodes.
- hypr-rdp multi-monitor, and its behaviour with an OpenH264-only build at 60 FPS and 1080p on
  typical CPUs.
- Exact WSLg HiDPI behaviour for a fullscreen RAIL surface (1536×864 observed at 125 %) and how to
  force 1:1 without affecting other WSLg apps.
- d3d12 VA-API encode availability per vendor (the AMD RX 9070 XT exposes none; #41733).

---

## 12. Sources (primary)

**Hyprland / Aquamarine / Omarchy:**
[aquamarine](https://github.com/hyprwm/aquamarine) (`src/backend/Backend.cpp`, `Wayland.cpp`, `Headless.cpp`, `Session.cpp`) ·
[Hyprland](https://github.com/hyprwm/Hyprland) (`src/render/OpenGL.cpp`, `GLRenderer.cpp`) ·
[Hyprland#3479](https://github.com/hyprwm/Hyprland/issues/3479) ·
[Hyprland disc. #4333](https://github.com/hyprwm/Hyprland/discussions/4333) ·
[Virtual-GPU wiki](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Virtual-GPU/) ·
[gelm#66](https://github.com/stubbedev/gelm/issues/66) ·
[omarchy-pkgs#649](https://github.com/omacom/omarchy-pkgs/pull/649) ·
[omarchy#11911](https://github.com/omacom/omarchy/pull/11911) ·
[omarchy plans/remote.md](https://github.com/omacom/omarchy/blob/quattro/plans/remote.md) ·
[omarchy disc. #473](https://github.com/basecamp/omarchy/discussions/473) ·
[#445](https://github.com/basecamp/omarchy/discussions/445) ·
[#3350](https://github.com/omacom/omarchy/discussions/3350) ·
[omarchy#12531](https://github.com/omacom/omarchy/issues/12531)

**Omarchy-on-WSL projects:**
[sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg) ·
[clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2) ·
[taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl) ·
[craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) ·
[valorisa script](https://github.com/valorisa/ArchLinux-Omarchy-WSL-Script) ·
[hypn/omarchy-for-wsl](https://github.com/hypn/omarchy-for-wsl) ·
[omarchy-theme-wsl](https://gotabs.net/omarchy-wsl-cross-platform-theme-sync)

**WSL / WSLg:**
[microsoft/wslg](https://github.com/microsoft/wslg) (README, `WSLGd/main.cpp`, `package/wslg.rdp`, `wslg_desktop.rdp`) ·
[weston-mirror](https://github.com/microsoft/weston-mirror) (`rdprail.c`, `rdp.c`) ·
[WSLg debug options](https://github.com/microsoft/wslg/wiki/WSLg-Configuration-Options-for-Debugging) ·
[WSLg architecture blog](https://devblogs.microsoft.com/commandline/wslg-architecture/) ·
wslg issues [#672](https://github.com/microsoft/wslg/issues/672),
[#583](https://github.com/microsoft/wslg/issues/583),
[#101](https://github.com/microsoft/wslg/issues/101),
[#896](https://github.com/microsoft/wslg/issues/896),
[#1016](https://github.com/microsoft/wslg/issues/1016),
[#1204](https://github.com/microsoft/wslg/issues/1204),
[#1321](https://github.com/microsoft/wslg/issues/1321),
[#1332](https://github.com/microsoft/wslg/issues/1332),
[#1421](https://github.com/microsoft/wslg/issues/1421),
[#1483](https://github.com/microsoft/wslg/issues/1483),
[#1498](https://github.com/microsoft/wslg/issues/1498),
[#1503](https://github.com/microsoft/wslg/issues/1503),
[#1512](https://github.com/microsoft/wslg/issues/1512) ·
[wslg disc. #67](https://github.com/microsoft/wslg/discussions/67),
[#146](https://github.com/microsoft/wslg/discussions/146) ·
[WSL2-Linux-Kernel configs](https://github.com/microsoft/WSL2-Linux-Kernel) ·
WSL [#40965](https://github.com/microsoft/WSL/issues/40965),
[#41733](https://github.com/microsoft/WSL/issues/41733),
[PR #41690](https://github.com/microsoft/WSL/pull/41690),
[PR #40426](https://github.com/microsoft/WSL/pull/40426),
[#5518](https://github.com/microsoft/WSL/issues/5518),
[#40618](https://github.com/microsoft/WSL/issues/40618) ·
[VA-API in WSL devblog](https://devblogs.microsoft.com/commandline/d3d12-gpu-video-acceleration-in-the-windows-subsystem-for-linux-now-available/) ·
[virtiofs/swiotlb article](https://www.boxofcables.dev/wsl2-per-device-swiotlb-pools-for-virtiofs-and-virtioproxy/) ·
[openvmm#4274](https://github.com/microsoft/openvmm/issues/4274) ·
[WSL-3 denial](https://x.com/craigaloewen/status/2069420597487055276)

**Other desktops:**
[sway-wsl2](https://github.com/jordankoehn/sway-wsl2) ·
[tdcosta100 GNOME gist](https://gist.github.com/tdcosta100/7def60bccc8ae32cf9cacb41064b1c0f) ·
[tdcosta100 Xwayland gist](https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912) ·
[niri#2307](https://github.com/niri-wm/niri/issues/2307),
[#2415](https://github.com/niri-wm/niri/issues/2415),
[#2944](https://github.com/niri-wm/niri/issues/2944) ·
[niri kiosk gist](https://gist.github.com/mle98/2deb6e0aa1da3aed70a73dad9c29e8f7) ·
[Cookiekira/niri#1](https://github.com/Cookiekira/niri/issues/1) ·
[Azure Linux Desktop PoC](https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/) ·
[X410 WSL2 VSOCK](https://x410.dev/cookbook/wsl/using-x410-with-wsl2/) ·
[X410 Hyper-V VSOCK](https://x410.dev/cookbook/hyperv/quick-testing-hyper-v-vsock-support-in-x410/) ·
[KDAB](https://www.kdab.com/wayland-on-windows/) ·
[Win-wayland/ntKDE](https://github.com/jace479/Win-wayland) ·
[xrdp H.264 wiki](https://github.com/neutrinolabs/xrdp/wiki/H.264-encoding) ·
[Virtualization Review WSLg](https://virtualizationreview.com/articles/2022/07/01/wslg-deeper-dive.aspx)

**Streaming:**
[hypr-rdp](https://github.com/MuNeNiCK/hypr-rdp) ·
[munenick blog](https://www.munenick.me/en/blog/hyprland-rdp/) ·
[lamco-rdp-server](https://github.com/lamco-admin/lamco-rdp-server) / [Hyper-V fork](https://github.com/moerketh/lamco-rdp-server) ·
[wayvnc](https://github.com/any1/wayvnc) (FAQ, [disc. #287](https://github.com/any1/wayvnc/discussions/287)) ·
[Sunshine config docs](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html) ·
[Sunshine#5384](https://github.com/LizardByte/Sunshine/issues/5384) ·
[moonlight-qt#527](https://github.com/moonlight-stream/moonlight-qt/issues/527) ·
[Moonlight latency write-up](https://note.com/cute_agapan9087/n/n5e400bb52235?hl=en) ·
[Parsec compatibility](https://support.parsec.app/hc/en-us/articles/32381568346644-Hardware-and-Software-Compatibility) ·
[Looking Glass](https://github.com/gnif/LookingGlass) ·
[g-r-d!294](https://gitlab.gnome.org/GNOME/gnome-remote-desktop/-/merge_requests/294) ·
[KRdp 6.8](https://www.phoronix.com/news/KDE-Plasma-6.8-KRDP-Lower-Lat) ·
[Weston 13](https://www.collabora.com/news-and-blog/news-and-events/weston-13-release-backends-consolidation.html) ·
[Mesa D3D12 AV1](https://www.phoronix.com/news/Microsoft-D3D12-AV1-Mesa)

**Keyboard:**
[KeyboardHookMode](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientsecuredsettings-keyboardhookmode) ·
[LowLevelKeyboardProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc) ·
[PowerToys Keyboard Manager](https://learn.microsoft.com/en-us/windows/powertoys/keyboard-manager) ·
[PowerToys#33364](https://github.com/microsoft/PowerToys/issues/33364) ·
[SDL2 WIN_KeyboardHookProc](https://github.com/libsdl-org/SDL/blob/SDL2/src/video/windows/SDL_windowsevents.c) ·
[TigerVNC vncviewer](https://tigervnc.org/doc/vncviewer.html) ·
[tigervnc#1899](https://github.com/TigerVNC/tigervnc/issues/1899) ·
[Hyper-V key combinations](https://learn.microsoft.com/en-us/archive/blogs/virtual_pc_guy/virtual-machine-connection-key-combinations-with-hyper-v) ·
[AHK WSLg Super thread](https://www.autohotkey.com/boards/viewtopic.php?t=124784) ·
[Parsec app (Immersive mode)](https://support.parsec.app/hc/en-us/articles/32381199341716-Parsec-App-for-Windows) ·
[Disable Win+L Q&A](https://learn.microsoft.com/en-us/answers/questions/1306201/i-want-to-disable-windows-l-key-on-windows10-ltsc)

*Local shallow clones used for verification: `upstream/sharpninja_omarchy-wslg`,
`upstream/clarenceb_omarchy-wsl2`, `upstream/taufderl_omarchy-wsl`. Pre-existing clones also used:
`wslg`, `weston-mirror`, `aquamarine`, `Hyprland`, `mesa-sparse`, `WSL2-Linux-Kernel-sparse`,
`omarchy`.*
