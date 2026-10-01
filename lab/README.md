# Lab experiments

Reproducible experiments behind [docs/FEASIBILITY.md](../docs/FEASIBILITY.md) §3. They run **only** inside the isolated lab distro `womarchy-lab`: the official Arch WSL image, stored at `D:\WSL\womarchy-lab`, with default user `lab`.

**Safety.** All WSL2 distros share one VM, kernel and cgroup tree.

- Scripts marked ⚠ touch VM-global state or use heavy CPU. Run them only with the machine owner's approval.
- Stop the lab when you are done: `wsl --terminate womarchy-lab`.
- On WSL ≤ 2.7, the lab user should not share a UID with users of other running systemd distros (see FEASIBILITY E8).

Run scripts from Windows with `wsl -d womarchy-lab -- bash <repo>/lab/<script>`. From Git Bash, set `MSYS_NO_PATHCONV=1` first. Don't pass `$vars` through `wsl.exe` inline; it expands them in a login shell.

| Script | Experiment | Notes |
|---|---|---|
| `probe-gbm-vgem.sh` | E3: which Mesa driver backs EGL's GBM platform on a vgem node | ⚠ needs `modprobe vgem` (VM-global) |
| `gbmtest.c`, `run-gbmtest.sh` | E3: GBM BO flags, EGL dmabuf import, render-to-BO | ⚠ vgem |
| `build-aquamarine.sh` | Builds aquamarine v0.15.1 with `patches/aquamarine/*` into `/opt/womarchy` (lab only) | light build |
| `test-headless.sh`, `hyprctl-lab.sh` | E4: Hyprland headless on vgem with d3d12 GL; screenshots into `out/` | ⚠ vgem |
| `debug-hang.sh`, `symbolize-hang.sh` | E5: stacks and debuginfod symbolisation of the d3d12 deadlock | ⚠ vgem |
| `bench-readback.c`, `run-bench.sh` | **E6: readback, upload and composition cost on EGL surfaceless (no DRM needed)** | safe; about 30 s of GPU load |
| `hvsock_bench.py` | **E7: hvsocket throughput and latency, WSL ↔ Windows (no config needed)** | safe; about 5 s |
| `build-mesa.sh` | Patched Mesa into `/opt/womarchy-mesa` (lab only) | ⚠ heavy CPU; run throttled only with approval |
| `run-hyprland.sh` | E2: stock Hyprland nested in WSLg (expected failure) | safe |

Outputs are in `out/` (for example `headless-d3d12.png`, the first captured frame of Hyprland rendered on D3D12 in WSL).

Remove the lab entirely with `wsl --unregister womarchy-lab`. That deletes `D:\WSL\womarchy-lab\ext4.vhdx`.
