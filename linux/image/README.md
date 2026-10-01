# womarchy WSL image builder

Builds `out/Omarchy-<omarchy-version>-womarchy-<date>[-lite].wsl`: Arch Linux with the real Omarchy 4 packages (`omarchy`, `omarchy-settings`, `omarchy-keyring`, `omarchy-nvim`), the womarchy WSL overlay, and the womarchy compositor/Mesa packages from `out/repo` when present. Double-click the `.wsl` file or run `wsl --install --from-file` to install it; the first launch runs the setup (OOBE).

## Pieces

| Path | What |
|---|---|
| `linux/packages/womarchy-compat/PKGBUILD` | `provides`/`conflicts` `limine limine-mkinitcpio-hook limine-snapper-sync snapper` (so `omarchy` installs without Limine's failing pacman hook or snapper), conflicts with kernels, and installs the overlay below |
| `linux/packages/womarchy-compat/prepare-sources.sh` | Packs `linux/overlay` into the PKGBUILD's local source; `linux/packages/build-all.sh` runs it, so `womarchy-compat` is built and published like every other `[womarchy]` package (0.4.0+) |
| `linux/packages/womarchy-keyring/` | The `[womarchy]` signing key (`EB71032617BBA1C4C8EE77C3047A25C1135F969D`): `womarchy.gpg`, `womarchy-trusted`, `womarchy-revoked`; populates pacman's keyring on install when it is initialised. `womarchy-compat` depends on it |
| `linux/packages/fetch-signed-db.sh` | Downloads the signed db (+ `.sig`) and the package `.sig` files of the `packages` release into `out/repo` (`--fetch-packages` also the packages), verifies every signature against the keyring files, and that the db lists exactly the local package files (names, sha256). `--verify-only` is what `build-image.sh` runs |
| `linux/overlay/rollback-point`, `hooks/00-womarchy-rollback-point.hook`, `womarchy-rollback` | Before any pacman transaction, `pacman -Q` is saved to `/var/lib/womarchy/rollback/<UTC>.pkgs` (one point per 30 min, newest 5, never blocks). `womarchy-rollback [--list] [--to N] [--yes] [--partial]` restores a point: old files from the cache, the local repo, or downloaded from womarchy's release / Omarchy's repo / the Arch Linux Archive (pacman checks signatures). Exit 0 ok, 1 error, 2 cancelled, 3 not found, 4 pacman failed, 5 no points |
| `linux/overlay/mesa-llvm-guard`, `hooks/10-womarchy-mesa-llvm.hook` | Aborts an `llvm-libs` upgrade whose soname differs from the one womarchy's Mesa links (unless `[womarchy]` offers a newer Mesa in the same update), with a message pointing at the rebuild issue list |
| `linux/overlay/womarchy-apply-system` | WSL-filtered `omarchy-apply-system`: upstream `install/{config,post-install}` leaves minus a skip list, no `hardware/` or `login/`, then the WSL leaves. `--list` prints the plan; `--reassert` reruns only the WSL leaves |
| `linux/overlay/wsl/*.sh` | WSL leaves: `binfmt` (WSL 3.0.1 degraded-boot fix), `pacman` (`[womarchy]` first, kernel `IgnorePkg`, kmod's depmod hook disabled because WSL's `/usr/lib/modules/<ver>` overlay is shared VM-wide), `enable-services` (docker.socket, oomd; masks NetworkManager, resolved, networkd, sddm, cups, avahi, power-profiles-daemon, bluetooth, gettys), `gpu` (`GALLIUM_DRIVER=d3d12`, `GSK_RENDERER=ngl`), `audio` (PipeWire pulse-tunnel to `/mnt/wslg/PulseServer`), `keyboard-locale`, `docker-dns`, `shm-mount` (check only; `womarchy-session` owns `mnt-wslgshm.mount`), `wslg-apps` (hide the distro's apps from the Windows Start menu) |
| `linux/overlay/womarchy-provision-user` | Upstream `omarchy-provision-user --first-install` with `OMARCHY_SETUP_CONTEXT=wsl`, then the user overlay (`linux/overlay/user/`): Super+L / Ctrl+Alt+Del rebinds, `monitors.lua` that loads `womarchy-session`'s generated rules, uwsm env, `shell.json` (idle service off, no Wi-Fi/Bluetooth/power widgets), menu overlay (suspend/hibernate/firmware/Wi-Fi/Bluetooth hidden; Shutdown = log out to Windows), update hooks |
| `linux/overlay/wslg-hide-apps`, `hooks/90-womarchy-wslg-apps.hook` | Writes `OnlyShowIn=Hyprland;` copies of `/usr/share/applications` entries to `/usr/local/share/applications`: WSLg skips them (no "App (distro)" Start-menu shortcuts), Omarchy still lists them. The pacman hook reruns it on every transaction touching desktop files. Opt out: `touch /etc/womarchy/wslg-show-apps`, rerun, `wsl --terminate <distro>` |
| `linux/overlay/systemd/60-womarchy-gpu` | systemd user environment generator: `GALLIUM_DRIVER=d3d12` only when `/dev/dxg` exists (Mesa does not fall back when it is set), `GSK_RENDERER=ngl`; `/etc/profile.d/womarchy-gpu.sh` does the same for login shells |
| `linux/overlay/bin/nm-online` | Session-PATH fallback (appended, real tools win) that reports "online", so Omarchy's first run shows "Update System" instead of "Setup Wi-Fi" |
| `linux/overlay/oobe.sh` | First-run setup (`/usr/lib/womarchy/oobe.sh`): pacman keyring, user (UID 1000, wheel), password, keyboard layout from Windows, `womarchy-provision-user` |
| `linux/image/rootfs/etc/` | `wsl.conf` (systemd, interop on, `appendWindowsPath=false`) and `wsl-distribution.conf` (OOBE, `defaultUid=1000`, `defaultName=Omarchy`, icon) |
| `linux/image/build-image.sh` | The builder (below) |
| `linux/image/verify-image.sh`, `test-image.ps1` | Install as `omarchy-test`, run the real OOBE unattended, check system and user |

## Build

One-time: create the build distro from the official Arch `.wsl` (use `--from-file`; on WSL 3.0.1 the named `wsl --install archlinux` path can launch DISM to enable Windows features) and initialise it:

```powershell
curl.exe -LO https://fastly.mirror.pkgbuild.com/wsl/2026.09.01.176721/archlinux-2026.09.01.176721.wsl   # sha256 7b35e65e...14b9
wsl --install --from-file archlinux-2026.09.01.176721.wsl --name womarchy-build --location D:\WSL\womarchy-build --no-launch
wsl -d womarchy-build -u root -e bash <repo>/linux/image/setup-build-distro.sh
```

The image installs the `[womarchy]` repo as published, so its packages come first:

```bash
# as the builder user (non-root, passwordless sudo): build into out/repo
bash <repo>/linux/packages/build-all.sh            # all womarchy packages, incl. womarchy-keyring + womarchy-compat
# CI signs out/repo's db and packages and publishes the `packages` release; then, for a release image:
bash <repo>/linux/packages/fetch-signed-db.sh --fetch-packages --prune
```

Build (as root in `womarchy-build`; `LITE=1` skips LibreOffice, Kdenlive, OBS, Obsidian, Pinta/.NET and the other Omarchy preinstalls; `ALLOW_UNSIGNED_REPO=1` accepts an unsigned `out/repo` for lab images, never for a release):

```powershell
wsl -d womarchy-build -u root -e bash -c "LITE=1 bash <repo>/linux/image/build-image.sh"
```

What it does:
1. Verifies `out/repo` with `fetch-signed-db.sh --verify-only` (db and packages signed by the pinned womarchy key, db listing exactly the files present) and trusts the womarchy key on the build host; `[womarchy]` uses `SigLevel = PackageOptional DatabaseRequired` during pacstrap, so the image's sync db keeps a valid `womarchy.db.sig`.
2. Stages the `[womarchy]` repo: an unmodified copy of `out/repo` with its `.sig` files (root-owned, not group/other-writable; the db is never rewritten, which would break its signature). Fails unless `womarchy-compat`, `womarchy-keyring`, `womarchy-session`, `aquamarine`, `hyprland` and `mesa` are in it (`ALLOW_STOCK_PACKAGES=1` overrides for the last four), and checks after pacstrap that those exact builds were installed. Same-named files from earlier local builds are removed from the package cache first.
3. Trusts Omarchy's packaging key on the build host: downloads `omarchy-keyring` from `pkgs.omarchy.org`, checks the DB checksum, and requires the set of primary keys in `omarchy.gpg` and the set in `omarchy-trusted` to both equal exactly the pinned fingerprint in `linux/image/omarchy-key.env` (shared with `verify-image.sh`).
4. `pacstrap` (niced) from Omarchy's frozen stable Arch snapshot (`stable-mirror.omarchy.org`) and `[omarchy]`, with `[womarchy]` first: `base`, the Omarchy packages, `womarchy-compat`, `womarchy-session`, PipeWire, `mesa vulkan-dzn vulkan-icd-loader mesa-utils xorg-xwayland`; then `install/omarchy-base.packages` from the installed `omarchy`, minus hardware/networking packages (and the preinstalls for `LITE`).
5. Runs `womarchy-apply-system --defer-provisioning --first-install` in the chroot, installs the WSL config files, copies the repo to `/var/lib/womarchy/repo` (root-owned, read-only for others: it is trusted and first), and installs `/etc/womarchy/config` (persistent settings: `WOMARCHY_DOCKER`, `WOMARCHY_FIREWALL`). The installed `pacman.conf` lists `[womarchy]` with the hosted repo (`https://github.com/sytelus/womarchy/releases/download/packages`) first and the local copy as offline fallback.
6. Scrubs the pacman keyring (OOBE re-creates it), machine-id, hostname, resolv.conf, the package cache and `*.old`/`*.pacnew`/`*.pacsave` files. It never deletes the rootfs while anything is still mounted under it (`rm --one-file-system`). The sync DBs are kept: they match the frozen snapshot the image was built from.
7. `tar --numeric-owner --xattrs --acls | xz -T0 -6` and writes a `.sha256`.

Package downloads are cached in `/var/cache/womarchy-pkg` in the build distro, so rebuilds are quick.

## Test

```powershell
pwsh linux/image/test-image.ps1 -Image out\Omarchy-4.0.4-womarchy-20260930-lite.wsl -Name omarchy-test-2 -Location D:\WSL\omarchy-test-2
```

This installs the test distro from the file (default location `%LOCALAPPDATA%\womarchy-test\<name>`), launches its default shell once with the **test-only** `WOMARCHY_OOBE_DEFAULTS=1` passed through `WSLENV` (user `omarchy`, password `omarchy`; never for real installs), then runs `verify-image.sh` as root and as the user, counts the distro's Windows Start-menu shortcuts (expected 0), and checks live that a package-updated desktop entry is published and then hidden again by the hook script. The distro is unregistered afterwards, also when a step fails, unless `-Keep` is given. Unattended installers can pass `WOMARCHY_OOBE_USER`, `WOMARCHY_OOBE_PASSWORD`, `WOMARCHY_XKB_LAYOUT` and related variables the same way (see `oobe.sh`).
