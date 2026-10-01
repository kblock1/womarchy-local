# womarchy — Feasibility Study

**Goal.** Run [Omarchy](https://omarchy.org) (Arch Linux + Hyprland) inside WSL2 on Windows 11 with GPU-accelerated graphics. The user types `omarchy` at a Windows prompt and lands in the full-screen Omarchy desktop. When they log out, they are back at the Windows prompt.

**Date:** 2026-09-30. **Status:** feasibility complete; see [PLAN.md](PLAN.md) for the plan.

**Evidence base:**
- four deep-dive research reports ([docs/research/](research/));
- hands-on experiments on a reference machine, in an isolated lab distro ([lab/](../lab/));
- source reading of WSL, WSLg, Weston, the WSL kernel, Mesa, aquamarine, Hyprland and Omarchy (shallow clones in `upstream/`).

---

## 1. Verdict

**Feasible, with moderate engineering, and without Microsoft's help, a custom kernel, or any global WSL setting.** No existing project delivers it. It needs three pieces of new work:

1. **A GPU-composited, DRM-free Hyprland.** This is a small, generic patch set to aquamarine and Hyprland, about 500–800 lines of code in the core. Hyprland renders with OpenGL ES on the host GPU through Mesa's `d3d12` driver. It reads the finished frame back to memory instead of scanning out through DRM/KMS.
2. **A Windows-native full-screen viewer and launcher (`omarchy.exe`).** It:
   - shows Hyprland's outputs as borderless full-screen windows, one per monitor;
   - owns the keyboard with a low-level hook so the Super/Win key works;
   - bridges clipboard, DPI and cursor;
   - ties the desktop session to the process, so logging out returns you to the prompt.

   Frames and input travel over hvsocket, with a zero-copy shared-memory path as an optimisation.
3. **An Omarchy WSL overlay.** Real upstream Omarchy 4 packages, plus a small compat package, a filtered system-apply runner, WSL replacement steps, and user-level overrides, shipped as a `.wsl` image. This needs **no fork of Omarchy**.

We verified the critical unknowns on real hardware:

- **Hyprland 0.56.2 runs its full GL renderer on the RTX 5070 through D3D12 inside WSL.** That covers GLES 3.1, dmabuf-style render targets, and the blur framebuffers. A headless 1920×1080 output rendered frames, and we captured them.
- **The d3d12 readback cost fits a 60 Hz budget up to 4K.** A full 4K frame reads back in 5.4 ms (1080p: 2.0 ms). Six-pass blur composition costs 1.0 ms at 4K on the GPU, against 176 ms on the CPU renderer.
- **hvsocket carries frames and input fast enough.** WSL→Windows 1.21 GB/s and Windows→WSL 1.60 GB/s, with a 64-byte round trip of 92 µs median. That is enough for raw 1080p/1440p at 60+ Hz and for 4K with damage tracking.
- **We found and root-caused a Mesa d3d12 deadlock** that hangs Hyprland on its first text texture. A fix patch is written ([patches/mesa](../patches/mesa/)).

The largest risks:

- **Maintenance:** we carry patches on fast-moving Hyprland and aquamarine, whose upstream is hostile to WSL-specific code.
- **Per-app GPU paths:** Chromium/Electron under a compositor with no dmabuf still needs validation.
- **Windows shortcuts:** Win+L and Ctrl+Alt+Del cannot be captured on Windows; they are rebound.

---

## 2. What makes this hard (ground truth)

### 2.1 The graphics stack WSL actually gives you

```
 Linux app (GL/Vulkan) ── Mesa d3d12 (GL 4.6 / GLES 3.1) / dzn (Vulkan 1.2, non-conformant)
                              │  (software-winsys driver: no DRM fd, no GBM, no dmabuf)
                              ▼
                        /dev/dxg (dxgkrnl, GPU-PV)  ──VMBus──►  Windows WDDM driver + GPU
```

- **There is no `/dev/dri`.** There is no DRM/KMS, no GBM device, no dmabuf, no display and no scanout. The GPU is reachable only as a paravirtualised D3D12 device.
- **How Mesa reaches it.** Mesa's `d3d12` Gallium driver renders on the real GPU and presents by reading frames back into CPU memory. Wayland clients present with `wl_shm`.
  - On Arch, d3d12 is **not auto-selected**: out of the box `glxinfo` reports `llvmpipe`.
  - `GALLIUM_DRIVER=d3d12` gives `D3D12 (NVIDIA GeForce RTX 5070)`, *Accelerated: yes* (verified).
  - Vulkan works through **Dozen** (`vulkaninfo`: Vulkan 1.2, `conformanceVersion 0.0.0.0`).
- **WSLg** is Microsoft's Weston 9 fork: an RDP backend with the RAIL shell, a pixman (CPU) renderer, one Windows window per Linux toplevel.
  - It advertises **only `wl_shm`**, with no `zwp_linux_dmabuf_v1`, and `xdg_wm_base` **v1** (verified with `wayland-info`).
  - It does not forward the Win key ([wslg#672](https://github.com/microsoft/wslg/issues/672), open since 2022).
- **DRM is being removed from the WSL kernel.**
  - The kernel on the reference machine (6.18.33.2, WSL 2.7.10) still has `CONFIG_DRM=y` and `CONFIG_DRM_VGEM=m`, but not VKMS or UDMABUF.
  - The WSL 6.18.40.1 kernel (**WSL 2.9.x / 3.0.1, released 2026-09-29**) has `# CONFIG_DRM is not set`. That is commit [`7e83488bd5`](https://github.com/microsoft/WSL2-Linux-Kernel/commit/7e83488bd5), which we verified in the kernel source.
  - **Any design that needs a DRM node (vgem, vkms) therefore needs a custom kernel on current WSL.** A custom kernel is a global change that affects every distro.

### 2.2 Why stock Hyprland cannot run on it

We reproduced every step of this on the lab distro.

1. **Nested in WSLg:** aquamarine fails with *"Wayland backend cannot start: Missing protocols"*. It requires `zwp_linux_dmabuf_v1` and binds `xdg_wm_base` v6 against WSLg's v1.
2. **Headless or DRM:** aquamarine fails with *"Cannot open backend: no allocator available"*. Its only allocator is GBM on a DRM fd, and the headless backend has none. Hyprland then aborts with `CBackend::create() failed!`.
3. **Even with an allocator,** Hyprland picks its EGL device from a DRM fd, and it asserts ("Couldn't open a gbm fd") when there is none. It also renders every output frame into an `EGLImage` imported from a dmabuf.

Hyprland's maintainers have declined WSL support ([Hyprland#3479](https://github.com/hyprwm/Hyprland/issues/3479), [discussion #4333](https://github.com/hyprwm/Hyprland/discussions/4333)).

### 2.3 What exists already (prior art)

| Project | What it achieves | Why it isn't the answer |
|---|---|---|
| [craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) (WSL PM) | Omarchy CLI/TUI in WSL | No desktop |
| [taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl) | Real Omarchy packages, filtered install | No Hyprland session |
| [clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2) | sway desktop on the CPU; best failure write-up | Not Hyprland; no GPU |
| [sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg) | Unmodified Hyprland nested in WSLg through a dmabuf→shm bridge | **Custom kernel** (VKMS), **CPU** rendering (llvmpipe), Win key unsolved, unverified |
| [noahkelly2024/wslg-gpu-direct](https://github.com/noahkelly2024/wslg-gpu-direct) | Zero-copy GPU presentation to Windows | Replaces the kernel, `wslservice.exe`, the WSLg VHD, Mesa and the msrdc plugin; not shippable |
| [omacom/try-omarchy-windows](https://github.com/omacom/try-omarchy-windows) (official) | Omarchy in a QEMU VM | Not WSL |

**Nobody has shown GPU-composited Hyprland in WSL.** This study's lab is, to our knowledge, the first run of Hyprland's renderer on D3D12.

---

## 3. Experiments and results (reference machine)

**Reference machine:**
- Windows 11 Pro 26200, WSL 2.7.10 (kernel 6.18.33.2, WSLg 1.0.73);
- Intel Core Ultra 7 265F (20 cores), 64 GB RAM;
- NVIDIA RTX 5070 (driver 32.0.16.1060);
- 3 × 3840×2160 monitors.

All experiments ran in a separate lab distro, `womarchy-lab` (official Arch WSL image, Mesa 26.2.3, Hyprland 0.56.2, aquamarine 0.15.1). Scripts are in [`lab/`](../lab/).

| # | Experiment | Result |
|---|---|---|
| E0 | Arch GL/Vulkan stack | llvmpipe by default. **`GALLIUM_DRIVER=d3d12` gives D3D12 (RTX 5070), accelerated, GL 4.6 / GLES 3.1.** Vulkan: Dozen 1.2 on the RTX 5070. VA-API d3d12 did not initialise on the X11 display (to revisit). |
| E1 | WSLg globals (`wayland-info`) | `wl_shm` only (no dmabuf), `xdg_wm_base` v1, `wl_compositor` v4, `wl_seat` v7, pointer-constraints and relative-pointer present |
| E2 | Stock Hyprland nested in WSLg | Fails: *Missing protocols*, then *no allocator available* (as §2.2) |
| E3 | GBM on a vgem node (`eglinfo -p gbm`) | `kms_swrast` with `GALLIUM_DRIVER=d3d12` → **D3D12 renderer**; the default is llvmpipe. `gbm_bo_create` succeeds only for `RENDERING`/implicit modifiers; `SCANOUT`, `LINEAR` and explicit modifiers fail. EGL import of the BO works. The fds are most likely dxgkrnl shared-handle fds, not true dmabufs (see [research note](research/README.md#corrections-from-lab-verification)). |
| E4 | Hyprland headless on vgem, with 3 small aquamarine patches ([patches/aquamarine](../patches/aquamarine/)) | **Hyprland 0.56.2 renders with "OpenGL ES 3.1, Renderer: D3D12 (NVIDIA GeForce RTX 5070)".** The GBM allocator, a headless output at 1920×1080@60, blur and work framebuffers were created, and a frame was captured through screencopy (`grim`) ([lab/out/headless-d3d12.png](../lab/out/headless-d3d12.png)). No explicit sync (no `EGL_ANDROID_native_fence_sync`), so Hyprland uses implicit sync. |
| E5 | Hyprland hang on the next runs | **A Mesa d3d12 self-deadlock**, symbolised with Arch debuginfod: `pb_slab_manager_create_buffer` (holds the slab mutex) → `d3d12_bo_new` → `d3d12_screen_reclaim_completed` → `pb_slab_buffer_destroy` → the same mutex. It is still present in Mesa main (26.3-devel). Fix: [patches/mesa/0001](../patches/mesa/0001-d3d12-reclaim-outside-pb-manager-locks.patch). Validation of the fix is pending (Phase 0). |
| E6 | **d3d12 readback/upload benchmark, no DRM node at all** (EGL surfaceless) | See table below |
| E7 | **hvsocket benchmark, WSL ↔ a non-elevated Windows process** (Python, stock config) | **WSL→Windows 1.21 GB/s** (146 full 1080p frames/s, 37 full 4K frames/s). **Windows→WSL 1.60 GB/s.** **64-byte round trip: 92 µs median, 240 µs p99.** |
| E8 | systemd user session | Fails on 2.7.10 when another systemd distro with a uid-1000 user is running. All WSL ≤ 2.7 distros share one cgroup namespace, so both systemds manage `/user.slice/user-1000.slice` → `EBUSY`. WSL ≥ 2.9 adds `isolateDistroCgroup` (on by default). |

E6 results, `GALLIUM_DRIVER=d3d12`, RTX 5070, OpenGL ES 3.1:

| Operation | 1920×1080 | 2560×1440 | 3840×2160 |
|---|---|---|---|
| Full-frame GPU→CPU readback, sync `glReadPixels` | **2.0 ms** (4.1 GB/s) | **3.5 ms** | **5.4 ms** (6.1 GB/s) |
| Readback, async PBO + map + memcpy | 8.5 ms | 12.5 ms | 25.8 ms (slower on d3d12; don't use as-is) |
| Damage-sized readback (400×300) | 0.7 ms | 0.7 ms | 0.8 ms (≈0.6 ms fixed sync cost) |
| Client `wl_shm` → texture upload (`glTexSubImage2D`) | 1.3 ms | 1.8 ms | 4.4 ms |
| 6-pass blur composition (GPU) | <1 ms (warm) | 0.5 ms | 1.0 ms |
| Same composition on llvmpipe (CPU) | 49 ms | 82 ms | **176 ms** |

**What these numbers mean:**
- **Worst case, 4K at 60 Hz** (a full-screen animated frame whose content also changes entirely): about 1 ms composition, 5.4 ms readback, and a client upload of up to 4.4 ms. That is about 11 ms of a 16.7 ms frame. Typical desktop damage costs a small fraction of that.
- **CPU composition (llvmpipe) is 10–40× too slow** for Omarchy's effects at 4K. So the "CPU Hyprland on vgem/vkms" route that the prior art takes is ruled out as the product.

---

## 4. Architecture options evaluated

| | Option | GPU compositing | Win key | Needs custom kernel / global config | Copies per frame | Verdict |
|---|---|---|---|---|---|---|
| A0 | Stock Hyprland nested in WSLg | — | — | — | — | **Impossible** (E2) |
| A1 | sharpninja bridge + VKMS + llvmpipe | ✗ CPU | ✗ | **Yes** | 3 | Demo only |
| A2 | Patched aquamarine Wayland backend (wl_shm, version clamp) nested in WSLg | ✓ | ✗ (RAIL) | No | 3 (+WSLg CPU copy) | **Development milestone** (reuses ~70% of the final work) |
| B1 | Headless Hyprland + [hypr-rdp](https://github.com/MuNeNiCK/hypr-rdp) (H.264) + mstsc full-screen | ✓ (with our patches) | ✓ | No | 2 + encode | **Secondary / remote mode** |
| B2/B3 | wayvnc + TigerVNC / Sunshine + Moonlight | — | ✓ | vgem (Sunshine) | 2 + encode | Poor fit (30 FPS default; Sunshine needs dmabuf/GBM) |
| **C** | **DRM-free GPU Hyprland + aquamarine "wsl" backend + native Windows viewer** | **✓** | **✓ (own LL hook)** | **No** | **2 (readback → shared memory/socket → D3D upload)** | **Target architecture** |
| D | vgem + d3d12 GBM (our E4 path) | ✓ | depends | **Yes on WSL ≥ 2.9** | 2 | Useful lab path; not shippable (DRM removed from the kernel) |
| E1 | WSLg desktop mode (`WSL2_WESTON_SHELL_DESKTOP`) | CPU re-encode | mstsc full-screen | **Global `.wslgconfig`** | 3 + encode | Rejected (single monitor, global, slow) |
| E2 | Omarchy in a Hyper-V VM | llvmpipe | ✓ | n/a | — | Not WSL |

### Why C

C is the only option that delivers all of these together:

- GPU composition, with no video codec in the path;
- the fewest copies: one unavoidable GPU readback, plus one host upload;
- a latency of 1–2 frames (estimated 15–40 ms input-to-photon);
- full Win-key capture;
- one window per monitor with per-monitor DPI;
- event-driven clipboard in both directions;
- an exact "prompt → desktop → prompt" lifecycle.

It needs **nothing global**: no custom kernel, no `.wslconfig`, no `.wslgconfig`, and no replacement WSLg. So it coexists with the user's other distros. It also works on current and future WSL kernels, which have no DRM.

---

## 5. Limitations and how each is resolved

| # | Limitation | Severity | Resolution |
|---|---|---|---|
| L1 | No DRM/GBM/dmabuf; the WSL kernel is dropping DRM | Blocker | **DRM-free rendering mode:** memfd/shm allocator in aquamarine; Hyprland EGL on the surfaceless/software device (→ d3d12); render into GL framebuffers with damage-limited readback. About 500–800 LOC; generic, not WSL-specific. |
| L2 | Hyprland can't nest in WSLg (dmabuf required, xdg v6 bind) | Blocker for A2 only | Bind-version clamp plus `wl_shm` output buffers in the Wayland backend (~150 LOC). Only needed for the A2 development milestone. |
| L3 | WSLg shows one Windows window per Linux window and doesn't pass Win | UX blocker | Bypass WSLg for display: our viewer (C). |
| L4 | GPU→CPU readback per frame | Performance | Measured 2.0 ms (1080p) / 5.4 ms (4K). Read back only damaged rectangles; read directly into the shared-memory transfer buffer; async/double-buffered pipeline so readback overlaps the next frame. |
| L5 | Client apps also read back (d3d12 presents through `wl_shm`) | Performance | Same as under WSLg today; the upload into Hyprland is measured at 4.4 ms for a full 4K frame. Future: zero-copy d3d12 shared handles between clients and Hyprland (research item). |
| L6 | Mesa d3d12 deadlock (E5) | Blocker | Patch written; ship patched Mesa in the womarchy repo until an upstream merge request lands. |
| L7 | d3d12 is not auto-selected on Arch (llvmpipe default) | Correctness | Set `GALLIUM_DRIVER=d3d12` session-wide (optionally `MESA_D3D12_DEFAULT_ADAPTER_NAME`). |
| L8 | GLES tops out at 3.1 on d3d12; no native fence fds | Minor | Hyprland already falls back to 3.0 and implicit sync (verified in E4). |
| L9 | Vulkan is Dozen 1.2, non-conformant | Minor | Default GTK4 to its GL renderer (`GSK_RENDERER=ngl`); Vulkan apps are best effort. |
| L10 | Win+L and Ctrl+Alt+Del cannot be intercepted on Windows | UX | Omarchy overlay rebinds Super+L (layout toggle) and Ctrl+Alt+Del (close all). All other Super chords are captured by the viewer's `WH_KEYBOARD_LL` hook while it has focus. Game Bar (Win+G) should be disabled by the user, or Omarchy's group binding moved. |
| L11 | hvsocket bandwidth (~1.2–2 GB/s) is below raw 4K60 (2 GB/s per monitor) | Performance at 4K | Damage tracking (most frames are small); fast lossless compression (LZ4/QOI) for full-screen bursts; **shared-memory frame ring over WSLg's section-backed virtio-fs DAX share** (Phase 0 spike); H.264/HEVC 4:4:4 via NVENC or d3d12 VA-API as a last resort. |
| L12 | Omarchy assumes bare metal: Limine, snapper/btrfs, SDDM, Plymouth, NetworkManager, Bluetooth, power | Install blocker | Overlay: a `womarchy-compat` package `provides` limine/snapper; a filtered `omarchy-apply-system`; skip hardware leaves; WSL-specific services, audio, GPU and keyboard leaves. No fork. |
| L13 | Omarchy's session comes from SDDM → `uwsm` → `start-hyprland` | Integration | `womarchy-session` runs the same `uwsm start` line from the launcher; logout (`uwsm stop`) ends `wsl.exe` → back to the prompt. |
| L14 | systemd distros share one cgroup tree on WSL ≤ 2.7 (E8) | Reliability | Require WSL ≥ 2.9 (`isolateDistroCgroup` on by default), or create the Omarchy user with a UID unlikely to clash (for example 1789) on older WSL. |
| L15 | Audio: no ALSA devices | Feature | PipeWire `pulse-tunnel` sink/source to WSLg's PulseServer (works while WSLg is enabled). Later: audio over the viewer channel (WASAPI). |
| L16 | Clipboard isolation | Feature | The viewer syncs the Windows clipboard ↔ Hyprland through `ext-data-control`/`wlr-data-control`. |
| L17 | Hardware video decode (VA-API's DRM path is gone without vgem) | Performance | VA-API through the X11 display type (to verify); NVDEC through CUDA on NVIDIA (`libnvcuvid` is present in `/usr/lib/wsl/lib`); software decode fallback. |
| L18 | Chromium/Electron GPU path on a no-dmabuf compositor | Unknown | Validate in Phase 0/2. Fallbacks: ANGLE-on-GL flags, or software compositing for web apps. |
| L19 | Screen recording (gpu-screen-recorder needs DRM/KMS) | Minor | Use portal/screencopy (shm) based tools (OBS via xdg-desktop-portal-hyprland, wf-recorder). |
| L20 | Upstream won't take WSL-specific code; Hyprland moves fast | Maintenance | Keep patches generic (a DRM-free mode also helps VMs and CI); pin to the Hyprland version Omarchy ships; a CI patch-queue rebase per release; propose the generic pieces upstream via human-filed PRs (hyprwm AI policy). |
| L21 | Omarchy updates may add hardware migrations or reboot prompts | Maintenance | Use upstream `post-update` / `pre-refresh-pacman` hooks to reassert WSL invariants; pre-mark inapplicable migrations; a CI job classifies new install leaves on each Omarchy release. |
| L22 | Any process of the same Windows user can connect to hvsocket | Security | The viewer protocol authenticates with a per-session random token passed over the launcher's private pipe; the listener binds only while a session is running. |

### 5.1 Outcome after implementation (2026-09-30)

See [WORKLOG.md](WORKLOG.md) §15–24.

**Resolved as planned:**
- L1: DRM-free Hyprland + aquamarine `wsl` backend, damage-only readback.
- L3: the viewer.
- L6: Mesa patch 0001.
- L7: session env.
- L9: `GSK_RENDERER=ngl`.
- L10: keyboard hook plus the overlay's rebinds.
- L11: DAX shared memory. Zero-copy for frames; 60 FPS measured.
- L12, L15, L21: the image agent's overlay.
- L13: `womarchy-session` + uwsm, with one extra step: `wsl --exec` processes are outside logind, so the session hands uwsm WSL's own user session.
- L14: WSL 3.0.1 isolates cgroups.
- L16: text clipboard via `wl-clipboard` data-control.
- L22: per-session token on both the display and clipboard channels.

**Skipped:** L2. The work went straight to the viewer.

**Answered:**
- L17/L18: Chromium runs on Wayland with GPU rasterization, WebGL/WebGPU and hardware video decode. Its compositing is software-only because there's no dmabuf. Browsing is smooth on the reference machine.
- L19: screenshots and screen capture work over shm, after fixing a Hyprland null-dmabuf crash.

**New findings the study didn't predict, all resolved:**
- WSL 3.0.1 made CPU writes to D3D12 UPLOAD heaps about 700× slower. Mesa patch 0002 uses write-back heaps.
- WSLg's DAX share rejects file sizes that aren't whole pages. aquamarine rounds up.
- WSL mounts WSLg's `/tmp/.X11-unix` read-only, so Xwayland couldn't start. A private writable socket directory fixes it.
- WSL runs an image's OOBE only for interactive shells. `omarchy.exe` runs setup itself.
- Hyprland snaps scales to whole logical pixels. The monitor-rule generator does the same.

**Not resolvable within WSL** (documented, accepted):
- true zero-copy GPU presentation to Windows (it needs Microsoft's VAIL host registration);
- capturing Win+L and Ctrl+Alt+Del;
- kernel, bootloader and firmware management (WSL owns them);
- suspend/hibernate (Windows owns them).

---

## 6. Hardware and software requirements

### Minimum

- Windows 11 22H2+ x64 (Windows 10 21H2+ may work but is untested). CPU virtualization enabled (VT-x/AMD-V, SLAT); "Virtual Machine Platform" enabled.
- **WSL ≥ 2.9** (3.0.1 recommended): per-distro cgroup isolation; kernel without DRM (supported). WSL 2.7.x works with the UID caveat (L14).
- A GPU with a WDDM 2.9+/3.x driver that supports WSL GPU paravirtualization (D3D12 feature level 11_0+, Shader Model 6.x):
  - NVIDIA GTX 900-series or newer on driver R510+;
  - AMD RDNA or newer, Adrenalin 22.x+;
  - Intel Gen9+ (Iris Xe/Arc recommended).
- 4 CPU cores, **16 GB RAM** (WSL gets 50% by default), 25 GB free SSD space.

### Recommended

- **A discrete GPU.** Readback speed is the limiting factor, and there are reports of very slow d3d12 readback on some Intel UHD iGPUs ([wslg#1498](https://github.com/microsoft/wslg/issues/1498)). We will measure iGPUs in the test matrix.
- 8+ cores with AVX2, **32 GB RAM**, NVMe SSD.

### Display scaling guidance

These are estimates from the measured costs, for full-screen motion. Desktop use with typical damage is much lighter.

| Setup | Expected |
|---|---|
| 1 × 1080p/1440p @ 60–144 Hz | Comfortable |
| 1 × 4K @ 60 Hz | Comfortable for desktop; full-screen video at 60 fps OK with the shared-memory path |
| 2–3 × 4K @ 60 Hz (the reference machine) | Desktop use OK; simultaneous full-screen motion on all 3 needs the shared-memory path and may drop below 60 fps |

### Software pinned by the plan

- Omarchy 4.0.x stable (package-based);
- Hyprland 0.56.x / aquamarine 0.15.x (whatever Omarchy ships);
- Mesa ≥ 26.2 with the d3d12 fix;
- the official Arch WSL image as the base.

---

## 7. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Hyprland/aquamarine internals churn and break the patch queue | High | Medium | Minimal, well-isolated patches; pinned versions; CI rebuild on each Omarchy release; upstream the generic parts |
| Chromium/Electron/Qt Quick misbehave without dmabuf | Medium | High (default apps) | Early compatibility matrix (Phase 0); per-app env/flags; software fallback for specific apps |
| d3d12 driver bugs beyond E5 (for example shader translation) | Medium | Medium | Upstream MRs; D3D12 debug-layer runs; llvmpipe fallback toggle |
| Slow readback on iGPUs | Medium | Medium | Measure; damage-only readback; lower refresh or scale on iGPU |
| The WSLg DAX share can't be used from a user distro | Medium | Low | hvsocket plus compression covers 1080p–1440p and damage-light 4K |
| A Microsoft change breaks hvsocket access or WSLg shared memory | Low | High | Keep the transport pluggable (hvsocket / DAX / localhost TCP) |
| Omarchy migration breaks a WSL invariant | Medium | Medium | Hooks plus CI migration audit |
| Upstream Omarchy/DHH disinterest in WSL | High | Low | Overlay design needs nothing upstream |

---

## 8. Conclusion

The goal is achievable on stock Windows and WSL.

- **Proven by experiment:** the hard technical question, whether Hyprland can composite on the GPU inside WSL, is answered yes. Hyprland's renderer runs on D3D12 as-is once it has a render target and an allocator. The readback costs fit a 60 Hz budget at 4K.
- **Engineering, not research:** the remaining work is (1) a DRM-free render-target/allocator mode, (2) a Windows viewer and transport, and (3) an Omarchy overlay.
- **Estimate:** about **16–22 engineer-weeks** to a polished 1.0 (see [PLAN.md](PLAN.md)). A GPU-composited desktop visible on screen is expected by about week 5.
