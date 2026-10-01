# Architecture

How `omarchy` on Windows turns into a GPU-composited Hyprland desktop running in WSL, and back. For the
reasoning behind the design see [FEASIBILITY.md](FEASIBILITY.md); for the wire format see
[protocol/wdp.h](../protocol/wdp.h).

```
 Windows                                              WSL 2 VM (the "Omarchy" distro)
 ───────                                              ──────────────────────────────
 omarchy.exe                                          womarchy-session  (started by omarchy.exe via wsl.exe)
  ├─ one borderless window per monitor                  └─ uwsm start hyprland.desktop  (like a display manager)
  ├─ one presenter thread per output                        └─ Hyprland (patched)
  │    D3D11 device, flip-model swapchain                       ├─ renders on the GPU: EGL surfaceless
  │    maps each output buffer once  ◀── shared memory ──┐      │  → Mesa d3d12 (patched) → /dev/dxg
  ├─ reader thread  ◀──── frames, cursor, outputs ───┐   │      ├─ reads back damaged pixels into
  ├─ input sender   ────── keys, pointer, focus ────▶│   │      │  shm buffers on /mnt/wslgshm (DAX)
  ├─ keyboard hook thread (Super, Alt+Tab, ...)      │   └──────┤
  └─ clipboard thread  ◀──── text ────▶ womarchy-clipd  hvsocket└─ aquamarine "wsl" backend (new)
                                       (Wayland data-control)  (AF_HYPERV ↔ AF_VSOCK)
```

## Components

| Component | Where | What it does |
|---|---|---|
| `omarchy.exe` | [windows/omarchy](../windows/omarchy) (Rust) | Viewer, launcher and installer. Starts the session, shows outputs, forwards input, syncs the clipboard, follows display changes. Also `install`, `uninstall` and `status`. |
| aquamarine `wsl` backend | [patches/aquamarine](../patches/aquamarine) | A new aquamarine backend. Its outputs are what the viewer reports as monitors. It listens on hvsocket, authenticates the viewer, sends frames and cursors, and turns viewer input into libinput-like events. |
| aquamarine shm allocator | same | CPU output buffers for backends without DRM: files on WSLg's DAX share, or memfd. |
| Hyprland patches | [patches/hyprland](../patches/hyprland) | Composite without DRM (surfaceless EGL), read damaged regions back into shm buffers, CPU cursor buffers, screen capture without dmabuf, per-output absolute pointer motion. |
| Mesa patches | [patches/mesa](../patches/mesa) | d3d12 driver: a deadlock fix, and write-back upload heaps on WSL 3.0.1 (write-combine heaps run at ~9 MB/s there). |
| `womarchy-session` | [linux/packages/womarchy-session](../linux/packages/womarchy-session) | The session entry point (plus `womarchy-clipd`, the DAX mount unit and the X11 socket fix). |
| Omarchy overlay and image | [linux/overlay](../linux/overlay), [linux/image](../linux/image) | Builds the `.wsl` image: Arch + Omarchy 4 + `[womarchy]` packages + WSL adaptations (first-run setup, keyboard/locale from Windows, services that make no sense in WSL turned off, update hooks that keep it all applied). |

## Session lifecycle

1. **Start.** `omarchy` (Start menu or prompt) creates a "starting" window on each monitor and installs its keyboard hook. It then runs:
   ```
   wsl.exe -d Omarchy --exec womarchy-session
   ```
   Secrets travel in the environment via `WSLENV`, never on a command line: two random 32-byte tokens (display and clipboard), a random vsock port, and the monitor layout (`WOMARCHY_MONITORS`).
2. **Session.** `womarchy-session`:
   - takes a per-user lock (one desktop at a time);
   - registers a logind session;
   - writes Hyprland monitor rules from the Windows layout: positions, and scales snapped to values Hyprland accepts;
   - prints the VM id (`WOMARCHY_VMID=...`);
   - runs `uwsm start hyprland.desktop` with `HYPRLAND_BACKEND=wsl`.

   On a freshly imported distro it instead exits with code 75 (`WOMARCHY_NEEDS_SETUP`). `omarchy.exe` then runs the first-run setup in the console (user name, password) and starts over.
3. **Connect.** Hyprland's `wsl` backend listens on the port. `omarchy.exe` connects over hvsocket (no admin rights; works under any network mode) and sends `HELLO` with the first half of the token. The compositor answers `WELCOME` with the second half, and the viewer refuses to send anything until that proof checks out. The viewer then sends `MONITORS`. The clipboard connects the same way on the next port, to `womarchy-clipd`.
4. **Run.** For each output the compositor sends:
   - `OUTPUT` (its size);
   - `FRAME` messages naming the shared-memory buffer that holds the frame and its damage rectangles (max 64; more become one bounding box);
   - `CURSOR` when the cursor image changes.

   The viewer maps each buffer once, copies the damaged rectangles into a D3D11 texture, presents it, and answers `FRAME_DONE`. The compositor renders that output's next frame only after the ack (one frame in flight per output), at most at the monitor's refresh rate.
5. **End.** Logging out of Hyprland ends `uwsm`; the backend sends `BYE` and `womarchy-session` exits with the compositor's status, which `omarchy.exe` returns to the prompt. Closing the viewer sends `QUIT`. If the viewer dies, the compositor exits after an orphan timeout, and the session stops anything that still runs.

## Frames: zero-copy shared memory

- WSLg already exports a virtio-fs share with DAX (tag `wslg`) to every WSL 2 VM, and Windows can open its files as named sections (`OpenFileMappingW("WSL\<vm id>\wslg\<name>")`).
- The image mounts it a second time at `/mnt/wslgshm` (`mnt-wslgshm.mount`; WSLg's own mount is left alone). The shm allocator creates each output buffer there, so the bytes Hyprland reads back are the bytes the viewer uploads, with no copy across the VM boundary.
- Without the share (another WSL setup, or for testing), the backend falls back to sending pixels inline over the socket.

Costs worth knowing (measured, see [WORKLOG.md](WORKLOG.md)):
- **First touch.** The first write to a DAX page is several hundred times slower than later ones, and the cost grows with the amount already mapped. Buffers are therefore written once when allocated, and shm swapchains have two buffers, not three. Three 4K outputs went from ~15 s to start to a few seconds.
- **Readback.** Hyprland renders on the GPU, then `glReadPixels` copies only damaged regions into the shm buffer: ~5 ms for a full 4K frame, well under 1 ms for typical damage. An idle desktop sends nothing.

## Input

- **Keyboard:** a low-level keyboard hook runs on its own thread. It forwards keys only while one of our windows has focus, so Super, Alt+Tab and similar reach Hyprland. Windows keeps Win+L and Ctrl+Alt+Del. Ctrl+Alt+End minimises the desktop (the escape hatch).
- **Keymap:** keys are sent as Linux evdev codes; the layout is applied in Linux (XKB, set from Windows' layouts at first run).
- **Mouse:** absolute positions per output, plus buttons and wheel. Hyprland maps an output's absolute motion onto that monitor (patch 0005), so the pointer moves between monitors exactly as Windows moves it between windows.
- **Cursor:** the cursor is drawn by Windows: the compositor sends cursor images, and the viewer turns them into native cursors. It never lags behind the frames.

## Display changes and DPI

`omarchy.exe` is per-monitor DPI aware.
- **DPI:** each Windows monitor's scale (e.g. 150%, 175%) becomes a Hyprland monitor scale, snapped to one that divides the mode cleanly (175% at 3840 px becomes 1.667).
- **Layout:** placement keeps Windows' left-to-right order without overlaps.
- **Display changes** (`WM_DISPLAYCHANGE`, `WM_DPICHANGED`), e.g. plugging in a monitor or changing a scale: the viewer re-reads the layout, keeps output ids stable by device name, sends `MONITORS`, and regenerates the monitor rules (`womarchy-session --update-monitors`).

## Threads in omarchy.exe

| Thread | Job |
|---|---|
| UI (main) | Window messages, creating cursors, display-change notifications. Never blocks on the network. |
| Keyboard hook | `WH_KEYBOARD_LL` hook on its own message loop, so slow work elsewhere can't make Windows drop it. |
| Input sender | Sends queued input (an mpsc channel) over the socket. |
| Reader | Reads messages and hands each frame to its output's presenter. |
| Presenter (one per output) | Owns its D3D11 device and swapchain (`SetMaximumFrameLatency(1)`). It uploads damage, presents, acks, and recovers from device loss by asking for a full frame (`REFRESH`). |
| Clipboard | Connects to `womarchy-clipd` and syncs text, or images (PNG) when there is no text, both ways. It converts between PNG and Windows bitmaps with Windows' own imaging component. Content marked secret by a password manager is not sent from either side. |
| Session waiter | Waits for `wsl.exe` to exit and returns its exit code. |

## Updates, rollback and signing

- **Updates.** Updates are Omarchy's own (`omarchy update` inside the distro, or the same from Windows).
  - `pacman.conf` lists our `[womarchy]` repository before Arch's. Our builds of aquamarine, Hyprland and Mesa, and our overlay package `womarchy-compat`, therefore replace the stock packages.
  - Overlay fixes arrive the same way. After each update, a hook runs `womarchy-apply-system --reassert`, which re-applies the WSL adjustments that Omarchy's update may have overwritten.
- **Keeping our builds in step with Omarchy.** Omarchy installs from a dated snapshot of Arch (`stable-mirror.omarchy.org`). When that snapshot moves Hyprland's libraries or LLVM, our builds must be rebuilt against it.
  - Our Hyprland and aquamarine packages depend on exact library versions (e.g. `libhyprutils.so=13-64`), so pacman refuses an update that would break them.
  - A pacman hook does the same for Mesa's LLVM.
  - Either way the update stops before changing anything. A daily CI job (`snapshot-watch.yml`) notices and opens an issue, and the on-demand build workflow (`packages.yml`) rebuilds against the new snapshot.
- **Rollback.** A pacman hook records the installed package list before every update (one record per update session, the newest 5 kept). `womarchy-rollback`, also run by `omarchy rollback`, reinstalls those versions:
  - from pacman's cache;
  - then from the local repository copy;
  - then, after asking, from the Arch archive and our release.

  `omarchy backup` / `omarchy restore` cover everything else, as a whole-distro export.
- **Signing.** The `[womarchy]` database and packages are signed in CI by a job that waits for a maintainer's approval; it is the only place the key exists.
  - Installed systems get the public key from the `womarchy-keyring` package and require a valid database signature (`SigLevel = PackageOptional DatabaseRequired`). Packages are verified through the checksums in that signed database.
  - Installs from before signing moved over automatically (see [INSTALL-NOTES.md](INSTALL-NOTES.md)).

## Security model

- Everything stays on the machine:
  - hvsocket connects only this Windows host and its own VM;
  - the vsock port is random per session;
  - the tokens prove both ends to each other (see [protocol/wdp.h](../protocol/wdp.h)).
- Secrets never appear on a command line; they reach the session as environment variables and are removed from the systemd user manager when the session ends.
- Nothing runs elevated:
  - no kernel modules, custom kernel or global WSL settings;
  - nothing is installed outside the distro except `omarchy.exe` (in `%LOCALAPPDATA%\Programs\Omarchy`), a Start menu shortcut and a user PATH entry.
- Images and downloads are checked against published SHA-256 sums. The `[womarchy]` package repository is signed (see above), and its local copy inside the image is root-owned and read-only.
