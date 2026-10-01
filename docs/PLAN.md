# womarchy — Implementation Plan

Companion to [FEASIBILITY.md](FEASIBILITY.md) (read that first for the evidence). Date: 2026-09-30.

**Outcome.** A user on Windows 11 installs "Omarchy for WSL" and then types `omarchy` in any prompt.
- The Omarchy 4 desktop takes over every monitor full-screen, composited by Hyprland on the host GPU.
- Omarchy's Super-key workflow works.
- Clipboard, audio and HiDPI behave natively.
- Logging out (Super+Esc → Exit) returns to the same prompt with exit code 0.
- `omarchy update` keeps the system current.

**Non-negotiable constraints:**
- No custom kernel.
- No global WSL settings (`.wslconfig`/`.wslgconfig`).
- No replacement of Microsoft binaries.
- Must coexist with the user's other WSL distros without affecting them or system performance while idle.

**Status (2026-10-01; details in [WORKLOG.md](WORKLOG.md)):**

| Milestone | State |
|---|---|
| M0 spikes | Done. DRM-free Hyprland on d3d12 (surfaceless EGL). Transport: WSLg's DAX share (zero-copy sections) plus hvsocket control. |
| M1 packages | Done. `[womarchy]` repo with aquamarine, hyprland, Mesa (two d3d12 patches: deadlock fix, WSL 3.0.1 write-combine upload fix), and `womarchy-session`. |
| M2 Omarchy image | Done. Omarchy 4.0.4 Lite `.wsl` (1.7 GB): first-run setup, WSL leaves, user overlay. Tested by a fresh install each build. |
| M3 viewer | Done. `omarchy.exe` full-screen/windowed; protocol v2 with mutual authentication; one presenter thread and swapchain per output; keyboard hook (Super), mouse, cursor, clipboard (text); exit codes; device-loss recovery. |
| M4 polish | Mostly done. Verified: three 4K monitors with mixed DPI (150%/175%) at ~100 frames/s combined; live display changes; audio via WSLg. Cold start on 3x4K takes ~5 s (was ~17 s). Open: hardware video decode paths. |
| M5 installer | Mostly done. `install.ps1` (installs or updates WSL with a clear warning, then downloads and installs); `omarchy install / uninstall / status`; GitHub releases (lite image only: the full image exceeds GitHub's 2 GB asset limit). Open: CI rebuilds against Omarchy's snapshots, package signing, `omarchy update`. |
| M6 upstreaming | Planned: see [UPSTREAMING.md](UPSTREAMING.md). |

**Update strategy:**
- `[womarchy]` is listed first in `pacman.conf`. pacman takes a package from the first repo that has it, so `omarchy update` keeps our `hyprland`, `aquamarine` and `mesa` even when `[extra]` has newer ones.
- Hosting: the repo is served from the GitHub release tagged `repo`, with the image's local copy as an offline fallback. It is unsigned for now (`SigLevel = Optional TrustAll`, over HTTPS only); signing is open.
- Their *dependencies* (hyprutils, hyprlang, hyprgraphics, hyprwayland-scanner, libdisplay-info, llvm-libs, …) still move with Omarchy's Arch snapshot (`stable-mirror.omarchy.org`). A soname bump there breaks our older builds.
- So the repo must be rebuilt whenever Omarchy advances its snapshot: a CI job in an Arch container that runs `regen-pkgbuilds.sh` against the snapshot's PKGBUILDs, then `build-all.sh`, signs and publishes. Until that exists, an `omarchy update` after Omarchy advances its snapshot can pull Hyprland-library bumps our packages weren't built against.
  - Interim options: `IgnorePkg` the hypr* libraries (updates then stop with a dependency error instead of breaking the desktop), or rebuild locally with `build-all.sh`.

---

## 1. Target architecture

```
┌──────────────────────────── Windows ─────────────────────────────┐
│  cmd / PowerShell / Terminal                                      │
│      │  omarchy            (exit code propagates back)             │
│      ▼                                                             │
│  omarchy.exe  ── launcher: install/update distro, start session    │
│   ├─ viewer: one borderless full-screen window per monitor         │
│   │   D3D11 flip-model swapchain, dirty-rect texture updates,      │
│   │   Win32 hardware cursor from the compositor's cursor image     │
│   ├─ input: WH_KEYBOARD_LL (Super/Alt+Tab etc. while focused),     │
│   │   Raw Input mouse (absolute + relative), scancode → evdev      │
│   ├─ clipboard (AddClipboardFormatListener), per-monitor DPI,      │
│   │   monitor hot-plug, focus/escape hatch                         │
│   └─ transport client: hvsocket control+input  |  frames via       │
│        shared-memory section (DAX) or hvsocket stream              │
└───────────────▲──────────────────────────────────▲──────────────┘
                │ AF_HYPERV (VM ID + port GUID)     │ OpenFileMapping("WSL\<VMID>\wslg\…")
════════════════╪══════════════ WSL2 VM ═══════════╪════════════════
┌───────────────┴───── "Omarchy" distro (Arch) ────┴───────────────┐
│  womarchy-session  (started by omarchy.exe via wsl.exe)           │
│   └─ uwsm start … Hyprland (hyprland-womarchy)                    │
│       ├─ aquamarine-womarchy                                      │
│       │    shm/memfd allocator (no DRM)                           │
│       │    "wsl" backend: outputs = Windows monitors, frames →    │
│       │    transport, input devices, cursor, vblank from viewer   │
│       ├─ GL renderer on EGL surfaceless → Mesa d3d12 → /dev/dxg   │
│       │    render to FBO → damage-only readback into frame ring   │
│       └─ Omarchy 4 (quickshell shell, owe, foot, chromium, …)     │
│  clients: GL/Vulkan via Mesa d3d12/dzn → wl_shm (GPU + readback)  │
│  audio: PipeWire → pulse-tunnel → WSLg PulseServer (phase 1)      │
│  womarchy-clipd: ext-data-control ↔ viewer                        │
└───────────────────────────────────────────────────────────────────┘
```

**Design rules:**
- Keep every Linux-side change generic ("DRM-free mode", "shm allocator", "stream backend"), so it has a chance upstream and survives rebases.
- Omarchy itself is **not forked**. We install the real packages and add an overlay.
- The transport is pluggable (hvsocket stream, DAX shared memory, localhost TCP for debugging), and the viewer negotiates it.

---

## 2. Repositories and forks

| Repo | Action | Contents |
|---|---|---|
| `womarchy` (this repo, monorepo) | **new** | docs, lab, patch queues, PKGBUILDs, overlay, image builder, Windows app, protocol spec |
| `hyprwm/aquamarine` | **fork** → `womarchy/aquamarine`, branch `womarchy/v0.15.x` rebased on each release tag | shm allocator, no-DRM start, Wayland-backend version clamp and wl_shm output, "wsl" stream backend |
| `hyprwm/Hyprland` | **fork** → `womarchy/Hyprland`, branch `womarchy/v0.56.x` | DRM-free EGL init, shm render target with damage readback, async readback, backend-type plumbing |
| Mesa | **patch in a PKGBUILD** (no fork); upstream merge request | d3d12 slab/reclaim deadlock fix (+ any further d3d12 fixes) |
| `omacom/omarchy` | **no fork**; optional small upstream PRs (WSL guards) | — |
| `microsoft/WSL`, `microsoft/wslg` | **no fork**; file issues if needed (for example shared-memory API) | — |
| `archlinux/archlinux-wsl` | vendor its image recipe | `.wsl` build scripts |

Proposed layout of this repo:

```
docs/            FEASIBILITY.md, PLAN.md, ARCHITECTURE.md, PROTOCOL.md, research/
lab/             reproducible experiments (isolated lab distro)
patches/         aquamarine/, hyprland/, mesa/  (quilt-style queues, CI-tested)
linux/
  packages/      PKGBUILDs: aquamarine-womarchy, hyprland-womarchy, mesa-womarchy,
                 womarchy-compat, womarchy-session, womarchy-clipd
  overlay/       womarchy-apply-system, wsl/*.sh leaves, user overlay templates, hooks
  image/         .wsl image builder (archlinux-wsl recipe + Omarchy + overlay)
windows/         omarchy.exe (Rust, windows-rs): launcher, viewer, input, clipboard
protocol/        WDP (womarchy display protocol) spec + shared message definitions
ci/              GitHub Actions: patch-queue rebuilds, image build, Windows build
upstream/        (git-ignored) shallow clones for reference
```

**Language choice for the Windows app:** Rust with `windows-rs`. That gives D3D11/DXGI, Win32 hooks, AF_HYPERV sockets and memory safety for a process that holds a global keyboard hook. The cargo toolchain is already on the dev machine. The alternative is C++/Win32 if a D3D sample base is preferred.

---

## 3. Phases

The effort figures assume one experienced engineer, and some phases can overlap. Every phase ends with a demo and an explicit acceptance check.

### Phase 0 — Foundations and de-risking spikes (1–2 weeks)

Each spike that touches the shared WSL VM is flagged ⚠ and needs the user's approval first (see §7).

| ID | Task | Acceptance |
|---|---|---|
| P0.1 | Repo hygiene: `git init`, `.gitignore` (`upstream/`, build outputs), CI skeleton, license decision | CI green on an empty build |
| P0.2 | **Spike: DRM-free Hyprland boot.** Minimal aquamarine shm allocator plus Hyprland surfaceless EGL plus a framebuffer render target with sync readback; headless output. No kernel module needed. | `grim` screenshot of a headless Hyprland output with `GL_RENDERER = D3D12 (…)`, on stock WSL, without vgem |
| P0.3 | **Mesa d3d12 deadlock fix validation.** Build Mesa 26.2.x with the patch (throttled: `nice -n19`, `-j4`, only when the user approves the build window) ⚠ perf; write a standalone reproducer | Reproducer hangs on stock Mesa and passes with the patch; Hyprland survives 1 h of notifications and text rendering |
| P0.4 | **Client compatibility matrix** under DRM-free Hyprland: foot, alacritty, kitty, Quickshell (Qt6 Quick), GTK4 (GL), Chromium/Electron (Wayland ozone), mpv, owe, Xwayland apps, a Vulkan app | Table of works / degraded / broken, with flags for each |
| P0.5 | **Spike: shared-memory frames.** Mount WSLg's section-backed virtio-fs share (`wslg` tag, DAX) in the Omarchy distro, create a file, and open it from Windows with `OpenFileMappingW("WSL\<VMID>\wslg\<name>")`. ⚠ This touches a VM-wide device that WSLg uses for all distros, so it needs **explicit user approval**. Run it when no other GUI apps are open, with a fallback plan. | Windows reads bytes written by Linux, zero-copy; no effect on WSLg apps in other distros |
| P0.6 | **Spike: viewer skeleton.** Rust window + D3D11 swapchain + AF_HYPERV connect + LL hook that captures Win, with an escape hatch (Ctrl+Alt+End releases the hook) | Win-key presses arrive in the lab; Win+L still locks; no stuck keys after focus changes |
| P0.7 | Measure readback on other GPUs (AMD, Intel iGPU) if hardware is available | Numbers added to FEASIBILITY §3 |

**Exit criterion:** DRM-free Hyprland renders on stock WSL, and both transports are proven. If P0.5 fails, the hvsocket stream (with compression) is the frame transport.

### Phase 1 — DRM-free GPU Hyprland (3–4 weeks)

**aquamarine** patch queue, to be kept generic and upstream-friendly:
1. `CShmAllocator`/`CShmBuffer` (memfd; `shm()`, `beginDataPtr()`, `AQ_ALLOCATOR_TYPE_SHM`), plus the `Swapchain` format fallback.
2. `CBackend::start`: when no backend exposes a DRM fd, use the shm allocator (opt-in `AQ_ALLOW_NO_DRM=1`, then automatic).
3. Wayland backend: clamp bind versions to what the parent advertises; `zwp_linux_dmabuf_v1` optional; `wl_shm` output buffers (the #228 ask). Needed for milestone M2.
4. Keep the lab patches 0001–0003 (headless render node, primary-node allocator, implicit GBM fallback) only as an optional path for kernels that still have vgem.

**Hyprland** patch queue:
1. `CHyprOpenGLImpl`: when there is no DRM fd, use `EGL_PLATFORM_SURFACELESS_MESA` (or the software `EGLDevice`), keep the GLES 3.2 → 3.0 fallback, and skip GBM.
2. `CGLShmRenderbuffer`: a framebuffer texture per swapchain buffer. At `endRender`, read back **only damaged rectangles** (`GL_PACK_ROW_LENGTH`, BGRA) into the buffer's mapping.
3. Async pipeline: overlap readback of frame N with rendering of N+1 (fence + deferred commit). PBO mapping was slow on d3d12 (E6), so benchmark direct `glReadPixels` into the transport buffer against staging textures.
4. `cursor:no_hardware_cursors` default in DRM-free mode (until the wsl backend supports cursor planes); `linux-dmabuf` stays off automatically (no DRM device); sysinfo/backend strings.

**Packaging:**
- `aquamarine-womarchy` and `hyprland-womarchy`: `provides`/`conflicts` with Arch's packages, pinned to Omarchy's versions.
- `mesa-womarchy`: Arch mesa plus our patch.
- Published in a `[womarchy]` pacman repo (GitHub Releases or Pages, signed).

**CI:** build the patch queues against each new upstream tag, and run a headless smoke test in a container (EGL surfaceless + llvmpipe) to catch regressions.

**Acceptance (M1):** On stock WSL (2.9+/3.0, no DRM), Omarchy's Hyprland config runs headless for 24 h with the Quickshell shell, foot and Chromium open. The renderer is D3D12. Screencopy frames are correct. A soak test shows no leaks.

### Phase 2 — Omarchy WSL overlay and distro image (2–3 weeks; parallel with Phase 1)

1. **`womarchy-compat`** package: `provides/conflicts = limine limine-mkinitcpio-hook limine-snapper-sync snapper`. It carries `/usr/lib/womarchy/*`.
2. **Repos:** Omarchy `pacman-stable.conf` + mirrorlist + `omarchy-keyring`; `IgnorePkg = linux linux-* *-dkms linux-firmware*`; the `[womarchy]` repo placed before `[extra]`.
3. **`womarchy-apply-system`** (about 50 lines): same environment and logging as `omarchy-apply-system`, iterating upstream `install/*/all.sh` through a skip list:
   - skip `config/snapper.sh`, `config/enable-services.sh` (replaced), `config/firewall.sh` (opt-in), all of `hardware/`, and `login/`;
   - then run the WSL leaves: `wsl/enable-services.sh` (docker optional; mask NetworkManager, resolved, networkd, sddm, cups, avahi, power-profiles), `wsl/gpu.sh`, `wsl/audio.sh` (PipeWire pulse-tunnel), `wsl/keyboard-locale.sh` (vconsole/locale from Windows), `wsl/docker-dns.sh`.
4. **User finalize:** upstream `omarchy-provision-user --first-install` with `OMARCHY_SETUP_CONTEXT=wsl`, then the WSL user overlay:
   - `~/.config/uwsm/env.d/10-womarchy`: `GALLIUM_DRIVER=d3d12`, `GSK_RENDERER=ngl`, backend env;
   - `~/.config/hypr/bindings.lua`: rebind Super+L → Super+Alt+L and Ctrl+Alt+Del → Super+Ctrl+Alt+Backspace; keep Win-chord bindings;
   - `~/.config/omarchy/shell.json`: idle lock off; drop the Wi-Fi, Bluetooth, battery and power widgets;
   - `~/.config/omarchy/extensions/omarchy-menu.jsonc`: Shutdown → "Exit to Windows", hide suspend/hibernate/firmware/snapshots;
   - `monitors.lua` generated from the viewer's monitor list (scale from Windows DPI);
   - remove `no-animations` once GPU mode is confirmed;
   - hooks `post-update.d` / `pre-refresh-pacman.d` reassert WSL invariants and silence the kernel-reboot prompt.
5. **`womarchy-session`:**
   - ensures the systemd user manager is running (`loginctl enable-linger` fallback) and `XDG_RUNTIME_DIR`;
   - sets the env;
   - writes the session handshake (VM ID, port, token) to stdout for the launcher;
   - `exec uwsm start -g -1 -e -D Hyprland hyprland.desktop`.

   The exit status propagates.
6. **Image builder** (`linux/image/`), using the archlinux-wsl recipe:
   - pacstrap base + Omarchy + the womarchy packages; apply-system; unit masks;
   - `/etc/wsl.conf`: `systemd=true`, `[user] default`, interop on;
   - `/etc/wsl-distribution.conf`: OOBE creates the user; **UID chosen to avoid collisions on WSL ≤ 2.7**; `defaultName=Omarchy`; icon; Windows Terminal template;
   - output `Omarchy-<omarchy-ver>-<womarchy-ver>.wsl` (xz), reproducible, signed.
7. **CI audit job:** on each Omarchy release tag, diff every `install/*/all.sh` and new `migrations/*` against the skip list and flag unclassified leaves.

**Acceptance (M2, "developer preview"):**
- `wsl --install --from-file Omarchy.wsl` then `wsl -d Omarchy -- womarchy-session --wslg` shows the complete Omarchy desktop, GPU-composited, in a full-screen WSLg window (Wayland-backend path).
- This is usable daily, except for the Win key.
- `omarchy update` runs cleanly.

### Phase 3 — Windows viewer + "wsl" backend (5–7 weeks)

1. **WDP v1 spec** (`protocol/`):
   - **Control:** hello/auth token, capabilities, transport negotiation.
   - **Outputs:** the viewer announces monitors (position, size, refresh, DPI), and the compositor may accept or adjust.
   - **Frames:** buffer ring descriptors, damage rectangles, present/ack for back-pressure, vblank timestamps.
   - **Cursor:** image and hotspot, position mode.
   - **Input:** keyboard as evdev keycodes plus lock state; pointer (absolute/relative, buttons, axis with high-res wheel); touch/pen later.
   - **Clipboard:** offers and data, lazy transfer.
   - **Session:** exit request and reason, keep-alive.
2. **aquamarine `CWslBackend`**, a new backend type (generic name: "stream"):
   - an output per announced monitor; a swapchain on the shm allocator; `commit` publishes damage and the buffer index;
   - frame pacing from viewer acks and vblank (no timer guessing);
   - `IKeyboard`/`IPointer` devices fed from WDP input;
   - `setCursor` sends cursor images, so the viewer shows a native Windows cursor with zero added latency;
   - output hot-plug and mode changes; clean shutdown when the viewer disconnects (with an optional grace period for reconnect).
3. **Frame transport, both implemented behind one interface:**
   - (a) hvsocket stream of damage rectangles with optional LZ4;
   - (b) DAX shared-memory ring (if P0.5 passed): readback writes straight into the section, and the viewer uploads from the same pages. That removes one CPU copy and the hvsocket bandwidth limit.
4. **`omarchy.exe` viewer:**
   - per-monitor borderless full-screen windows, DXGI flip-discard with a waitable frame-latency object, and a present-to-ack loop;
   - per-monitor DPI v2;
   - dirty-rect `UpdateSubresource` (or a persistently mapped `D3D11_USAGE_DYNAMIC` staging texture);
   - optional windowed mode (Super+Ctrl+Alt+F style toggle handled locally).
5. **Input:**
   - `WH_KEYBOARD_LL` active only while an Omarchy window is the foreground window. It swallows Win, Alt+Tab, Alt+Esc and Ctrl+Esc and forwards them.
   - Scancode → evdev mapping, respecting the Windows keyboard layout. The XKB layout is set to match, and Omarchy reads `/etc/vconsole.conf`.
   - Raw Input for high-resolution mouse and relative motion (pointer-constraints for games).
   - IME: pass-through (fcitx5 runs on the Linux side).
   - **Escape hatch:** Ctrl+Alt+End (or a configurable chord) releases capture and minimises. Win+L and Ctrl+Alt+Del stay with Windows.
6. **Lifecycle:**
   - `omarchy` → spawns `wsl.exe -d Omarchy -e womarchy-session --viewer` with pipes → reads the handshake → connects → shows windows.
   - Logout → Hyprland exits → the session exits → `wsl.exe` exits → the viewer closes and returns the exit code.
   - If the viewer is closed with Alt+F4 or from the taskbar, it asks, then sends a session exit request.
   - Crash handling: if the viewer dies, the session gets a grace period, then logs out cleanly.
7. **Clipboard:** `womarchy-clipd` in the session (ext/wlr-data-control) ↔ WDP ↔ Win32 clipboard; text, HTML, images; lazy transfer for large data.

**Acceptance (M3, "1.0 beta"):**
- From cmd, `omarchy` shows the desktop full-screen on all monitors within 5 s of a warm start.
- Super bindings work.
- Clipboard works both ways.
- 60 Hz animations at 4K single monitor, and at 1440p on all monitors.
- Logout returns to cmd with `%ERRORLEVEL% == 0`.
- No input stuck after Alt+Tab, lock/unlock, or sleep/resume of Windows.

### Phase 4 — Integration polish and performance (3–4 weeks)

- **Audio:** PipeWire pulse-tunnel to WSLg PulseServer by default. Optional native path: PCM over WDP to WASAPI (lower latency, and allows running with `guiApplications=false` for this distro only).
- **HiDPI:** fractional scales from Windows DPI, per-monitor; Xwayland zero-scaling; cursor size sync.
- **Video:** hardware decode via VA-API on the X11 display type or NVDEC (CUDA) in mpv/Chromium; verify owe (the mpv wallpaper engine) cost.
- **Browser/Electron GPU acceleration:** settle flags per the Phase 0 matrix; web apps (`chromium --app`) are Omarchy's backbone.
- **Performance:**
  - async readback pipeline; readback straight into DAX pages;
  - 120/144 Hz support where the monitor has it;
  - frame pacing against the monitor's DWM vblank;
  - idle cost near zero: no damage means no readback and no transport, and the viewer waits on events.
- **Optional zero-copy for GPU clients (research):** d3d12 shared-handle fds exchanged through a private Wayland protocol, removing the client readback plus the compositor upload.
- Windows integration niceties: Start-menu shortcut, taskbar icon, "open in Windows" helpers, `/mnt/c` in the file manager.

**Acceptance:**
- Audio latency under 60 ms;
- 4K video at 60 fps plays smoothly;
- idle CPU under 1% for both the Windows and Linux side;
- published benchmark table on reference hardware.

### Phase 5 — Packaging, distribution, updates, QA (2–3 weeks)

- **Installer:** `omarchy.exe install [--location] [--name]`. It checks the WSL version (≥ 2.9 recommended; warns on 2.7 about the UID caveat), downloads and verifies the signed `.wsl`, runs `wsl --install --from-file`, and creates the Start-menu shortcut. `omarchy uninstall` runs `wsl --unregister` after confirmation.
- **Distribution:** GitHub Releases, then a winget manifest. The `.wsl` is also usable standalone.
- **Updates:**
  - Omarchy itself through `omarchy update`;
  - womarchy compositor packages through the `[womarchy]` repo (same update run);
  - `omarchy.exe` self-update check.
- **Test matrix:**
  - GPUs: NVIDIA (RTX 30/40/50), AMD (RDNA2/3/4), Intel (Xe iGPU, Arc);
  - displays: 1/2/3 monitors, 100/125/150/200% DPI, mixed DPI;
  - WSL: 2.7.x, 2.9.x, 3.0.x;
  - keyboard layouts: US, UK, DE, FR, JP (IME);
  - scenarios: sleep/resume, RDP into the Windows host, Windows lock/unlock.
- **Documentation:** install guide, keybinding differences, troubleshooting, and a "how it works" architecture page.

**Acceptance (1.0):** a clean install on 3 different GPU vendors passes the scripted end-to-end test (launch → apps → clipboard → audio → logout → exit code). No global WSL changes are made.

### Phase 6 — Upstreaming and sustainability (ongoing)

- **Mesa:** submit the d3d12 deadlock fix as an upstream merge request, plus any further d3d12 fixes found.
- **aquamarine and Hyprland:** propose the generic pieces:
  - aquamarine: shm allocator and no-DRM start (issue [#228](https://github.com/hyprwm/aquamarine/issues/228)), and the bind-version clamp ([#398](https://github.com/hyprwm/aquamarine/issues/398));
  - Hyprland: DRM-free EGL and shm render target, useful for CI and VMs without render nodes.

  These must be written and filed by humans, per hyprwm's AI-usage policy. Whatever isn't merged stays in our patch queue.
- **Omarchy:** optionally upstream `omarchy-hw-wsl` detection plus a few one-line guards. The overlay does not depend on it.
- **Microsoft:** file feedback for a supported shared-memory or GPU-surface presentation API for user distros, and for Win-key passthrough in WSLg.

---

## 4. Milestones and timeline

| Milestone | Content | Target (cumulative) |
|---|---|---|
| M0 | Spikes pass: DRM-free Hyprland on stock WSL; transport proven | week 2 |
| M1 | DRM-free GPU Hyprland packages; 24 h headless soak | week 5 |
| M2 | **Developer preview:** Omarchy `.wsl` + GPU desktop in a full-screen WSLg window | week 6 |
| M3 | **1.0 beta:** `omarchy.exe` viewer, Win key, multi-monitor, clipboard, prompt↔desktop lifecycle | week 12–13 |
| M4 | Polish: audio, HiDPI, video, performance targets | week 16–17 |
| M5 | **1.0:** installer, updates, test matrix, docs | week 19–22 |

---

## 5. Performance targets and budgets

Measured components are from [FEASIBILITY §3](FEASIBILITY.md#3-experiments-and-results-reference-machine) (RTX 5070):

| Frame stage (4K, full damage worst case) | Budget | Measured / basis |
|---|---|---|
| Composition (GPU, with effects) | ≤ 2 ms | 1.0 ms (6-pass blur) |
| Readback (damage only; full frame worst case) | ≤ 6 ms | 5.4 ms full, 0.7 ms per small rectangle |
| Transport | ≤ 2 ms (DAX: 0 copies) / ≤ 8 ms (hvsocket + LZ4) | 1.2–1.6 GB/s raw hvsocket |
| Viewer upload + present | ≤ 3 ms | to measure (D3D11 `UpdateSubresource` of dirty rectangles) |
| **Total added latency** | **≤ 1 frame beyond native** | target input-to-photon 20–35 ms at 60 Hz |
| Input event (Windows → Hyprland) | < 0.3 ms | 92 µs round trip median |
| Idle (static desktop) | ~0% CPU, 0 GPU readbacks | damage-driven design |

---

## 6. Test strategy

- **Unit/integration (Linux):** aquamarine allocator and backend tests; Hyprland headless smoke tests in CI (llvmpipe, surfaceless); WDP codec tests.
- **Lab end-to-end (WSL):** scripted launch, client matrix, pixel checks via screencopy, soak tests (24 h), latency probe (viewer injects input and timestamps the first changed frame).
- **Windows:** viewer unit tests; input-mapping tables per layout; hook-safety tests (no stuck keys, hook removed on crash or focus loss); DPI and hot-plug tests.
- **Performance regression:** per-release benchmark (readback, fps at 1080p/4K, idle CPU) stored in CI artifacts.
- **Safety:** tests verify that nothing global is modified. Snapshot `.wslconfig`/`.wslgconfig`, the registry keys WSL uses, and other distros' state before and after install, launch and uninstall.

---

## 7. Operating rules for development on the user's machine

The user's other WSL distros must never be affected, and system performance must not degrade.

1. **All experiments run in the isolated `womarchy-lab` distro** (stored at `D:\WSL\womarchy-lab`), in user space. The lab is **stopped whenever not in use** (`wsl --terminate womarchy-lab` affects only the lab).
2. **Never without explicit approval:**
   - loading kernel modules (VM-global, e.g. vgem);
   - `.wslconfig` / `.wslgconfig` / custom kernel / `systemDistro`;
   - mounting WSLg's shared-memory share (P0.5);
   - `wsl --shutdown` or `wsl --update`;
   - touching other distros;
   - Windows settings or registry;
   - heavy builds (they share the VM's CPU and RAM with the user's distros).
3. **Heavy builds** (Mesa, Hyprland), when approved, run throttled (`nice -n19`, `-j4`) at an agreed time. Prefer building in CI (GitHub Actions) and downloading packages instead.
4. **Known interaction on WSL 2.7.x:** all systemd distros share one cgroup tree. The lab's user must not share a UID with a user of another running systemd distro. The lab currently uses uid 1000, which collides with the default distro's user. Change it (for example to 1789) before the lab is used again, or keep the lab's systemd user session unused.
5. Before any step that could affect the user's WSL or performance, **ask first**.

---

## 8. Open questions for the user

1. **WSL version policy.** Target WSL ≥ 2.9/3.0 (DRM-free kernel, cgroup isolation), keeping 2.7 as best effort? Your machine is on 2.7.10, and 3.0.1 shipped yesterday. We will **not** update WSL for you.
2. **Build location.** OK to build packages in GitHub Actions (a public or private repo under your account) instead of on this machine?
3. **Spike P0.5** (WSLg shared-memory mount): approve running it in a controlled window, or skip it and rely on hvsocket plus compression?
4. **Lab distro.** Keep `womarchy-lab` on `D:\WSL\womarchy-lab` (stopped) for Phase 0, or remove it (`wsl --unregister womarchy-lab`)?
5. **Scope of 1.0.** Full Omarchy app set, or a "lite" profile first (skipping LibreOffice, Kdenlive, OBS…)?
