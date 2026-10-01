# 03 — WSL / WSLg / Mesa-on-WSL / dxgkrnl: platform research for womarchy

*Research date: 2026-09-30. Scope: the Windows/WSL platform side of running Omarchy (Arch + Hyprland) inside WSL2 with GPU-accelerated graphics, fullscreen, Super key, and clean exit back to the Windows prompt. Source-level research only; no commands were run inside WSL and no WSL configuration was changed.*

Local source checkouts used (all shallow / sparse, under `<repo>\upstream\`):

| Checkout | Upstream | Commit / ref |
|---|---|---|
| `wslg` | https://github.com/microsoft/wslg | `6942bb5` (2026-06-24) |
| `weston-mirror` | https://github.com/microsoft/weston-mirror (branch `working`) | `7fbf693` (2026-09-10), Weston **9.0.0** base |
| `FreeRDP-mirror` (sparse) | https://github.com/microsoft/FreeRDP-mirror (branch `working`) | `f31f15e` |
| `WSL` | https://github.com/microsoft/WSL | `b87456d` (2026-09-29, post-3.0.1) |
| `WSL2-Linux-Kernel-sparse` | https://github.com/microsoft/WSL2-Linux-Kernel | `1479418` = tag `linux-msft-wsl-6.18.40.1` |
| `mesa-sparse` | https://gitlab.freedesktop.org/mesa/mesa | `cec59b2` (2026-09-30, 26.3.0-devel) |
| `archlinux-wsl` | https://gitlab.archlinux.org/archlinux/archlinux-wsl | `27c3224` (2026-09-25) |
| `arch-pkg-mesa` | https://gitlab.archlinux.org/archlinux/packaging/packages/mesa | `79d24f7` (mesa 1:26.2.3-2) |
| `arch-pkg-directx-headers` | https://gitlab.archlinux.org/archlinux/packaging/packages/directx-headers | directx-headers 1.619.5 |

Line references below are to those commits (paths relative to `upstream/`).

---

## 0. Executive summary

1. **WSLg is a CPU-memory compositor.** The Weston 9 fork uses the **pixman renderer only** (`weston-mirror/libweston/backend-rdp/rdp.c:2237`), never calls `linux_dmabuf_setup()` (no `zwp_linux_dmabuf_v1`, no `wl_drm`), and presents each RAIL window by **CPU-copying the surface into a host-backed shared-memory section** exposed through a virtio-fs **DAX** share (`/mnt/shared_memory`), then sending a metadata-only `GFXREDIR PresentBuffer` PDU to `msrdc.exe` over an hvsocket RDP connection. Microsoft's own README states vGPU interop is "through system memory" with up to 50% overhead at very high frame rates (`wslg/README.md:173`). Nothing in WSLg 1.0.73–1.0.79 or weston-mirror 2024–2026 changes that.
2. **Copy count, GPU (d3d12) Wayland client → Windows screen:** VRAM→readback (GPU DMA) + CPU copy into Mesa displaytarget + CPU copy into `wl_shm` + CPU copy into the DAX section (Weston) + CPU→GPU upload in msrdc + DWM composition. That is ~3 CPU full-damage copies, 1 readback, 1 upload. For a CPU-rendered `wl_shm` client it is 1 CPU copy (Weston) + 1 upload.
3. **No dma-buf / DRM on stock WSL.** `/dev/dxg` (dxgkrnl) is the only GPU device. dxgkrnl shared resources are anonymous-inode fds (`"dxgresource"`), **not dma-bufs** (no mmap, no PRIME). The shipping kernel on the target (6.18.33.2) has `CONFIG_DRM=y`, `DRM_VGEM=m`, no VKMS/UDMABUF — **but the kernel that ships with WSL 3.0.1 / 2.9.x (6.18.40.1) disables `CONFIG_DRM` entirely** (commit `7e83488bd5`, 2026-07-27). Any design that depends on `vgem` or any `/dev/dri` node needs either the 2.7.x WSL line or a custom kernel (which applies to every distro).
4. **GPU sharing that does exist:** D3D12 shared handles inside the VM (Mesa d3d12 `WINSYS_HANDLE_TYPE_FD` and dzn `VK_KHR_external_memory_fd` both map to dxgkrnl share fds) and dxgkrnl sync objects ↔ Linux `sync_file`. Guest→host GPU sharing exists in the kernel UAPI (`LX_DXSHAREOBJECTWITHHOST`, returns an NT handle in the host "VAIL process"), but stock WSLg does not use it and making a Windows process the VAIL host requires `D3DKMTRegisterVailProcess` plus a token only WSL's service can mint. A third-party proof-of-concept ([noahkelly2024/wslg-gpu-direct](https://github.com/noahkelly2024/wslg-gpu-direct), Aug 2026) achieved zero-copy only by replacing the kernel, **`wslservice.exe`**, the system distro, Mesa and the msrdc plugin. That route cannot ship as a distro.
5. **Best transports from a user distro to a Windows process:** (a) the **WSLg virtio-fs DAX share** (tag `wslg`, 8 GB window, **section-backed**: every file becomes a named section `\Sessions\<n>\BaseNamedObjects\WSL\<VMID>\wslg\<name>` that any process of the logged-on user can `OpenFileMapping`). This gives true shared memory with zero extra copies. (b) **AF_VSOCK ↔ AF_HYPERV (hvsocket)** for control/input or compressed video. The VM's hvsocket bind/connect security descriptor grants the interactive user full access. (c) RDP to the stock `msrdc.exe` (what WSLg does). (d) localhost TCP.
6. **Knobs:** `%USERPROFILE%\.wslgconfig` `[system-distro-env]` (all `WESTON_RDP_*`, `WESTON_RDPRAIL_SHELL_*`, `WSL2_WESTON_SHELL_DESKTOP=true` for a single-window "desktop mode", log/debug vars). `.wslconfig` `[wsl2] systemDistro=` (private WSLg VHD), `guiApplications=false`, `kernel=`, `kernelModules=`, `loadKernelModules=`. Per-distro `/etc/wsl.conf` `[general] guiApplications=false`. All VM-level settings are **global to the Windows user's WSL VM**.
7. **Hard limitations of WSLg for a full desktop:** RAIL is one Windows window per toplevel. Desktop mode is **single-monitor** and uses RemoteFX/NSCodec encode over the socket instead of shared memory. Win/Super goes to Windows by default ([wslg#672](https://github.com/microsoft/wslg/issues/672), open). `xdg_wm_base` is v1. HiDPI uses integer scale unless enabled otherwise. Frame pacing is 60 Hz by default (max about 144).
8. **Packaging:** a `.wsl` file is a tar (gzip recommended, xz accepted) of the rootfs with `/etc/wsl-distribution.conf` (OOBE, default UID/name, `.ico`, Windows Terminal template) and `/etc/wsl.conf` (systemd, default user, per-distro GUI opt-out). Install it by double-click or `wsl --install --from-file X.wsl [--name N] [--location D] [--no-launch] [--vhd-size S]`. The Start-menu shortcut and WT profile always run `wsl.exe --distribution-id <GUID>`, so their command line cannot be customised. A desktop launcher must be separate. `wsl.exe -d X -- cmd` returns the Linux exit code.

---

## 1. WSLg architecture

### 1.1 Components and startup

* **System distro**: Azure Linux 3.0 container image built by `wslg/Dockerfile` (`ARG MARINER_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0`, line 4). It is converted to an ext4 `system.vhd` with `tar2ext4` (`wslg/CONTRIBUTING.md` "Build instructions") and shipped as `C:\Program Files\WSL\system.vhd` (374 MB on the target). It is mounted **read-only**, and one instance runs per running user distro, in its own mount/PID/UTS namespace with a **shared IPC namespace** (`wslg/README.md` "WSLg System Distro"; `WSL/src/linux/init/main.cpp:2370` `CLONE(CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWUTS)`).
* **Mesa in the system distro** is built with `-Dgallium-drivers=swrast,d3d12 -Dvulkan-drivers=` (`wslg/Dockerfile:240-244`). **Weston** is built with `-Dbackend-default=rdp -Dwslgd=true -Dshell-fullscreen=false ...` (`wslg/Dockerfile:296-321`). **FreeRDP 2** is built server-only with `WITH_CHANNEL_GFXREDIR=ON`, `WITH_CHANNEL_RDPAPPLIST=ON`.
* **WSLGd** is launched by WSL init as the system distro's `boot.command` (`wslg/config/wsl.conf`: `[boot] command=/usr/bin/WSLGd`, `[user] default=wslg`). It is the whole orchestrator (`wslg/WSLGd/main.cpp`):
  1. Sets defaults: `XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir`, `WAYLAND_DISPLAY=wayland-0`, `DISPLAY=:0`, `PULSE_SERVER=/mnt/wslg/PulseServer`, cursor theme, and so on (`main.cpp:227-248`).
  2. `SetupOptionalEnv()` reads `%USERPROFILE%\.wslgconfig` (via `WSL2_USER_PROFILE`, fallback `C:\ProgramData\Microsoft\WSL\.wslgconfig`) and `setenv(..., overwrite=true)` every key in `[system-distro-env]` (`main.cpp:153-185`).
  3. Gets the VM ID via `wslinfo --vm-id -n` (`main.cpp:137-151, 274-279`).
  4. Mounts the shared-memory share: `mount("wslg", "/mnt/shared_memory", "virtiofs", 0, "dax")` if `WSL2_SHARED_MEMORY_OB_DIRECTORY` is set (`main.cpp:316-329`).
  5. Binds an **AF_VSOCK** listener on the first free port in the reserved range 1..1023 (`main.cpp:331-352`). It passes the fd to Weston as `USE_VSOCK=<fd>` and computes `WSLG_SERVICE_ID` with the hvsocket template `"%08X-FACB-11E6-BD58-64006A7986D3"` (`main.cpp:17, 84-93`).
  6. Launches `weston --backend=rdp-backend.so --modules=wslgd-notify.so --xwayland --socket=wayland-0 --shell=rdprail-shell.so|desktop-shell.so --log=/mnt/wslg/weston.log --logger-scopes=log,rdp-backend[,rdprail-shell]` with `CAP_SYS_ADMIN|CAP_SYS_CHROOT|CAP_SYS_PTRACE` (needed to `setns` into the user distro to enumerate `.desktop` files) (`main.cpp:367-448`).
  7. Waits for the `wslgd-notify` ready socket, then launches the **Windows RDP client through WSL interop**: `/init <C:\Program Files\WSL\msrdc.exe> msrdc.exe /wslg /silent /v:<VMID> /hvsocketserviceid:<GUID> /plugin:WSLDVC_PACKAGE /wslgsharedmemorypath:WSL\<VMID>\wslg C:\Program Files\WSL\wslg.rdp` (`main.cpp:458-509`). Setting `WSLG_USE_MSTSC=1` falls back to `mstsc.exe`.
  8. Starts system `dbus-daemon` and `pulseaudio` with `module-rdp-sink`, `module-rdp-source` and `module-native-protocol-unix socket=/mnt/wslg/PulseServer` (`main.cpp:511-548`).
  9. `ProcessMonitor::Run()` restarts crashed children, giving up after more than 10 crashes per minute (`WSLGd/ProcessMonitor.cpp:87-120`).
* **Windows side** (`C:\Program Files\WSL\`, verified on the target): `msrdc.exe`, `rdclientax.dll`, `rdpnanoTransport.dll`, `RdpWinStlHelper.dll`, `WSLDVCPlugin.dll`, `wslg.rdp`, `wslg_desktop.rdp`, `system.vhd`. The plugin is registered in `HKLM\SOFTWARE\Microsoft\Terminal Server Client\Default\OptionalAddIns\WSLDVC_PACKAGE` (`WSL/msipackage/package.wix.in:508-522`). WSL service also writes `HKCU\SOFTWARE\Microsoft\Terminal Server Client\LocalDevices\<VMID> = 0xC4` so msrdc allows clipboard, mic and printer without prompting (`WSL/src/windows/service/exe/WslCoreVm.cpp:46, 1893-1901`).
* Contents of the `.rdp` files on the target:
  * `wslg.rdp`: `audiocapturemode:i:2`, `authentication level:i:0`, `disableconnectionsharing:i:1`, `enablecredsspsupport:i:0`, `hvsocketenabled:i:1`, `remoteapplicationmode:i:1`, `remoteapplicationprogram:s:dummy-entry`
  * `wslg_desktop.rdp`: the same without the two `remoteapplication*` lines.
  * Neither sets `keyboardhook`, `screen mode id` or `use multimon`, so RDP defaults apply.
* **User-distro side** (`WSL/src/linux/init`): a tmpfs `/mnt/wslg` is shared between the user and system distro (`main.cpp:2347-2361`). The user distro gets `/tmp/.X11-unix` bind-mounted read-only from `/mnt/wslg/.X11-unix` (`config.cpp:643-668`, plus a `/run/tmpfiles.d/x11.conf` override). Env: `XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir`, `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0`, `PULSE_SERVER=unix:/mnt/wslg/PulseServer`, `WSL2_GUI_APPS_ENABLED=1` (`config.cpp:1908-1935`). With systemd, a generator installs `wslg.service` (re-binds `/tmp/.X11-unix` after `tmp.mount`) and a **user** unit `wslg-session.service` that symlinks `wayland-0`, `wayland-0.lock` and `pulse/native` into `/run/user/<uid>` (`init.cpp:267-315, 385-400`). Sessions get `XDG_RUNTIME_DIR=/run/user/<uid>` (`init.cpp:707-726`), and WSL ≥ 2.5.1 mounts `/run/user/<uid>` as tmpfs.

### 1.2 How a frame travels (RAIL/"VAIL" mode, the default)

```
Linux client ──wl_shm (memfd in guest RAM)──► Weston 9 (pixman) in system distro
   │                                             │ weston_surface_copy_content()  ← CPU copy of damaged rect
   │                                             ▼
   │                        /mnt/shared_memory/{GUID}   (virtio-fs DAX window; file == host section)
   │                                             │ GFXREDIR OpenPool/CreateBuffer (once) + PresentBuffer (per frame, metadata only)
   │                                             ▼  over RDP DVC "Microsoft::Windows::RDS::RemoteAppGraphicsRedirection"
   │                              AF_VSOCK ⇄ hvsocket (VMID + service GUID)
   ▼                                             ▼
                                  msrdc.exe (RAIL window per toplevel) opens section
                                  "WSL\<VMID>\wslg\{GUID}", uploads/composes → DWM
```

Code evidence:
* Shared memory is enabled when `WESTON_RDP_SHARED_MEMORY` (default true) is set **and** `WSL2_SHARED_MEMORY_MOUNT_POINT` is set **and** FreeRDP exports `gfxredir_server_context_new` (`weston-mirror/libweston/backend-rdp/rdprail.c:4909-4967`).
* Per window: `rdp_allocate_shared_memory()` creates `/mnt/shared_memory/{uuid}` with `O_CREAT|O_EXCL`, calls `fallocate`, and mmaps it `MAP_SHARED` (`rdputil.c:124-195`). Weston then sends `OpenPool{sectionName=L"{GUID}"}` and `CreateBuffer{stride,w,h,ARGB8888}` (`rdprail.c:2566-2620`).
* Per frame: `weston_surface_copy_content(surface, section_ptr+offset, ...)` copies the damaged region (`rdprail.c:2737-2760`), then `PresentBuffer{windowId, bufferId, dirtyRect, targetWidth/Height, opaqueRects}` is sent (`rdprail.c:2766-2800`). Scaling is done by the client (`rdprail.c:2542-2552`). `isUpdatePending` waits for `PresentBufferAck`, which gives back-pressure (`rdprail.c:1305-1340`).
* If shared memory is unavailable, RAIL falls back to **RDPGFX** surfaces with pixel payload in the PDU (`rdprail.c:2620-2660, 2806-2830`).
* The gfxredir protocol (`FreeRDP-mirror/include/freerdp/channels/gfxredir.h`) has only `OPEN_POOL`, `CLOSE_POOL`, `CREATE_BUFFER`, `DESTROY_BUFFER`, `PRESENT_BUFFER`, `PRESENT_BUFFER_ACK`, with pixel formats `XRGB_8888`/`ARGB_8888`. It has **no GPU-handle PDU**.
* The WSL service creates the share as `AddSharedMemoryDevice(L"wslg", L"wslg", 8192 MB)` only when GUI apps and virtio are enabled (`WslCoreVm.cpp:42, 1879-1892`). `GuestDeviceManager::AddSharedMemoryDevice()` makes it a `VirtiofsShareKind_SectionBacked` virtio-fs device rooted at the NT object directory `\Sessions\<sid>\BaseNamedObjects\WSL\<VMID>\wslg` (`GuestDeviceManager.cpp:79-100`). **Each guest file is a named section object in the user's session namespace.**

**Copy counts per presented frame** (full-damage worst case):

| Client type | Copies |
|---|---|
| CPU-rendered Wayland (`wl_shm`) | client draw → **Weston CPU copy into section** → **msrdc upload** → DWM compose |
| GPU Wayland via Mesa d3d12 (GL/GLES/EGL) | GPU render → **GPU copy to readback + CPU `util_copy_rect` into sw displaytarget** (`mesa/src/gallium/drivers/d3d12/d3d12_screen.cpp:692-760`) → **CPU memcpy into `wl_shm`** (`src/egl/drivers/dri2/platform_wayland.c:3029-3060`) → **Weston CPU copy into section** → **msrdc upload** → DWM. About 3 CPU copies, 1 readback, 1 upload. |
| GPU Vulkan via dzn | dzn uses the software WSI on Linux (`src/microsoft/vulkan/dzn_wsi.c:91-94`, `sw_device=true`), so it follows the same readback→shm path as d3d12 GL |
| X11 GL app via Xwayland | as d3d12 GL, but `XPutImage`/MIT-SHM to Xwayland (no glamor: there is no DRM) → Xwayland `wl_shm` → Weston. Adds 1–2 more copies. |
| "Desktop mode" (`WSL2_WESTON_SHELL_DESKTOP=true`) | Weston pixman composites **all** surfaces into one shadow image (CPU) → RemoteFX/NSCodec/raw **encode** (CPU) → bytes over vsock → msrdc decode/upload (`rdp.c:263-275, 289-345`). Heaviest option. |

At 3840×2160×4 B = 33 MB per full frame, each full-screen CPU copy at 60 Hz is about 2 GB/s. Damage tracking reduces this for desktop use, but full-screen animation (Hyprland) will be close to the worst case.

### 1.3 Renderer, protocols, presentation

* **Renderer:** `pixman_renderer_init(compositor)` is unconditional (`weston-mirror/libweston/backend-rdp/rdp.c:2237`). The GL renderer is never loaded in the RDP backend. Presentation clock is software (`rdp.c:2234`, `weston_compositor_set_presentation_clock_software`).
* **dmabuf:** in weston-mirror, `linux_dmabuf_setup()` is called only by the DRM, headless, wayland and x11 backends (`libweston/backend-drm/drm.c:2985`, `backend-headless/headless.c:466`, and so on), **never by backend-rdp**. So `zwp_linux_dmabuf_v1` (and `wl_drm`) are **not advertised**. A global dump from a WSLg Weston ([clarenceb/omarchy-wsl2 docs/12](https://github.com/clarenceb/omarchy-wsl2/blob/main/docs/12-wayland-on-wsl2.md)) shows: `wl_compositor v4, wl_subcompositor, wp_viewporter, zxdg_output_manager_v1, wp_presentation, zwp_relative_pointer_manager_v1, zwp_pointer_constraints_v1, zwp_input_timestamps_manager_v1, wl_data_device_manager, wl_shm, wl_output, zwp_input_panel_v1, zwp_text_input_manager_v1, xdg_wm_base v1, zxdg_shell_v6, wl_shell, weston_rdprail_shell, weston_screenshooter, wl_seat v7, zwp_input_method_v1`.
* **Upstream Weston** (16.0.90) RDP backend now supports pixman, GL and Vulkan renderers (`gitlab.freedesktop.org/wayland/weston libweston/backend-rdp/rdp.c` `WESTON_RENDERER_GL/VULKAN`). It is still TCP/TLS only (no vsock and no RAIL/gfxredir). The Microsoft fork has not been rebased (still 9.0).
* **GPU-accelerated presentation plans:** the README still describes the "first release" system-memory interop (`wslg/README.md:173`). The only public "future plans" note is automatic frame-rate matching ([wiki: Controlling WSLg frame rate](https://github.com/microsoft/wslg/wiki/Controlling-WSLg-frame-rate)). WSLg releases 1.0.60 → 1.0.79 (2024–2026) contain only maintenance items: Azure Linux rebases, `wslinfo --vm-id`, the security hardening of shell selection in 1.0.71, and docker-buildx in the image ([releases](https://github.com/microsoft/wslg/releases), `gh api repos/microsoft/wslg/tags`). No official GPU-composition work is visible.

### 1.4 Fullscreen, multi-monitor, HiDPI

* **Fullscreen:** rdprail-shell implements `xdg_toplevel.set_fullscreen` (`rdprail-shell/shell.c:2746-2795, 2887-2895`). The backend maps it to a Windows window with `RAIL_WINDOW_FULLSCREEN_STYLE = WS_POPUP|WS_VISIBLE|...` (no caption or frame) and `showState=WINDOW_SHOW` (`rdprail.c:50-51, 2233-2271`). A fix "full screen offset to bottom right" landed in May 2026 (weston-mirror `02b7ad5f`). A Wayland client can therefore get a borderless window covering one monitor.
* **Multi-monitor:** in RAIL mode Weston mirrors the client's monitor layout (up to `RDP_MAX_MONITOR 16`, `rdp.h:67`) as separate heads/outputs (`rdp.c:1735-1790`, `rdpdisp.c`). **Non-RAIL (desktop) mode supports one monitor only**: `"WARNING: multiple monitor is not supported in non HiDef RAIL mode"` (`rdp.c:1747-1752`), and repaint uses `rdp_get_first_output()` (`rdp.c:266`). For womarchy this means one fullscreen window per monitor is possible only in RAIL mode (for example a nested compositor opening one toplevel per output and fullscreening each on a different `wl_output`).
* **HiDPI:** `disp_get_client_scale_from_monitor()` (`rdpdisp.c:45-62`). With `WESTON_RDP_HI_DPI_SCALING` (default **true**), scale is `desktopScaleFactor/100` **truncated to an integer**. Options: `..._ROUNDUP` rounds, `WESTON_RDP_FRACTIONAL_HI_DPI_SCALING` (default false) gives a fractional client scale, and `WESTON_RDP_DEBUG_DESKTOP_SCALING_FACTOR` (100–500) forces a value. The Weston output scale is always an integer (Weston 9). For a nested compositor, `WESTON_RDP_HI_DPI_SCALING=false` gives 1:1 physical pixels.
* **Refresh:** `WESTON_RDP_MONITOR_REFRESH_RATE` defaults to 60 (`include/libweston/backend-rdp.h:38`). The wiki says the effective maximum is 144.

### 1.5 Keyboard (Super key), clipboard, audio

* **Keyboard:** the RDP backend forwards every scancode it receives, with no filtering of the Windows keys. It maps scancode → VK → evdev (`rdp.c:1589-1690`). Whether Win/Super reaches Linux is decided by **msrdc's keyboard hook**. The `.rdp` files do not set `keyboardhook`, so the RDP default `2` applies (Windows key combinations go to the remote side only in full-screen *session* mode). For RAIL windows, [wslg#672 "The Windows (aka Super) Key isn't Emitted to WSLG"](https://github.com/microsoft/wslg/issues/672) (2022) is still **open**, and [WSL#7730](https://github.com/microsoft/WSL/issues/7730) was closed without a fix. One 2026 third-party project ([sharpninja/omarchy-wslg docs/usage.md](https://github.com/sharpninja/omarchy-wslg)) says "Press the Windows key and Enter in that window" for a fullscreen RAIL Hyprland window. That conflicts with the issue and **must be tested hands-on** (it may apply only to a `WS_POPUP` fullscreen RAIL window, or only to chords that Windows itself does not reserve). rdprail-shell also has `binding-modifier` (default `none`), `alt-f4-to-close-app` (default true) and `allow-zap` (`shell.c:760-790`).
* **Clipboard:** CLIPRDR ↔ Weston selection, with formats `CF_UNICODETEXT`↔`text/plain;charset=utf-8`, `CF_TEXT`↔`STRING`, `CF_DIB`↔`image/bmp`, RTF↔`text/rtf`, HTML↔`text/html` (`rdpclip.c:87-95`). Toggle with `WESTON_RDP_CLIPBOARD` (default true). This syncs only Weston's (WSLg's) selection, so a nested compositor must bridge its own clipboard to the parent `wl_data_device`.
* **Audio:** PulseAudio in the system distro with `module-rdp-sink` and `module-rdp-source` ([pulseaudio-mirror](https://github.com/microsoft/pulseaudio-mirror/tree/working/src/modules/rdp)). Weston multiplexes audio onto RDP (RDPSND/AUDIN). Toggles are `WESTON_RDP_AUDIO_PLAYBACK` and `WESTON_RDP_AUDIO_CAPTURE`. User distros reach it at `PULSE_SERVER=unix:/mnt/wslg/PulseServer`. For PipeWire (Omarchy), use `pipewire-pulse` plus `module-tunnel-sink`/`module-pulse-tunnel` to that socket, or leave `PULSE_SERVER` pointing at WSLg.

### 1.6 Every `.wslgconfig` option (source-derived)

File: `%USERPROFILE%\.wslgconfig` (Store/MSI WSL) or `C:\ProgramData\Microsoft\WSL\.wslgconfig`, section `[system-distro-env]`. Values are `true/false/1/0` or integers. Changes need `wsl --shutdown`. **The file applies to every distro's WSLg instance.**

| Variable | Default | Meaning / source |
|---|---|---|
| `WSL2_WESTON_SHELL_DESKTOP` | false | `true` runs Weston `desktop-shell` and msrdc with `wslg_desktop.rdp` (no `remoteapplicationmode`): the whole Weston desktop appears in **one msrdc window** (`WSLGd/main.cpp:39-45, 371-384, 491-496`). Single-monitor, legacy bitmap codec path (§1.2). This replaced the older free-form `WSL2_WESTON_SHELL_OVERRIDE` and `WSL2_RDP_CONFIG_OVERRIDE` in WSLg 1.0.71 ("don't allow arbitrary settings for shell", wslg commit `100914a9`, 2025-10-03). The wiki page [WSLg Configuration Options for Debugging](https://github.com/microsoft/wslg/wiki/WSLg-Configuration-Options-for-Debugging) still lists the old names. |
| `WSLG_USE_MSTSC` | false | Use `C:\Windows\System32\mstsc.exe` instead of msrdc (`main.cpp:470-481`). |
| `WSLG_USE_WSLDVC_PRIVATE` | false | Use `/plugin:WSLDVC_PRIVATE` (a privately registered plugin) (`main.cpp:483-489`). |
| `WSLG_WESTON_GDBSERVER_PORT` | — | Run Weston under gdbserver if present. |
| `WSLG_ERR_LOG_PATH`, `WSLG_WESTON_LOG_PATH`, `WSLG_PULSEAUDIO_LOG_PATH`, `WSLG_LOG_KMSG` | `/mnt/wslg/*.log` | Logging. |
| `WSLG_USE_USER_DISTRO_XFONTS` | true | Font monitor. |
| `WESTON_RDP_SHARED_MEMORY` | true | Use DAX + gfxredir. `false` sends pixels in RDPGFX PDUs. |
| `WESTON_RDP_MONITOR_REFRESH_RATE` | 60 | Repaint pacing. |
| `WESTON_RDP_HI_DPI_SCALING` / `_FRACTIONAL_HI_DPI_SCALING` / `_FRACTIONAL_HI_DPI_SCALING_ROUNDUP` / `WESTON_RDP_DEBUG_DESKTOP_SCALING_FACTOR` | true / false / false / 0 | DPI (§1.4). |
| `WESTON_RDP_CLIPBOARD`, `WESTON_RDP_AUDIO_PLAYBACK`, `WESTON_RDP_AUDIO_CAPTURE`, `WESTON_RDP_DISABLE_AUDIO_PLAYBACK_DYNAMIC_VIRTUAL_CHANNEL` | true… | I/O channels. |
| `WESTON_RDP_APPLIST` | true | Start-menu app list over rdpapplist. |
| `WESTON_RDP_WINDOW_ZORDER_SYNC`, `WESTON_RDP_WINDOW_SNAP_ARRANGE`, `WESTON_RDP_WINDOW_SHADOW_REMOTING` | true | RAIL window integration. |
| `WESTON_RDP_APPEND_DISTRONAME_TITLE` | true | Appends "(Distro)" to window titles. |
| `WESTON_RDP_COPY_WARNING_TITLE` | true (x64) | Title warning when the slow copy path is used. |
| `WESTON_RDP_PERSISTENT_RAIL_SEAT`, `WESTON_RDP_DISPLAY_POWER_BY_SCREENUPDATE` | true / false | Seat/power. |
| `WESTON_RDP_DEBUG_LEVEL`, `WESTON_RDP_DEBUG_CLIPBOARD_LEVEL`, `WESTON_RDPRAIL_SHELL_DEBUG_LEVEL`, `WESTON_LOG_SCOPES`, `WESTON_DEBUG_PROTOCOL`, `WESTON_IDLE_TIME`, `WLOG_LEVEL`, `PULSE_LOG`, `XKB_LOG_LEVEL` | — | Debugging (`compositor/main.c:2831-2898`; `rdp.c:2152-2185`). |
| `WESTON_RDPRAIL_SHELL_ALLOW_ZAP`, `..._ALLOW_ALT_F4_TO_CLOSE_APP`, `..._LOCAL_MOVE`, `..._APPEND_DISTRONAME_STARTMENU`, `..._BLEND_OVERLAY_ICON_APPLIST/_TASKBAR`, `..._USE_WSLPATH`, `..._APP_LIST_PATH` | — | rdprail-shell (`rdprail-shell/shell.c:760-845`). |
| `LIBGL_ALWAYS_SOFTWARE` | — | Affects the system distro's Mesa (Xwayland). |

The full list was extracted with `grep -rhoE '"(WESTON|WSL|WSLG|WSL2)_[A-Z0-9_]+"'` over weston-mirror plus `WSLGd/main.cpp`.

**Undocumented knob (unverified, test before relying on it):** `SetupOptionalEnv()` runs **before** WSLGd reads `WSL2_INSTALL_PATH` (`main.cpp:250` vs `281-288`). A `.wslgconfig` entry `WSL2_INSTALL_PATH=C:\Users\me\wslg-alt` therefore makes WSLGd look for `msrdc.exe` and `wslg.rdp`/`wslg_desktop.rdp` in that folder (`main.cpp:469-496`; it falls back to mstsc if `msrdc.exe` is absent). With a copied `msrdc.exe` and its DLLs, this would allow a user-editable `.rdp` file (for example `keyboardhook:i:1`, `screen mode id:i:2`, `use multimon:i:1` for desktop mode) without admin rights or a custom VHD. It may be considered a loophole and closed like `WSL2_RDP_CONFIG_OVERRIDE` was.

### 1.7 Replacing or disabling the system distro

* **Private system distro:** `.wslconfig` `[wsl2] systemDistro=C:\\path\\system.vhd`. Build it from the `wslg` repo (Docker + `build-and-export.sh`, or `docker build` + `tar2ext4 -vhd`; `wslg/CONTRIBUTING.md:1-100`). It is loaded read-only via `MountFileAsPersistentMemory` or a SCSI LUN (`WslCoreVm.cpp:496, 1506-1530`). It is **global** (all distros) and can be blocked by the policy `AllowCustomSystemDistroUserSetting` (`WslCoreConfig.cpp:343-348`). This is the supported way to ship a modified Weston (GL renderer, dmabuf, other protocols), but it affects every distro of that Windows user.
* **Disable globally:** `.wslconfig` `[wsl2] guiApplications=false`. This removes the system distro and also the `wslg` DAX device (`WslCoreVm.cpp:1881-1892`).
* **Disable per distro:** `/etc/wsl.conf` `[general] guiApplications=false` in the user distro. Init skips the system-distro launch for that distro only (`WSL/src/linux/init/main.cpp:2281-2290, 2332-2342`). The VM-level `wslg` DAX device still exists as long as GUI apps are enabled globally.
* **Inspect:** `wsl --system -d <distro>` opens a shell in the paired system distro (changes are discarded at shutdown).

### 1.8 Showing a user-distro compositor on Windows without WSLg

1. **Nested inside WSLg as a Wayland client.** This needs a backend that can present with `wl_shm` (wlroots/sway, weston-wayland). Hyprland/Aquamarine requires `zwp_linux_dmabuf_v1` from the parent and a GBM allocator. The 2026 projects either bridge (sharpninja's `wslg-protocol-bridge` gives Hyprland a fake dmabuf parent, copies frames into shm, and needs a **custom kernel with VKMS**) or give up and use sway (clarenceb).
2. **Own RDP server in the user distro + stock `msrdc.exe`** launched via interop with WSLg-style arguments (`/v:<VMID> /hvsocketserviceid:<port GUID>`, `hvsocketenabled:i:1`) or plain TCP/localhost with `mstsc`. A user-distro rebuild of weston-mirror (+ FreeRDP-mirror) can speak RAIL + gfxredir and even mount the `wslg` DAX share itself. That gives a "WSLg clone" per distro with full control over renderer, protocols and `.rdp` settings, without touching the global system VHD. Unverified: whether msrdc accepts `/wslg` from a second caller, and whether a second virtiofs mount of tag `wslg` works from a user distro.
3. **Custom Windows viewer + DAX sections + hvsocket** (§2.7). Hyprland renders headless (or on its Wayland backend into a local bridge). Frames are copied into DAX-backed files, and a Windows app maps `WSL\<VMID>\wslg\<name>`, uploads to a D3D11 texture and presents fullscreen per monitor. Input returns over hvsocket to `uinput` (`INPUT_UINPUT=m`) or virtual-keyboard/pointer protocols. The viewer can own the Win key with a `WH_KEYBOARD_LL` hook. This is the most control with only stock Microsoft binaries.
4. **VNC/RDP over TCP** (wayvnc works with Hyprland's screencopy): simplest, and the slowest.

### 1.9 GPU-direct presentation (third-party proof, not shippable)

[noahkelly2024/wslg-gpu-direct](https://github.com/noahkelly2024/wslg-gpu-direct) (v0.1.0, 2026-08-11; tested on an RTX 5060, Win11 26200, WSL 2.9.4, WSLg 1.0.79) keeps d3d12 textures on the GPU end-to-end. Its design doc (`overlays/wslg/docs/GPU_SURFACE_PRESENTATION.md`):

* It adds a kernel ioctl `LX_DXSHAREGPUSURFACEWITHHOST` (0x4a) that duplicates a dxgkrnl resource fd and fence into NT handles "in the VAIL host process".
* It extends the rdpapplist channel to v5 with `OPEN/PRESENT/CLOSE_GPU_SURFACE` PDUs.
* WSLDVCPlugin (loaded inside msrdc) opens the handles with `ID3D11Device5::OpenSharedResource1`, waits on the fence and attaches an `IDCompositionTexture` overlay to the RAIL HWND.
* msrdc must first call **`gdi32!D3DKMTRegisterVailProcess(&vmId)`** (`overlays/wslg/WSLDVCPlugin/VailRegistration.cpp`). That needed a **patched `wslservice.exe`** ("GpuPresentationTokenBroker") to hand msrdc a special same-user delegation token.

Conclusion: zero-copy guest→host presentation is technically possible with the existing hypervisor and dxgkrnl plumbing. It needs non-shippable replacements of Microsoft-signed host binaries plus a custom kernel, so it is out of scope for a distributable womarchy, but it is useful as a reference.

---

## 2. WSL itself (github.com/microsoft/WSL, open source since Build 2025)

Versions: target machine **2.7.10** (kernel 6.18.33.2-2, WSLg 1.0.73.2, MSRDC 1.2.6676). Current: **3.0.1** (2026-09-29, "WSLc is generally available"), which ships kernel **6.18.40.1-1**, WSLg **1.0.79** and MSRDC 1.2.7214 (`gh api repos/microsoft/WSL/contents/packages.config?ref=3.0.1`). The 2.7.x servicing line (2.7.14, 2026-09-11) stays on 6.18.33.2 and WSLg 1.0.73.2.

### 2.1 Distro packaging (`.wsl`)

Official guide: https://learn.microsoft.com/en-us/windows/wsl/build-custom-distro (WSL ≥ 2.4.4).

* **Format:** a tar of the rootfs, with the root at `/`, not in a subdirectory. Create it with `tar --numeric-owner --absolute-names -c * | gzip --best`, then rename to `.wsl`. gzip is recommended. **xz is accepted**: the Arch image is `tar | xz -T0 -9` renamed to `.wsl` (`archlinux-wsl/scripts/build-image.sh:72-88`), and WSL 2.5.1 added xz/bzip2 support. Don't include `/etc/resolv.conf`, a kernel or an initramfs. Include `root` with uid 0 and no password hashes. `wsl.conf` and `wsl-distribution.conf` must be `root:root 0644`.
* **`/etc/wsl-distribution.conf`** (parsed by WSL init):
  * `[oobe] command` runs as root at the first interactive launch; a non-zero exit refuses the shell (`WSL/src/linux/init/init.cpp:626-700`).
  * `[oobe] defaultUid` sets the default user after OOBE and refreshes DrvFs ownership.
  * `[oobe] defaultName` is the registration name, required for double-click install (`main.cpp:2476-2490`).
  * `[shortcut] enabled` / `icon`: `.ico`; the docs say ≤ 10 MB but the code reads at most **1 MB**, and paths with `..` are rejected (`main.cpp:2499-2512`).
  * `[windowsterminal] enabled` / `profileTemplate`: JSON fragment, read at most 1 MB (`main.cpp:2515-2531`).
* **Generated artifacts:** a Start-menu `.lnk` that runs `wsl.exe --distribution-id <GUID> --cd ~` (`WSL/src/windows/service/exe/LxssUserSession.cpp:2808-2830`), and a WT profile whose `commandline` is **forced** to `wsl.exe --distribution-id <GUID>`. Only cosmetics (colour scheme, font, `startingDirectory`) come from the template (`LxssUserSession.cpp:2860-2910`). **A "launch desktop" entry point therefore needs its own shortcut** (created by an installer or OOBE via interop), or a login-shell hook.
* **Install:**
  * `wsl --install --from-file X.wsl [--name N] [--location DIR] [--no-launch] [--vhd-size SIZE] [--fixed-vhd]` (`WSL/src/windows/inc/wsl.h:36-54`; `--vhd-size/--fixed-vhd` since 2.5.4).
  * Double-clicking a `.wsl` installs and starts it (2.5.1).
  * Manifest-based `wsl --install <flavor>` via `DistributionInfo.json` (`ModernDistributions` → `Name/FriendlyName/Default/Amd64Url{Url,Sha256}`). Arch is already listed: `archlinux` → `https://fastly.mirror.pkgbuild.com/wsl/2026.09.01.176721/archlinux-2026.09.01.176721.wsl` (`WSL/distributions/DistributionInfo.json:202-211`).
  * Private manifests: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\DistributionListUrl` / `DistributionListUrlAppend` (`file://` supported). Public listing requires a PR and the distros-list membership criteria.
* **Post-install management:** `wsl --manage <d> --set-default-user <u>` (≥ 2.4.10), `--move`, `--resize`, `--set-sparse`; `wsl --export --format tar.xz`.
* **Building with WSL containers:** Craig Loewen's (WSL PM) [Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) builds a Containerfile with `wslc.exe` and exports via `wslc create` + `wslc export -o X.wsl` (`export-wsl.ps1`). It is CLI-only, with `[user] default=omarchy`, `systemd=true`, `defaultUid=1000`, a WT template and an icon.

### 2.2 `/etc/wsl.conf` (per distro)

Keys from `WSL/src/linux/init/WslDistributionConfig.{h,cpp}` (h:24-41, defaults h:60-85):

| Section.key | Default | Notes |
|---|---|---|
| `boot.systemd` | false | WSL2 only; needs `/sbin/init` (cpp:88-94). Init forks and systemd becomes PID 1, waiting for `is-system-running` = running/degraded. |
| `boot.command` | — | Runs as root at boot. |
| `boot.initTimeout` | 10000 ms | |
| `boot.protectBinfmt` | true | |
| `user.default` | — | |
| `automount.enabled/root/options/mountFsTab/ldconfig/cgroups` | true, `/mnt`, —, true, true, v2 | `ldconfig` controls writing `/etc/ld.so.conf.d/ld.wsl.conf` → `/usr/lib/wsl/lib` + running ldconfig (`config.cpp:2226-2272`). |
| `interop.enabled/appendWindowsPath` | true/true | Needed to launch Windows executables (msrdc, viewer) from Linux. |
| `network.generateHosts/generateResolvConf/hostname` | true/true | |
| `time.useWindowsTimezone` | true | |
| `fileServer.enabled/logFile/logLevel/logTruncate` | true | Plan 9 server. |
| `gpu.enabled` | true | Mounts `/usr/lib/wsl` and `/dev/dxg` access. |
| `gpu.appendLibPath` | true | Appends `/usr/lib/wsl/lib` to PATH. |
| `general.guiApplications` | (true) | Per-distro WSLg opt-out (`main.cpp:2281-2290`). |
| `filesystem.umask` | 022 | |

With systemd, WSL's generator masks `systemd-networkd-wait-online`, `NetworkManager-wait-online` and `console-getty`, and installs `wsl-mnt-guard`, `wslg.service` and the user unit `wslg-session` (`init.cpp:322-400, 267-315`).

### 2.3 `.wslconfig` (per Windows user; applies to the single VM = all distros)

Keys (`WSL/src/windows/common/WslCoreConfig.h:236-300`, defaults `:317-370`):

* `[wsl2]`:
  * `kernel`, `kernelCommandLine`, `kernelModules` (a modules VHD)
  * `loadDefaultKernelModules` (default modules: `tun, ip_tables, br_netfilter`, `WslCoreConfig.cpp:202-212`), `loadKernelModules` (comma list)
  * `memory`, `processors`, `swap`, `swapFile`
  * `localhostForwarding`, `nestedVirtualization`, `virtio9p`, `virtiofs` (DrvFs over virtiofs, file-backed and **no DAX**)
  * `gpuSupport` (default true), `guiApplications` (true), `systemDistro`
  * `vmIdleTimeout` (60000 ms), `debugConsole`, `earlyBootLogging`, `kernelBootTimeout`, `distributionStartTimeout`
  * `virtio` (default true on x64), `hostFileSystemAccess`, `mountDeviceTimeout`, `hardwarePerformanceCounters`
  * `networkingMode` (`nat`/`mirrored`/`virtioproxy`→"Consomme"/`bridged`/`none`), `vmSwitch`, `macAddress`, `dhcp`, `dhcpTimeout`, `ipv6`, `dnsProxy`, `dnsTunneling`, `firewall`, `autoProxy`
  * `safeMode`, `defaultVhdSize`, `crashDumpFolder`, `maxCrashDumpCount`, `isolateDistroCgroup`
* `[general]`: `distributionInstallPath`, `instanceIdleTimeout` (15000 ms).
* `[experimental]`: `autoMemoryReclaim` (default `dropCache`), `sparseVhd`, `bestEffortDnsParsing`, `dnsTunnelingIpAddress`, `initialAutoProxyTimeout`, `ignoredPorts`, `hostAddressLoopback`, `setVersionDebug`, `swiotlb`, `virtioFsAggregateShares`.
* Policies can override `kernel`, `kernelModules`, `systemDistro`, `kernelCommandLine`, `kernelDebugPort` and `nestedVirtualization` (`WslCoreConfig.cpp:334-348`).

### 2.4 Custom kernel / modules: global effect and the DRM removal

* `kernel=` swaps the kernel for **the whole VM** (every distro plus docker-desktop). `kernelModules=` supplies a modules VHD; without it, WSL uses `<install>/lib/modules.vhd` or `artifacts.vhd` (`WslCoreVm.cpp:245-270, 1820-1823`). Modules can be auto-loaded with `loadKernelModules=vgem,...`. A user reported that a custom `modules.vhdx` broke networking on WSL 2.9.12 and built VKMS into the kernel instead ([sharpninja/omarchy-wslg docs/kernel.md](https://github.com/sharpninja/omarchy-wslg)).
* **DRM availability by kernel** (checked via `gh api .../contents/arch/*/configs/config-wsl*?ref=<tag>`):

| Kernel tag | x86_64 | arm64 |
|---|---|---|
| 6.18.33.2 / 6.18.35.2 (WSL 2.7.x) | `CONFIG_DRM=y`, `DRM_VGEM=m`, VKMS **not set**, UDMABUF **not set** | `DRM=m`, `VGEM=m`, **`VKMS=m`**, **`UDMABUF=y`** |
| **6.18.40.1** (WSL 2.9.x / **3.0.1**) | **`# CONFIG_DRM is not set`**, UDMABUF not set | `# CONFIG_DRM is not set`, UDMABUF=y |

  The cause is commit [`7e83488bd5` "Align x86 config with upcoming ARM64 changes — Disables DRM, task stats…"](https://github.com/microsoft/WSL2-Linux-Kernel/commit/7e83488bd5) (2026-07-27). `DXGKRNL=y`, `SYNC_FILE=y`, `HYPERV_VSOCKETS`, `VIRTIO_FS=y`, `FUSE_DAX=y` and `INPUT_UINPUT=m` remain in 6.18.40.1.
* **Implication:** on WSL ≥ 2.9 no `/dev/dri` is possible without a custom kernel. This kills vgem-based VA-API (`vainfo --display drm --device /dev/dri/card0`; [WSL#41733](https://github.com/microsoft/WSL/issues/41733) already observes "stock WSL kernel lacks CONFIG_DRM_VGEM") and every GBM/KMS trick. VA-API through the X11 display type should still work (§3.6).

### 2.5 `wsl.exe` process/console semantics

* `wsl.exe -d X [-u user] [--cd dir] [--shell-type standard|login|none] [-e cmd | -- cmd args]` → `SvcComm::LaunchProcess()`, which **returns the Linux process's exit code** as `wsl.exe`'s exit code (`WSL/src/windows/common/wslclient.cpp:681-693`; special codes map to `WSL_E_USER_NOT_FOUND` / `WSL_E_TTY_LIMIT`).
* When stdin/stdout are a console, a pty is created and sized from the Windows console. Ctrl-C and resizes are relayed. With redirected handles, pipes are relayed (2.9.13 changed the relay buffer to 64 KiB). `wslg.exe` is the same program built as a GUI-subsystem binary, so it starts without a console. Use it for shortcuts that launch a desktop directly (`WSL/doc/docs/technical-documentation/wslg.exe.md`).
* **Lifetime:** a distro stops `general.instanceIdleTimeout` (15 s) after the last `wsl.exe` session ends, even with systemd services running. The VM stops after `wsl2.vmIdleTimeout` (60 s). A blocking `wsl.exe -d Omarchy -- omarchy-desktop` naturally "returns to the prompt" when the desktop process exits.

### 2.6 hvsocket / AF_VSOCK between a user distro and a Windows process

* All distros share one VM and kernel, so a user-distro `AF_VSOCK` socket is a VM socket. WSLg itself: guest listens (`VMADDR_CID_ANY`, port p), host `msrdc` connects with `/v:<VMID> /hvsocketserviceid:<p as %08X>-FACB-11E6-BD58-64006A7986D3` (`WSLGd/main.cpp:17, 331-352, 458-509`).
* **Security:** WSL creates the VM with `HvSocketConfig.DefaultBindSecurityDescriptor = DefaultConnectSecurityDescriptor = "D:P(A;;FA;;;SY)(A;;FA;;;<user SID>)"` (`WslCoreVm.cpp:1826-1837`). Any process of the interactive user can **connect to** or **bind for** the WSL VM **without elevation and without the `GuestCommunicationServices` registry registration** that ordinary Hyper-V VMs need. WSL's own user-mode binaries do exactly this (`WSL/src/windows/common/hvsocket.cpp:22-36, 102-107`; `interop.cpp:286` connects from `wsl.exe`/`wslhost.exe`).
* **VM ID:** inside Linux, `wslinfo --vm-id` works in any user distro, which queries init (`WSL/src/linux/init/wslinfo.cpp:150-165`, `util.cpp:1366-1395`). Windows-side enumeration (`hcsdiag list`) needs admin. The practical pattern, as WSLg does, is for Linux to launch the Windows helper via interop and pass the VM ID on the command line.
* **Directions:** Windows→Linux: Linux `listen(AF_VSOCK, port)`, Windows `connect(AF_HYPERV{VmId, ServiceId(port)})`. Linux→Windows: Windows binds `AF_HYPERV{VmId=<VMID>, ServiceId(port)}`; Linux connects to `VMADDR_CID_HOST` (2) on that port. Ports < 1024 need `CAP_NET_BIND_SERVICE` in the guest. WSLg moved to that range in 2024 to prevent squatting.

### 2.7 Shared memory visible to Windows

* **The only zero-copy guest↔host memory channel on stock WSL is the WSLg DAX share** (§1.2). It is a VM-wide virtio-fs device, tag `wslg`, with an 8192 MB DAX window. It is section-backed: a file `/<mnt>/{name}` corresponds to the section `\Sessions\<sid>\BaseNamedObjects\WSL\<VMID>\wslg\{name}`. From a Windows process in the same session, `OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, L"WSL\\<VMID>\\wslg\\{name}")` (or the `Local\` prefix), which is how msrdc consumes `/wslgsharedmemorypath:WSL\<VMID>\wslg` plus `OpenPool.sectionName`.
  * Requirements: GUI apps enabled globally (`guiApplications=true`) and `wsl2.virtio` on.
  * A **user distro** would need root to `mount -t virtiofs wslg /mnt/wslgshm -o dax` itself. The system distro's mount lives in a separate mount namespace. **To verify:** a second mount of the same virtiofs tag from another namespace (Linux reuses the superblock per device, so it should work), and file-name rules (WSLg uses `{GUID}` names).
* **Not usable for zero-copy:** DrvFs over 9p (`/mnt/c`), which copies through the Plan 9 server. DrvFs over virtiofs (`wsl2.virtiofs=true`) is `VirtiofsShareKind_FileBacked` with `SharedMemorySizeMb=0`, i.e. no DAX (`GuestDeviceManager.h:11-12`). `/dev/shm` memfds are guest-only. AF_UNIX does not cross the VM boundary in WSL2.

### 2.8 WSL release notes 2024–2026: graphics-related items

(Full notes in `gh api repos/microsoft/WSL/releases`.)

* 2.1.x–2.2.x (2024): WSLg 1.0.60/1.0.61 and MSRDC updates. DXCore compatible with down-level host graphics kernels (#11095).
* 2.3.x (mid-2024): kernel 6.6 with "hundreds of new modules"; kernel modules mounted earlier.
* 2.5.1 (2025-03): **modules moved to a VHD**; WSLg 1.0.66; **WSLg creates `/run/user/<uid>` as tmpfs** (#11261); double-click `.wsl` install; OOBE for WSL1; `wsl --manage --resize`.
* 2.5.4: `--vhd-size/--fixed-vhd`; MSRDC 1.2.6074.
* 2.5.7: WSLg and binfmt units are created by a **systemd generator**.
* 2.6.x (2025-08/10): WSLg 1.0.69/1.0.71 (`wslinfo --vm-id`; locked-down shell selection); MSRDC 1.2.6353; WSLg shortcut-generation fix.
* 2.7.x (2025-12 → 2026-09): kernel 6.18.x; WSLg 1.0.73.2 (2.7.7); "Don't use an overlay for the GPU libraries if the inbox folder isn't present".
* 2.9.3 (2026-06, preview): **WSL Containers (WSLC)** preview including "GPU-enabled containers with CDI"; MSRDC 1.2.7214 (CVE-2026-32157); per-device SWIOTLB for virtiofs.
* 2.9.x / 3.0.1 (2026-09): kernel 6.18.40.1 (**DRM disabled**), WSLg 1.0.79, WSLC GA.
* **No release mentions dmabuf, a DRM render node, GPU-accelerated WSLg composition or a "WSL desktop" feature.** Third-party articles about a "WSL 3" with a new paravirtualised GPU/NPU path ([techtimes](https://www.techtimes.com/articles/317598/20260602/wsl-3-build-2026-near-native-gpu-npu-passthrough-brings-local-ai-windows.htm), [runaihome](https://www.runaihome.com/blog/wsl3-gpu-passthrough-local-ai-windows-2026/)) are **not backed** by the official Build 2026 post ([blogs.windows.com 2026-06-02](https://blogs.windows.com/windowsdeveloper/2026/06/02/build-2026-furthering-windows-as-the-trusted-platform-for-development/)), which covers only WSL containers. "3.0" is the WSLC GA version bump.

---

## 3. Mesa on WSL

### 3.1 d3d12 Gallium driver: capabilities and loading

* **Versions:** `glsl_feature_level = 460` (compat 460), `essl_feature_level = 310` (`mesa/src/gallium/drivers/d3d12/d3d12_screen.cpp:289-291`). `docs/features.txt` lists d3d12 as done for GL 3.0 → **4.6** (`features.txt:39-229`) and **GLES 3.1** (`:244`), plus `GL_EXT_memory_object(_win32)` and `GL_EXT_semaphore(_win32)` (`:328-337`). The actual version depends on the adapter's shader model (up to SM 6.8, `d3d12_screen.cpp:1719-1731`).
* **Loading on WSL:** there is no DRM device, so every Mesa GL path ends in the **software winsys loader**. `sw_screen_create_vk()` tries, in order: `$GALLIUM_DRIVER`, then **`d3d12`** (skipped if `LIBGL_ALWAYS_SOFTWARE`), then `llvmpipe`, then `softpipe` (`src/gallium/auxiliary/target-helpers/sw_helper.h:72-98`). d3d12 creation is `d3d12_create_dxcore_screen(winsys)` (`:64-67`). It dlopens `libdxcore.so` and `libd3d12.so` from `/usr/lib/wsl/lib`, which WSL puts on the loader path via `/etc/ld.so.conf.d/ld.wsl.conf` plus ldconfig (`WSL/src/linux/init/config.cpp:2226-2272`). **No manual ld.so config is needed on Arch** unless `automount.ldconfig=false`.
* **Adapter selection:** `MESA_D3D12_DEFAULT_ADAPTER_NAME` does a case-insensitive substring match. Otherwise the first **integrated** adapter is preferred (battery), falling back to the first D3D12 graphics adapter (`d3d12_dxcore_screen.cpp:63-130`; [wiki: GPU selection](https://github.com/microsoft/wslg/wiki/GPU-selection-in-WSLg)). On the RTX 5070-only target this is moot, but set `MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA` defensively.
* **Debug env:** `D3D12_DEBUG=verbose,blit,dxil,res,debuglayer,gpuvalidator,...`, `DXIL_DEBUG` (`docs/drivers/d3d12.rst`). Open MR [!37469 "gallium/sw: Fix llvmpipe being chosen when not wanted"](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/37469) (2026-09) touches the same selection code.

### 3.2 EGL platforms and present paths available on WSL

| EGL platform | Works? | Path |
|---|---|---|
| **wayland** | yes | No `wl_drm`/dmabuf from WSLg, so `dri2_initialize_wayland_swrast`. Buffers are `wl_shm_pool_create_buffer` and frames are memcpy'd in `dri2_wl_swrast_put_image2` (`platform_wayland.c:2841, 3029-3060, 3215`). |
| **x11** | yes | drisw via XPutImage/MIT-SHM to Xwayland. |
| **surfaceless** | yes | No DRM, so "Falling back to surfaceless swrast without DRM" → swrast → d3d12 (`platform_surfaceless.c:388-394`). If vgem is present, it uses `kms_swrast` on the vgem primary node (`:274-294`). Useful for **headless GPU rendering + readback**. |
| **device** (`EGL_EXT_platform_device`) | yes (software device) | `platform_device.c:274-316` → swrast → d3d12. |
| **gbm / drm** | only with a DRM node (vgem, or custom VKMS) | See §3.3. |

The sw displaytarget present path for d3d12 is always `texture_map(READ)` + `util_copy_rect` into `winsys->displaytarget_map()` (`d3d12_screen.cpp:692-760`). GPU→CPU readback is unavoidable for any window-system output on Linux.

### 3.3 GBM / `kms_swrast` / vgem: can d3d12 run on a vgem node?

* **GBM:** `gbm_create_device(fd)` → `dri_screen_create()` with the kernel driver name (`vgem` has no DRI driver) → tries `zink` → falls back to `dri_screen_create_sw()` = **`kms_swrast`** (`src/gbm/backends/dri/gbm_dri.c:284-330, 1229-1236`). `kms_swrast` is `pipe_loader_sw_probe_kms(fd)` with the **kms_dri winsys** (dumb buffers plus PRIME on the DRM fd; `src/gallium/auxiliary/pipe-loader/pipe_loader_sw.c:62-77, 213-236`; `src/gallium/winsys/sw/kms-dri/kms_dri_sw_winsys.c:175-200, 530`). The screen is created by `sw_screen_create_vk()`, so **d3d12 is chosen for rendering even on the kms_swrast path** (`dri2.c:1726-1737`).
* **But d3d12 is not dma-buf-coherent:**
  * d3d12 allocates a winsys displaytarget only for `PIPE_BIND_DISPLAY_TARGET` (`d3d12_resource.cpp:417-436`). GBM/EGLImage buffers use `SCANOUT|SHARED|RENDER_TARGET`, so they are D3D12 resources in VRAM, not vgem dumb buffers.
  * `resource_get_handle(WINSYS_HANDLE_TYPE_FD)` returns an **`ID3D12Device::CreateSharedHandle` fd** (a dxgkrnl `"dxgresource"` fd), **not a dma-buf** (`d3d12_resource.cpp:862-890`).
  * `resource_from_handle(FD)` calls `OpenSharedHandle(fd)`, so a real dma-buf (for example from vgem) fails to import (`:576-584, 660-662`).
  * d3d12 has no `get_screen_fd`, so `caps.dmabuf = 0` (`u_screen.c:176-182`). GBM therefore sets `has_dmabuf_export=false`, and `gbm_bo_create` falls back to `create_dumb()` for scanout/cursor only (`gbm_dri.c:902-903, 1244-1247`).
  * Net effect: **Aquamarine/Hyprland on vgem+d3d12 gets either CPU dumb buffers it cannot render into with GL, or dxg fds that it mistakes for dma-bufs.** clarenceb's VKMS experiment hit exactly this: `GBM: Failed to allocate a GBM buffer: bo null` ([docs/12](https://github.com/clarenceb/omarchy-wsl2/blob/main/docs/12-wayland-on-wsl2.md) §4).
* **llvmpipe on kms_swrast + vgem is dma-buf-coherent** (it uses the winsys displaytarget for shared resources). That gives a working GBM/dmabuf stack, but CPU rendering, which defeats the goal.
* **Opportunistic d3d12↔d3d12 zero-copy inside the VM:** if both producer and consumer use Mesa d3d12, a dxg fd passed as if it were a "dmabuf" (for example via `zwp_linux_dmabuf_v1` with a fake modifier) is importable by the other side's `resource_from_handle(FD)`. wslg-gpu-direct relies on this ("single-plane Linux DMA-BUF backed by a shareable D3D12 texture"). Mesa main sets `D3D12_HEAP_FLAG_SHARED` for `PIPE_BIND_SHARED` (`d3d12_resource.cpp:370-371, 401-402`). This is a possible in-VM GPU path between Hyprland's clients and Hyprland, not towards Windows.

### 3.4 dzn (Vulkan on D3D12, "microsoft-experimental")

* API **1.2** (`DZN_API_VERSION`, `src/microsoft/vulkan/dzn_device.c:61`). **Non-conformant**: `conformanceVersion 0.0.0.0` and `vk_warn_non_conformant_implementation("dzn")` (`:1000-1005, 1134`).
* **External memory:** `KHR_external_memory_fd` and `KHR_external_semaphore_fd` are exposed on Linux (`:119-120`), but "opaque fd" means D3D12 shared handles (`opaque_external_flag` = `OPAQUE_FD` on Linux; import via `OpenSharedHandle`, export via `CreateSharedHandle`; `:65-70, 2640-2700, 2912-2930`). **There is no `VK_EXT_external_memory_dma_buf` and no `VK_EXT_image_drm_format_modifier`.** `EXT_external_memory_host` is Windows-only in practice (`:2760-2783`, `#else goto cleanup`).
* WSI on Linux is the **software WSI** (`dzn_wsi.c:91-94`), so presentation to Wayland/X11 is via CPU copies. `zink` on dzn therefore cannot provide dmabuf either.

### 3.5 d3d12 VA-API (video)

* Built whenever d3d12 is built (`gallium-d3d12-video` auto; `meson.build:735-739`). Decode: H.264, HEVC (8/10-bit), VP9, AV1. Encode: **H.264, HEVC, AV1** (AV1 since Mesa 23.2), plus VideoProc (scale/rotate/blend). Support depends on the host driver ([MS blog 2023-02](https://devblogs.microsoft.com/commandline/d3d12-gpu-video-acceleration-in-the-windows-subsystem-for-linux-now-available/)). An open MR "d3d12: WSL VAAPI encode fixes (HEVC active DPB + AV1 AMDENC)" ([!44798](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44798), 2026-09-29) shows ongoing WSL encode work. AMD RDNA4 exposes no decode profiles on WSL ([WSL#41733](https://github.com/microsoft/WSL/issues/41733)).
* **Initialisation:** the VA frontend special-cases a **vgem** DRM fd, using `vl_vgem_drm_screen_create` (sw kms → d3d12) (`src/gallium/frontends/va/context.c:172-192`). This is the documented `vainfo --display drm --device /dev/dri/card0` path, and it **disappears with kernel 6.18.40.1**. The X11 display type uses `vl_xlib_swrast_screen_create` (sw → d3d12) (`context.c:156-164`), so `vainfo --display x11` with WSLg's `DISPLAY=:0` should keep working (to verify).
* **Relevance to streaming:** NVENC-class encode on the RTX 5070 is reachable either through d3d12 VA-API or through NVIDIA's own **`libnvidia-encode.so` + `libcuda.so`** in `/usr/lib/wsl/lib` (present on the target, driver 32.0.16.1060; there are **no** NVIDIA Vulkan/GL ICDs, i.e. no `libnvidia-glcore` or `nvidia_icd.json`). CUDA on WSL does **not** support OpenGL-CUDA interop ([NVIDIA CUDA on WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html), 13.4). Zero-copy GL → encoder therefore only works via d3d12 shared handles (GL `EGL_MESA_image_dma_buf_export` → dxg fd → VA `vaCreateSurfaces(DRM_PRIME)` → d3d12 `resource_from_handle`). This is untested; see the proposed PoC [Cookiekira/niri#1](https://github.com/Cookiekira/niri/issues/1) (2026-08, no results yet).

### 3.6 Arch Linux packages

* **`mesa` 1:26.2.3-2** (`arch-pkg-mesa/PKGBUILD:246-270`): `-D gallium-drivers=all` (includes `d3d12`, `meson.build:207-211`), `-D video-codecs=all`, and VA drivers merged into `mesa` (provides `libva-mesa-driver`, so `d3d12_drv_video.so` ships in `mesa`). `-D vulkan-drivers=...,microsoft-experimental,...`. `makedepends` includes **`directx-headers`** (build-time only, 1.619.5; Mesa needs ≥ 1.619.1, `meson.build:720-726`).
* **`vulkan-dzn`** is a split package containing `libvulkan_dzn.so`, `libspirv_to_dxil.*`, `spirv2dxil` and `dzn_icd.json` (`PKGBUILD:343-346, 485-510`).
* Runtime needs no extra package for d3d12. `libd3d12.so`, `libd3d12core.so` and `libdxcore.so` come from Windows via `/usr/lib/wsl/lib`.
* **Arch Wiki tips** ([Install Arch Linux on WSL](https://wiki.archlinux.org/title/Install_Arch_Linux_on_WSL)): install `mesa` and `vulkan-dzn` (+ `vulkan-icd-loader`), export `GALLIUM_DRIVER=d3d12` and `LIBVA_DRIVER_NAME=d3d12`, and on Intel add a `libedit.so.2` symlink (wslg#996).

---

## 4. dxgkrnl (`drivers/hv/dxgkrnl`, `include/uapi/misc/d3dkmthk.h`)

### 4.1 Relevant ioctls (`d3dkmthk.h:1664-1792`)

| Area | ioctls |
|---|---|
| Resources & sharing | `LX_DXCREATEALLOCATION` (0x06), `LX_DXSHAREOBJECTS` (0x3f) → returns an fd per object: anon-inode `"dxgresource"` or `"dxgsyncobj"` (`ioctl.c:4750-4769`; fops have only `.release`, so **no mmap and no dma-buf**, `ioctl.c:55-92`); `LX_DXQUERYRESOURCEINFOFROMNTHANDLE` (0x41), `LX_DXOPENRESOURCEFROMNTHANDLE` (0x42) import such an fd; `LX_DXLOCK2`/`UNLOCK2` (CPU mapping of allocations) |
| Host sharing | **`LX_DXSHAREOBJECTWITHHOST` (0x44)**: `{device, object}` in, `object_vail_nt_handle` out, via VMBus `DXGK_VMBCOMMAND_SHAREOBJECTWITHHOST` (`ioctl.c:5336-5364`, `dxgvmbus.c:968-1006`, `dxgvmbus.h:863-874`). It "create[s] a Windows NT handle on the host for the given shared object… the host application can open the shared resource using the NT handle" ([patch v2 14/24](https://lore.kernel.org/lkml/b057425ee4a1e95a3a652e516b5ac31484d3f6e9.1644025661.git.iourit@linux.microsoft.com/)). The handle is created in the **registered VAIL host process** for the VM (§1.9). |
| Sync | `LX_DXCREATESYNCHRONIZATIONOBJECT` (0x10), `SIGNAL/WAIT*` (0x11, 0x12, 0x31-0x36, 0x3a-0x3b), `LX_DXOPENSYNCOBJECTFROMNTHANDLE2` (0x40), **`LX_DXCREATESYNCFILE` (0x45)**: monitored fence + value → a real Linux `sync_file`/`dma_fence` (`dxgsyncfile.c:50-120`); `LX_DXWAITSYNCFILE` (0x46); `LX_DXOPENSYNCOBJECTFROMSYNCFILE` (0x47) |
| Misc | `LX_DXENUMADAPTERS2/3`, `LX_DXQUERYADAPTERINFO`, `LX_DXESCAPE`, `LX_DXENUMPROCESSES` (0x48), `LX_ISFEATUREENABLED` (0x49) |

Present-related host commands exist in the VMBus protocol (`DXGK_VMBCOMMAND_PRESENTHISTORYTOKEN = 34`, `SETREDIRECTEDFLIPFENCEVALUE = 35`, `PROPAGATEPRESENTHISTORYTOKEN`; `dxgvmbus.h:90-139`), but no ioctl exposes a guest "present to host swapchain" path.

### 4.2 Cross-partition GPU surface sharing to Windows

* **Possible in principle:** `LX_DXSHAREOBJECTWITHHOST` plus a VAIL-registered host process that opens the NT handle (D3D11 `OpenSharedResource1`, `OpenSharedFence`). That is how WSA presented GPU surfaces and how a GPU-resident WSLg could work.
* **Blocked for us:**
  1. stock WSLg/msrdc never registers as VAIL host or uses GPU handles (gfxredir has no GPU PDU);
  2. `gdi32!D3DKMTRegisterVailProcess(GUID* vmId)` apparently requires a token the user doesn't have, so wslg-gpu-direct had to patch `wslservice.exe` to broker it;
  3. the stock ioctl takes a *device+object handle* in the calling process, and wslg-gpu-direct added a new fd-based ioctl (0x4a) to export client-owned resources from a compositor.
* **Explicit sync for in-VM compositing:** `LX_DXCREATESYNCFILE` gives compositors standard `sync_file`s (usable with `zwp_linux_explicit_synchronization_v1`). DRM syncobj (`wp_linux_drm_syncobj_v1`) needs DRM and is unavailable.

### 4.3 Upstreaming status / DRM shim

* v4 of the series (55 patches, **2026-03-19**, posted by Eric Curtin, authored by Iouri Tarassov) adds dma-fence/sync_file, compute-only adapters, `pin_user_pages`, and more. It remains a **misc device `/dev/dxg`, with no DRM render node and no dma-buf export** ([ratatoskr lkml mirror](https://ratatoskr.run/lkml/2026/03/3469789/t), [lkml.iu.edu 11/55](https://lkml.iu.edu/2603.2/09629.html)). No acceptance has been visible so far. Earlier versions were rejected in 2020/2022 ([Phoronix](https://www.phoronix.com/news/Microsoft-DXGKRNL-2022)).
* No public Microsoft effort for a DRM render-node shim, virtio-gpu/venus/native-context, or a DRM driver for Hyper-V synthetic video in WSL (`DRM_HYPERV` is not set). With DRM now disabled in the x86 WSL config, the direction is *away* from DRM.

---

## 5. 2024–2026 developments (summary)

| Topic | Status (2026-09-30) |
|---|---|
| dmabuf on WSL | **None.** UDMABUF off on x86; DRM off from 6.18.40.1. dxgkrnl shares are non-dmabuf fds. |
| DRM render node on WSL | None. vgem (=m) only on ≤ 6.18.35 x86; VKMS=m only on arm64 ≤ 6.18.35. Both are gone in 6.18.40.1. |
| virtio-gpu / venus / native context in Hyper-V/WSL | Nothing announced. `VIRTIO_GPU` not set. |
| MS statements on full Linux desktops | WSLg's stated purpose is per-app integration (README). No official desktop mode beyond the hidden `WSL2_WESTON_SHELL_DESKTOP`. Build 2026 announced only WSL containers. |
| NVIDIA native Vulkan/GL on WSL | Not shipped. The `/usr/lib/wsl/lib` NVIDIA set is CUDA/NVDEC/NVENC/OptiX/NGX plus the D3D12 UMD (`libnvwgf2umx.so`). GL/Vulkan go through Mesa d3d12/dzn. |
| GPU-accelerated WSLg composition | Not in Microsoft's WSLg. There is a third-party experimental proof (wslg-gpu-direct, 2026-08) requiring a patched kernel, `wslservice.exe`, system distro, Mesa and plugin. |
| Community Omarchy-on-WSL | [craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) (CLI-only, wslc build). [taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl) (real omarchy package, no Hyprland session). [clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2) (sway fallback; documents why Aquamarine fails). [sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg) (dmabuf→shm bridge letting unmodified Hyprland nest in WSLg fullscreen; needs a custom VKMS kernel). |

---

## 6. Arch Linux on WSL

* **Official image** ([archlinux-wsl](https://gitlab.archlinux.org/archlinux/archlinux-wsl), monthly, reproducible, cosign-signed; `wsl --install archlinux`):
  * `/etc/wsl.conf` = `[boot] systemd=true` (`rootfs/etc/wsl.conf`).
  * `/etc/wsl-distribution.conf` = `[oobe] command=/usr/lib/wsl/first-setup.sh`, `defaultName=archlinux`; `[shortcut] icon=/usr/lib/wsl/archlinux.ico`. **No `defaultUid`**, so the default user is **root**.
  * `first-setup.sh` prints docs and runs `pacman-key --init` + `pacman-key --populate archlinux` (the keyring is wiped at build for reproducibility, `build-image.sh:64-65`). `LANG=C.UTF-8`.
  * The build pacstraps `base` from an archive snapshot. It masks `console-getty, systemd-firstboot, systemd-networkd(-wait-online), systemd-resolved, systemd-tmpfiles-clean, systemd-tmpfiles-setup(-dev)(-dev-early), tmp.mount` and `/dev/null`-links `getty@`/`serial-getty@` (WSL#13595). It excludes `/etc/resolv.conf`, `/etc/hostname`, `/etc/machine-id` and caches (`scripts/build-image.sh:35-62`, `scripts/exclude`), then compresses with xz → `.wsl`.
* **Known issues relevant to a desktop:**
  * Masking `systemd-tmpfiles-setup` means tmpfiles-managed dirs (for example `/tmp/.X11-unix`, `/var/tmp` cleanup) aren't created by systemd. WSL's own `wslg.service` handles `/tmp/.X11-unix`, and `/run/tmpfiles.d/x11.conf` is overridden by init.
  * `XDG_RUNTIME_DIR` is `/run/user/<uid>` in systemd sessions, with WSLg sockets symlinked by the `wslg-session` user unit. A user compositor (Hyprland) will create `wayland-1` there. Keep `WAYLAND_DISPLAY=wayland-0` pointing at WSLg for the parent connection.
  * Arch Wiki notes user-session failures and early crashes, mitigated by `loginctl enable-linger <user>`, and warns against multiple systemd distros whose default users share a UID.
  * Omarchy's `uwsm start` needs a foreground VT and does not work. Use a direct launcher (sharpninja docs).
  * `sddm`/`graphical.target` must stay disabled. Default to `multi-user.target` (Craig's Containerfile).
* **Building a custom `.wsl` with Omarchy preinstalled:**
  1. Reuse the archlinux-wsl recipe (`make` with devtools/fakechroot/fakeroot), or build in a container (`docker build`/`wslc build`, then export).
  2. Pacstrap `base` plus the `omarchy` package (from the `[omarchy]` repo with pinned `omarchy-keyring`, as taufderl does) or run Omarchy's `install/` scripts adapted for WSL.
  3. Add `/etc/wsl.conf` (`[boot] systemd=true`, optionally `[user] default=<u>`, **`[general] guiApplications` according to the chosen transport**, `[interop] enabled=true`).
  4. Add `/etc/wsl-distribution.conf` (`oobe.command` creating uid 1000, `defaultUid=1000`, `defaultName=Omarchy`, `.ico`, WT template).
  5. Mask the units above, drop `resolv.conf`/`machine-id`, clear the pacman keyring (re-init in OOBE), then `tar --numeric-owner --xattrs --acls | gzip` → `Omarchy.wsl`.
  6. Distribute via `wsl --install --from-file` or double-click, or a private manifest via `DistributionListUrlAppend`.
  7. VM-global pieces (custom kernel, `.wslgconfig`, `systemDistro`) **cannot** be carried inside the `.wsl` file. They need a separate Windows-side installer step and affect all distros.

---

## 7. Implications for womarchy (platform view)

1. **Stock WSLg + nested Hyprland** (sharpninja-style bridge) is the lowest-effort path to "a fullscreen Hyprland window". It pays the full WSLg copy chain (≥ 3 CPU copies at 4K per monitor), relies on the unresolved Super-key behaviour, and currently needs a DRM node (custom kernel with VKMS/vgem) for Aquamarine's GBM allocator. Kernel ≥ 6.18.40.1 makes that dependency worse.
2. **User-distro "WSLg clone"**: run our own RDP/RAIL server (weston-mirror or a custom Aquamarine RDP backend) in the Omarchy distro with `guiApplications=false`. Mount the `wslg` DAX share ourselves and launch stock `msrdc.exe` with our own `.rdp` (`keyboardhook`, fullscreen). Copies: GPU readback + 1 CPU copy into the section + host upload. No global changes. Must verify: msrdc `/wslg` from a user distro, DAX re-mount, RAIL Win-key behaviour with `keyboardhook:i:1`.
3. **Custom Windows viewer**: DAX sections for frames plus hvsocket for input/control/pacing, D3D11 flip-model fullscreen per monitor, LL keyboard hook for Super. Same minimal copy count as (2), full control of multi-monitor, HiDPI, Super, exit semantics. Launched from Linux via interop with `wslinfo --vm-id`.
4. **Compressed stream**: d3d12 VA-API or NVENC → hvsocket → Windows MF/D3D11 decode. This lowers memory bandwidth (useful at 3×4K) at the cost of latency and quality. Zero-copy GL→VA is only possible via d3d12 shared-handle fds, and VA-DRM init breaks without vgem, so use the X11 VA display or NVENC.
5. **Zero-copy GPU present to Windows**: only with the VAIL path, which requires non-shippable host binary replacements. Treat it as research-only.

---

## 8. Open questions for hands-on verification

1. Does `WSL2_WESTON_SHELL_DESKTOP=true` start a working single-window desktop on WSLg 1.0.73.2? In it, does the Win key reach Weston when msrdc is fullscreen (default `keyboardhook:i:2`)?
2. RAIL fullscreen (`xdg_toplevel.set_fullscreen`) window: does Win/Super reach the Linux client? Does Win+Enter reach it?
3. Can a user distro (root) `mount -t virtiofs wslg <dir> -o dax` while WSLg is running? Can a Windows process `OpenFileMappingW(L"WSL\\<VMID>\\wslg\\{guid}")` a file created there?
4. Can a user-distro process `listen(AF_VSOCK)` and be reached by a non-elevated Windows `AF_HYPERV` connect with `wslinfo --vm-id`? Does the reverse (Windows bind, Linux connect to CID 2) work?
5. Does `.wslgconfig` `WSL2_INSTALL_PATH=` redirect msrdc and `.rdp` lookup as the source suggests?
6. With WSL 3.0.1 (kernel 6.18.40.1): confirm there is no `/dev/dri` after `modprobe vgem`, and whether `LIBVA_DRIVER_NAME=d3d12 vainfo --display x11` works.
7. Measure WSLg throughput at 3840×2160 per window: CPU time in Weston's `weston_surface_copy_content` and msrdc, and achievable fps with `WESTON_RDP_MONITOR_REFRESH_RATE=144`.

---

## 9. References

* WSLg: https://github.com/microsoft/wslg (README, CONTRIBUTING, `WSLGd/main.cpp`, `Dockerfile`, `config/`); wiki: [frame rate](https://github.com/microsoft/wslg/wiki/Controlling-WSLg-frame-rate), [debug options](https://github.com/microsoft/wslg/wiki/WSLg-Configuration-Options-for-Debugging), [GPU selection](https://github.com/microsoft/wslg/wiki/GPU-selection-in-WSLg); [releases](https://github.com/microsoft/wslg/releases); issues [#672](https://github.com/microsoft/wslg/issues/672), [WSL#7730](https://github.com/microsoft/WSL/issues/7730)
* Weston fork: https://github.com/microsoft/weston-mirror/tree/working (`libweston/backend-rdp/{rdp.c,rdprail.c,rdputil.c,rdpdisp.c,rdpclip.c}`, `rdprail-shell/shell.c`, `compositor/main.c`)
* FreeRDP fork: https://github.com/microsoft/FreeRDP-mirror/tree/working (`include/freerdp/channels/gfxredir.h`)
* PulseAudio fork: https://github.com/microsoft/pulseaudio-mirror/tree/working/src/modules/rdp
* WSL: https://github.com/microsoft/WSL (`src/windows/common/{WslCoreConfig.*,GuestDeviceManager.cpp,hvsocket.cpp,wslclient.cpp}`, `src/windows/service/exe/{WslCoreVm.cpp,LxssUserSession.cpp}`, `src/linux/init/{main.cpp,init.cpp,config.cpp,WslDistributionConfig.*,wslinfo.cpp}`, `msipackage/package.wix.in`, `distributions/DistributionInfo.json`, `doc/docs/technical-documentation/`); [releases](https://github.com/microsoft/WSL/releases)
* MS Learn: [Build a custom distro](https://learn.microsoft.com/en-us/windows/wsl/build-custom-distro), [wsl-config](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
* Kernel: https://github.com/microsoft/WSL2-Linux-Kernel (`drivers/hv/dxgkrnl/*`, `include/uapi/misc/d3dkmthk.h`, `arch/x86/configs/config-wsl`, commit [7e83488bd5](https://github.com/microsoft/WSL2-Linux-Kernel/commit/7e83488bd5)); dxgkrnl v4 on lkml ([ratatoskr](https://ratatoskr.run/lkml/2026/03/3469789/t)); [LX_DXSHAREOBJECTWITHHOST patch](https://lore.kernel.org/lkml/b057425ee4a1e95a3a652e516b5ac31484d3f6e9.1644025661.git.iourit@linux.microsoft.com/)
* Mesa: https://gitlab.freedesktop.org/mesa/mesa (`src/gallium/drivers/d3d12`, `src/gallium/auxiliary/target-helpers/sw_helper.h`, `src/gallium/auxiliary/pipe-loader/pipe_loader_sw.c`, `src/gallium/winsys/sw/kms-dri`, `src/gallium/frontends/{dri,va}`, `src/egl/drivers/dri2`, `src/gbm/backends/dri/gbm_dri.c`, `src/microsoft/vulkan`, `docs/features.txt`, `docs/drivers/d3d12.rst`)
* MS blogs: [D3D12 video accel in WSL (2023-02)](https://devblogs.microsoft.com/commandline/d3d12-gpu-video-acceleration-in-the-windows-subsystem-for-linux-now-available/), [DirectX ❤ Linux](https://devblogs.microsoft.com/directx/directx-heart-linux/), [Build 2026 dev post](https://blogs.windows.com/windowsdeveloper/2026/06/02/build-2026-furthering-windows-as-the-trusted-platform-for-development/), [WSLC GA](https://blogs.windows.com/windowsdeveloper/2026/09/29/wsl-containers-now-generally-available/)
* NVIDIA: [CUDA on WSL user guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)
* Arch: [archlinux-wsl](https://gitlab.archlinux.org/archlinux/archlinux-wsl), [mesa PKGBUILD](https://gitlab.archlinux.org/archlinux/packaging/packages/mesa), [Arch Wiki: Install Arch Linux on WSL](https://wiki.archlinux.org/title/Install_Arch_Linux_on_WSL)
* Prior art: [noahkelly2024/wslg-gpu-direct](https://github.com/noahkelly2024/wslg-gpu-direct), [sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg), [clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2), [taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl), [craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl), [Cookiekira/niri#1](https://github.com/Cookiekira/niri/issues/1)
