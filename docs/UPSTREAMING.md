# Upstreaming plan

womarchy should eventually be a thin layer: an image recipe, `omarchy.exe` and a session script, on top
of upstream projects that support running without DRM. This is the plan to get there. The patches
themselves are in [patches/](../patches/README.md).

## Ground rules

- **A person submits.** Every change is reviewed, understood and sent by a human maintainer of this repo, who can answer review questions. No bot-filed issues or pull requests.
- **Disclose AI assistance** the way each project asks:
  - Mesa requires `Generated-by:` trailers on AI-generated code (our patches carry `Generated-by: LLM`);
  - hyprwm projects expect disclosure in the PR description.
- **Small and independent first.** Bug fixes that stand on their own go first: they are useful to everyone, easy to review, and build trust for the larger feature patches.
- **Keep the series rebased.** Before submitting, rebase on the project's main branch:
  1. bump [patches/versions.sh](../patches/versions.sh);
  2. run `FORCE=1 tools/setup-src.sh`;
  3. re-run the end-to-end tests ([DEVELOPMENT.md](DEVELOPMENT.md#tests)).

## Order of submission

| # | Project | Change | Kind | Notes |
|---|---|---|---|---|
| 1 | Hyprland | [0004](../patches/hyprland/0004-protocols-screen-capture-without-linux-dmabuf.patch) screen capture without linux-dmabuf | crash fix | Independent. Reproducible on any setup where linux-dmabuf isn't created (e.g. software rendering). |
| 2 | Hyprland | [0005](../patches/hyprland/0005-input-absolute-pointer-motion-relative-to-the-backen.patch) absolute motion per output | bug fix | Independent. Reproducible with the Wayland backend and several outputs (nested Hyprland with two windows). |
| 3 | Mesa | [0001](../patches/mesa/0001-d3d12-reclaim-outside-pb-manager-locks.patch) d3d12 reclaim deadlock | deadlock fix | Independent. Merge request on gitlab.freedesktop.org, with the backtrace from the commit message. |
| 4 | Microsoft WSL | Issues (below) | reports | No code. |
| 5 | aquamarine | [0001](../patches/aquamarine/0001-allocator-shm-allocator-for-backends-without-DRM.patch) shm allocator | feature | Generic: it also helps headless CI and software rendering. Open an issue first to agree on the shape (memfd vs directory-backed files). |
| 6 | Hyprland | [0001](../patches/hyprland/0001-render-DRM-free-mode-surfaceless-EGL-shm-output-buff.patch) DRM-free mode, [0003](../patches/hyprland/0003-pointer-CPU-cursor-buffers-without-dmabuf.patch) CPU cursors | feature | After 5. Lets Hyprland run on any EGL-only GPU (WSL, some VMs, CI). |
| 7 | aquamarine | [0002](../patches/aquamarine/0002-backend-wsl-a-remote-viewer-backend.patch) wsl backend | feature | The biggest patch (~1600 lines) and the most WSL-specific. Ask the maintainers first whether they want an in-tree "remote viewer" backend. If not, propose a small backend plugin interface instead, and ship the backend from this repo. |
| 8 | Hyprland | [0002](../patches/hyprland/0002-compositor-select-aquamarine-s-wsl-backend-with-HYPR.patch) `HYPRLAND_BACKEND=wsl` | glue | Follows 7: trivial once the backend exists upstream. |
| 9 | Mesa | [0002](../patches/mesa/0002-d3d12-write-back-upload-heaps-on-wsl.patch) write-back upload heaps | workaround | Depends on Microsoft's answer to the upload-heap issue. If WSL fixes write-combine mappings, drop the patch. If not, propose it as a WSL-specific default. |

## Issues to report to Microsoft (microsoft/WSL, microsoft/wslg)

Each with numbers and a reproducer from `lab/`:

1. **CPU writes to D3D12 UPLOAD (write-combine) heaps run at ~9 MB/s on WSL 3.0.1**, against several GB/s for write-back heaps (measured on kernel 6.18.40.1; earlier versions not measured). This makes every Mesa d3d12 texture upload ~500x slower. Reproducers: `lab/bench-upload.c`, `lab/bench-faults.c`.
2. **`systemd-binfmt.service` fails in every systemd distro on WSL 3.0.1**: the global binfmt_misc flush is now read-only, so the distro boots `degraded`. Workaround in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#other-wsl-distros-after-the-wsl-update).
3. **`getty@tty1.service` hits its start limit** on WSL 3.0.1 (seen in an Ubuntu 24.04 distro).
4. **Named `wsl --install <distro>` can launch DISM elevated** to enable VirtualMachinePlatform, even when WSL is already working (that's why we only use `--from-file`).
5. **DAX share first-touch cost grows with the amount mapped.** The first write to a page costs ~0.25 s per 33 MB buffer with nothing else mapped, and ~1 s once ~300 MB is mapped. Reproducer: `lab/bench-dax-alloc.c`.
6. **Feature request: a supported zero-copy shared-memory API** between a WSL distro and Windows. Today we rely on WSLg's internal virtio-fs share (`wslg` tag) and its section names, which may change without notice. The request is a documented API or a stable contract for that share.

## Omarchy (basecamp/omarchy)

We don't fork Omarchy: the image runs its normal installer, and [linux/overlay](../linux/overlay) replaces the hardware-specific steps with WSL equivalents ("WSL leaves"). Candidates for small upstream PRs, each a no-op outside WSL:

- Detect WSL (`systemd-detect-virt --container` reports `wsl`) and skip what cannot work there:
  - the `hardware/` and `login/` install phases (drivers, firmware, boot loader, boot splash, display manager);
  - snapper (no btrfs root);
  - services that need real hardware (see `linux/overlay/wsl/enable-services.sh`).
- Keep Omarchy's bindings working where the host OS reserves keys (Super+L, Ctrl+Alt+Del), e.g. by making those bindings easy to override.

Upstreaming these would shrink the overlay's `womarchy-apply-system` to almost nothing.

## Tracking

Keep this table current. When something is merged, delete the patch here and bump the pinned version.

| Change | Submitted | Status |
|---|---|---|
| (none yet) | | |
