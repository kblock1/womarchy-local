# Install notes

These are distilled, repeatable requirements and steps, each with the reason behind it. [WORKLOG.md](WORKLOG.md) has the full history. Items marked **(script)** are done by the installers ([install.ps1](../install.ps1), `omarchy install`) or the image.

## Host prerequisites
- Windows 11 x64 with virtualization enabled and the "Virtual Machine Platform" feature on.
- **WSL ≥ 3.0.1** (the tested version). **(script)** `install.ps1` checks `wsl --version`.
  - If WSL is older, it runs `wsl --update`, which **needs UAC elevation** and restarts the WSL VM, stopping all running distros.
  - If WSL is missing, it runs `wsl --install --no-distribution`, which may need a Windows restart.
  - Either way it explains this, including that the update applies to every distro, and asks first. `omarchy.exe` refuses older versions with the same advice.
- A GPU driver with WSL GPU-PV support (`/dev/dxg` present in WSL).
- GUI apps must stay enabled globally (`guiApplications` must not be `false` in `.wslconfig`). The shared-memory frame path uses WSLg's virtio-fs share, and audio uses WSLg's PulseServer.

## Distro base
- Official Arch WSL image (`wsl --install archlinux` / `--from-file`). **(script)** Our `.wsl` image replaces it.
- **(script)** First run needs `pacman-key --init && pacman-key --populate archlinux` (Arch OOBE does this, but it is skipped with `--no-launch`).
- **(script)** Locale: enable `en_US.UTF-8` in `/etc/locale.gen`, run `locale-gen`, and write `LANG` to `/etc/locale.conf` (the image defaults to C.UTF-8).
- `/etc/wsl.conf`: `[boot] systemd=true`, `[user] default=<user>`.
- **(script)** User UID: on WSL ≤ 2.7 all distros share one cgroup tree, so pick a UID not used by other systemd distros' users (for example 1789). On WSL ≥ 2.9 this is harmless either way.

## Graphics
- **(script)** Set `GALLIUM_DRIVER=d3d12` session-wide. Mesa on Arch otherwise picks llvmpipe.
- Install `mesa`, `vulkan-dzn` and `vulkan-icd-loader`. `/usr/lib/wsl/lib` is added to the loader path by WSL (`/etc/ld.so.conf.d/ld.wsl.conf`).
- **(script)** Use patched Mesa from the womarchy repo (`patches/mesa/`):
  - `0001` fixes a d3d12 deadlock in the slab/reclaim path; Hyprland hangs on its first text texture without it.
  - `0002` puts CPU-write buffers in write-back heaps. On WSL 3.0.1 the write-combine UPLOAD heaps run at about 9 MB/s, which makes texture uploads 700× slower; it is mandatory for usable GUI performance.
- Do **not** load vgem or any kernel module. On WSL ≥ 2.9 the kernel has no DRM, and loading modules affects all distros.

## Installing on a user's machine (`omarchy.exe`)
- `install.ps1` (run with `irm …/install.ps1 | iex`): Windows 11 and WSL checks (above), then it downloads `omarchy.exe` (checked against `omarchy.exe.sha256`) and runs `omarchy install`.
- `omarchy install [IMAGE.wsl|URL]` checks WSL ≥ 3.0.1, then imports the image with `wsl --install --from-file … --name Omarchy --no-launch`.
  - The image comes from the argument, else an `Omarchy*.wsl` next to the exe, else the latest GitHub release (`Omarchy.wsl`, checked against `Omarchy.wsl.sha256`).
  - It then runs first-run setup, copies the exe to `%LOCALAPPDATA%\Programs\Omarchy` (plus the user PATH) and creates Start menu `Omarchy.lnk`.
- **First-run setup:** WSL runs an image's `[oobe] command` only when its default shell is opened interactively, **never** for `wsl --exec`.
  - So `omarchy.exe` runs `/usr/lib/womarchy/oobe.sh` as root in the console, then `wsl --terminate`s the distro so the `[user] default` it wrote applies.
  - `womarchy-session` signals a missing setup with `WOMARCHY_NEEDS_SETUP` and exit code 75.
- `omarchy uninstall` requires typing the distro name (it deletes the distro), then removes the shortcut and PATH entry. WSL leaves an empty `Start Menu\Programs\<distro>` folder on unregister; uninstall removes it.
- User PATH edits fail closed (never write a PATH that couldn't be read). The previous value is appended to `%LOCALAPPDATA%\Programs\Omarchy\path-backup.txt`.

## Packages (the `[womarchy]` repo)
- **(script)** Add the repo **before** `[core]`/`[extra]` in `/etc/pacman.conf` so its same-named packages win: `aquamarine`, `hyprland`, `mesa`, `vulkan-dzn`, `vulkan-swrast`, `vulkan-mesa-implicit-layers`, `vulkan-mesa-layers` (pkgrel `<arch>.<n>`), plus `womarchy-session`. Build with `linux/packages/build-all.sh` in an Arch distro. See WORKLOG §17.
- When Arch bumps one of these packages, `pacman -Syu` would replace ours with Arch's. **(script)** Rebuild ours against the new Arch PKGBUILD (`ref/`), or hold them with `IgnorePkg` until rebuilt.

## Session
- **(script)** Entry point `/usr/bin/womarchy-session` (package `womarchy-session`), launched by `omarchy.exe` via `wsl.exe -d <distro> --exec`. It prints `WOMARCHY_VMID=`, prepares the environment and runs `uwsm start -g -1 -e -D Hyprland hyprland.desktop`.
- `/etc/wsl.conf`: `[boot] systemd=true` (needs the systemd user manager and logind), and a non-root `[user] default=`. Recommended: `[interop] appendWindowsPath=false`; the session strips `/mnt/*` from PATH anyway.
- `wsl --exec` processes are outside any logind session. uwsm needs `XDG_SESSION_ID`/`XDG_SEAT`, so the session passes WSL's `user` class session and `seat0`.
- Monitor rules come from the Windows layout, written to `$XDG_RUNTIME_DIR/womarchy/monitors.lua`. **(script)** The Omarchy user overlay's `~/.config/hypr/monitors.lua` must `dofile()` it when present.
- `WOMARCHY_ORPHAN_TIMEOUT` (default 30 s) ends the compositor if the viewer vanishes without QUIT.
- Logs: `~/.cache/womarchy/session.log` (session + uwsm) and `hyprland.log` (copied from `$XDG_RUNTIME_DIR/hypr/*/`, which is tmpfs).

## Shared memory (frames)
- WSLg's virtio-fs share, tag `wslg`, can be mounted in the distro (root): `mount -t virtiofs wslg /mnt/wslgshm -o dax`. Details on creating and keeping files are pending (see WORKLOG §11).
- **(script, done in package `womarchy-session`)** Mount the share at boot: systemd unit `mnt-wslgshm.mount` (`What=wslg`, `Type=virtiofs`, `Options=dax`). The share is flat (no mkdir or readdir). Create files with `open(O_CREAT|O_EXCL)` + `fallocate` + `mmap(MAP_SHARED)` and keep the fd open. Write every page once at creation: the first write to a DAX page is several hundred times slower than later ones, and the cost grows with how much is mapped (`MAP_POPULATE` only read-faults a shared mapping, so it adds cost without helping). Hyprland keeps two such buffers per output. **File sizes must be whole pages** (otherwise `EINVAL`); aquamarine rounds up. Windows opens `WSL\<VMID>\wslg\<leaf-name>` with `OpenFileMappingW`. Measured at 6 GB/s both ways.
- **(script, WSL 3.0.1)** Add `systemd-binfmt` drop-in `ExecStart=-/usr/lib/systemd/systemd-binfmt`, or the distro boots `degraded`.

## Omarchy image (overlay + `.wsl` builder)
Details are in [linux/image/README.md](../linux/image/README.md) and [WORKLOG.md](WORKLOG.md), in "Omarchy overlay & image builder".

### Installing
- **(script)** Install **only** with `wsl --install --from-file <image>.wsl --name <name> --location <dir>`. A named `wsl --install <distro>` runs WSL's optional-component check first. On WSL 3.0.1 that check can relaunch wsl.exe elevated and run DISM to enable `VirtualMachinePlatform` (a pending Windows change) instead of installing. `--from-file` skips the check.
- The image's `/etc/wsl-distribution.conf` runs `/usr/lib/womarchy/oobe.sh` the first time the distro's **default shell** is opened interactively, with `defaultUid = 1000` and `defaultName = Omarchy`. WSL never runs the OOBE for `wsl -e`/`--exec`. A launcher that only uses `--exec` must run `oobe.sh` itself as root. `oobe.sh` is idempotent: marker `/var/lib/womarchy/oobe-done`; on a rerun it exits 0 so WSL records completion.
- **(script)** Unattended OOBE: set the variables below and add their names to `WSLENV`, then launch the default shell once (`wsl.exe -d <name> < NUL`).
  - `WOMARCHY_OOBE_USER`, `WOMARCHY_OOBE_PASSWORD` (or `WOMARCHY_OOBE_DEFAULTS=1`, which means user `omarchy`, password `omarchy`);
  - optional: `WOMARCHY_OOBE_FULLNAME`, `WOMARCHY_OOBE_EMAIL`, `WOMARCHY_XKB_LAYOUT`/`WOMARCHY_XKB_VARIANT`, `WOMARCHY_OOBE_NOPASSWD=1`.
- The OOBE does these steps, in order:
  1. `pacman-key --init` and `--populate archlinux omarchy`. The image ships no keyring, because a keyring would carry a private key.
  2. Creates the user (UID 1000, groups `wheel`; sudo `%wheel` with a password unless NOPASSWD was requested) and writes `[user] default=` to `/etc/wsl.conf`.
  3. Sets the keyboard layout. Interactively, the default comes from the Windows layout (`HKCU\Keyboard Layout\Preload`, read-only) through a KLID→XKB table.
  4. Runs `womarchy-provision-user` as the user. It needs network access (mise fetches Node) and takes about 40 s.
- When `omarchy-provision-user` fails (usually the network), the user can rerun it: `womarchy-provision-user --force`.
- WSLg publishes the distro's `.desktop` apps to the Windows Start menu as "Name (distro)". `wsl --unregister` leaves that folder behind, so the uninstaller should delete `%APPDATA%\Microsoft\Windows\Start Menu\Programs\<distro>` when it holds only that distro's shortcuts. The image sets `[shortcut] enabled=false`, because `omarchy.exe` creates the "Omarchy" entry.

### What the image guarantees (checked by `linux/image/verify-image.sh`)
- **`womarchy-compat`** provides and conflicts with `limine limine-mkinitcpio-hook limine-snapper-sync snapper`, so `omarchy` installs without Limine's failing hook. It also conflicts with kernel packages.
- **pacman:** `/etc/pacman.conf` is Omarchy's stable template, plus `IgnorePkg` for kernels, DKMS and firmware, plus `[womarchy]` as the **first** repo (the GitHub release `repo`, then the local copy in `/var/lib/womarchy/repo`). `omarchy update` and `omarchy refresh pacman` rewrite the file, so the user hooks `~/.config/omarchy/hooks/{post-update.d,pre-refresh-pacman.d}/10-womarchy` reapply these entries by running `sudo womarchy-apply-system --reassert`.
- **Services:**
  - Masked: `NetworkManager`, `systemd-resolved`, `systemd-networkd`, `sddm`, `cups`, `avahi-daemon`, `power-profiles-daemon`, `bluetooth`, gettys, `systemd-firstboot`.
  - Enabled: `docker.socket` (`WOMARCHY_DOCKER=0` in `/etc/womarchy/config` disables it) and `systemd-oomd`.
  - WSL keeps generating `/etc/resolv.conf`.
  - The `dns` key is removed from `/etc/docker/daemon.json`, because it depends on resolved.
- **GPU:** `GALLIUM_DRIVER=d3d12` (only when `/dev/dxg` exists) and `GSK_RENDERER=ngl`: the user environment generator `60-womarchy-gpu` (user manager) and `/etc/profile.d/womarchy-gpu.sh` (login shells); `womarchy-session` applies the same `/dev/dxg` rule.
- **Audio** (see WORKLOG D.5 for the cause):
  - PipeWire loads pulse-tunnel sink and source modules to `unix:/mnt/wslg/PulseServer` (`/etc/pipewire/pipewire.conf.d/50-womarchy-wslg.conf`).
  - **(script)** A drop-in for WSL's generated `wslg-session.service` stops it from symlinking WSLg's `pulse/native` over pipewire-pulse's socket.
  - Inside the desktop, `PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native` (set in `~/.config/uwsm/env.d/10-womarchy`).
- **Boot:** systemd-binfmt drop-in (WSL 3.0.1) and `/etc/wsl.conf` with `systemd=true`, `appendWindowsPath=false`, interop on.
- **Locale and keyboard:** `en_US.UTF-8`; `XKBLAYOUT` (and `XKBVARIANT`) in `/etc/vconsole.conf`, with no `KEYMAP`.
- **Known:** at the end of every `omarchy update`, Omarchy asks "Linux kernel has been updated. Reboot?", because no pacman-owned kernel matches `uname -r`. Answer **no**. "Yes" only terminates the distro. This needs an upstream guard.

### Building the image
- **(script)** Create the build distro from the official Arch `.wsl` with `--from-file`, then run `linux/image/setup-build-distro.sh` and `LITE=1 bash linux/image/build-image.sh` as root inside it. It runs niced, and downloads are cached in `/var/cache/womarchy-pkg`. Output: `out/Omarchy-<omarchy-ver>-womarchy-<date>[-lite].wsl` plus `.sha256`.
- The lite profile drops Omarchy's preinstalls: LibreOffice, Kdenlive, OBS, Obsidian, Pinta/.NET, Xournal++, moonlight, aether, cliamp, lazydocker, omacut/omacalc/omawrite. It also writes `~/.local/state/omarchy/preinstalls-removed`, which hides those apps' key bindings.

## Acceptance tests (Windows side, `lab/`)
Run these after building or changing anything. All but `fullscreen-test.ps1` use windowed mode or throwaway distros and never take over the real displays.
- `viewer-test.ps1 [-Session …] [-EndBy close|kill]`: launch, frame dump, and exit-code propagation.
- `clipboard-test.ps1 [-Distro …]`: all three clipboard directions. It saves and restores your clipboard text.
- `gpu-clients-test.ps1`: GL (es2gears) and Vulkan (vkcube / Dozen) clients inside the session.
- `display-change-test.ps1`: live monitor add, remove and resize on fake monitors (`OMARCHY_FAKE_MONITORS_FILE`).
- `installer-test.ps1 -Image Omarchy-….wsl`: `omarchy install` → desktop → `uninstall`, and the first-launch setup path, on `omarchy-test-e2e`.
- `fullscreen-test.ps1 -Distro …`: the real monitors (~1.5 min): an app on each monitor, DPI and positions, a Windows-side capture, frame rates and viewer CPU.
- `omarchy.exe --input-script lab/scripts-omarchy-*.txt`: Omarchy tours (menus, terminal, Chromium, HiDPI, lock, logout) with screenshots taken inside the session.

### Omarchy image: follow-ups
- **Never write into `/usr/lib/modules/$(uname -r)` on WSL.** It is WSL's overlay, and its upper layer is shared by **every distro in the VM**. The same applies to any pacman hook that writes there: the image disables kmod's `60-depmod.hook` (`/etc/pacman.d/hooks/60-depmod.hook -> /dev/null`). Keep `IgnorePkg` for kernels and DKMS packages.
- **Windows Start menu:** WSLg publishes each distro app as "Name (distro)", which is not wanted for Omarchy. The image hides them with `OnlyShowIn=Hyprland;` copies in `/usr/local/share/applications`, generated by `/usr/lib/womarchy/wslg-hide-apps` and a pacman hook. Expect 0 entries in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\<distro>`; WSLg still creates that folder empty.
  - Opt out: `touch /etc/womarchy/wslg-show-apps`, run `/usr/lib/womarchy/wslg-hide-apps`, then `wsl --terminate <distro>`.
  - **(script)** The uninstaller removes the per-distro folder when it holds only that distro's shortcuts.
- **First-run Wi-Fi toast:** `/usr/lib/womarchy/bin/nm-online` is appended to the session PATH and reports "online", so Omarchy's first run shows only "Update System".
- **Kernel prompt:** "Linux kernel has been updated. Reboot?" after `omarchy update` has no clean overlay-side fix. The check needs a pacman-owned `vmlinuz` inside WSL's shared modules overlay (see above). Answer no; an upstream guard is the fix.
- The image ships pacman sync DBs from the build, which match its frozen snapshot, so a fresh install gives no "database file does not exist" warnings.

### Omarchy image: after the code review
What changed after the code review, in detail (the notes above are updated to match).
- **[womarchy] repository**
  - The local copy is at `/var/lib/womarchy/repo`, not `/var/cache`, because cache cleaners would delete it.
  - It is root-owned and never group/other-writable: it is trusted (`TrustAll`) and comes first, so a writable copy would let any user plant packages that root installs.
  - `pacman.conf` lists `Server = https://github.com/sytelus/womarchy/releases/download/packages` first, then `file:///var/lib/womarchy/repo` as the offline fallback.
  - `wsl/pacman.sh` repairs ownership and permissions, migrates the old `/var/cache/womarchy-repo`, and **fails loudly** rather than leave `[womarchy]` out.
  - **(script)** The installer must never copy the repo with modes from a Windows drive.
- **Settings:** `/etc/womarchy/config` holds `WOMARCHY_DOCKER` (default 1) and `WOMARCHY_FIREWALL` (default 0). Change a setting with `sudo WOMARCHY_DOCKER=0 womarchy-apply-system --reassert`: the value is saved to the file and kept across `omarchy update`.
- **Masks:** a service the user unmasks after womarchy masked it is left alone from then on (`/var/lib/womarchy/{masked,released}-units`).
- **GPU:** `GALLIUM_DRIVER=d3d12` is set only when `/dev/dxg` exists. Mesa does not fall back to llvmpipe once the variable is set. It is set by the user environment generator `60-womarchy-gpu` and by `/etc/profile.d/womarchy-gpu.sh`, not by `environment.d`.
- **Keyboard:** the OOBE takes **all** Windows keyboard layouts, in order (for example `us,ru`).
  - With more than one layout it adds `grp:alt_shift_toggle` (Alt+Shift switches layouts) as `XKBOPTIONS` in `/etc/vconsole.conf`, and `~/.config/hypr/womarchy.lua` appends that to Omarchy's `kb_options`.
  - Names are validated against `xkeyboard-config`'s `base.lst`. An invalid layout never blocks locale generation.
- **Unattended OOBE:** use `WOMARCHY_OOBE_USER` **and** `WOMARCHY_OOBE_PASSWORD`. Without a terminal, one without the other is an error. `WOMARCHY_OOBE_DEFAULTS=1` (user `omarchy`, password `omarchy`, sudo) is **for test distros only**.
- Install log permissions: `/var/log/omarchy-install.log` is 0640 after every `womarchy-apply-system` run; `/var/log/womarchy-oobe.log` is 0600.
- **Building:** the build fails unless `out/repo` holds `womarchy-session`, `aquamarine`, `hyprland` and `mesa`, and those exact builds get installed (`ALLOW_STOCK_PACKAGES=1` overrides). The rootfs is never deleted while anything is mounted under it.
- **Testing:** `test-image.ps1 -Image … -Name omarchy-test-N [-Location …]` defaults its location to `%LOCALAPPDATA%\womarchy-test\<name>`. It unregisters the distro even when a step fails, unless `-Keep` is given.
- **(release step)** Before publishing an image, run `lab/overlay/privacy-scan.sh` on a `KEEP_ROOTFS=1` build. It greps every file, binaries included, for owner and machine strings, and checks machine-id, hostname, logs, keys and history. The builder itself refuses to pack when machine-id, hostname, pacman's keyring, `/root` or `/home` content, journal files or SSH host keys are present. The image ships without `/etc/machine-id`; systemd creates a unique one at first boot.
- Package **file** names in the `[womarchy]` repo carry no `:` (epochs renamed, as GitHub release assets require). Tools must find packages by name in the db (`%FILENAME%`) or with `pacman -Q`, never by globbing file names.

### [womarchy] signing, overlay updates, rollback points
- **Overlay updates:** fixes reach installed systems through `womarchy-compat` from the `[womarchy]` repo with a plain `omarchy update`. The post-update hook then runs the new `womarchy-apply-system --reassert`.
  - **(release step)** Build `womarchy-keyring` and `womarchy-compat` with `linux/packages/build-all.sh` like the other packages. CI signs and publishes them.
- **Signing**
  - **What CI publishes** in the `packages` release: `womarchy.db`, `womarchy.files` (and the `.tar.gz` copies), each with a `.sig`; every package with a `.sig`; old package files kept (for `womarchy-rollback`).
  - **(release step)** Before building an image, run `linux/packages/fetch-signed-db.sh --fetch-packages --prune`. `build-image.sh` refuses an unsigned or inconsistent `out/repo` (`ALLOW_UNSIGNED_REPO=1` is for lab images only).
  - **On installed systems:** `[womarchy] SigLevel = PackageOptional DatabaseRequired` is written once the womarchy key (`EB71032617BBA1C4C8EE77C3047A25C1135F969D`, from `womarchy-keyring`) is in pacman's keyring and trusted. Until then `Optional TrustAll` stays, with a warning.
  - **Repo URL:** set by `WOMARCHY_REPO_URL` in `/etc/womarchy/config`.
- **Moving v0.1.0 installs to the signed repo:** v0.1.0 installs don't have the womarchy key. With `Optional TrustAll`, pacman still verifies a published `.sig`, fails to fetch the unknown key, and aborts `omarchy update` ("failed to synchronize all databases"). So signing is not added to the old URL. Instead:
  - The signed repo lives at a **new** release tag, `packages`. `womarchy-compat` 0.4.0 and later default `WOMARCHY_REPO_URL` to it.
  - The old `repo` tag stays **unsigned** (never any `.sig`) and **frozen**. It holds the same `womarchy-compat`, `womarchy-keyring` and `womarchy-session` builds as `packages`, so a v0.1.0 install's next `omarchy update` gets the key and the new overlay. The post-update `--reassert` then switches it to `packages` with `DatabaseRequired`. Nobody has to do anything by hand.
  - **(release step)** Publish `packages` first, then the transition packages on `repo`. In the other order, a v0.1.0 install would switch to a URL that doesn't exist yet.
- **Rollback:** before every package change a rollback point is saved (`/var/lib/womarchy/rollback`; one per 30 min, newest 5).
  - **(script)** `sudo womarchy-rollback` returns to the newest point; `--list`, `--to N`, `--yes`, `--partial` are available, and `omarchy rollback` will call it.
  - It downloads old packages only after asking, and pacman verifies them.
  - Exit codes: 0 ok, 1 error, 2 cancelled or no terminal (use `--yes`), 3 old packages not found (use `--partial`), 4 pacman failed, 5 no points.
- **LLVM:** `omarchy update` stops, changing nothing, when an `llvm-libs` upgrade would break womarchy's Mesa. Run it again once womarchy has published a matching Mesa (issues labelled `rebuild-needed`).
- **(script)** `omarchy update -y` is not fully unattended: Omarchy's final "Linux kernel has been updated. Reboot?" prompt still appears, and it hangs without a terminal. A launcher that runs it must give it a terminal or answer that prompt.
