# Research reports

These are the deep-dive reports behind [FEASIBILITY.md](../FEASIBILITY.md) and [PLAN.md](../PLAN.md). They were written on 2026-09-30 from source reading, primary docs and web research. The clones they cite are in `upstream/`, which is git-ignored.

| Report | Scope |
|---|---|
| [01-omarchy.md](01-omarchy.md) | Omarchy 4 (package-based) install flow, every install step classified for WSL, keybinding conflicts with Windows, overlay strategy, prior WSL ports |
| [02-hyprland-aquamarine.md](02-hyprland-aquamarine.md) | aquamarine backends and allocators, the Hyprland renderer's DRM/GBM/dmabuf requirements, exact failure points, patch options (a)–(e) with LOC estimates |
| [03-wsl-wslg-mesa.md](03-wsl-wslg-mesa.md) | WSLg frame path and knobs, WSL packaging and config, hvsocket and DAX shared memory, Mesa d3d12/dzn on WSL, dxgkrnl sharing, kernel DRM removal |
| [04-prior-art-architectures.md](04-prior-art-architectures.md) | Prior art, streaming stacks, Win-key capture, compositors without DRM, architecture comparison with estimates |

## Corrections from lab verification

The reports were written without running anything, while the lab experiments ran in parallel. Where the two disagree, the lab result wins.

1. **vgem + d3d12 GBM (reports 02 §5.2/§8b and 03 §3.3 say it "does not work").**
   - With Mesa 26.2.3 on the reference machine, EGL on `kms_swrast` + `GALLIUM_DRIVER=d3d12` advertises `EGL_EXT_image_dma_buf_import(_modifiers)` and `EGL_MESA_image_dma_buf_export`.
   - `gbm_bo_create(…, GBM_BO_USE_RENDERING)` succeeds and returns a valid fd; `SCANOUT`, `LINEAR` and explicit modifiers fail.
   - `eglCreateImage` of that fd works, and Hyprland rendered frames into such buffers (lab E3/E4).
   - Most likely explanation (consistent with 03 §3.3, last bullet): the fds are dxgkrnl shared-handle fds that d3d12 can re-import, not true dmabufs. So this works *within* d3d12 processes only.
   - It is moot for the product, because the WSL ≥ 2.9 kernel has no DRM at all. It remains useful as a lab path, and as evidence for the future "d3d12 shared-handle zero-copy client" optimisation.
2. **"The WSL 6.18.33.2 kernel ships `vkms.ko`"** (report 01 §11) is **wrong for x86_64.** `/proc/config.gz` shows `# CONFIG_DRM_VKMS is not set`; only `vgem.ko` exists. VKMS is arm64-only in those kernels (report 03 §2.4).
3. **"linux-msft-wsl-6.18.y: CONFIG_DRM not set"** (report 04 §0 table) is **too broad.** 6.18.33.2 (WSL 2.7.x, the reference machine) has `CONFIG_DRM=y` and `CONFIG_DRM_VGEM=m` (verified). DRM was removed in 6.18.40.1 (WSL 2.9.x/3.0.1) by commit `7e83488bd5`, as report 03 states correctly.
4. **Async PBO readback** (02 §8c v2, 04 §10.1) is **slower** than synchronous `glReadPixels` on d3d12: 25.8 ms against 5.4 ms at 4K, because mapping the readback buffer is slow (lab E6). The async design must use something else, for example a fence plus deferred readback, or a staging texture.
5. **The systemd user session on WSL 2.7.x** is not covered by the reports.
   - All distros share one cgroup namespace, so two systemd distros whose users share a UID fight over `/user.slice/user-<uid>.slice`. The second one's `user@<uid>.service` fails with `EBUSY` (lab E8).
   - WSL 2.9.13+ adds `wsl2.isolateDistroCgroup` (default `true`), which fixes this.
6. **Mesa d3d12 slab/reclaim self-deadlock** (lab E5) is a new finding and is not in the reports. The fix is in `patches/mesa/`.
