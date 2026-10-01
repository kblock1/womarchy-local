# Lab: experiments, benchmarks and end-to-end tests

The measurements behind the design ([docs/FEASIBILITY.md](../docs/FEASIBILITY.md), [docs/WORKLOG.md](../docs/WORKLOG.md)) and the
end-to-end tests ([docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md#tests)). Outputs go to `lab/out/` (not committed).

**Where things run.**
- Linux-side experiments run in an isolated Arch lab distro (`womarchy-lab`: the official Arch WSL image, default user `lab`), never in your everyday distros.
- The PowerShell tests run on Windows against an installed Omarchy distro (`-Distro <name>`).

**Safety.** All WSL 2 distros share one VM, kernel and cgroup tree.
- Scripts marked ⚠ touch VM-global state or load the CPU heavily. Run them only with the machine owner's approval.
- Stop the lab when you are done: `wsl --terminate womarchy-lab`. Remove it with `wsl --unregister womarchy-lab`.
- On WSL ≤ 2.7, the lab user should not share a UID with users of other running systemd distros (`setup-lab-uid.sh`; see FEASIBILITY E8).

**Running scripts.**
- Linux scripts: `wsl -d womarchy-lab -- bash <repo>/lab/<script>`.
- From Git Bash, set `MSYS_NO_PATHCONV=1` first.
- Don't pass `$vars` through `wsl.exe` inline: a login shell expands them. Put the commands in a script file.

## End-to-end tests (PowerShell, Windows)

| Script | What it checks |
|---|---|
| `viewer-test.ps1` | Windowed session: connect, frames, clean exit with the session's exit code, final frame dump. |
| `clipboard-test.ps1` | Clipboard text both ways, at connect and live (CRLF ↔ LF). |
| `gpu-clients-test.ps1` | GL (es2gears) and Vulkan (vkcube on Dozen) clients on the GPU inside the session. |
| `display-change-test.ps1` | Live monitor add/remove/resize using fake monitors (the real display settings are untouched). |
| `fullscreen-test.ps1` | Full screen on the real monitors (~1.5 min): apps on every monitor, DPI, Windows-side capture, frame rates, viewer CPU. |
| `installer-test.ps1` | `omarchy install` / `uninstall` on a throwaway distro (`omarchy-test-e2e`), without touching the user's PATH or Start menu. |
| `system-health.ps1` | After a work session: WSL settings untouched; every distro boots and reports its systemd state. |
| `correlate-frames.ps1` | Per-frame timelines, Linux (send → ack) against the viewer (receive → ack). |
| `scripts-*.txt` | `--input-script` scenarios used by the tests (tour, HiDPI, browser, X11, lock, logout, system menu, full screen). |

## Benchmarks (C / Python; build with `cc -O2`, see each file's header)

| File | Question it answers |
|---|---|
| `bench-readback.c`, `run-bench.sh` | E6: readback, upload and composition cost of a DRM-less compositor on surfaceless EGL (~30 s of GPU load). |
| `bench-upload.c`, `bench-map.c`, `bench-pbo.c`, `bench-copypattern.c`, `bench-faults.c` | Why Mesa d3d12 texture uploads are slow on WSL 3.0.1 (write-combine upload heaps; led to Mesa patch 0002). |
| `bench-dax-alloc.c` | What it costs to prepare 4K frame buffers on WSLg's DAX share, per strategy and with many buffers mapped (led to two-buffer shm swapchains). |
| `hvsock_bench.py`, `hvsock_framepace.py` | E7: hvsocket throughput, latency and frame pacing, WSL ↔ Windows. |
| `dax-spike.sh`, `dax-spike2.py`, `dax_spike_win.py` | P0.5: a user distro mapping WSLg's DAX share, and Windows opening the same memory. ⚠ mounts the VM-wide `wslg` share. |
| `mesa-texsubdata.py`, `mesa-fix-trace.py` | Edit helpers for the lab Mesa tree: an experimental d3d12 `texture_subdata` fast path, and a fix-up of a debug trace. |

## Debugging helpers

| File | Use |
|---|---|
| `sample-stacks.sh`, `strace-hypr.sh` | Poor man's profiler: sample the Hyprland main thread's stacks or blocking syscalls. |
| `debug-hang.sh`, `symbolize-hang.sh` | E5: stacks and offline symbolisation of a hang (found the d3d12 deadlock). ⚠ vgem |
| `dev-build.sh`, `build-aquamarine.sh`, `build-mesa.sh` | Build the forks into `/opt/womarchy*` in the lab, for `LD_LIBRARY_PATH` testing. Mesa: ⚠ heavy CPU. |
| `run-session.sh`, `run-hyprland.sh`, `hypr-test.conf` | Dev stand-ins for `womarchy-session` and a minimal Hyprland config for the wsl backend. |
| `hyprctl-lab.sh` | Interactive lab sessions: start a headless Hyprland, run clients in it. |
| `overlay/` | Tests for the image overlay (WSL leaves, first-run setup, repo fallback) in a throwaway chroot. |

## Early experiments (vgem; superseded by the DRM-free design)

| File | Experiment |
|---|---|
| `probe-gbm-vgem.sh`, `gbmtest.c`, `run-gbmtest.sh` | E3: GBM and EGL dmabuf behaviour on a vgem render node. ⚠ `modprobe vgem` (VM-global) |
| `test-headless.sh` | E1/E4: Hyprland headless on vgem with d3d12 GL. ⚠ vgem |
| `vgem-patches/` | aquamarine patches for that approach, kept for reference. |
