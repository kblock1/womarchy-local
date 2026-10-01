# womarchy engineering log

A chronological record of what was done, the issues found, and the fixes applied. It is the raw material for the install procedure and script (see [INSTALL-NOTES.md](INSTALL-NOTES.md) for the distilled, repeatable steps). Each entry lists **Did**, **Found** and **Fix/Decision**.

---

## 2026-09-30

### 1. Environment survey (reference machine)
- **Did:** inventoried the host and its WSL setup.
  - Windows 11 Pro 26200; WSL 2.7.10 (kernel 6.18.33.2, WSLg 1.0.73.2, MSRDC 1.2.6676).
  - RTX 5070 (driver 32.0.16.1060); Core Ultra 7 265F (20 cores); 64 GB RAM; 3×4K monitors.
  - Existing distros: four of the owner's own (the default is an Ubuntu 26.04 with systemd).
- **Found:**
  - The WSL kernel has `CONFIG_DRM=y` and `DRM_VGEM=m`, but no VKMS or UDMABUF. `/dev/dxg` is present; `/dev/dri` is absent.
  - WSLg Weston advertises `wl_shm` only (no dmabuf) and `xdg_wm_base` v1.

### 2. Lab distro
- **Did:** `wsl --install archlinux --name womarchy-lab --location D:\WSL\womarchy-lab --no-launch`; ran the `pacman-key` init manually (OOBE is skipped with `--no-launch`); `pacman -Syu`; created user `lab` (wheel, passwordless sudo); wrote `/etc/wsl.conf` with `[user] default=lab`.
- **Found:** `wsl.exe <distro> -- bash -c '...'` runs through a login shell, which expands `$vars` early. From Git Bash, `/mnt/...` paths are mangled unless `MSYS_NO_PATHCONV=1` is set.
- **Fix:** put experiments in script files under `lab/`, run them with `wsl -d womarchy-lab -- bash /mnt/d/.../lab/x.sh`, and set `MSYS_NO_PATHCONV=1` in Git Bash.

### 3. Mesa on Arch-in-WSL
- **Found:** Mesa 26.2.3 falls back to **llvmpipe** by default; d3d12 is not auto-selected on Arch.
- **Fix:** set `GALLIUM_DRIVER=d3d12`, which gives `D3D12 (NVIDIA GeForce RTX 5070)`, accelerated, GL 4.6 / GLES 3.1. Vulkan comes from `vulkan-dzn` (Dozen 1.2, non-conformant).
- **Found:** Wayland clients fail under systemd sessions because `XDG_RUNTIME_DIR=/run/user/<uid>` lacks `wayland-0` when the `wslg-session` user unit isn't running.
- **Fix (lab):** symlink `/mnt/wslg/runtime-dir/wayland-0*` into `$XDG_RUNTIME_DIR`.

### 4. Stock Hyprland 0.56.2 fails
- **Nested in WSLg:** "Wayland backend cannot start: Missing protocols" (it requires dmabuf, and binds xdg_wm_base v6 against WSLg's v1).
- **Headless or DRM:** "Cannot open backend: no allocator available", then `CBackend::create() failed!`.

### 5. vgem experiments (DRM path, lab only; later reverted)
- **Did:** `modprobe vgem`, then GBM probes.
- **Found:**
  - `kms_swrast` + `GALLIUM_DRIVER=d3d12` yields a D3D12 renderer.
  - `gbm_bo_create` works only with `RENDERING` and implicit modifiers.
  - aquamarine reopens the render node, but dumb buffers need the primary node.
- **Fix (lab patches `patches/aquamarine/0001..0003`):** the headless backend exposes `AQ_HEADLESS_RENDER_NODE`; the allocator uses the primary node for headless; a GBM implicit render-only fallback.
- **Result:** Hyprland rendered on D3D12, and a headless frame was captured.
- **Issue:** `modprobe vgem` is **VM-global**. It exposed `/dev/dri` to the user's Ubuntu.
- **Fix:** unloaded it right away (`modprobe -r vgem`). Rule: no kernel modules without approval.
- **Found later:** WSL ≥ 2.9 kernels have **no DRM at all**, so this path is lab-only.

### 6. Mesa d3d12 deadlock
- **Found:** Hyprland hung on its first text texture.
- **Diagnosis:** gdb plus Arch debuginfod gives `pb_slab_manager_create_buffer` (holds the mutex) → `d3d12_bo_new` → `d3d12_screen_reclaim_completed` → `pb_slab_buffer_destroy` → the same mutex, a self-deadlock. `GALLIUM_THREAD=0` does not help. It is still present in Mesa main.
- **Fix:** `patches/mesa/0001-d3d12-reclaim-outside-pb-manager-locks.patch` moves the reclaim and OOM retry to `init_buffer()`, where no pb manager lock is held. Validation is pending.

### 7. Benchmarks
- **Readback/upload/composition:** `lab/bench-readback.c` on EGL surfaceless (no DRM): 4K sync readback 5.4 ms, 1080p 2.0 ms; PBO async is slower on d3d12; blur composition is 1.0 ms on the GPU against 176 ms on llvmpipe.
- **hvsocket:** `lab/hvsock_bench.py` gives 1.21 GB/s WSL→Windows, 1.60 GB/s Windows→WSL, and a 92 µs median round trip. This needs no admin rights and no configuration.

### 8. systemd cgroup interaction between distros (WSL ≤ 2.7)
- **Found:** the lab's `user@1000.service` failed with `EBUSY`. On WSL 2.7, all distros share **one cgroup namespace**, and Ubuntu's uid-1000 user manager already owned `/user.slice/user-1000.slice`. Ubuntu itself was unaffected (verified from service start times).
- **Fix:**
  - moved the lab user to **UID 1789** (`lab/setup-lab-uid.sh`), after which the user session reports `running`;
  - WSL ≥ 2.9.13 has `wsl2.isolateDistroCgroup=true` by default, which makes this fix unnecessary there;
  - **install note:** on WSL ≤ 2.7, the Omarchy distro user must not share a UID with users of other systemd distros.

### 9. User constraints recorded
- Do not destabilise the machine or other distros; do not degrade performance; ask when in doubt.
- Approved: keep the lab; WSL 3.0 upgrade; local builds; using WSLg's shared memory.
- The WSL upgrade was deferred while the user's Codex agent ran in Ubuntu, and resumed once the user confirmed it had ended.

### 10. Hyprland 0.56 screencopy is not suitable as the frame source
- **Found:** `CScreenshareFrame::copyShm` allocates a full framebuffer, re-renders the monitor texture and reads back **the full frame** on every capture (`// TODO: add a damage ring`). The cursor is drawn into frames.
- **Decision:** build a dedicated aquamarine **"wsl" backend**: damage-only readback straight into shared memory, a hardware cursor that becomes the Windows cursor, input devices that respect Omarchy's XKB config, and frame pacing from the viewer's acks.

### 11. WSLg DAX shared-memory spike, attempt 1 (WSL 2.7.10)
- **Did:** as root in the lab, `mount -t virtiofs wslg /mnt/wslgshm -o dax`.
- **Found:**
  - the mount works (`dax=always`);
  - `readdir` gives ENOSYS;
  - `ftruncate` gives EINVAL;
  - the file had disappeared by the next check, and Windows `OpenFileMappingW("WSL\<VMID>\wslg\<name>")` gave ERROR_FILE_NOT_FOUND.
- **Hypothesis:** section-backed semantics. WSLg's Weston uses `open(O_CREAT|O_EXCL)` + `fallocate` + `mmap`, and the section lives only while a handle is open.
- **Next:** retry with `fallocate`, keeping the fd and mapping open while Windows opens it.

### 12. WSL upgrade to 3.0.x
- **Did:** `wsl --update`.
- **Found:** it needs a **UAC elevation** (msiexec), so it cannot be fully unattended. The install script must tell the user or run elevated.

### 13. WSL upgraded to 3.0.1 (user approved UAC; done after the user's Codex session ended)
- **Result:** WSL 3.0.1, kernel 6.18.40.1-1 (**no DRM**), WSLg 1.0.79, MSRDC 1.2.7214.
- **Found:** each distro now has **its own cgroup namespace** (`isolateDistroCgroup`), so the systemd cross-talk from §8 is gone.
- **Found (regression from the WSL upgrade, not from womarchy):** the owner's Ubuntu 26.04 distro boots `degraded`, because `systemd-binfmt.service` exits 1 under WSL 3.0.1 ("Failed to flush binfmt_misc rules: Read-only file system", then non-zero). Running it by hand succeeds, and interop and binfmt entries work.
- **Proposed fix, needs the user's OK** since it touches their distro: a drop-in `[Service] ExecStart=` / `ExecStart=-/usr/lib/systemd/systemd-binfmt`.
- **Install note:** the Omarchy distro should ship the same drop-in, or mask `systemd-binfmt` if it has no binfmt.d entries.

### 14. DAX shared-memory spike, attempt 2 (WSL 3.0.1): **works**
- **Did:** as root, `mount -t virtiofs wslg /mnt/wslgshm -o dax`; created the file with `O_CREAT|O_EXCL` + **`fallocate`** (not ftruncate) + `mmap(MAP_SHARED)`, **keeping the fd open**.
- **Windows side:** `OpenFileMappingW(FILE_MAP_READ|WRITE, "WSL\<VMID>\wslg\<name>")` works (no `Local\`/`Global\` prefix). The data matches, and writes are coherent both ways.
- **Throughput:**
  - Linux first-touch write 0.12 GB/s (page faults), steady-state write **6.3 GB/s**, read 1.0 GB/s;
  - Windows read **6.0 GB/s**.
  - **Fix:** pre-fault buffers at allocation (`MAP_POPULATE` plus a memset).
- **Semantics:** the file vanishes when the last Linux fd/mapping closes, so unlink isn't needed (it returns ENOENT). `readdir` and `mkdir` give ENOSYS (flat namespace); `ftruncate` gives EINVAL.
- **Non-root users** can create, fallocate and mmap files once root has mounted the share (root dir is 0777).
- **Security note:** any process of the same Windows user can open the sections by name. Names include PID and a counter, and frame data is not secret beyond the user's own session.
- **Install note:** a root-owned systemd mount unit mounts `wslg` at `/mnt/wslgshm` (virtiofs, `dax`) at boot. It requires WSLg enabled globally (default).

### 15. DRM-free Hyprland + wsl backend + Windows viewer: **first end-to-end frame** (2026-09-30)
- **Code:**
  - aquamarine (fork, `src/aquamarine`, branch `womarchy`): `CShmAllocator`/`CShmBuffer` (memfd or file on the DAX share, packed stride, pre-faulted); new `AQ_BACKEND_WSL` backend (`src/backend/Wsl.cpp`): vsock server, WDP protocol, outputs from `WOMARCHY_MONITORS`, frame pacing by viewer acks, keyboard/pointer devices, cursor images; `CBackend::start` falls back to a backend's own allocator when there is no DRM fd; swapchain format fallback for shm.
  - Hyprland (fork, `src/Hyprland`, branch `womarchy`): EGL on `EGL_PLATFORM_SURFACELESS_MESA` when no DRM fd; `CGLRenderbuffer` renders shm buffers into a texture FBO; `readbackToBuffer()` does damage-only `glReadPixels` with `GL_PACK_ROW_LENGTH` in `endRender`; `HYPRLAND_BACKEND=wsl` selects the backend; CPU cursor path uses `buf->size` and turns on automatically for shm allocators; `ensureBufferPresent` accepts shm buffers.
  - Mesa 26.2.3 with the d3d12 deadlock patch, built into `/opt/womarchy-mesa` (lab). Text rendering (notifications) no longer hangs, which **validates the Mesa fix**.
  - Windows viewer `windows/omarchy` (Rust): AF_HYPERV client, WDP, per-output D3D11 flip-model swapchains, section mapping (`OpenFileMappingW`), inline fallback, LL keyboard hook, mouse, cursor, launcher lifecycle.
- **Issues found and fixed:**
  1. Hyprland crashed in `CInputManager::newKeyboard`: devices were announced inside `CBackend::start()`. Fix: announce from an idle event.
  2. The viewer hung on the first connect. An AF_HYPERV `connect()` to a port with no listener yet blocks for the long default timeout. Fix: `setsockopt(HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT=1, 1000ms)` plus a retry loop.
  3. The Mesa tarball had been left half-extracted by an earlier killed build. Fix: re-extract.
- **Result:**
  - The viewer shows Hyprland (foot plus es2gears, blur, rounded borders, notifications). Renderer: D3D12 (RTX 5070); transport: shared-memory sections.
  - The session's exit code propagates to `omarchy.exe` (it returned 134 when Hyprland aborted, 0 on a clean exit), and `WDP_BYE` is received.
- **Open issue:** only about 10 frames/s. Investigating.

### 16. Frame-rate investigation: 5 FPS → 60 FPS (WSL 3.0.1 d3d12 upload regression)
- **Symptom:** es2gears ran at 5 FPS inside Hyprland but 61 FPS on plain WSLg, and only every other frame ack was processed promptly.
- **False leads, recorded to save time next time:**
  - split socket writes: now one write per message anyway;
  - nested epoll fd: replaced by direct poll fds plus `pollFDsChanged` anyway;
  - hvsocket Nagle/ack delays: the raw frame/ack ping-pong is 0.09 ms;
  - hidden-window Present throttling: the viewer now presents non-blocking when minimised, and the test runs visibly.
- **Real cause (gdb stack sampling, `lab/sample-stacks.sh`):** Hyprland's main thread sat in `_mesa_TexSubImage2D → u_default_texture_subdata → util_copy_rect`. Uploading es2gears' wl_shm buffer took about 190 ms.
- **Root cause (`lab/bench-*.c`):** on **WSL 3.0.1** (kernel 6.18.40.1), CPU stores into D3D12 **UPLOAD (write-combine) heap** mappings run at about **9 MB/s**, while **write-back** custom heaps run at 6–18 GB/s.
  - Mesa d3d12 streams texture uploads and CPU-write buffers through UPLOAD heaps, so a 1080p `glTexSubImage2D` took **860–930 ms** (it was 1.25 ms on WSL 2.7.10).
  - It is not page faults (only ~3 per call; `lab/bench-faults.c`).
  - PBOs were fast only because the state tracker gives PIXEL_UNPACK buffers STAGING usage, which puts them in a write-back heap.
- **Fix:** `patches/mesa/0002-d3d12-write-back-upload-heaps-on-wsl.patch`. On non-Windows builds, CPU-write buffers use the write-back custom heap (`D3D12_UPLOAD_WRITE_BACK=0` restores the old behaviour).
  - Results: 1080p upload **1.18 ms**; 4K upload 3.5 ms; readback 4K 4.4 ms.
  - End to end: **es2gears 60 FPS, viewer 60.6 frames/s**, 26.5 Mpx/s from shared memory.
- **Impact outside womarchy:** any Mesa-d3d12 GL app on WSL 3.0.1 is affected, but only through our patched Mesa does it get fixed. The owner's default Ubuntu distro has no Mesa GL stack installed, so it is unaffected. This is worth reporting to Microsoft/Mesa, and must be filed by a human (Mesa's AGENTS.md policy).
- **Also:** `lab/build-mesa.sh` rebuilt to be reproducible (`CLEAN=1` re-extracts the pristine tarball and applies `patches/mesa/*`). The patches carry `Generated-by: LLM` per Mesa policy.

### 17. Packages, the real session entry point, first packaged end-to-end run (2026-09-30)
- **Packages** (`linux/packages/`, local pacman repo `out/repo`, repo name `womarchy`, listed first in `pacman.conf`). They keep Arch's names and versions; pkgrel is `<arch pkgrel>.<womarchy revision>`:
  - `aquamarine 0.15.1-1.2`, `hyprland 0.56.2-4.1` (hyprland only; `hyprpm` dropped, Omarchy doesn't use it), `mesa`/`vulkan-dzn`/`vulkan-swrast`/`vulkan-mesa-implicit-layers`/`vulkan-mesa-layers 1:26.2.3-2.1` (drivers: d3d12, llvmpipe, softpipe, zink; Vulkan: dzn, lavapipe), `womarchy-session 0.1.0-2`.
  - Workflow: edit `src/<repo>` → `linux/packages/regen-pkgbuilds.sh` (re-exports the patches via `refresh-patches.sh` and derives the PKGBUILDs from Arch's `ref/*.PKGBUILD`; bump the revision there when patches change) → `build-all.sh [pkg...]` inside an Arch distro (niced `makepkg`, `repo-add`, installs for later builds).
  - Build times on this machine: aquamarine < 1 min, hyprland ~3 min, Mesa (trimmed) ~3 min.
  - `-debug` split packages are off by default (`DEBUG_PKGS=1` keeps them); hyprland-debug alone was 168 MB.
- **Verified:** the packaged Mesa (no `/opt` overrides) uploads 1080p BGRA in 1.2–1.8 ms, so both Mesa patches are in.
- **`womarchy-session`** (`/usr/bin/womarchy-session`, what `omarchy.exe` runs through `wsl --exec`):
  - Handshake line on stdout; everything else goes to `~/.cache/womarchy/session.log`. Errors also go to the Windows console.
  - Uses the DAX share if `/mnt/wslgshm` is mounted and writable; otherwise frames go inline.
  - Generates `$XDG_RUNTIME_DIR/womarchy/monitors.lua` from the Windows layout: one `hl.monitor` per output `WSL-<n>`, the Windows scale, and logical positions. Each output sits after the outputs that end left of or above it, which keeps mixed-DPI layouts free of gaps and overlaps. `GDK_SCALE` is 2 if any output is ≥ 150 %.
  - Strips `/mnt/*` (Windows) entries from PATH.
  - Runs `uwsm start -g -1 -e -D Hyprland hyprland.desktop` (Omarchy's own session command) and derives the exit status from the uwsm units.
  - Also package-shipped: `mnt-wslgshm.mount`, statically enabled, guarded by `ConditionVirtualization=wsl` + `ConditionPathExists=/mnt/wslg`.
- **Issues found and fixed:**
  1. **uwsm under `wsl --exec`:** uwsm deduces the login session from the foreground VT and failed with "Could not determine session on foreground VT". `wsl --exec` processes are not inside any logind session (cgroup `/non-systemd`), but WSL opens a `user` class session (`c1`) for the distro user. Fix: pass `XDG_SESSION_ID` from `loginctl list-sessions`, and `XDG_SEAT=seat0`.
  2. **uwsm reported 0 when its environment preloader failed.** Fix: read `Result`/`ExecMainStatus` of `wayland-wm-env@` and `wayland-wm@` after uwsm returns.
  3. **A failed uwsm start strips `PATH` and `LANG` from the systemd user manager** (its cleanup without a saved pre-state). A later successful start re-exports them. Just noted.
  4. **Orphaned compositors:** if `omarchy.exe` dies without sending QUIT, nothing can reattach (a new viewer has a new token), so the compositor would idle forever inside the VM. Fix: aquamarine `WOMARCHY_ORPHAN_TIMEOUT` (seconds, 0 = off). With it, the compositor exits when no viewer is authenticated that long after start or after losing one. The session sets it to 30.
- **Result:** in `womarchy-lab`, `omarchy.exe --windowed` → `womarchy-session` → uwsm → packaged Hyprland ran over shared memory at 60 frames/s. Closing the window sent QUIT and the session ended with 0. No `WOMARCHY_*` variables remained in the user manager, and no compositor was left running.

### 18. Clipboard, multi-output windows, installer, crash cleanup (2026-09-30)
- **Clipboard (text, both directions):**
  - `womarchy-clipd` (Python; package `womarchy-session`) is a user service. It is wanted by `graphical-session.target` and guarded by `ConditionEnvironment=WOMARCHY_TOKEN`, so it only runs in omarchy.exe sessions.
  - It listens on vsock `port+1` and authenticates the viewer with the session token (`WDP_CLIP_HELLO`/`WDP_CLIP_TEXT` in `protocol/wdp.h`).
  - The Wayland side is `wl-paste --watch` / `wl-copy` (data-control, no focus needed). The viewer side (`windows/omarchy/src/clip.rs`) uses `AddClipboardFormatListener` on a message-only window.
  - Echo is suppressed by "last synced text" on both ends. CRLF↔LF is converted, and Windows' clipboard is pushed at connect.
  - `lab/clipboard-test.ps1` covers Windows→Linux at connect, Linux→Windows and live Windows→Linux: all pass. It saves and restores the user's clipboard text.
  - Gotcha: under uwsm, `graphical-session.target` (and so clipd) only starts once the compositor publishes `WAYLAND_DISPLAY` to systemd. Omarchy's autostart does it (`systemctl --user import-environment $(env …)`); a bare config needs `exec-once = uwsm finalize`. Test tools must never fall back to WSLg's `wayland-0`: WSLg syncs *its* clipboard with Windows by itself, which made a first test pass falsely.
- **Multi-output test without a full-screen takeover:** `omarchy --windowed WxH --monitors N` opens N windows, one output each. With 2 outputs, both render at 60 FPS (120 frames/s total).
- **WSL OOBE semantics (tested with a throwaway Arch `.wsl`, `omarchy-test-oobe`, removed afterwards):** WSL runs a distro's `[oobe] command` only when the default shell is opened interactively. It does **not** run it for `wsl --exec …` or `wsl -- cmd`, and `RunOOBE` stays 1.
  - So `omarchy.exe` checks `/var/lib/womarchy/oobe-done`. If setup hasn't run, it runs `oobe.sh` in the console as root, then `wsl --terminate`s the distro so the default user written to `wsl.conf` applies.
  - `wsl --unregister` leaves an empty `Start Menu\Programs\<distro>` folder behind; `omarchy uninstall` removes it.
- **`omarchy.exe` subcommands:**
  - `install [IMAGE.wsl|URL] [--distro] [--location] [--launcher-only]`:
    - checks WSL ≥ 2.5;
    - takes the image from the argument, else an `Omarchy*.wsl` next to the exe, else `DEFAULT_IMAGE_URL`;
    - runs `wsl --install --from-file … --no-launch` and then setup;
    - copies itself to `%LOCALAPPDATA%\Programs\Omarchy`, adds that to the user PATH and creates Start menu `Omarchy.lnk` with the Omarchy icon.
  - `uninstall` asks the user to type the distro name before `wsl --unregister`, then removes the shortcut and the PATH entry.
  - `status` shows WSL, distro, setup, user, `/dev/dxg`, the shm mount and package versions.
  - PATH editing fails closed: if the value exists but can't be read, nothing is written, and the old value is appended to `path-backup.txt` before any write.
  - Started from Explorer or the Start menu, the viewer hides its own console, and shows it again with the error if the session fails.
- **Crash cleanup:** the viewer puts `wsl.exe` in a kill-on-close job object.
  - When `omarchy.exe` is killed, `wsl.exe` dies, the session gets SIGHUP, and uwsm stops the compositor. Measured 1 s once and ~30 s once; in the slow case the hangup arrived late and the orphan timeout backstopped it.
  - No processes are left and the user manager stays `running`.
  - `womarchy-session` traps HUP with a handler, not ignore, so uwsm still gets the signal. That lets it finish its log and env cleanup.
- **Launch racing distro shutdown:** WSL stops an idle distro shortly after its last client exits. A launch during that teardown waits several seconds for a fresh instance. It works, just slower; the viewer allows 60 s.

### 19. Startup UX, first-run handshake, GPU clients (2026-09-30)
- **Splash:** until the render thread takes the windows over (swapchains), they paint "Starting Omarchy…" (GDI, DPI-scaled Segoe UI). The windows appear 140 ms after launch.
- **Cold start is dominated by WSL.** Measured with the lab distro stopped, from launch to viewer connected ≈ 10.5–14 s:
  - about 8 s until `womarchy-session` runs (WSL starts the distro; systemd reports 1.5–3 s of it);
  - about 1 s in the session script (0.8 s of it is `uwsm check is-active`);
  - about 5 s from `uwsm start` to Hyprland accepting the viewer (uwsm's Python steps, the unit reload, prepare-env's login shell, then Hyprland).
  - A warm distro starts in a few seconds. Optimising this is on the list (skip the is-active probe; profile prepare-env).
- **First-run setup moved out of the hot path.**
  - The viewer's pre-launch "setup done?" probe cold-booted the distro before any window existed, so nothing was on screen for 5+ s.
  - Now `womarchy-session` detects a fresh image (uid 0, `oobe.sh` present, no `oobe-done`), prints `WOMARCHY_NEEDS_SETUP` and exits 75.
  - The viewer then hides its windows, shows the console, runs setup (`oobe.sh` as root, then `wsl --terminate` so the new default user applies) and relaunches itself.
- **GPU clients inside the session (`lab/gpu-clients-test.ps1`):**
  - es2gears (GLES on Mesa d3d12) and vkcube (Vulkan on Dozen, "Microsoft Direct3D12 (NVIDIA GeForce RTX 5070)") render side by side, tiled by Hyprland.
  - es2gears runs at about 57 FPS while sharing the GPU; the viewer holds 61.7 frames/s at 117 Mpx/s of damage.
  - Clients present through `wl_shm`: there is no dmabuf import on WSL, so Hyprland doesn't offer linux-dmabuf, and Mesa's d3d12 and Dozen Wayland paths fall back to shm.
  - Frame: `lab/out/gpu-clients-gl-vulkan.png`.

### 20. Live display changes, and a DAX page-size bug that broke non-page-aligned monitors (2026-09-30)
- **Feature:** Windows display changes mid-session (resolution, scale, monitors added or removed).
  - The viewer debounces `WM_DISPLAYCHANGE`/`WM_DPICHANGED` (1.5 s) and re-enumerates. It moves or resizes surviving windows, closes or opens windows for removed or added outputs, and sends a new `WDP_MONITORS`.
  - The render thread follows the window list lazily: a new swapchain when a window is new, `ResizeBuffers` when its size changed, and it drops outputs on `WDP_OUTPUT_REMOVED`.
  - The viewer also runs `womarchy-session --update-monitors`, which rewrites `$XDG_RUNTIME_DIR/womarchy/monitors.lua` and runs `hyprctl reload`.
  - Testable without touching real display settings: `OMARCHY_FAKE_MONITORS_FILE` makes enumeration read a layout file, so `lab/display-change-test.ps1` drives the full-screen code path on small fake monitors. Result: 1 → 2 → 1 monitors with a resize of WSL-1, and the outputs, sizes and generated rules all followed.
- **Backend:** Hyprland treats every non-DRM output as "created by user" (`m_createdByUser`). For those, a *sized* `IOutput::events.state` is how to change the mode (an empty one is ignored for them). The WSL backend emits the sized event after updating its single preferred mode. Hyprland got a debug log line in that listener.
- **Bug found by it (also affected startup!):** WSLg's DAX share rejects file sizes that are not whole pages (`fallocate`/`ftruncate` → `EINVAL`).
  - All sizes tested so far happened to be page-aligned (640x360, 1280x720, 1920x1080, 3840x2160). 800x450, 960x540, 1366x768 or 1600x900 would have made Hyprland reject every mode ("NO FALLBACK MODES").
  - Fix (aquamarine rev 6): shm files and mappings are rounded up to whole pages; the buffer's logical size stays `stride × height`.

### Omarchy overlay & image builder (agent)

Scope: Phase 2 of PLAN.md: the `womarchy-compat` package, the WSL overlay (`linux/overlay/`) and the reproducible `.wsl` image builder (`linux/image/`). Omarchy is pinned to **v4.0.4**, the `omarchy 4.0.4-1` package on `pkgs.omarchy.org/stable`. Upstream files were read from `git archive v4.0.4` of `upstream/omarchy`; the clone itself was not touched.

#### A. Incident: `wsl --install archlinux` enabled a Windows optional feature
- **Did:** ran `wsl --install archlinux --name womarchy-build --location D:\WSL\womarchy-build --no-launch`, as instructed.
- **Found:**
  - WSL 3.0.1 printed "The requested operation requires elevation", then "successful … not effective until the system is rebooted", and did **not** create the distro.
  - The Windows Setup event log shows DISM turning on `VirtualMachinePlatform` at 11:16:05 (event IDs 7 and 9).
  - **Cause**, from the WSL source (`WslClient.cpp` `InstallPrerequisites`, `WslInstall::CheckForMissingOptionalComponents`): every named-distro `wsl --install` first checks the VMP optional feature through WMI. Here WMI reported it missing, even though WSL2 already worked. So wsl.exe relaunched itself elevated as `wsl --install --no-distribution` and ran `dism /Online /NoRestart /enable-feature /featurename:VirtualMachinePlatform`.
  - The change takes effect at the next Windows reboot. Nothing was reverted, because reverting would be another elevated Windows change. **The owner must be told.**
- **Fix:** the `--from-file` path skips `InstallPrerequisites` entirely.
  - Downloaded the official image from the URL in Microsoft's `DistributionInfo.json` (`archlinux-2026.09.01.176721.wsl`) and verified its SHA-256 (`7b35e65e…14b9`).
  - Ran `wsl --install --from-file … --name womarchy-build --location D:\WSL\womarchy-build --no-launch`.
  - **Rule:** scripts and the installer use only `wsl --install --from-file`, never `wsl --install <name>`.

#### B. Build distro `womarchy-build`
- `linux/image/setup-build-distro.sh` runs as root and does the following:
  - pacman-key init and populate;
  - adds the systemd-binfmt drop-in;
  - installs `arch-install-scripts base-devel git jq xz zstd python devtools`;
  - creates user `builder` (UID 1790) for makepkg;
  - generates the en_US locale.
- The distro boots `running`. Downloaded packages are cached in `/var/cache/womarchy-pkg`, so rebuilds take about 5 minutes.

#### C. Findings while building the overlay
1. **v4.0.4 differs from the research (which read HEAD).** v4.0.4 has no `o.rebind`, no `install/user/hardware/vm-no-animations.sh` and no `no-animations` toggle.
   - Rebinding uses `hl.unbind` plus `o.bind` in `~/.config/hypr/womarchy.lua`, which `bindings.lua` requires.
   - The animations step removes the toggle only if it exists and the d3d12 path works (checked with `eglinfo`). It leaves a flag in `~/.local/state/womarchy/`.
2. **Menu extension semantics.** In v4.0.4, a row in `~/.config/omarchy/extensions/omarchy-menu.jsonc` is normalised before merging. A partial row therefore replaces the whole default row, and its label and icon become empty. `womarchy-provision-user` builds full rows from the installed default menu with jq:
   - `"when": "false"` hides a row;
   - Shutdown and Logout run `omarchy-system-logout`.
3. **shell.json** has no deep-merge. Idle is the first-party service `omarchy.idle`, which is switched off through `disabledPlugins`, the documented switch. The user's file is edited in place with jq:
   - the widgets `omarchy.bluetooth`, `omarchy.network`, `omarchy.power` and `omarchy.battery` are dropped;
   - the `omarchy.idle` and `omarchy.battery` services are disabled.
4. **uwsm 0.26.7** sources `$XDG_CONFIG_HOME/uwsm/env.d/*` last, after `/usr/share/uwsm/env.d/10-omarchy` (see `/usr/lib/uwsm/prepare-env.sh`). So `~/.config/uwsm/env.d/10-womarchy` takes effect.
5. **Omarchy's autostart imports the whole Hyprland environment** into the user manager (`systemctl --user import-environment $(env | cut -d= -f1)`). `PULSE_SERVER` must therefore be correct in the uwsm env, which sets it to `unix:$XDG_RUNTIME_DIR/pulse/native`.
6. **The official Arch WSL image masks only** `console-getty`, `getty@`, `serial-getty@` and `systemd-firstboot`. It does not mask tmpfiles or tmp.mount, unlike the newer upstream recipe, and it boots `running`. The image follows the official image.
7. **`/tmp/.X11-unix` is a read-only tmpfs mounted by WSL.** Xwayland inside our Hyprland cannot create `/tmp/.X11-unix/X1` there. Flagged to the lead.
8. **OOBE contract** (WSL `init.cpp` and `LxssInstance.cpp`):
   - `[oobe] command` runs only when the default shell is launched interactively, never for `wsl -e`.
   - It runs as root through `/bin/sh -c`, attached to the console.
   - Exit 0 persists `RunOOBE=0` and `DefaultUid`. A non-zero exit closes the shell, and the OOBE runs again at the next launch.
   - `oobe.sh` is idempotent (marker `/var/lib/womarchy/oobe-done`), so omarchy.exe can also run it through `wsl -e`.
9. **pacstrap** verifies packages with the host keyring, because `GPGDir` is not re-rooted. `-G` keeps the host keyring out of the image.
   - The Omarchy key is bootstrapped by downloading `omarchy-keyring` from `pkgs.omarchy.org`.
   - The build checks the package against the DB's SHA-256, and checks that it carries the pinned fingerprint `40DFB630FF42BCFFB047046CF0134EE680CAC571`.
10. **`omarchy-settings` 4.0.4 ships `default/pacman/pacman-stable.conf`.** taufderl/omarchy-wsl found it missing on an older version. Upstream `post-install/pacman.sh` therefore runs unmodified; `wsl/pacman.sh` then re-adds `[womarchy]` and `IgnorePkg`.
11. **WSLg Start menu.** WSLg publishes every `.desktop` app of the distro as a Windows Start-menu shortcut named "Name (distro)". This produced 17 entries for the lite image, including Avahi browsers and V4L2 test tools.
    - Its app list (weston `rdprail-shell/app-list.c`) is keyed by file name, and it scans `/usr/share/applications` before `/usr/local/share/applications`.
    - It skips entries that have `Hidden`, `NoDisplay`, `Terminal=true` or any `OnlyShowIn`.
    - A copy in `/usr/local/share/applications` with `OnlyShowIn=Hyprland;` would therefore hide an app from Windows but keep it in Omarchy's launcher. Not done; this is the lead's decision.

#### D. Build and runtime problems hit and fixed
1. **`keyboard-locale.sh` exited 2 without a message.** `sed` on the missing `/etc/vconsole.conf` inside `$(…)` failed under `set -e`/`pipefail`. Fix: test for the file first, and the same for `locale.conf`.
2. **`docker-dns.sh` did not strip `dns`.** In a chroot, `systemctl is-active` prints "Running in chroot, ignoring command" and returns 0. Fix: skip that check when `systemd-detect-virt --chroot` is true.
3. **`arch-chroot` warned "rootfs is not a mountpoint".** Fix: bind-mount the rootfs onto itself first.
4. **`ttf-font` was satisfied by `gnu-free-fonts`**, pacman's default provider. Fix: install `noto-fonts` in the first pacstrap.
5. **Audio.** After OOBE, `pactl` on `$XDG_RUNTIME_DIR/pulse/native` reached WSLg's PulseAudio, not PipeWire.
   - Cause: WSL's user generator installs `wslg-session.service` (in default.target.wants). Its `ExecStart` lines `ln -sf` WSLg's `pulse/native` and `pid` into `$XDG_RUNTIME_DIR/pulse/`, which replaces pipewire-pulse's socket.
   - Fix (`wsl/audio.sh`): a drop-in `/etc/systemd/user/wslg-session.service.d/10-womarchy-pipewire.conf` resets `ExecStart` and keeps only the `wayland-0` and `wayland-0.lock` links. `/etc/systemd/user` takes precedence over generator output.
   - Verified: `pactl info` reports "PulseAudio (on PipeWire 1.6.8)" with default sink `wslg-sink`. Two seconds of silence played through it appear on WSLg's server as the sink-input "Tunnel for omarchy@…".
6. **`test-image.ps1` sent `exit\r`.** Piping `"exit"` from PowerShell adds a CR. Fix: `cmd /c "wsl.exe -d X < NUL"`.

#### E. Lead's contract, as applied
- **`[womarchy]` repo is first:** `SigLevel = Optional TrustAll`, `Server = file:///var/cache/womarchy-repo`, plus a commented placeholder for the hosted URL.
  - The build copies `out/repo` into it, minus the debug packages, and adds `womarchy-compat`.
  - `womarchy-session` is installed when the repo has it (0.1.0-6 in the final lite image).
- **`mnt-wslgshm.mount` belongs to `womarchy-session`.** `wsl/shm-mount.sh` only checks that the unit exists, and removes an older womarchy copy from `/etc`.
- **`monitors.lua`** loads `$XDG_RUNTIME_DIR/womarchy/monitors.lua` when it exists; otherwise it uses Omarchy's default rule with `GDK_SCALE=1`.
- **`/etc/wsl.conf`** sets `[interop] enabled=true` and `appendWindowsPath=false`.
- **`wsl-distribution.conf`** sets `[shortcut] enabled=false`, because omarchy.exe creates the Start-menu entry. The Windows Terminal profile is kept.
- **`test-image.ps1`** removes the per-distro WSLg Start-menu folder after `--unregister`, but only when it holds nothing except that distro's shortcuts.

#### F. Results
- **Lite image:** `out/Omarchy-4.0.4-womarchy-20260930-lite.wsl`, 1.69 GB xz (rootfs 5.2 GB), built in about 5 minutes from a warm cache.
- **`omarchy-test` (first lite build, kept for the lead):**
  - The only failures were the two PipeWire audio checks, before fix D.5.
  - After applying `wsl/audio.sh` inside it and restarting that distro, everything passes.
  - Default user `omarchy` (UID 1000), OOBE completed, womarchy-session 0.1.0-3 (the lead updates it with `pacman -U`).
- **`omarchy-test-2` (final lite build: fresh install, then the real OOBE through `WSLENV` defaults):** OOBE plus first shell took 43 s. **0 failures** in `verify-image.sh`, for both the system and the user. The distro was then unregistered.
  - **System:**
    - state `running`, no failed units;
    - `omarchy-version` 4.0.4-1;
    - limine, snapper and linux absent;
    - `[womarchy]` is the first repo;
    - NetworkManager, resolved, networkd, sddm, cups, avahi, power-profiles-daemon and bluetooth are masked;
    - no `dns` key in the docker config;
    - `/mnt/wslgshm` mounted.
  - **User:**
    - user manager `running`;
    - Omarchy's hypr Lua config plus the womarchy overrides;
    - shell.json and menu overlays applied;
    - `eglinfo -B -p surfaceless` in a login shell reports `D3D12 (NVIDIA GeForce RTX 5070)`;
    - `pactl` reaches both WSLg directly and PipeWire, and the tunnel sink is the default.
- **Full image:** `out/Omarchy-4.0.4-womarchy-20260930.wsl`, 2.28 GB (rootfs 7.2 GB; 126 of the 150 base packages). Fresh install as `omarchy-test-full`: OOBE plus first shell took 38 s, **0 failures** for the system and the user. The distro was then unregistered.
- **Distros left installed:** `womarchy-build` (stopped; `D:\WSL\womarchy-build`) and `omarchy-test` (stopped; kept for the lead's omarchy.exe test).

### 21. Full Omarchy 4 desktop end to end; Xwayland; screen-capture crash; Chromium (2026-09-30)
- **Setup:** the image agent's `omarchy-test` (Omarchy 4.0.4 Lite, user `omarchy`) was upgraded to the current `[womarchy]` packages and driven by `omarchy.exe --windowed 1600x900 --input-script …`.
  - `--input-script` is a new viewer test driver: `sleep`, `key super+Return`, `type …`, `move/click/scroll`, and `shot PATH`, which runs `grim` inside the session. It replaces `--selftest-input`.
- **Result:**
  - The Omarchy desktop runs: wallpaper, Quickshell bar (workspaces, clock, weather, audio), notifications.
  - Super+Return opens the terminal; typed commands run.
  - Super+Space (Omarchy menu), Super+Alt+Space (apps) and Super+K (keybindings) work.
  - Clipboard daemon connected; `quit` logs out with exit code 0.
  - Screenshots: `docs/img/omarchy-desktop.png`, `docs/img/omarchy-menu.png`.
- **Bug: screen capture crashed Hyprland.** `ext-image-copy-capture` sessions call `PROTO::linuxDma->getMainDevice()`, and without a DRM device the linux-dmabuf protocol doesn't exist, so the pointer is null (SEGV). Omarchy's screenshot and screen-record tools and `grim` all hit it.
  - Fix (hyprland rev 3): capture offers shm only when there's no dmabuf protocol, in both session kinds; wlr-screencopy no longer advertises `linux_dmabuf`.
  - Also noticed: with the watchdog, a crash restarts Hyprland in a fresh instance without the viewer, which then orphan-times-out after 30 s.
- **Bug: no Xwayland.** WSL's generated `wslg.service` bind-mounts WSLg's `/mnt/wslg/.X11-unix` read-only over `/tmp/.X11-unix` (mode 0777, no sticky bit). Hyprland refuses the directory ("writable by others"), and it couldn't create sockets there anyway.
  - Fix (`womarchy-session` package): `womarchy-x11-unix.service`, ordered after `wslg.service`, mounts a private 1777 tmpfs on `/tmp/.X11-unix` in this distro only. It links `X0` to WSLg's socket, which may dangle until WSLg starts its X server; that keeps WSLg's X usable outside the desktop and keeps our Xwayland off :0.
  - Result: Xwayland on `:1`; `xeyes` and `xdpyinfo` work inside the desktop. Abstract-only sockets were rejected as the fix: they have no filesystem permissions, so any process in any distro could reach the desktop's X server.
- **Chromium** (Omarchy's browser, `--ozone-platform=wayland`): pages load and render.
  - `chrome://gpu` (`docs/img/chromium-gpu.png`): rasterization, canvas, OpenGL, video decode, WebGL and WebGPU are hardware (D3D12).
  - Compositing is "software only". Chromium's GPU compositing on Wayland needs linux-dmabuf, and WSL has no dmabuf export (no DRM). That's a platform limit; see FEASIBILITY.
- **Small things:** `xdg-desktop-portal-gtk` exits "failed" when the compositor goes away at logout. The session now runs `systemctl --user reset-failed` after the session so the user manager isn't left "degraded". The first-run "Setup Wi-Fi" notification is meaningless on WSL; the overlay will suppress it.

### 22. HiDPI with Omarchy's config; clean scales (2026-09-30)
- **Test mode:** `omarchy --windowed 2560x1440 --scale 1.5` reports the window output at a Windows-style 150%, driving the real path: `WOMARCHY_MONITORS` → generated rules → Omarchy's `monitors.lua` → Hyprland.
- **Found:** Hyprland only accepts scales that give whole logical pixels. Otherwise it searches 1/120 steps outward, applies the result and shows an "invalid scale" notification.
  - Example: 150% of 2560x1440 becomes 1.6.
  - With several monitors, positions computed with the Windows scale would then leave gaps or overlaps.
- **Fix (`womarchy-session`):** the generator runs the same search (integer maths: `w*120 % k == 0 && h*120 % k == 0`, outward from `round(scale*120)`), so the rule already carries the scale Hyprland will use and positions use it too.
  - Examples: 2560x1440@150% → 1.6; 3840x2160@175% → 1.66667 (5/3); 1366x768@125% → 1 (no clean scale nearer); 4K@150% stays 1.5.
  - Result: Hyprland applies 1.6 as given and no notification appears.

### 23. Startup time, measured on the Omarchy image (2026-09-30)
- **Cold start** (distro fully stopped; waiting until `wsl --list --running` no longer shows it matters, because a start racing the asynchronous teardown takes twice as long): **8.5 s** from launch to the first frame. That's 4.8 s until the session prints its VM id (WSL starts the distro; systemd userspace takes 1.5 s of it), then 3.6 s of uwsm + Hyprland.
- **Warm start** (distro running): **3.5 s**.
- A bare `wsl --exec /bin/true` on the stopped distro takes 3.2–4.0 s, so most of the cold cost is WSL's. The splash covers the wait. The §19 numbers (10–14 s) were measured on the heavier lab distro and include teardown races.

### 24. Omarchy session lifecycle and desktop features, verified (2026-09-30)
All in `omarchy-test` via `--input-script` (scripts in `lab/scripts-omarchy-*.txt`, screenshots in `lab/out/omarchy/`):
- **Log out from Omarchy's own UI** (Super+Escape → Logout): the compositor says BYE, uwsm returns 0, and `omarchy.exe` exits 0 back to the prompt in 16 s from launch. No compositor is left, and the user manager is `running`, not degraded, thanks to the `reset-failed` step.
- **Lock screen** (Super+Escape → Lock): hyprlock with a blurred wallpaper. Typing the password (PAM) unlocks back to the desktop.
- **Clipboard** in the real Omarchy session: all three directions pass. clipd starts with `graphical-session.target` (Omarchy's autostart imports the environment into systemd) and exits 0 at logout.
- **Boot units after the move off the local-fs path:** systemd userspace 1.52 s; `/mnt/wslgshm` is `virtiofs dax=always`; `/tmp/.X11-unix` is our writable 1777 tmpfs over WSL's read-only bind.

### Omarchy overlay & image builder (agent), follow-ups: Wi-Fi toast, Start menu, kernel prompt, rebuild
1. **"Setup Wi-Fi" first-run toast.**
   - Source: `install/user/first-run/wifi.sh`, run by `omarchy-provision-first-run`. When `nm-online -q -x` fails it shows "Setup Wi-Fi". Without NetworkManager, `nm-online` is "command not found", so the toast always appeared.
   - Skipping that step alone is not possible: the first run is a single script, and marking it done would also skip the unit and theme steps.
   - **Fix:** add a fallback `/usr/lib/womarchy/bin/nm-online` that reports online; it waits for a default route unless given `-s`/`-x`, and always exits 0.
   - The user's uwsm env **appends** `/usr/lib/womarchy/bin` to the session PATH, so a real `/usr/bin/nm-online` still wins if NetworkManager is installed.
   - Result: the first run shows only Omarchy's "Update System" toast. `nm-online` is used nowhere else in Omarchy 4.0.4.
2. **Start-menu clutter (lead's decision: hide).**
   - `wslg-hide-apps` writes a copy of each `/usr/share/applications` entry that WSLg would publish to `/usr/local/share/applications`, marked with a first-line comment and with `OnlyShowIn=Hyprland;`. WSLg drops any entry with `OnlyShowIn`. The Omarchy session still lists it, because `/usr/local/share` comes first in `XDG_DATA_DIRS` and `XDG_CURRENT_DESKTOP=Hyprland`.
   - Kept current by the `90-womarchy-wslg-apps.hook` pacman hook on any transaction touching `usr/share/applications/*.desktop`, and by the `wsl/wslg-apps.sh` leaf. Admin-written overrides are left alone.
   - **Verified live with the WSLg weston log (`/mnt/wslg/weston.log`):**
     - A fresh install produces **0 shortcuts**; earlier images produced 17.
     - Replacing a system entry the way a package update does (`cp` then `mv` over `foot.desktop`) publishes "Foot (omarchy-test-2)" within 1 s. The hook script hides it again within 1 s.
   - **WSLg quirks found:**
     - Deleting an override is treated as "file removed", which drops the whole app key even though `/usr/share` still has the entry. So opting out needs `wsl --terminate` so that WSLg rescans.
     - `touch` changes attributes only and does not trigger a rescan.
   - `test-image.ps1` now counts the shortcuts and runs this live publish-and-hide check.
3. **"Linux kernel has been updated. Reboot?": attempted fix, withdrawn, and an incident.**
   - `omarchy-update-restart` stays quiet only when a **pacman-owned** `/usr/lib/modules/$(uname -r)/vmlinuz` exists.
   - I tried a locally generated marker package, `womarchy-wsl-kernel`, owning that path and installed from the post-update hook. It worked: the real `omarchy-update-restart` went straight to "Restarting shell".
   - Then a fresh distro reported that the file "exists in filesystem". **WSL's `/usr/lib/modules/<ver>` overlay upper layer (`upperdir=/lib/modules/<ver>/rw/upper`, in the utility VM) is VM-wide**: my build distro, which never ran the marker, saw it too.
   - Worse, installing the marker triggered kmod's `60-depmod.hook`. That rewrote `modules.alias/.dep/.symbols/…(.bin)` and added `modules.weakdep` in the **shared** layer (12:50:55). Every distro in the running WSL VM sees these files, including the user's distros if they start before the VM restarts.
   - **Cleanup:**
     - Removed the placeholder `vmlinuz`. It existed only in the upper layer, so this was a true delete, not a whiteout. It is gone from all distros.
     - Left the regenerated indexes in place: deleting them would create whiteouts that hide WSL's originals.
     - Checked the indexes: 736 module files and 736 `modules.dep` entries; `modprobe --dry-run --show-depends` resolves sampled modules (sch_htb, kvm, kvm-intel, kvm-amd, lockd).
     - They disappear when the WSL VM next restarts. **Confirmed at 13:06:** after every distro stopped and the VM idled out, `womarchy-build` showed WSL's original files again (WSL's timestamps, no `modules.weakdep`, no `vmlinuz`). The side effect is gone.
     - **Owner/lead should know.** No kernel module was loaded; only index files were rewritten, and only while that VM was up.
   - **Decision:**
     - Removed the marker leaf. **Nothing may write into `/usr/lib/modules/<ver>` on WSL.**
     - The image now disables kmod's depmod hook (`/etc/pacman.d/hooks/60-depmod.hook -> /dev/null`, set by `wsl/pacman.sh`): with no package-managed kernel it could only touch WSL's shared indexes.
     - The kernel prompt stays a documented known issue ("answer no"). The clean fix is upstream: skip the check when no pacman-owned kernel exists under `/usr/lib/modules`, or when `systemd-detect-virt` = wsl.
   - `verify-image.sh` now fails if a `vmlinuz` appears in the shared modules directory, or if the depmod hook is active.
4. **pacman "database file … does not exist" warnings on a fresh image.** The build now keeps the sync DBs. They describe exactly the frozen Omarchy snapshot the image was built from, so there is no partial-upgrade risk.
5. **Final lite image:** `out/Omarchy-4.0.4-womarchy-20260930-lite.wsl`, 1.69 GB, SHA-256 `1af6e4e0…70a3`.
   - Contents: aquamarine 0.15.1-1.6, hyprland 0.56.2-4.3, womarchy-session 0.1.0-12, womarchy-compat 0.2.0-1.
   - `test-image.ps1` on a fresh `omarchy-test-2`: OOBE 35 s, **0 failures** for system and user, **0 Start-menu entries**, live check passed. The distro and its Start-menu folder were then removed.
   - `omarchy-test` (the lead's, from the first build) was not touched.

### 25. Installer end to end on the final image; patch series; a VM-shared-path incident (2026-09-30)
- **`lab/installer-test.ps1`** on the rebuilt Lite image (aquamarine 1.6, hyprland 4.3, womarchy-session 0.1.0-12), throwaway distro `omarchy-test-e2e`:
  - **A.** `omarchy install IMAGE --no-launcher` (import plus unattended first-run setup) took 125 s. `status` was all green, the desktop tour exited 0, and `uninstall --yes` removed the distro, its folder and the Start-menu folder.
  - **B.** Bare `wsl --install --from-file --no-launch`, then plain `omarchy`: the session reported `WOMARCHY_NEEDS_SETUP`, the viewer ran setup and relaunched, and the desktop exited 0. That took 68 s end to end; cleanup was complete.
  - A fresh install shows only Omarchy's normal "Update System" toast; the Wi-Fi toast is gone (image agent's `nm-online` fallback).
- **Patch series:** `refresh-patches.sh` now exports one patch per logical change, grouped by file, and checks that every changed file is covered:
  - aquamarine: `0001` shm allocator, `0002` WSL backend;
  - Hyprland: `0001` DRM-free rendering, `0002` wsl-backend selection, `0003` CPU cursor without dmabuf, `0004` screen capture without dmabuf.
  - The series apply cleanly to pristine sources (makepkg prepare). aquamarine's vendored `wdp.h` is synced with `protocol/wdp.h` (rev 7).
- **Incident (image agent, verified by lead):** trying to silence Omarchy's post-update "kernel updated, reboot?" prompt, the agent installed a package owning `/usr/lib/modules/<wsl-kernel>/vmlinuz`. kmod's depmod pacman hook then rewrote WSL's module index files.
  - That directory is an overlay whose writable layer is shared by **every distro in the VM**, so the change was visible VM-wide from 12:50 until the VM restarted.
  - The user's distros were all stopped in that window, and no module was loaded.
  - Checked after the VM restart: all `modules.*` files are WSL's originals (dated 2026-07-31).
  - The approach was withdrawn. The image now disables kmod's depmod hook (there's no pacman-managed kernel on WSL). The prompt stays documented as "answer no" until Omarchy adds a WSL guard upstream.
  - **Rule for future work:** `/usr/lib/modules`, `/mnt/wslg`, `/tmp/.X11-unix` (WSLg's bind) and `/usr/lib/wsl` are VM-shared or WSL-owned; never write there from a distro.
