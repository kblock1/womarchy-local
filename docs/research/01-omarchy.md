# 01: Omarchy upstream analysis for WSL2 (womarchy)

Scope: the Omarchy side only. This covers what Omarchy installs and assumes, and how each install step fares under WSL2 (WSL 2.7.10, kernel 6.18.33.2-microsoft-standard-WSL2, WSLg 1.0.73, systemd on, no `/dev/dri`, GPU through `/dev/dxg` + Mesa d3d12/dzn, audio through `/mnt/wslg/PulseServer`).

Research date: 2026-09-30. All paths are relative to `<repo>\upstream\omarchy` unless marked otherwise.

---

## 0. TL;DR

- **Omarchy is now version 4 ("Quattro").** It is no longer a `curl | bash` installer. It ships as Arch **pacman packages**: `omarchy` and `omarchy-settings` (plus `omarchy-keyring` and `omarchy-nvim`), from Omarchy's own repo `pkgs.omarchy.org`, installed against a frozen Arch snapshot mirror `stable-mirror.omarchy.org`. The **ISO owns orchestration** and calls two target-side entry points: `omarchy-apply-system` (root) and `omarchy-provision-user` (user). `install.sh`/`boot.sh` and `install/preflight/guard.sh` exist only in the legacy v3 line (last tag v3.8.4).
- **Hyprland start chain:** SDDM (a Wayland greeter that itself runs inside `start-hyprland`), then the `omarchy.desktop` session, then `uwsm start -g -1 -e -D Hyprland hyprland.desktop`, then `start-hyprland` (the Hyprland 0.56.2 watchdog), then `~/.config/hypr/hyprland.lua` (a **Lua** config). On `hyprland.start` it runs `omarchy-launch-shell` (a single **Quickshell** process that is the whole desktop: bar, notifications, OSD, menu/launcher, lock screen, idle, polkit agent, clipboard) and `omarchy-provision-first-run`.
- **v4 dropped these v3 components:** Waybar, Mako, Walker/Elephant, SwayOSD, hyprlock, hypridle, swaybg, hyprpolkitagent. They are all replaced by the Quickshell "omarchy-shell". Wallpapers come from `owe`. The Hyprland target is **0.56.2**, and Omarchy uses **no Hyprland plugins**.
- **Blocking assumptions for WSL:**
  1. Hyprland/Aquamarine need a DRM render node and a GBM allocator. WSL has neither, which is the compositor/GPU workstream's problem (§11).
  2. SDDM, Limine/UKI, Btrfs, Snapper, Plymouth, mkinitcpio and LUKS assume a real boot.
  3. NetworkManager, systemd-resolved and ufw assume they own networking.
  4. PipeWire assumes ALSA devices.
  5. The keymap is Super-centric: about 70% of Super bindings collide with Windows shell hotkeys, and `Super+L` (Omarchy's "toggle workspace layout") is Windows' uncapturable lock.
- **Good news:** the install is already factored into flat `run_logged` lists (`install/{config,hardware,login,post-install,user}/all.sh`), so a filtered runner is trivial. Almost every hardware script self-detects and no-ops under WSL. Several upstream extension points exist that need zero forking: `/etc/skel` seed, a user menu overlay, user hooks (`post-update`, `pre-refresh-pacman`, `post-boot`, `theme-set`), `omarchy_default_bindings = false` plus Lua rebinding, `OMARCHY_SETUP_CONTEXT`, and `omarchy dev link`.
- **Recommendation: an overlay, not a fork.**
  - Install the real `omarchy` and `omarchy-settings` packages.
  - Add a small `womarchy-compat` package that `provides` `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` and `snapper`.
  - Run a WSL-filtered copy of `omarchy-apply-system` (about 30 lines) that sources upstream leaf scripts minus a skip list, plus WSL replacement leaves.
  - Run upstream `omarchy-provision-user --first-install` unmodified with `OMARCHY_SETUP_CONTEXT=wsl`.
  - Replace SDDM with a `wsl.exe … womarchy-session` launcher that `exec`s the same `uwsm start` line.
  - Keep `omarchy update` as the update path, with post-update and pre-refresh-pacman hooks to reassert WSL invariants.
  - Optionally upstream an `omarchy-hw-wsl` detector with about 8 one-line guards.

---

## 1. Upstream snapshot

| Item | Value |
|---|---|
| Clone | `git clone --depth 50 https://github.com/basecamp/omarchy.git` into `<repo>\upstream\omarchy` |
| Canonical repo | `basecamp/omarchy` now **redirects to `github.com/omacom/omarchy`** (43.6k★). Issues and PRs live at `omacom/omarchy`. |
| Default branch | **`quattro`** (the Omarchy 4 line). Other long-lived branches: `dev`, `rc`. v3 lived on `master`, which is no longer a head. |
| HEAD commit | `8b4eae66da2938ba9559f103b18dbf85cdf28a70`, 2026-09-29 19:44:16 +0200, "Merge pull request #13771 from omacom/fix-aether-nvim-path" |
| Latest release tag | **`v4.0.4`**: commit `c668141e9c42b13c80c9ca4ea108e11708c5e8a5`, 2026-09-14 (GitHub release published 2026-09-15). This is what the `omarchy` 4.0.4-1 package in `pkgs.omarchy.org/stable` builds (`_commit` in `omarchy-pkgs/pkgbuilds/omarchy/PKGBUILD`). |
| Other tags | v4.0.3, v4.0.2, v4.0.1, v4.0.0 (+ v4.0.0-beta3), then v3.8.4 (`8fcc9d6`, 2026-07-20), v3.8.3, … |
| `version` file | `4.0.0.alpha` on `quattro` HEAD, which is stale. At runtime there is no version file; `omarchy-version` derives the version from `pacman -Q omarchy` (docs/update-process.md). |
| HEAD vs v4.0.4 | HEAD adds `hype`, `monologue`, `omasnap`, `owe`, `owe-lockfeed` and `vi` to `install/omarchy-base.packages`, and drops `tensaku`. `hype` and `monologue` are currently only in the **edge** Omarchy repo. The diff also adds `default/hypr/qconsole.lua` (the scratchpad as a Quake console), `toggles/no-animations.lua` and `install/user/hardware/vm-no-animations.sh`. **Pin womarchy to release tags (the stable channel), not `quattro` HEAD.** |
| Related repos (cloned to scratchpad for reading only) | `github.com/omacom/omarchy-iso` (ISO and install orchestrator, branch `quattro`); `github.com/omacom/omarchy-pkgs` (PKGBUILDs for the Omarchy repo, branch `master`) |

---

## 2. How Omarchy 4 is built, installed and laid out

### 2.1 Packages and repositories

Source: `docs/file-layout.md` and `omarchy-pkgs/pkgbuilds/{omarchy,omarchy-settings}`.

- **`omarchy`** (4.0.4-1) ships:
  - `bin/omarchy-*` to `/usr/bin` (symlinked into `/usr/share/omarchy/bin`);
  - `install/`, `migrations/`, `themes/`, `shell/`, `version` to `/usr/share/omarchy/`;
  - ALPM hooks `00-omarchy-update-guard.hook` and `10/90-omarchy-hyprland-reload-*`;
  - `/etc/skel/.local/state/omarchy/migrations/*` markers.

  Its hard dependencies are `omarchy-keyring`, `omarchy-settings=4.0.4`, `hyprland`, `quickshell`, `uwsm`, `sddm`, `xdg-desktop-portal-hyprland`, `wireplumber`, `pipewire`, `gnome-keyring`, `gum`, `jq`, `git`, `perl`, `fakeroot`, `pacman-contrib` and `ttf-jetbrains-mono-nerd-basic`. On x86_64 it also depends on **`limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` and `snapper`**. On aarch64 those are replaced by `iwd` and `networkmanager`, so upstream already splits dependencies by platform.
- **`omarchy-settings`** (4.0.4-1) ships `config/**` to `/etc/skel/.config/**` and `/usr/share/omarchy/config`, `default/**` to `/usr/share/omarchy/default/`, and `etc/**` drop-ins. It also ships:
  - the SDDM theme and `/usr/share/sddm/hyprland.lua`;
  - `/usr/local/share/wayland-sessions/omarchy.desktop`;
  - the Plymouth theme;
  - `uwsm/env.d/10-omarchy`, `environment.d`, fontconfig, `mimeapps.list` and systemd user units;
  - the zram-generator conf and the Limine/Snapper templates.

  It depends on `bash`, `curl`, `gum`, `hicolor-icon-theme` and **`plymouth`**. Its `post_install`/`post_upgrade` scriptlet `cp -f`s "etc-overrides" over upstream-owned files: `/etc/os-release` (becomes Omarchy), `/etc/nsswitch.conf`, `/etc/security/faillock.conf`, `/etc/plymouth/plymouthd.conf`, `/etc/skel/.bashrc` and the cups configs.
- `omarchy-keyring` provides the GPG key `40DFB630FF42BCFFB047046CF0134EE680CAC571` (v3's `preflight/pacman.sh` fetched it from keys.openpgp.org). `omarchy-nvim` is a prebuilt LazyVim that seeds `/etc/skel`.
- **pacman config** (`default/pacman/pacman-{stable,rc,edge}.conf` and `mirrorlist-*`):
  - The `[core]`, `[extra]` and `[multilib]` repos point at Omarchy's **frozen Arch snapshot** (`https://stable-mirror.omarchy.org/$repo/os/$arch`; rc uses `rc-mirror.omarchy.org`, edge uses `mirror.omarchy.org`).
  - An extra repo `[omarchy]` points at `https://pkgs.omarchy.org/stable/$arch` (plus `stable-mirror.omarchy.org`).
  - Channels are `stable`, `rc`, `edge` and `dev`. `dev` is a git checkout linked via `omarchy dev link`.
- **Pacman guard:** `00-omarchy-update-guard.hook` runs `omarchy-update-pacman-guard`, which aborts a raw `pacman -Syu` unless `OMARCHY_UPDATE_PACMAN=1` is set (by Omarchy tools) or `OMARCHY_ALLOW_DIRECT_PACMAN=1` is set (by the user).

### 2.2 Install pipeline (ISO)

Source: `omarchy-iso/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`. The phases run in this order:

1. `prepare_live` and `prepare_install_target`: disk cleanup, or verify a pre-mounted target.
2. `arch_install_system` (archinstall):
   - partitioning, **Btrfs** subvolumes (`@`, `@home`, `@log`, `@pkg`) and **LUKS** by default;
   - base install plus "early" packages: `base-devel`, `git`, `limine`, `efibootmgr`, `omarchy-keyring`, `omarchy-settings`, `lua51`, `luarocks`, `omarchy-nvim`. These are installed before `useradd`, so `/etc/skel` seeds the new home.
   - **Limine** EFI/BIOS install, an `efibootmgr` entry and a pacman hook;
   - `useradd`;
   - the runtime packages: `omarchy` plus every line of `omarchy-base.packages`;
   - fstab, zram swap, keyboard (`/etc/vconsole.conf` `XKBLAYOUT`/`XKBVARIANT`), timezone and locale;
   - PipeWire audio via archinstall's audio config. The ISO's `builder/archinstall.packages` also brings `linux`, `linux-firmware`, `amd-ucode`/`intel-ucode`, `snapper`, `tailscale` and `openssh`.
3. `configure_hibernation`.
4. `run_system_finalizer`: `arch-chroot` as root runs **`omarchy-apply-system --install-user USER --first-install`**. The env includes `OMARCHY_PATH=/usr/share/omarchy`, `OMARCHY_INSTALL`, `OMARCHY_INSTALL_USER`, `OMARCHY_USER_NAME`, `OMARCHY_USER_EMAIL`, `OMARCHY_MIRROR` and the start time.
5. `finalize_limine_boot`: final UKI and limine.conf.
6. `run_chroot_finalizer`: `arch-chroot -u USER` runs **`omarchy-provision-user --force --first-install`**.
7. `configure_login`:
   - writes `/etc/sddm.conf.d/99-omarchy-login.conf`;
   - writes `autologin.conf` (`User=…`, `Session=omarchy.desktop`) **only for encrypted installs**, because the LUKS passphrase already authenticated the user;
   - seeds `/var/lib/sddm/state.conf`;
   - runs `systemctl enable sddm.service`.
8. `configure_ssh_access` and `configure_tailscale` (unattended installs only), then `validate_boot`.

Deferred provisioning ("prepare for another owner") installs with no user. `omarchy-provision-owner.service` creates the user on tty1 at first boot and then runs the same user finalization.

### 2.3 Three layers populate `$HOME`

Source: `docs/file-layout.md`.

1. **Seed:** `/etc/skel/**` from `omarchy-settings`, copied by `useradd -m`. This includes `~/.config/hypr/*.lua`, `~/.config/omarchy/shell.json`, app configs, `.bashrc`, and migration markers.
2. **Finalize:** `omarchy-provision-user` (routed as `omarchy finalize user`), which runs once per user. See §5.4.
3. **Resync:** `omarchy-reinstall-configs`, which copies `/etc/skel/.` over `$HOME`. It is destructive, and it also runs `omarchy-refresh-limine`, `omarchy-refresh-plymouth` and the nvim refresh.

First interactive login: Hyprland autostart runs `omarchy-provision-first-run` (§5.5). Its marker is `~/.local/state/omarchy/done/first-run-user`.

### 2.4 Legacy v3 flow (for reference; v3.8.4)

- `boot.sh`:
  - sets `OMARCHY_ONLINE_INSTALL=true` and points `/etc/pacman.d/mirrorlist` at `stable`/`rc`/`mirror.omarchy.org`;
  - runs `pacman -Syu git`;
  - clones `basecamp/omarchy` to `~/.local/share/omarchy`;
  - sources `install.sh`.
- `install.sh` sources, in order: `helpers/all.sh`, `preflight/all.sh`, `packaging/all.sh`, `config/all.sh`, `login/all.sh`, `post-install/all.sh`. Each is a `run_logged` list.
- **`install/preflight/guard.sh` (v3 only).** Each check calls `abort`, which offers "Proceed anyway?". It requires:
  - `/etc/arch-release` and no CachyOS/EndeavourOS/Garuda/Manjaro marker;
  - not running as root;
  - `uname -m == x86_64`;
  - Secure Boot disabled (`bootctl status`);
  - no `gnome-shell` or `plasma-desktop` installed;
  - `limine` present;
  - root filesystem is **btrfs**.

  Under WSL the limine and btrfs checks fail, and `bootctl` is meaningless.
- v3 modes:
  - `OMARCHY_CHROOT_INSTALL=1`: the `chrootable_systemctl_enable` helper does enable-only (no `--now`). It also changed the mise-work and "finished" behaviour.
  - `OMARCHY_ONLINE_INSTALL`: the boot.sh path, which configures pacman and the keyring.
  - There is **no `OMARCHY_BARE`** in v3.8.4 or v4.
- v3 still had the component set Waybar, Mako, Walker/Elephant, SwayOSD, hyprlock/hypridle and swaybg. `bin/omarchy-upgrade-to-quattro` (2,410 lines) removes them when upgrading to v4.

### 2.5 Existing environment variables and modes relevant to WSL (v4)

| Variable / mechanism | Where | Use for womarchy |
|---|---|---|
| `OMARCHY_SETUP_CONTEXT` (`runtime` \| `iso-chroot` \| `provision-owner`) | `bin/omarchy-provision-user`, `install/user/theme.sh`, `install/user/mise-work.sh` | **Key trick:** export `OMARCHY_SETUP_CONTEXT=wsl`. Any value other than `runtime` makes `theme.sh` set the theme headlessly. Any value other than `iso-chroot`/`provision-owner` makes `mise-work.sh` install Node over the network instead of demanding `/opt/packages/node-*.tar.gz`. If you called `--first-install` from the `runtime` context, it would be rewritten to `iso-chroot` and **`mise-work.sh` would exit 1** because the bundled Node tarball is missing. |
| `OMARCHY_INSTALL_USER`, `--install-user`, `--first-install`, `--upgrade`, `--defer-provisioning` | `bin/omarchy-apply-system`, `bin/omarchy-apply-hardware` | Reuse the same semantics in the WSL runner. |
| `OMARCHY_USER_NAME`, `OMARCHY_USER_EMAIL` | `install/user/git.sh`, `install/user/xcompose.sh` | Prompt for these in WSL OOBE. |
| `OMARCHY_MIRROR` (`stable`\|`rc`\|`edge`) | `install/post-install/pacman.sh` | `stable` |
| `OMARCHY_INSTALL_LOG_FILE`, `OMARCHY_LOG_TO_STDOUT=1`, `OMARCHY_INSTALL_DEBUG=1` | `install/helpers/logging.sh` | Logging for the WSL runner. |
| `OMARCHY_THEME_HEADLESS=1` | `omarchy-theme-set` | Set implicitly through the setup context. |
| `/etc/omarchy.conf` via `omarchy dev link <checkout>` | `default/bash/env-bootstrap`, `bin/omarchy-dev-link` | The supported way to run a **modified checkout** of `bin/`, `default/`, `shell/`, `themes/`, `config/`. `omarchy update` then does `git pull --ff-only` on it (`bin/omarchy-update-dev`). This is the fallback for a thin fork. |
| `~/.local/state/omarchy/preinstalls-removed` | `default/hypr/helpers.lua` (`o.preinstalled_bindings_enabled`), `omarchy-remove-preinstalls` | A "lite" WSL profile: skip the heavy preinstalled apps and their keybindings. |
| `omarchy_default_bindings = false`, `omarchy_preinstalled_bindings = false` (Lua globals) | `default/hypr/omarchy.lua`, `config/hypr/hyprland.lua` | Rebind for Windows (§8.3). |
| **VM detection** `bin/omarchy-hw-vm` = `systemd-detect-virt --vm --quiet` | Used only by `install/user/hardware/vm-no-animations.sh`, which drops `toggles/hypr/no-animations.lua` | Probably true in WSL2 (the CPUID hypervisor is Hyper-V); verify on the target. This turns off animations, blur, shadows and transparency. |
| **WSL detection** | none | No reference to WSL/microsoft/`WSL_DISTRO_NAME` anywhere in the tree. |

---

## 3. Package inventory

### 3.1 `install/omarchy-base.packages` (HEAD: 152 packages)

Sources were resolved against the live repo DBs on 2026-09-30:
- `pkgs.omarchy.org/stable/x86_64/omarchy.db` (253 packages);
- `stable-mirror.omarchy.org/{core,extra,multilib}` (15,432 packages).

In v4 **nothing is pulled from the AUR at install time**. `yay` is installed only for users.

Legend: **[O]** comes from the Omarchy repo, **[A]** from Arch core/extra (Omarchy snapshot), **[edge]** is only in the Omarchy edge repo today. Heavy/GPU marks: 🌐 Chromium/Electron/CEF, 🎞 GPU/video heavy.

| Group | Packages (source) | WSL notes |
|---|---|---|
| Compositor and session | hyprland 0.56.2 [A], hyprland-guiutils [A], hyprland-preview-share-picker [O], hyprpicker [A], hyprsunset [A], uwsm [A], xdg-desktop-portal-hyprland [A], xdg-desktop-portal-gtk [A], quickshell [O: `quickshell-git` 0.3.0.r20 provides it; Arch also has 0.3.1], owe [O] 🎞 (mpv/libepoxy wallpaper engine), owe-lockfeed [O], sddm [A], plymouth [A], wl-clipboard [A], wtype [A], grim [A], slurp [A], gpu-screen-recorder [O+A] 🎞 | Core of the port. Compositor feasibility is blocked on DRM/GBM (§11). SDDM and Plymouth are not used. gpu-screen-recorder needs a DRM/KMS or portal capture path. |
| Audio | wireplumber [A], pamixer [A], alsa-utils [A], mpv-mpris [A]. The PipeWire stack comes from archinstall and "other": pipewire, pipewire-alsa, pipewire-jack, pipewire-pulse, gst-plugin-pipewire, libpulse | Needs a WSLg PulseServer bridge (§6.4). |
| Networking | networkmanager [A], avahi [A], nss-mdns [A], inetutils [A], whois [A], ufw [A], ufw-docker [O], wireless-regdb [A], tzupdate [O], localsend [O] 🌐 (Flutter) | NM, resolved and ufw conflict with WSL networking; skip or disable them. LocalSend discovery relies on multicast, which is limited under WSL NAT. |
| Bluetooth | bluez, bluez-tools, bluez-utils [A] | No Bluetooth in WSL; skip. |
| Printing | cups, cups-filters, cups-pk-helper, system-config-printer [A] | Optional; Windows owns the printers. |
| Power/HW | power-profiles-daemon, brightnessctl, ddcutil, bolt [A], asdcontrol [O], kernel-modules-hook [A], udiskie [A], gvfs-mtp/nfs/smb [A], dosfstools, exfatprogs [A], gnome-disk-utility [A] | Mostly inert under WSL; skip. |
| Docker | docker, docker-buildx, docker-compose, lazydocker [A] | Works under systemd in WSL. Conflicts conceptually with Docker Desktop's WSL integration. |
| Terminal/TUI/dev | foot [A] (**default terminal** via `default/xdg-terminal-exec/hyprland-xdg-terminals.list`), tmux, herdr [O], btop, bat, eza, fd, fzf, ripgrep, zoxide, starship, fastfetch, gum, jq, less, man-db, tldr, dua-cli, lazygit, git, clang, llvm, ruby, lua51, luarocks, tree-sitter-cli, mise-bin [O], usage, yay [O], expac, fakeroot, pacman-contrib, plocate, inotify-tools, inxi, unzip, socat, qrencode, zbar, tesseract, tesseract-data-eng, imagemagick, libvips, libyaml, mariadb-libs, postgresql-libs, python-gobject, python-poetry-core, nvim, vi [O], omarchy-nvim [O], tobi-try [O], ttfx [O], cliamp [O] (TUI music player), yt-dlp, bash-completion | Works as-is (this is what the terminal-only WSL ports use). |
| Browser and web apps | chromium [A 152; Omarchy also has `omarchy-chromium-bin`] 🌐. **Default browser**; web apps are `chromium --app=URL`. | GPU through d3d12 is uncertain; may need `--disable-gpu` or ANGLE flags. |
| GUI apps (the "preinstalls") | nautilus, nautilus-python, sushi, evince, imv, mpv 🎞, ffmpegthumbnailer, obsidian 🌐 (Electron), libreoffice-fresh, xournalpp, pinta [O] (.NET → `dotnet-runtime`), kdenlive 🎞, obs-studio 🎞, moonlight-qt 🎞, aether [O] 🌐 (webkit2gtk), omacalc [O], omacut [O] 🎞, omawrite [O], omasnap [O], hype [edge], monologue [edge] | Candidates for a "lite" profile via `omarchy-remove-preinstalls`. |
| Input | fcitx5, fcitx5-gtk, fcitx5-qt [A] (drives XCompose; `omarchy-fcitx5.service`) | OK |
| Fonts/theme | fontconfig, noto-fonts, noto-fonts-cjk, noto-fonts-emoji, woff2-font-awesome, ttf-jetbrains-mono-nerd-basic [O], ttf-ia-writer [O], gnome-themes-extra, yaru-icon-theme [O], gnome-keyring, libsecret, qt6-imageformats | Works as-is. |
| Emulation | qemu-user-static-binfmt [A] | ⚠ It registers binfmt handlers through `systemd-binfmt`; check that the WSLInterop registration survives. |

### 3.2 `install/omarchy-other.packages` (57): ISO/hardware-conditional

- Base and boot: `base`, `base-devel`, `dkms`, `btrfs-progs`, `limine` [A], `limine-mkinitcpio-hook` [O], `limine-snapper-sync` [O], `snapper`, `zram-generator`, `linux-firmware`, `linux-omarchy` 7.2.5 [O] and `linux-omarchy-headers` [O].
- Graphics:
  - NVIDIA: `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils`, `libva-nvidia-driver`, `egl-wayland`, and the legacy `nvidia-580xx-*` [O].
  - Intel: `intel-media-driver`, `libva-intel-driver`, `libvpl`, `vpl-gpu-rt`.
  - Vulkan: `vulkan-intel`, `vulkan-radeon`, `vulkan-asahi`.
- Audio: the PipeWire set, `sof-firmware`, `lsp-plugins-lv2`.
- CPU/power: `thermald`, `intel-lpmd` [O].
- Vendor quirks:
  - Asus: `asusctl`.
  - Intel: `intel-ipu7-camera`.
  - Apple: `broadcom-wl-dkms`, `macbook12-spi-driver-dkms`, and T2 packages (`linux-t2`, `apple-t2-audio-config`, `apple-bcm-firmware`, `t2fanrd`) from the extra `[arch-mact2]` repo.
  - Surface: `linux-firmware-marvell`.
  - Dell: `dell-xps-touchpad-haptics` and `dell-xps13-sidecar-amps` [O].
  - Framework: `qmk-hid`.
  - TUXEDO: `tuxedo-drivers-nocompatcheck-dkms`.
- Misc: `gtk4-layer-shell`, `qt6-wayland`, `webp-pixbuf-loader`, `autoconf-archive`, `yay-debug`.

**For WSL all of these are C (skip)** except the PipeWire set, `qt6-wayland`, `gtk4-layer-shell`, `webp-pixbuf-loader` and `base`/`base-devel`. They are replaced by the **WSL GPU set**, which is available in the same Arch snapshot: `mesa` 26.2.2 (d3d12 Gallium), `vulkan-dzn` 26.2.2, `vulkan-icd-loader` and `xorg-xwayland`. These rely on WSL's `/usr/lib/wsl/lib` (`libd3d12.so`, `libdxcore.so`). The exact recipe belongs to the GPU research doc.

---

## 4. System configuration Omarchy applies (v4)

### 4.1 Boot and storage (all C in WSL)

- **Limine** plus UKI:
  - `etc/limine-entry-tool.d/omarchy-defaults.conf` sets the cmdline (`quiet splash … initramfs_async=0`), `CUSTOM_UKI_NAME=omarchy`, the boot order (`linux-omarchy` first) and snapshot entries;
  - `omarchy-uki.conf` sets `ENABLE_UKI=yes`;
  - templates live in `default/limine/{limine.conf,default.conf}`.
- **mkinitcpio** (`etc/mkinitcpio.conf.d/omarchy_hooks.conf`): `HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)`. It includes NVIDIA-only kms-drop logic and bundles vconsole for Latin layouts. `thunderbolt_module.conf` adds `MODULES+=(thunderbolt)`.
- **Plymouth:** the `omarchy` theme (`default/plymouth/`, `etc/plymouth/plymouthd.conf`).
- **Snapper on Btrfs:** `install/config/snapper.sh` runs `snapper create-config /`, installs `default/snapper/root` (NUMBER_LIMIT 5), disables the timeline timer, and enables `snapper-cleanup.timer` and `limine-snapper-sync.service`. `omarchy update` takes a snapshot first (`bin/omarchy-snapshot`, which exits 127 when snapper is missing, and the update ignores that).
- **zram:** `default/systemd/zram-generator.conf.d/90-omarchy.conf`, plus `etc/tmpfiles.d/omarchy-zswap.conf` to disable zswap, plus `etc/sysctl.d/99-omarchy-sysctl.conf` (swappiness 150 and related tuning).
- The kernel `linux-omarchy` is installed by migration `1789325478`, and `omarchy-setup-direct-boot` handles EFI entries.

### 4.2 Login and session

- **SDDM** with the Wayland greeter:
  - `etc/sddm.conf.d/10-wayland.conf`: `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`;
  - `10-theme.conf`: `Current=omarchy`;
  - QML theme in `default/sddm/omarchy/`.
- **Autologin** happens only on encrypted installs and is written by the ISO. `install/login/sddm.sh` strips `pam_gnome_keyring` from `/etc/pam.d/sddm`. `install/user/default-keyring.sh` creates an unlocked `Default_keyring`.
- **Session entry** `default/wayland-sessions/omarchy.desktop`: `Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop`.
  - The `hyprland` package's `hyprland.desktop` has `Exec=/usr/bin/start-hyprland` (verified in Hyprland v0.56.2 `example/hyprland.desktop.in`). So the compositor runs as the uwsm-managed unit `wayland-wm@hyprland.desktop.service` under the `start-hyprland` watchdog.
  - uwsm env: `default/uwsm/env.d/10-omarchy` sources `default/bash/env-bootstrap` (which sets `OMARCHY_PATH`, `PATH`, mise shims), `default/uwsm/default` (`TERMINAL=xdg-terminal-exec`, `EDITOR="omarchy-launch-editor --inline"`) and `mise activate --shims`.
  - `default/environment.d/10-omarchy-fcitx.conf` sets `INPUT_METHOD`/`QT_IM_MODULE`/`XMODIFIERS`/`SDL_IM_MODULE=fcitx`.
- **Hyprland config** (Lua, Hyprland 0.56.2):
  - `~/.config/hypr/hyprland.lua` `dofile`s `$OMARCHY_PATH/default/hypr/bootstrap.lua` (which sets the module path) and then `require("default.hypr.omarchy")`.
  - `default/hypr/omarchy.lua` loads helpers, autostart, the bindings (unless `omarchy_default_bindings == false`), envs, looknfeel, qconsole, input, windows (which pulls in `default/hypr/apps/*.lua`) and the theme override `~/.local/state/omarchy/current/theme/hyprland.lua`.
  - User overrides come next: `hypr.monitors`, `hypr.input`, `hypr.bindings`, `hypr.looknfeel`, `hypr.autostart`. Toggles come last: `default.hypr.toggles` loads everything in `~/.local/state/omarchy/toggles/hypr/*.lua` plus saved workspace layouts.
- **Autostart** (`default/hypr/autostart.lua`, on `hyprland.start`):
  - `systemctl --user import-environment …`;
  - `dbus-update-activation-environment --systemd --all`;
  - `omarchy-launch-shell`, a supervised `quickshell -n -p $OMARCHY_PATH/shell` with a restart loop;
  - `omarchy-provision-first-run`;
  - `omarchy-powerprofiles-init`;
  - `uwsm-app -- omarchy-hyprland-monitor-watch`;
  - `uwsm-app -- udiskie --automount --no-notify --no-tray`;
  - `sleep 2 && omarchy-hook post-boot`.
- **Session exit paths:**
  - `omarchy-system-logout` runs `uwsm stop` after 2 s, shows an OSD, and closes all windows.
  - `omarchy-system-shutdown` and `omarchy-system-reboot` run `systemd-run --user --on-active=2s systemctl poweroff|reboot`.
  - `omarchy-system-lock` runs `omarchy-shell lock lock`, a Quickshell `WlSessionLock` using the PAM stack `/etc/pam.d/omarchy-lock-password` written by `omarchy-apply-lock`.

### 4.3 Services

- **System services enabled** by `install/config/enable-services.sh`: `cups`, `avahi-daemon`, `linux-modules-cleanup`, `docker.socket`, `systemd-resolved`, `NetworkManager`, `power-profiles-daemon`, `sddm` and `systemd-oomd`. It also masks `NetworkManager-wait-online`.
- Other scripts add:
  - `install/config/firewall.sh`: `ufw` (deny incoming; allow LocalSend 53317; docker DNS; ufw-docker rules);
  - `install/hardware/bluetooth.sh`: `bluetooth`;
  - `install/config/snapper.sh`: `snapper-cleanup.timer` and `limine-snapper-sync`;
  - hardware-gated units: `thermald`, `intel_lpmd`, `t2fanrd`, `omarchy-nvme-suspend-fix`.
  - `install/hardware/network.sh` disables `iwd` and systemd-networkd and masks `systemd-networkd-wait-online`.
- **User units** enabled at first run (`install/user/first-run/enable-user-units.sh`): `bt-agent`, `owed` (the OWE wallpaper daemon from the `owe` package), `omarchy-recover-internal-monitor`, `omarchy-sleep-lock`, `omarchy-migrate-notify`, `omarchy-fcitx5` and `omarchy-crash-watch`. Unit files are in `default/systemd/user/`.

### 4.4 `/etc` drop-ins shipped by `omarchy-settings` (`etc/`)

- **Networking:**
  - `NetworkManager/conf.d/omarchy-wifi-powersave.conf`;
  - `systemd/resolved.conf.d/{10-disable-multicast,20-docker-dns}.conf`;
  - `docker/daemon.json` (`"dns":["172.17.0.1"]`, `"bip":"172.17.0.1/16"`; this relies on resolved's `DNSStubListenerExtra`);
  - `nsswitch.conf` (`hosts: mymachines mdns_minimal [NOTFOUND=return] resolve files myhostname dns`).
- **Kernel/perf:**
  - `sysctl.d/90-omarchy-file-watchers.conf`;
  - `sysctl.d/99-omarchy-sysctl.conf` (`tcp_mtu_probing`, fq plus **bbr**, zram-tuned VM knobs, dirty bytes);
  - `udev/rules.d/60-omarchy-io-scheduler.rules` (kyber);
  - `modprobe.d/omarchy-usb-autosuspend.conf`;
  - `tmpfiles.d/omarchy-zswap.conf`.
- **systemd:**
  - `system.conf.d/10-faster-shutdown.conf` (5 s);
  - `system.conf.d/20-omarchy-nofile.conf` and `user.conf.d/20-omarchy-nofile.conf`;
  - `logind.conf.d/{10-ignore-power-button,20-inhibit-delay}.conf`;
  - `oomd.conf.d/10-omarchy.conf`;
  - `system/docker.service.d/no-block-boot.conf`;
  - `system/plocate-updatedb.service.d/ac-only.conf`;
  - `system/cups-browsed.service.d`;
  - `system/user@.service.d/10-faster-shutdown.conf`.
- **Security:**
  - `security/faillock.conf` (deny=10);
  - sudoers drop-ins `sudoers.d/omarchy-{dns,passwd-tries,theme-browser,tzupdate}`;
  - `tmpfiles.d/omarchy-nopasswd-sudo.conf`.
- **Boot:** `mkinitcpio.conf.d/*`, `limine-entry-tool.d/*`, `plymouth/plymouthd.conf`, `sddm.conf.d/*`.
- **Misc:** `profile.d/omarchy.sh`, `fastfetch/config.jsonc`, `xdg/kitty/kitty.conf`, `mise/conf.d/omarchy.toml`, `gnupg/dirmngr.conf`, `cups/*`, `sysusers.d/omarchy-cups-browsed.conf`.

---

## 5. Install steps in detail

The WSL classification is in §7. Here is what each step does.

### 5.1 `bin/omarchy-apply-system` (root)

`set -euo pipefail`. It requires root and an existing non-root `--install-user` (or `--defer-provisioning`). It exports `OMARCHY_*`, starts `/var/log/omarchy-install.log`, and then runs:

1. `source install/config/all.sh`;
2. `omarchy-apply-hardware` (which sources `install/hardware/all.sh`);
3. `source install/login/all.sh`;
4. `source install/post-install/all.sh`.

Each `all.sh` is a flat list of `run_logged "$OMARCHY_INSTALL/<path>.sh"`. `run_logged` (`install/helpers/logging.sh`) runs each leaf in `bash -eE -c 'source …'` and returns its exit code. **Because the caller has `set -e`, the first failing leaf aborts the whole apply.** Under WSL that is `snapper.sh`, and `increase-lockout-limit.sh` if SDDM's PAM file is absent.

### 5.2 `install/config/all.sh`

`theme-system.sh`, `browser-policy.sh`, `increase-lockout-limit.sh`, `lockscreen-pam.sh`, `fix-powerprofilesctl-shebang.sh`, `ssh-command-path.sh`, `ssh-keepalive.sh`, `docker.sh` (a deliberate no-op: no docker group), `snapper.sh`, `enable-services.sh`, `firewall.sh`.

### 5.3 `install/hardware/all.sh` (via `omarchy-apply-hardware`)

- **Vendor packages:** `asus-rog.sh`, `framework16.sh`, `dell-xps-touchpad-haptics.sh`, `surface.sh`.
- **Networking and input:** `network.sh`, `set-wireless-regdom.sh`, `fix-fkeys.sh` (hid_apple fnmode=2), `fix-synaptic-touchpad.sh`, `bluetooth.sh`.
- **GPU:** `nvidia.sh` detects via `lspci`, chooses between the `nvidia-open-dkms` and `nvidia-580xx` sets, and writes `modprobe.d/nvidia.conf` (modeset=1) and `mkinitcpio.conf.d/nvidia.conf`. The per-session env lives in `default/hypr/nvidia.lua`. `vulkan.sh` picks Intel, AMD or Apple ICDs by `lspci` "VGA|Display".
- **Intel:** `intel/{video-acceleration,lpmd,thermald,ipu7-camera,fred,fix-wifi7-eht,sof-firmware}.sh`.
- **Other devices:** `fix-elgato-camlink-4k.sh`, `dell-xps13-sidecar-amps.sh`.
- **Asus:** `asus/{fix-asus-ptl-display-backlight,fix-asus-ptl-b9406-display,fix-asus-ptl-b9406-touchpad,fix-z13-touchpad}.sh`.
- **Framework:** `framework/qmk-hid.sh`.
- **Apple:** `apple/{fix-spi-keyboard,fix-suspend-nvme,fix-t2,fix-brcmfmac-supplicant}.sh`.
- **Lenovo:** `lenovo/fix-yoga-pro7-bass-speakers.sh`.
- **Misc:** `fix-bcm43xx.sh`, `fix-surface-keyboard.sh`, `fix-yt6801-ethernet-adapter.sh` (comment-only), `fix-tuxedo-backlight.sh`, `speaker-tuning.sh`, `pacman.sh` (adds the T2 repo).

Detection relies on `lspci`, `/sys/class/dmi/id/*`, `/proc/cpuinfo`, `/sys/class/power_supply/BAT*`, `/sys/bus/acpi`, `/sys/bus/usb` and the `omarchy-hw-*` helpers.

### 5.4 `bin/omarchy-provision-user` (user; `--first-install` from the ISO)

1. Creates skill symlinks into `~/.agents`, `~/.claude`, `~/.codex`, `~/.pi`, `~/.gemini` and `~/.hermes` skills directories.
2. Runs `xdg-user-dirs-update` and writes GTK bookmarks.
3. Sources `install/user/all.sh`:
   - `theme.sh`: `omarchy-theme-set "Tokyo Night"`, `omarchy-theme-set-pi`, btop theme link;
   - `chromium.sh`: native messaging hosts for the copy-url and yt-dlp extensions;
   - `git.sh`, `xcompose.sh`;
   - `mise-work.sh`: `~/Work`, and Node via mise;
   - hardware leaves: `asus/fix-audio-mixer`, `asus/fix-mic`, `framework/fix-f13-amd-audio-input`, `dell/xps13-text-scaling`, `fix-nouveau-cursor`, `vm-no-animations`;
   - `default-keyring.sh`;
   - `mise.sh`: mise installs codex, claude, crush, antigravity, gh, copilot, opencode, playwright, pi, omp, grok, cursor-agent, ghui, hunk, hey, basecamp, cf, ori, muse.
4. Runs `omarchy-refresh-applications`.
5. Runs `xdg-settings set default-web-browser chromium.desktop` and `xdg-mime default HEY.desktop x-scheme-handler/mailto`.
6. With `--first-install`, marks **all shipped migrations as done**.
7. Writes the marker `done/finalize-user`.

### 5.5 `bin/omarchy-provision-first-run` (user, from Hyprland autostart)

1. Calls `omarchy-provision-user || true`.
2. Installs the post-update hooks `install-voxtype.hook`, `setup-fingerprint.hook` and `setup-agent.hook`.
3. Runs `enable-user-units.sh`, `gnome-theme.sh` (gsettings: Adwaita-dark, prefer-dark, Yaru-blue) and `gtk-primary-paste.sh`.
4. Runs `audio-tuning.sh` (`omarchy-audio-tuning on`, which matches by DMI).
5. Waits for the notification server (`omarchy-notification-wait`).
6. Runs `welcome.sh`, a toast: "Super + K for cheatsheet. Super + Space for Omarchy Menu".
7. Runs `wifi.sh`: waits on `nm-online`, then shows the "Setup Wi-Fi" and/or "Update System" toasts.
8. Writes the marker `done/first-run-user` only if every step succeeded; otherwise it retries next login.

---

## 6. Desktop stack details

### 6.1 Hyprland version and features used

- The target is **Hyprland 0.56.2**: Arch `extra` has `hyprland 0.56.2-2`, `aquamarine 0.15.0`, `hyprlang 0.6.8` and `hyprutils 0.14.2`. `omarchy-pkgs` also carries 0.56.2 and aquamarine 0.15.1 PKGBUILDs, and `default/hypr/qconsole.lua` notes it was "measured on Hyprland 0.56.2".
- **Lua config API.** A pre-Lua hyprlang build will not load this config.
  - Core calls: `hl.config`, `hl.bind`/`hl.unbind`, `hl.dsp.*`, `hl.on("hyprland.start"|"layer.opened"|…)`, `hl.window_rule`, `hl.layer_rule`, `hl.workspace_rule`, `hl.curve`, `hl.animation`, `hl.monitor`, `hl.env`, `hl.timer`, `hl.get_active_window`, `hl.get_config`, `hl.device`, `hl.exec_cmd`, `hl.gesture`.
  - Dispatchers: `send_key_state` (universal clipboard) and `global` (Quickshell global shortcuts, from `default/omarchy/shortcuts`).
- **No Hyprland plugins.** No hyprpm and no `.so` loads. `cua-hyprland-plugin` exists in `omarchy-pkgs`, but the config does not reference it.
- Look and feel (`default/hypr/looknfeel.lua`):
  - dwindle layout (`scrolling` is available via the Super+L toggle), gaps 5/10, border 2 with a gradient;
  - **blur and shadow off**, rounding 0;
  - animations **on** with custom beziers; `workspaces` and `fadeSwitch` are off;
  - groupbar styling; `misc.anr_missed_pings=3` (the ANR dialog comes from `hyprland-guiutils`), `allow_session_lock_restore`, `cursor.hide_on_key_press`.
  - `qconsole.lua` sets `decoration.dim_special=0.6`, plus a workspace rule and animation for the scratchpad console.
  - Window opacity is `0.985 0.96` through the `default-opacity` tag, so it is on by default.
- Envs (`default/hypr/envs.lua`):
  - `XCURSOR_SIZE`/`HYPRCURSOR_SIZE=24`;
  - Wayland is forced everywhere: `GDK_BACKEND=wayland,x11,*`, `QT_QPA_PLATFORM=wayland;xcb`, `QT_QPA_PLATFORMTHEME=gtk3`, `MOZ_ENABLE_WAYLAND=1`, `ELECTRON_OZONE_PLATFORM_HINT=wayland`, `OZONE_PLATFORM=wayland`, `XDG_SESSION_TYPE=wayland`, `XDG_CURRENT_DESKTOP`/`XDG_SESSION_DESKTOP=Hyprland`;
  - `XCOMPOSEFILE`, `OMARCHY_PATH`, and `PATH` with `$OMARCHY_PATH/bin` first;
  - `xwayland.force_zero_scaling=true`, `ecosystem.no_update_news=true`.
- **GPU env** (`default/hypr/nvidia.lua`): this only applies when `omarchy-hw-nvidia` finds PCI vendor `0x10de` with class `0x03*` in `/sys/bus/pci/devices`.
  - It sets `NVD_BACKEND=direct|egl`, plus `LIBVA_DRIVER_NAME=nvidia` and `__GLX_VENDOR_LIBRARY_NAME=nvidia` when NVIDIA drives the display.
  - There is nothing for AMD or Intel.
  - **WSL:** the GPU-PV device is `1414:008e` ("Microsoft Basic Render Driver", class 0x0302), so no NVIDIA env is set. That is correct for d3d12.
- Monitors (`config/hypr/monitors.lua`):
  - `hl.monitor({output="", mode="preferred", position="auto", scale="auto"})`;
  - **`GDK_SCALE=2` by default**. Under WSL, derive this from the Windows DPI.
- Input (`default/hypr/input.lua`):
  - `kb_layout`/`kb_variant` are read from **`/etc/vconsole.conf` `XKBLAYOUT`/`XKBVARIANT`** (default `us`);
  - `kb_options="compose:caps,shift:both_capslock_cancel"`, so **CapsLock is the Compose key**; non-Latin layouts get `us,` prepended plus `grp:alts_toggle`;
  - repeat 40/250, numlock on, touchpad settings.
- Portal: `config/hypr/xdph.conf` sets `custom_picker_binary = hyprland-preview-share-picker` and `allow_token_by_default`.
- hyprsunset (`config/hypr/hyprsunset.conf`, identity by default; toggled through `hyprctl hyprsunset` and the shell nightlight service). hyprpicker is used for the color picker and screen freeze during region capture.

### 6.2 omarchy-shell (Quickshell)

`shell/`, `docs/omarchy-shell.md`. One `quickshell` process hosts the plugins:

- `bar` (with workspaces, clock, indicators, tray, network, bluetooth, audio, monitor, power, agents, weather, system-update);
- `notifications` (the Mako replacement), `osd` (the SwayOSD replacement), `menu` (the Walker/launcher replacement; the menu data is `default/omarchy/omarchy-menu.jsonc` plus the user overlay `~/.config/omarchy/extensions/omarchy-menu.jsonc`);
- `lock` (`WlSessionLock` plus PAM; `owe-lockfeed` provides video frames);
- `services/idle` (screensaver after 150 s and lock after 300 s, from `~/.config/omarchy/shell.json`), `services/battery`, `services/media`, `services/nightlight`;
- `polkit` (the polkit agent), `clipboard`, `emojis`, `image-picker`, `background`, `reminders`;
- panels: audio (Quickshell PipeWire service), bluetooth, clock, network (nmcli), monitor, power, weather, elsewhen, tailscale, dropbox, speedtest.

IPC goes through `omarchy-shell <target> <method>`. The desktop background is `owe` (an mpv/libepoxy layer-shell wallpaper engine). `omarchy-launch-shell` restarts the shell only while `hyprctl monitors` answers.

### 6.3 Launchers and default apps

- **Terminal:** `foot` (`xdg-terminal-exec` preference list). `omarchy-launch-terminal` opens it in the current terminal's cwd.
- **Browser:** `chromium`, with flags in `config/chromium-flags.conf`: `--ozone-platform=wayland`, `--password-store=gnome-libsecret`, and `--load-extension=` for Omarchy's copy-url, yt-dlp and whatsapp-slim extensions. `omarchy-launch-browser` and `omarchy-launch-webapp` run `chromium --app=URL` through `uwsm-app`.
- **Web apps** (`applications/*.desktop` and bindings): Basecamp, HEY (mail/calendar), ChatGPT, Grok, YouTube, WhatsApp, Google Messages, Photos, Maps and Contacts, X, Discord, Zoom. All are Chromium, so GPU-heavy under WSL.
- **TUIs:** btop, lazygit, lazydocker (Docker TUI), dua, cliamp, herdr, tmux, nvim (omarchy-nvim).
- **Default MIME handlers** (`default/applications/mimeapps.list`): Nautilus (directories), imv (images), Evince (PDF), mpv (video), chromium (http/https), HEY (mailto).
- **Launch wrapper:** every binding uses `uwsm-app -- <cmd>` (`o.launch` in `default/hypr/helpers.lua`), which needs the uwsm/systemd user session.

### 6.4 Audio

- Omarchy expects PipeWire, PipeWire-pulse and WirePlumber on real ALSA cards.
- `config/wireplumber/wireplumber.conf.d/{bluetooth-a2dp-autoconnect,kef-lsx-no-suspend}.conf`; `default/wireplumber/.../alsa-soft-mixer.conf` (Asus).
- `default/audio/` holds the speaker-tuning filter chains, matched by DMI, and `omarchy-speaker-tuning.service`.
- Controls: `omarchy-audio-*` use `pactl`/`wpctl`; the Quickshell audio panel uses the PipeWire API directly.
- **WSL:** there are no ALSA devices; WSLg exposes a PulseAudio server at `unix:/mnt/wslg/PulseServer` and sets `PULSE_SERVER`. Recommended replacement (D): keep PipeWire, load a `libpipewire-module-pulse-tunnel` sink/source to `/mnt/wslg/PulseServer`, make it the default, and **unset `PULSE_SERVER`** inside the Hyprland session. That way `pactl`, the Quickshell panel and every app all go through the same PipeWire graph.

### 6.5 Hardware-specific fixes (all gated)

Apple (T2, SPI keyboard, NVMe suspend, brcmfmac, bcm43xx), Asus (ROG/asusctl, Z13 touchpad, B9406 display/touchpad/backlight, mic and mixer), Framework (F16 qmk-hid, F13 AMD mic), Dell (XPS haptics, XPS13 sidecar amps, DX13260 text scaling), Lenovo Yoga Pro 7 bass, Surface (keyboard modules, marvell firmware), TUXEDO backlight, Elgato Cam Link 4K, Intel (PTL FRED, BE200/211 EHT off, IPU7 camera, SOF firmware, lpmd, thermald, VA-API), NVIDIA, the nouveau cursor, and Synaptics InterTouch.

**None apply under WSL.** DMI is absent, `lspci` shows only the virtual GPU-PV device, and there is no battery, so `thermald`/`lpmd` stay gated off.

---

## 7. WSL2 classification of every install step

Legend:
- **A:** works as-is.
- **B:** needs adaptation.
- **C:** skip or no-op.
- **D:** needs a WSL-specific replacement.

"Self no-op" means the script's own detection makes it do nothing under WSL, but a skip list is still recommended for determinism.

### 7.1 ISO-owned phases (not in this repo; `omarchy-iso`)

| Step | WSL | How |
|---|---|---|
| Partitioning, Btrfs subvolumes, LUKS, fstab | C | WSL supplies an ext4 VHDX. No encryption layer; BitLocker covers the host. |
| Kernel (`linux`, `linux-omarchy`), microcode, `linux-firmware` | C | WSL boots its own kernel. Add `IgnorePkg = linux linux-* *-dkms linux-firmware*` as a safety net (the taufderl/omarchy-wsl approach). |
| Limine install, UKI, `efibootmgr`, `validate_boot`, `configure_hibernation` | C | No bootloader. Satisfy the dependency with `womarchy-compat` (§10). |
| zram swap (archinstall `setup_swap`) | C | Swap is configured in `%UserProfile%\.wslconfig`. |
| `useradd` + wheel + sudo | D | Use the WSL OOBE (`/etc/wsl-distribution.conf [oobe]`) or the womarchy installer. Ensure the user is in `wheel` and sudoers has `%wheel`. Set `/etc/wsl.conf [user] default=`. |
| Keyboard (`/etc/vconsole.conf` `XKBLAYOUT`/`XKBVARIANT`) | D | Write it from the Windows keyboard layout, because `default/hypr/input.lua` reads it. |
| Timezone, locale, hostname | B | Timezone follows Windows (`useWindowsTimezone`). Write `locale.conf` and generate the locale. WSL sets the hostname. |
| Early packages (`omarchy-keyring`, `omarchy-settings`, `omarchy-nvim`) before the user exists | B | Order matters only for the `/etc/skel` seed. If the WSL user already exists, run `omarchy-reinstall-configs`-style `cp -a /etc/skel/. ~` once, or create the user after installing the packages (preferred). |
| Runtime packages (`omarchy` + base list) | B | Use a filtered list (§3, §10) plus the WSL GPU set. |
| `configure_login` (SDDM autologin/state, `enable sddm`) | D | Replaced by the Windows-side launcher `wsl.exe -d <distro> -u <user> -- womarchy-session`, which `exec`s `uwsm start -g -1 -e -D Hyprland hyprland.desktop`. Do not enable `sddm.service`. |
| SSH / Tailscale unattended | C | Optional. |

### 7.2 `omarchy-apply-system` and `install/config/all.sh`

| Script | WSL | Notes |
|---|---|---|
| `bin/omarchy-apply-system` (orchestrator) | D | Its fixed sequence includes hardware and snapper, and `set -e` aborts on the first failure. Replace it with `womarchy-apply-system`, which uses the same env and logging and sources the same leaves through a skip-list filter (§10). |
| `config/theme-system.sh` (Yaru icon links, Chromium `initial_preferences`) | A | |
| `config/browser-policy.sh` (hardened `/etc/chromium/policies/managed`) | A | |
| `config/increase-lockout-limit.sh` (faillock in `/etc/pam.d/system-auth` and `sddm-autologin`) | B | `sed -i` on a missing `/etc/pam.d/sddm-autologin` fails and aborts the apply. Either keep the `sddm` package installed but disabled (recommended; it is also a hard dependency of `omarchy`), or guard the `sddm-autologin` lines. |
| `config/lockscreen-pam.sh` → `omarchy-apply-lock` (`/etc/pam.d/omarchy-lock-password`, fingerprint) | A | Needed by the Quickshell lock. |
| `config/fix-powerprofilesctl-shebang.sh` | A | Harmless. C if power-profiles-daemon is dropped. |
| `config/ssh-command-path.sh` (PATH in `pam_env.conf`) | A | |
| `config/ssh-keepalive.sh` | A | |
| `config/docker.sh` (no-op) | A | |
| `config/snapper.sh` | **C** | No btrfs, so `snapper create-config /` fails. taufderl observed `Failure (org.freedesktop.DBus.Error.FileNotFound)`. That aborts the apply. Skip it and don't install snapper (compat provides it), so `omarchy-snapshot` exits 127 and updates skip snapshots silently. |
| `config/enable-services.sh` | **B/D** | Split it. Keep `docker.socket` (optional; conflicts with Docker Desktop integration) and `systemd-oomd` (verify PSI/cgroup v2 in the WSL kernel). **Do not enable `NetworkManager`**: WSL configures `eth0` and NM would fight it, and Microsoft's custom-distro guidance lists NM, resolved and networkd as units to mask. **Do not enable `systemd-resolved`**: keep WSL's generated `/etc/resolv.conf` or DNS tunneling. Skip `cups`, `avahi-daemon`, `linux-modules-cleanup`, `power-profiles-daemon` and `sddm`. Masking `NetworkManager-wait-online` is harmless. Replace the script with `wsl/enable-services.sh`. |
| `config/firewall.sh` (ufw + ufw-docker) | C (opt-in B) | The Hyper-V firewall and WSL NAT/mirrored networking already gate inbound traffic. ufw works on the WSL kernel but is redundant; offer it as opt-in. |

### 7.3 `omarchy-apply-hardware` and `install/hardware/all.sh`

**Skip the whole phase (C)** and add a WSL GPU leaf (D).

| Script(s) | WSL | Notes |
|---|---|---|
| `asus-rog.sh`, `framework16.sh`, `dell-xps-touchpad-haptics.sh`, `surface.sh`, `dell-xps13-sidecar-amps.sh`, `fix-tuxedo-backlight.sh`, `fix-surface-keyboard.sh`, `speaker-tuning.sh`, `asus/*`, `framework/qmk-hid.sh`, `apple/*`, `lenovo/*`, `fix-elgato-camlink-4k.sh` | C (self no-op) | DMI, USB and ACPI IDs are absent. |
| `network.sh` (disable iwd/networkd, mask networkd-wait-online, retire `20-*.network`) | C | Mostly harmless, but it touches networkd, which WSL may use for nothing. Leave WSL networking alone. |
| `set-wireless-regdom.sh` | C | Inert. |
| `fix-fkeys.sh` (`/etc/modprobe.d/hid_apple.conf`) | C | Inert. Windows handles the physical keyboard. |
| `fix-synaptic-touchpad.sh` | C | Self no-op. |
| `bluetooth.sh` (`systemctl enable bluetooth`) | C | No adapter; the unit's condition keeps it inert anyway. |
| `nvidia.sh` | C (self no-op) | `lspci` shows no NVIDIA device inside WSL. It must never install `nvidia-*` or DKMS in WSL, even when the Windows host has an NVIDIA GPU. |
| `vulkan.sh` | D | It is a self no-op because the device class is "3D controller: Microsoft", not VGA. Replace it with the WSL GPU leaf: `mesa` (d3d12 Gallium), `vulkan-dzn`, `vulkan-icd-loader`, `libva` (if applicable), `/usr/lib/wsl/lib` in the loader path, and env such as `GALLIUM_DRIVER=d3d12` and `MESA_D3D12_DEFAULT_ADAPTER_NAME`. This is owned by the GPU research doc. |
| `intel/video-acceleration.sh`, `intel/ipu7-camera.sh`, `intel/fix-wifi7-eht.sh`, `intel/sof-firmware.sh` | C (self no-op) | |
| `intel/lpmd.sh`, `intel/thermald.sh` | C (self no-op) | Gated on `omarchy-battery-present`; WSL has no BAT. |
| `intel/fred.sh` | C | On a Panther Lake host it would write an inert Limine drop-in. |
| `pacman.sh` (T2 repo) | C (self no-op) | |

### 7.4 `install/login/all.sh` and `install/post-install/all.sh`

| Script | WSL | Notes |
|---|---|---|
| `login/sddm.sh` (strip `pam_gnome_keyring` from `/etc/pam.d/sddm`) | C | Only relevant if SDDM is used. Harmless if the file exists. |
| `post-install/pacman.sh` | A | Installs Omarchy `pacman-stable.conf` and the stable mirrorlist (the Omarchy Arch snapshot plus `[omarchy]`), fixes CUPS file ownership, and re-sources `hardware/pacman.sh`. Re-append WSL `IgnorePkg` lines and any womarchy repo afterwards. `omarchy refresh pacman` overwrites the file too, so use the upstream `pre-refresh-pacman` hook. |
| `post-install/udev.sh` | A | Harmless (`udevadm` reload/trigger). |
| `post-install/localdb.sh` (`updatedb`) | A | |

### 7.5 `omarchy-provision-user` and `install/user/all.sh`

| Step | WSL | Notes |
|---|---|---|
| `omarchy-provision-user --first-install` (orchestrator) | **A with env** | Run it unmodified as the user with `OMARCHY_SETUP_CONTEXT=wsl OMARCHY_USER_NAME=… OMARCHY_USER_EMAIL=…` (and optionally `OMARCHY_INSTALL_LOG_FILE` for `run_logged` logging). It has `set -euo pipefail`, so a failing leaf (for example a network failure in `mise.sh`) aborts it; rerun with `--force`. |
| Skill symlinks, xdg-user-dirs, GTK bookmarks, `omarchy-refresh-applications`, default browser and mailto, migration markers | A | |
| `user/theme.sh` | A | Headless theme set because the context is not `runtime`. |
| `user/chromium.sh` (native messaging hosts) | A | |
| `user/git.sh`, `user/xcompose.sh` | A | These need `OMARCHY_USER_NAME` and `OMARCHY_USER_EMAIL`. |
| `user/mise-work.sh` | B | Works only with a non-`iso-chroot` context. With `wsl` it runs `mise use -g node@latest` over the network. |
| `user/hardware/asus/*`, `framework/fix-f13-amd-audio-input.sh`, `dell/xps13-text-scaling.sh`, `fix-nouveau-cursor.sh` | C (self no-op) | |
| `user/hardware/vm-no-animations.sh` | B | `omarchy-hw-vm` is probably true under WSL2 (verify with `systemd-detect-virt --vm`), which disables animations, blur, shadows and opacity. Keep that when rendering falls back to llvmpipe. Remove `~/.local/state/omarchy/toggles/hypr/no-animations.lua` when d3d12 acceleration works (`omarchy-toggle-animations`). |
| `user/default-keyring.sh` | A | The gnome-keyring daemon is activated via D-Bus in the session. |
| `user/mise.sh` (about 20 AI/dev CLIs) | A | Heavy network; could be optional in a lite profile. |

### 7.6 `omarchy-provision-first-run` (Hyprland autostart)

| Step | WSL | Notes |
|---|---|---|
| Voxtype, fingerprint and agent invitation hooks | A | The fingerprint hook is a self no-op because there is no USB reader. Voxtype needs a microphone, which WSLg provides through the PulseServer. |
| `first-run/enable-user-units.sh` | B | `owed`, `omarchy-migrate-notify`, `omarchy-fcitx5` and `omarchy-crash-watch`: A. `bt-agent` and `omarchy-recover-internal-monitor`: inert through conditions. `omarchy-sleep-lock`: harmless (WSL never suspends). |
| `first-run/gnome-theme.sh`, `gtk-primary-paste.sh` | A | |
| `first-run/audio-tuning.sh` | A (self no-op) | |
| `first-run/welcome.sh` | B | The toast text points at Super+K and Super+Space, which collide with Windows (§8). Adjust via rebinding, or accept. |
| `first-run/wifi.sh` | D | `nm-online` fails without NM running, which shows a spurious "Setup Wi-Fi" toast and suppresses the "Update System" toast. WSL replacement: show only the update toast. Options: an upstream guard; mark the step done by pre-running it; or accept the toast. |

### 7.7 Hyprland session pieces

| Piece | WSL | Notes |
|---|---|---|
| SDDM greeter (`etc/sddm.conf.d/10-wayland.conf`, `start-hyprland -- --config /usr/share/sddm/hyprland.lua`) | C | There is no seat or DRM for a greeter. |
| `omarchy.desktop` → `uwsm start -g -1 -e -D Hyprland hyprland.desktop` → `start-hyprland` | D | Keep uwsm; it gives `OMARCHY_PATH`, env.d, `graphical-session.target` and `uwsm-app`. Start it from `womarchy-session` in a WSL systemd user session. The compositor backend (nested Wayland in WSLg, or headless/vkms plus a bridge) is set by env from the GPU/compositor workstream. |
| `autostart.lua`: import-environment, dbus env, `omarchy-launch-shell`, `omarchy-provision-first-run`, `omarchy-hook post-boot` | A | Quickshell needs working EGL/GLES from Mesa d3d12, or a software fallback. |
| `autostart.lua`: `omarchy-powerprofiles-init` | C | Harmless; errors are ignored. |
| `autostart.lua`: `omarchy-hyprland-monitor-watch` | A | The clamshell and lid logic sees no lid. |
| `autostart.lua`: udiskie | C | No removable media. |
| `envs.lua` | A | Nothing GPU-vendor-specific fires. Add WSL env (for example `GALLIUM_DRIVER=d3d12`, cursor theme, `GDK_SCALE`) through `~/.config/uwsm/env.d/` or `hypr/*.lua`. |
| `monitors.lua` | B | The single virtual output is `WAYLAND-1` or `HEADLESS-1`. Set the mode to the Windows window or monitor size, and set `GDK_SCALE` from the Windows DPI instead of the default 2. |
| `input.lua` | B | Write `vconsole.conf`. CapsLock-as-Compose is fine. See §8 for keybindings. |
| Idle and lock (`shell.json` idle 150/300 s; `SUPER+CTRL+L`) | B | Disable screensaver and idle-lock by default, because the Windows lock already covers the session. Keep manual lock as an option. |
| System menu Suspend and Hibernate (`omarchy-hibernation-available`) | C | Hide them via the `~/.config/omarchy/extensions/omarchy-menu.jsonc` overlay. |
| System menu Shutdown and Reboot (`systemctl poweroff/reboot` → terminates the WSL distro) | B | Remap in the menu overlay. "Exit" should be `omarchy-system-logout` (`uwsm stop`), which returns to the Windows prompt. "Restart desktop" should be logout plus relaunch, with shutdown optional (`wsl --terminate`). |
| Wi-Fi, Bluetooth, power and monitor-brightness panels and bar widgets | C | Remove them from the bar layout in `~/.config/omarchy/shell.json`. The network widget can stay if NM is absent (it shows offline), but better to drop it or replace it. |
| Nightlight (hyprsunset) | A/B | It needs a CTM or gamma path in the backend. That is harmless nested; it may just do nothing. |
| Screenshots (grim/slurp/omasnap), screen recording (gpu-screen-recorder), color picker (hyprpicker), OCR | B | These depend on screencopy from the compositor. That works in principle, but gpu-screen-recorder's capture path needs verification. |

### 7.8 Shipped `/etc` drop-ins and units under WSL

| Item | WSL | Notes |
|---|---|---|
| `mkinitcpio.conf.d/*`, `limine-entry-tool.d/*`, `plymouth/plymouthd.conf`, zram conf, `tmpfiles.d/omarchy-zswap.conf`, `modprobe.d/*`, `udev/rules.d/60-omarchy-io-scheduler.rules` | C (inert) | These ship with `omarchy-settings` and cannot be excluded without forking. They are harmless because nothing reads them. The kyber scheduler rule may just fail silently on WSL's virtual disks. |
| `sddm.conf.d/*`, SDDM theme, `wayland-sessions/omarchy.desktop` | C (inert) | Keep them for fidelity. |
| `nsswitch.conf` (`resolve` before `files`/`dns`) | A | With resolved not running, nss-resolve returns UNAVAIL and lookup falls through to files and dns. |
| `resolved.conf.d/*`, `NetworkManager/conf.d/*` | C | Inert when those services are not enabled. |
| `docker/daemon.json` (`dns: 172.17.0.1`) | B | This relies on the resolved stub listener at 172.17.0.1. Without resolved, containers lose DNS. Drop the `dns` key in WSL (the post-update hook reasserts this, because `omarchy-settings` owns the file). |
| `sysctl.d/99-omarchy-sysctl.conf` | A/B | bbr and fq may or may not be available in the WSL kernel (a harmless warning). The swappiness of 150 assumes zram; acceptable, or override. |
| `systemd/oomd.conf.d`, `user/app.slice.d/10-oomd.conf` | B | Verify that `systemd-oomd` runs (PSI and cgroup v2). |
| `logind.conf.d/*`, `system.conf.d/*`, `user@.service.d/*` | A | |
| `sudoers.d/*`, `security/faillock.conf`, `profile.d/omarchy.sh` | A | |
| `/etc/os-release` override (`omarchy-settings` post_install) | A | WSL will show "Omarchy". |
| libalpm hooks: update guard, Hyprland reload pause/resume | A | |
| Limine's own pacman hook (if the real `limine` or `limine-mkinitcpio-hook` is installed) | C | Fails on every transaction with "FAT32 boot partition not found" (observed by taufderl/omarchy-wsl). Avoid it with the compat `provides`. |

---

## 8. Keybindings and Windows conflicts

### 8.1 Where bindings live

- `default/hypr/bindings/{applications,clipboard,media,tiling,utilities,voxtype}.lua` defines 195 `o.bind`/`o.bind_toggle` calls, including loops.
- `o.bind` (`default/hypr/helpers.lua`) wraps `hl.bind` and turns `{menu=…}`, `{panel=…}` and `{ipc=…}` targets into Quickshell global shortcuts (`omarchy:<kind>.<target>`) when they are listed in `default/omarchy/shortcuts`.
- Users add bindings in `~/.config/hypr/bindings.lua` with `o.bind` or `o.rebind`, or remove them with `hl.unbind`.
- `omarchy menu keybindings --print` (`Super+K`) lists them.
- Keycodes: `code:10…19` are the digits 1…0, `code:20`/`21` are minus/equal, `code:34`/`35` are `[`/`]`, and `code:201` is F23. That makes `SUPER+SHIFT+code:201` the **Copilot key** (Shift+Win+F23).

### 8.2 Full default list with Windows 11 collision

Legend:
- **⛔** Windows always handles it (secure attention sequence or workstation lock); no app or RDP hook can receive it.
- **⚠** A Windows shell or accessibility hotkey. The Linux side sees it only if the Windows-side client installs a low-level keyboard hook while focused, like mstsc in "apply Windows key combinations on the remote computer" mode.
- **ok** No stock Windows meaning.

Some Windows items depend on settings: PrtScn to Snipping Tool, color filters, the Copilot key, IME. Verify on the target build.

**Core and application launchers** (`applications.lua`):

| Keys | Omarchy action | Windows |
|---|---|---|
| SUPER+RETURN | Terminal (foot) | ok |
| SUPER+SHIFT+RETURN, SUPER+SHIFT+B | Browser | ok |
| SUPER+SHIFT+ALT+B | Browser (private) | ok |
| SUPER+SHIFT+F / SUPER+ALT+SHIFT+F | File manager / file manager (cwd) | ok |
| SUPER+SHIFT+N | Editor | ok |
| SUPER+ALT+RETURN | Tmux | ok |
| SUPER+CTRL+RETURN | Herdr | ⚠ Win+Ctrl+Enter toggles Narrator |
| SUPER+SHIFT+M | Music (Spotify) | ⚠ restores minimized windows |
| SUPER+SHIFT+ALT+M | Music TUI (cliamp) | ok |
| SUPER+SHIFT+D | Docker TUI | ok |
| SUPER+SHIFT+G | Signal | ok |
| SUPER+SHIFT+O | Obsidian | ok |
| SUPER+SHIFT+W | Omawrite | ok |
| SUPER+SHIFT+SLASH | 1Password | ok |
| SUPER+SHIFT+A / +ALT+A | ChatGPT / Grok web apps | ok |
| SUPER+SHIFT+C | HEY Calendar | ok (legacy charms) |
| SUPER+SHIFT+E / +ALT+E | HEY Email / new email | ok |
| SUPER+SHIFT+Y | YouTube | ok |
| SUPER+SHIFT+ALT+G / SUPER+SHIFT+CTRL+G | WhatsApp / Google Messages | ok |
| SUPER+SHIFT+P | Google Photos | ok |
| SUPER+SHIFT+S | Google Maps | ⚠ **Snipping Tool region capture** |
| SUPER+SHIFT+X / +ALT+X | X / X post | ok |

**Clipboard** (`clipboard.lua`; implemented with `send_key_state` Ctrl chords, with Ctrl+Shift for terminals):

| Keys | Action | Windows |
|---|---|---|
| SUPER+A | Select all | ⚠ Quick Settings |
| SUPER+C | Universal copy | ⚠ Copilot (Win11) |
| SUPER+V | Universal paste | ⚠ Clipboard history |
| SUPER+X | Universal cut | ⚠ Quick Link menu |
| SUPER+CTRL+V | Clipboard manager panel | ⚠ Sound output flyout (Win11) |

**Window and workspace management** (`tiling.lua`):

| Keys | Action | Windows |
|---|---|---|
| SUPER+W, SUPER+Q | Close window | ⚠ Widgets / Search |
| CTRL+ALT+DELETE | Close all windows | ⛔ Secure attention sequence |
| SUPER+J | Toggle split | ⚠ (focus tip, minor) |
| SUPER+P | Pseudo-tile | ⚠ Project/display mode |
| SUPER+T | Float/tile | ⚠ Cycle taskbar |
| SUPER+F | Fullscreen | ⚠ Feedback Hub |
| SUPER+CTRL+F | Tiled fullscreen | ⚠ Find computers (domain) |
| SUPER+ALT+F | Full width (maximize) | ok |
| SUPER+O | Pop out (float and pin) | ⚠ Lock rotation (tablets) |
| SUPER+ALT+Home / SUPER+Home | Save / restore window width | ok / ⚠ minimize all but active |
| **SUPER+L** | **Toggle dwindle/scrolling layout** | **⛔ Lock workstation** |
| SUPER+Arrows | Focus direction | ⚠ Snap |
| SUPER+SHIFT+Arrows | Swap window | ⚠ Move to monitor / stretch |
| SUPER+SHIFT+ALT+Arrows | Move workspace to monitor | ok |
| SUPER+1…0 | Workspace N | ⚠ Taskbar app N |
| SUPER+SHIFT+1…0 | Move window to workspace N | ⚠ New instance of taskbar app N |
| SUPER+SHIFT+ALT+1…0 | Move window silently | ok |
| SUPER+S, SUPER+grave | Toggle scratchpad (qconsole) | ⚠ Search / ok |
| SUPER+ALT+S, SUPER+SHIFT+grave | Move to scratchpad | ok |
| SUPER+TAB | Next workspace | ⚠ Task View |
| SUPER+SHIFT+TAB / SUPER+CTRL+TAB | Previous / former workspace | ok |
| ALT+TAB, ALT+SHIFT+TAB | Cycle windows (+bring to top) | ⚠ Windows switcher |
| CTRL+ALT+TAB, CTRL+ALT+SHIFT+TAB | Focus next/prev monitor | ⚠ Persistent switcher |
| SUPER+minus / SUPER+equal (and SHIFT/ALT/CTRL variants) | Resize | ⚠ Magnifier zoom out/in (plain Win+-/=) |
| SUPER+mouse wheel | Scroll workspaces | ok |
| SUPER+LMB / SUPER+RMB | Move / resize window | ok |
| SUPER+G | Toggle group | ⚠ Xbox Game Bar |
| SUPER+ALT+G | Remove from group | ⚠ Game Bar "record last 30 s" |
| SUPER+ALT+Arrows | Move into group | ⚠ Snap top/bottom half (24H2) |
| SUPER+ALT+TAB / +SHIFT | Next/prev in group | ok |
| SUPER+CTRL+Left/Right | Group focus | ⚠ **Switch virtual desktop** |
| SUPER+ALT+wheel | Cycle group | ok |
| SUPER+ALT+1…5 | Group window N | ⚠ Taskbar jump list |
| SUPER+SLASH / SUPER+ALT+SLASH | Monitor scaling up/down | ⚠ IME reconversion / ok |

**Utilities, menus and panels** (`utilities.lua`):

| Keys | Action | Windows |
|---|---|---|
| **SUPER+SPACE** | **Omarchy menu** | ⚠ Switch input language |
| SUPER+ALT+SPACE | Apps menu | ok |
| SUPER+SHIFT+code:201 (Copilot key) | Omarchy menu | ⚠ Copilot key |
| SUPER+ESCAPE | System menu | ⚠ Exit Magnifier (only while active) |
| SUPER+K | Keybindings cheatsheet | ⚠ Cast/Connect |
| SUPER+ALT+K | Tmux keybindings | ⚠ Mute mic in calls |
| SUPER+CTRL+K | Herdr keybindings | ok |
| SUPER+CTRL+E | Emoji picker | ok |
| SUPER+CTRL+C | Capture menu | ⚠ Color filters (if enabled) |
| SUPER+CTRL+O | Toggle menu | ⚠ On-screen keyboard |
| SUPER+CTRL+H | Hardware menu | ok |
| SUPER+CTRL+Q, XF86Calculator | Calculator (omacalc) | ⚠ Quick Assist / host calculator |
| SUPER+SHIFT+SPACE | Toggle top bar | ⚠ Previous input language |
| SUPER+CTRL+SPACE | Background switcher | ⚠ Previous IME |
| SUPER+SHIFT+CTRL+SPACE | Theme menu | ok |
| SUPER+BACKSPACE / +SHIFT / +CTRL | Transparency / gaps / square-aspect toggles | ok |
| SUPER+CTRL+ALT+F | Fullscreen desktop toggle | ok |
| SUPER+comma | Dismiss notification | ⚠ Peek at desktop |
| SUPER+SHIFT+comma / +CTRL / +ALT / +SHIFT+ALT | Dismiss all / silence / invoke last / history | ok |
| SUPER+CTRL+I | Toggle idle lock | ok |
| SUPER+CTRL+N | Toggle nightlight | ⚠ Narrator settings |
| SUPER+CTRL+Delete | Toggle laptop display | ok |
| SUPER+CTRL+ALT+Delete | Laptop display mirroring | ⛔ contains Ctrl+Alt+Del |
| Lid switch on/off | Lid close / clamshell | n/a in WSL |
| PRINT | Screenshot | ⚠ Snipping Tool (Win11 default) |
| ALT+PRINT | Screen recording | ⚠ Capture active window |
| SUPER+PRINT | Color picker | ⚠ Screenshot to file |
| SUPER+CTRL+PRINT | OCR capture | ok |
| SUPER+ALT+[ / ] | Webcam overlay size | ok |
| SUPER+CTRL+S | Share (LocalSend) | ⚠ Speech Recognition (legacy) |
| SUPER+CTRL+PERIOD | Transcode | ok |
| SUPER+CTRL+R / +ALT+R / SUPER+SHIFT+CTRL+R | Set / show / clear reminders | ok |
| SUPER+CTRL+ALT+T / B / W | Time / battery / weather toast | ok |
| SUPER+SHIFT+CTRL+A | Agent picker | ok |
| SUPER+CTRL+A / B / W / P / T | Audio / Bluetooth / Network / Power panel / btop | ok |
| SUPER+CTRL+D | Display panel | ⚠ **New virtual desktop** |
| SUPER+CTRL+ALT+D / E | Calendar / world clock | ok |
| SUPER+CTRL+1…9 | Bar panel N | ⚠ Last window of taskbar app N |
| SUPER+CTRL+Z / +ALT+Z | Zoom in / reset | ok |
| SUPER+CTRL+L | Lock (Quickshell) | ok (duplicates the Windows lock) |
| Slurp-scoped RETURN / CTRL+RETURN / TAB / CTRL+TAB / arrows | Region-capture helpers (temporary) | ok |

**Media keys** (`media.lua`): XF86Audio{Raise,Lower}Volume, Mute, MicMute, MonBrightness±, KbdBrightness±, KbdLightOnOff, TouchpadToggle/On/Off, AudioNext/Prev/Play/Pause, Eject, their ALT/SHIFT variants, and XF86PowerOff (system menu). **⚠/⛔:** Windows' HID stack consumes these globally for its own volume, brightness and media OSD. The Linux side mostly will not see them, which is acceptable because the Windows volume governs WSLg audio anyway.

**Voxtype** (only if installed): SUPER+CTRL+X toggles dictation (ok). F9 is push-to-talk (ok).

**Summary.**
- The two hard, uncapturable collisions are **Super+L** (Omarchy's layout toggle; Windows locks) and **Ctrl+Alt+Del** (and Super+Ctrl+Alt+Del). Rebind both.
- The headline bindings users learn first, **Super+Space, Super+K, Super+W/Q, Super+1…0, Super+Tab, Super+Arrows, Super+A/C/V/X, Super+S and Super+Shift+S**, are all Windows shell hotkeys. They reach Hyprland only if the Windows-side window captures the keyboard with a low-level hook, as RDP clients do in full-screen.

### 8.3 Omarchy-side remapping options (no fork)

1. **Rely on Windows-side capture**, owned by the WSLg/launcher research, for all ⚠ items while the Omarchy window has focus. Rebind only the ⛔ ones in `~/.config/hypr/bindings.lua`:
   ```lua
   o.rebind("SUPER + L", "Toggle workspace layout", …)
   ```
   Move the layout toggle to, say, `SUPER + ALT + L`, and close-all to `SUPER + CTRL + ALT + BACKSPACE`.
2. **Translate the modifier in Lua** if Windows-side capture is not possible (for example, windowed mode):
   - In `~/.config/hypr/hyprland.lua`, set `omarchy_default_bindings = false` before `require("default.hypr.omarchy")`.
   - Afterwards, wrap `o.bind` with a function that rewrites `SUPER` to a chosen chord (for example `ALT + SUPER`, or a CapsLock-derived `MOD3` via `kb_options`).
   - Then `require` the six `default.hypr.bindings.*` modules and restore `o.bind`.

   This reuses every upstream binding definition verbatim and picks up future upstream additions automatically. `sharpninja/omarchy-wslg`'s `scripts/hyprland-wsl.lua` already re-requires the same modules this way.
3. Also adjust the first-run welcome toast text and the `SUPER+SHIFT+code:201` Copilot mapping.

---

## 9. Update mechanism, migrations, and staying current

- **`omarchy update`** (`bin/omarchy-update`; docs/update-process.md) runs these steps in order:
  1. transcript to `/tmp/omarchy-update.log`, then the lock;
  2. 10 GiB free-space check;
  3. confirm, then one sudo authorization plus a keepalive;
  4. `paccache` prune;
  5. **snapper snapshot**, skipped silently when snapper is absent;
  6. stay-awake inhibitor;
  7. `omarchy-update-keyring`;
  8. `omarchy-update-system-pkgs` (`pacman -Syu --overwrite '/usr/share/omarchy/*'` through `omarchy-update-pacman`, which is `systemd-run --scope`);
  9. **`omarchy-migrate`** (per-user migrations);
  10. orphan review;
  11. status refresh;
  12. restart marked services and the shell;
  13. **`omarchy-hook post-update`**;
  14. mise update;
  15. AUR updates (yay, with no shared sudo);
  16. **reboot prompt**.

  In dev-link mode, it first does `git pull --ff-only` on the checkout.
- **Channels:** `omarchy-channel-set stable|rc|edge|dev`. The Omarchy-pinned Arch snapshot moves with Omarchy releases.
- **Migrations:** `migrations/<unix-ts>.sh` (133 on HEAD, from 1778623107 to 1790542069).
  - They run as the user through `omarchy-migrate`, with per-user markers in `~/.local/state/omarchy/migrations/`.
  - A fresh install marks all shipped migrations done (`--first-install`), and `/etc/skel` carries the markers.
  - At login, `omarchy-migrate-notify.service` prompts if any are pending.
  - Keyword survey: 28 install packages, 12 drop packages, 42 use sudo, 23 call systemctl, 9 touch Limine, 7 mkinitcpio, 4 NetworkManager.
  - Most boot-related ones guard with `omarchy-cmd-present limine-mkinitcpio || exit 0` or a config-file check. Some do not: for example `1789325478.sh` installs `linux-omarchy` plus headers and runs `limine-mkinitcpio`, and `1782002156.sh` retires networkd in favor of NM. Those are marked done at a fresh install, but **future migrations of this kind are the main ongoing risk for a WSL overlay**.
  - Real-world example: [omacom/omarchy#12531](https://github.com/omacom/omarchy/issues/12531) (2026-09-19, open). The `elsewhen` migration pulls in the `omarchy` package and breaks updates on the checkout-based WSL install from craigloewen-msft/Omarchy-wsl.
- **WSL pitfalls in the update path:**
  1. `bin/omarchy-update-restart` assumes a pacman-owned kernel in `/usr/lib/modules/*/vmlinuz` matches `uname -r`. Under WSL none does, so **every update ends with "Linux kernel has been updated. Reboot?"**. Answering yes runs `omarchy-system-reboot`, which runs `systemctl reboot` and terminates the distro.
  2. `omarchy-update-system-pkgs` must see the compat `provides`, or `pacman -Syu` will try to pull limine or snapper back in.
  3. `omarchy refresh pacman` and `omarchy-channel-set` rewrite `/etc/pacman.conf` from the template, so re-add WSL `IgnorePkg` lines and any womarchy repo through `~/.config/omarchy/hooks/pre-refresh-pacman.d/`.
  4. Migrations can re-enable NM, resolved or sddm, or install hardware packages. Reassert WSL invariants in `~/.config/omarchy/hooks/post-update.d/` (mask NM, resolved and sddm; strip `dns` from `daemon.json`). For migrations known to be inapplicable, a womarchy wrapper can `touch ~/.local/state/omarchy/migrations/<id>.sh` **before** `omarchy update` runs.
- **Staying on upstream:** use the real `omarchy` and `omarchy-settings` packages from `pkgs.omarchy.org/stable`, so updates arrive through upstream's own path with no merges. Only the WSL overlay (compat package, runner, hooks, launcher and user overrides) is ours. If a `bin/` change is unavoidable, `omarchy dev link` can point `OMARCHY_PATH` at a small fork checkout that rebases on release tags. `omarchy update` then fast-forwards that checkout, but `/etc/skel` and `/etc` still come from `omarchy-settings`, so the fork's delta must stay limited to `bin/`, `default/`, `shell/`, `themes/` and `config/`.

---

## 10. Recommended adaptation strategy (minimal divergence)

**Principle:** install real Omarchy and filter, don't fork. The factoring (flat `run_logged` lists, self-detecting hardware leaves, `/etc/skel` seeding, user overlays and hooks) makes an overlay cheap.

1. **Base.** Use the official Arch WSL image (`wsl --install archlinux`) or a womarchy `.wsl` image built the same way.
   - `/etc/wsl.conf`: `[boot] systemd=true`, `[user] default=<user>`, and interop settings.
   - `/etc/wsl-distribution.conf` `[oobe]` for first-run user creation, as taufderl/omarchy-wsl does.
   - Mask what Microsoft's custom-distro guidance lists (`NetworkManager`, `systemd-resolved`, `systemd-networkd`, `systemd-tmpfiles-*`/`tmp.mount` where applicable).
2. **Repos.** Import the `omarchy-keyring` key (`40DFB630FF42BCFFB047046CF0134EE680CAC571`) and write the Omarchy `pacman-stable.conf` and `mirrorlist-stable`. `bin/omarchy-upgrade-to-quattro` (`configure_pacman_channel`, `install_keyrings`) is a ready-made reference for doing this on an existing Arch system. Add `IgnorePkg = linux linux-* *-dkms linux-firmware*`.
3. **`womarchy-compat` package** (ours): `provides=(limine limine-mkinitcpio-hook limine-snapper-sync snapper)` and `conflicts` the same.
   - This satisfies `omarchy`'s x86_64 dependencies without Limine's pacman hook (which fails every transaction), mkinitcpio, or snapper. `omarchy-snapshot` then exits 127, which the update ignores.
   - Keep `sddm` and `plymouth` really installed but disabled; they are inert, and upstream scripts expect their files (`/etc/pam.d/sddm-autologin`).
   - The package also carries the womarchy scripts and defaults below.
4. **Packages.** `pacman -S omarchy-keyring omarchy-settings omarchy-nvim omarchy` plus the filtered `omarchy-base.packages`, plus PipeWire, plus the WSL GPU set (`mesa`, `vulkan-dzn`, `vulkan-icd-loader`, `xorg-xwayland`).
   - Drop from the base list: bluez\*, cups\*, avahi/nss-mdns, networkmanager (or install it but never enable it), power-profiles-daemon, brightnessctl, ddcutil, bolt, asdcontrol, kernel-modules-hook, tzupdate, wireless-regdb, udiskie, and optionally ufw/ufw-docker and qemu-user-static-binfmt.
   - Optional "lite" profile: skip the preinstalls and write `~/.local/state/omarchy/preinstalls-removed`, which also hides their bindings.
5. **System apply.** `womarchy-apply-system`: copy the ~20 lines of env and logging from `bin/omarchy-apply-system`, then iterate each upstream `all.sh` and run only the lines whose leaf path is not on the skip list.
   ```bash
   while read -r l; do
     [[ $l =~ run_logged\ \"?\$OMARCHY_INSTALL/([^\"]+)\"? ]] || continue
     skip "${BASH_REMATCH[1]}" || run_logged "$OMARCHY_INSTALL/${BASH_REMATCH[1]}"
   done < "$OMARCHY_INSTALL/config/all.sh"
   ```
   - **Default-allow** for `config/` and `post-install/`: skip `config/snapper.sh`, `config/enable-services.sh` (replaced) and `config/firewall.sh` (opt-in).
   - **Default-deny** for `hardware/` and `login/`.
   - Then run WSL leaves: `wsl/enable-services.sh`, `wsl/gpu.sh`, `wsl/audio.sh` (pulse-tunnel), `wsl/keyboard-locale.sh` (vconsole, locale), and `wsl/docker-dns.sh`.
   - Add a CI check that diffs upstream `all.sh` files on each release tag and flags new leaves for classification.
6. **User finalize.** `sudo -u USER env OMARCHY_SETUP_CONTEXT=wsl OMARCHY_USER_NAME=… OMARCHY_USER_EMAIL=… omarchy-provision-user --first-install` runs unmodified. Then apply the WSL user overlay:
   - `~/.config/hypr/monitors.lua`: output mode and `GDK_SCALE` from the Windows DPI;
   - `~/.config/hypr/bindings.lua` / `hyprland.lua`: the ⛔ rebinding, and optionally the modifier translation (§8.3);
   - `~/.config/omarchy/shell.json`: idle off; drop the bluetooth, network and power widgets;
   - `~/.config/omarchy/extensions/omarchy-menu.jsonc`: hide Suspend, Hibernate, Wi-Fi, Bluetooth, firmware and snapshot rows, and make "Shutdown" mean exit to Windows;
   - `~/.config/omarchy/hooks/{post-update.d,pre-refresh-pacman.d}/10-womarchy`;
   - `~/.config/uwsm/env.d/10-womarchy` for the WSL GPU and backend env;
   - optionally remove `toggles/hypr/no-animations.lua` when GPU acceleration is confirmed.
7. **Session.** The Windows command `womarchy` runs `wsl.exe -d <distro> -u <user> -- womarchy-session`. That makes sure the systemd user manager and `XDG_RUNTIME_DIR` exist, prepares the display backend (per the compositor workstream), and then `exec uwsm start -g -1 -e -D Hyprland hyprland.desktop` (the same line as `omarchy.desktop`). Hyprland's autostart then runs `omarchy-provision-first-run` unchanged. Exit through Super+Esc → Logout (`uwsm stop`); `wsl.exe` returns to the Windows prompt.
8. **Updates.** Use `omarchy update` as-is, with the hooks above. Pre-mark known-inapplicable migrations. Accept the spurious kernel reboot prompt or get it fixed upstream.
9. **Optional upstream PRs.** Keep them tiny and self-contained:
   - `bin/omarchy-hw-wsl`: `systemd-detect-virt --container` equals `wsl`, or `/proc/sys/fs/binfmt_misc/WSLInterop` exists.
   - One-line guards in `config/snapper.sh`, `config/enable-services.sh`, `config/firewall.sh`, `hardware/all.sh` (early return), `user/first-run/wifi.sh`, `bin/omarchy-update-restart` (skip the kernel check when no pacman-owned kernel exists, which also helps containers), and `bin/omarchy-system-{shutdown,reboot}`.

   Upstream acceptance is uncertain. DHH is reported to have said "WSL2 is not suitable to run Omarchy" (X, 2026-04-03, snippet only), and the official Windows route is the VM-based `try-omarchy-windows`. So design for the overlay first and treat upstreaming as a bonus.

---

## 11. Blocking assumptions at the platform boundary (hand-off to the compositor/GPU research)

These are not fixable on the Omarchy side, but Omarchy hard-requires them:

1. **Hyprland 0.56.2 / Aquamarine needs a GBM allocator on a DRM node.** WSL has only `/dev/dxg` and no `/dev/dri`.
   - clarenceb/omarchy-wsl2's `docs/12-wayland-on-wsl2.md` documents that the headless backend fails with "no allocator available". The nested Wayland backend in WSLg fails with "Missing protocols", because WSLg Weston lacks `zwp_linux_dmabuf_v1` and offers only `xdg_wm_base` v1.
   - The WSL 6.18.33.2 kernel ships `vkms.ko`, which is a possible render/scanout node.
   - The only known Hyprland-in-WSL proof (sharpninja/omarchy-wslg) uses a custom kernel with VKMS, a C protocol bridge that offers dmabuf and xdg-shell to Hyprland and copies frames to shm, and `GALLIUM_DRIVER=llvmpipe` (CPU rendering). It also bypasses `uwsm start`.
   - See also [hyprwm/Hyprland#3479](https://github.com/hyprwm/Hyprland/issues/3479) and [discussion #4333](https://github.com/hyprwm/Hyprland/discussions/4333) (maintainers: not supported), and [hyprwm/aquamarine#398](https://github.com/hyprwm/aquamarine/issues/398) (xdg_wm_base < v6 abort).
2. **Quickshell (Qt Quick), Chromium, Electron, mpv/owe, OBS and Kdenlive expect EGL/GLES with dmabuf from the compositor.** With Mesa d3d12 there is no dmabuf/GBM, so expect a copy-back or llvmpipe path. This is the reason `vm-no-animations` is probably desirable at first.
3. **Clipboard:** WSLg lacks a clipboard-manager protocol ([microsoft/wslg#1512](https://github.com/microsoft/wslg/issues/1512)). Any nested compositor must bridge the Windows clipboard itself. Omarchy's "universal clipboard" (`SUPER+C/V`) only works inside Hyprland.
4. **uwsm** needs a working systemd user manager and `graphical-session.target` in WSL. It is available with `systemd=true`, but the launcher must create a proper login session.

---

## 12. Existing WSL efforts (web research, 2026-09-30)

Repositories were verified via the GitHub API or a clone; X/Twitter items come from search snippets only.

| Project | Date / ★ | What it achieves | Limitations |
|---|---|---|---|
| [craigloewen-msft/Omarchy-wsl](https://github.com/craigloewen-msft/Omarchy-wsl) (Craig Loewen, Microsoft WSL PM) | 2026-06-16 → 08-31, 25★ | Builds `Omarchy-Basic.wsl` (pinned to v4.0.0, amd64 and arm64). The install script places a **git checkout at `/usr/share/omarchy`** instead of installing the package. | **Terminal/TUI only**, with no Hyprland or GUI. The checkout approach breaks on migrations ([#12531](https://github.com/omacom/omarchy/issues/12531); fix [PR #12532](https://github.com/omacom/omarchy/pull/12532) is still open). |
| [taufderl/omarchy-wsl](https://github.com/taufderl/omarchy-wsl) | 2026-08-28, 2★ | Installs the **real `omarchy` package** and runs upstream `install/config/all.sh` and `post-install/all.sh` wholesale, without `set -e`. Skips `hardware/`. Uses `IgnorePkg` for kernels and DKMS. Disables sddm, cups and avahi; masks NM, resolved and networkd. Uses WSL `[oobe]` to run the real `omarchy-provision-owner`. `docs/install-audit.md` records real failures: snapper, and the Limine hook failing on every transaction. | "v1 runs without a Hyprland desktop session." GUI apps open one per WSLg window, and nested Hyprland is on the roadmap. |
| [clarenceb/omarchy-wsl2](https://github.com/clarenceb/omarchy-wsl2) | 2026-08-28 → 08-30, 1★ | Three modes: headless; WSLg apps; a full desktop using **sway** (not Hyprland) with Omarchy keys and themes, either nested or over VNC. Best technical write-up of why Hyprland fails (`docs/12-wayland-on-wsl2.md`). | CPU rendering, no animations, blur or Xwayland in the session, and a single output. |
| [sharpninja/omarchy-wslg](https://github.com/sharpninja/omarchy-wslg) | 2026-09-23/24, 0★ | **Real Hyprland plus the Omarchy shell nested in one WSLg window** (windowed or `--fullscreen`), using a C bridge that provides `zwp_linux_dmabuf_v1` and xdg-shell and copies frames to shm. | Custom WSL kernel with VKMS (affects all distros), llvmpipe CPU rendering, no `uwsm start`, no `pacman -Syu`, paths hardcoded to the author's PC. Not independently confirmed. |
| [valorisa/ArchLinux-Omarchy-WSL-Script](https://github.com/valorisa/ArchLinux-Omarchy-WSL-Script) | 2025-10-29 | A French guide and script that installs Arch, Hyprland and Omarchy. | Never shows Hyprland actually running. |
| [hypn/omarchy-for-wsl](https://github.com/hypn/omarchy-for-wsl), [peregrinus879/eyrwsl](https://github.com/peregrinus879/eyrwsl), [tvcam/omarchy-theme-wsl](https://github.com/tvcam/omarchy-theme-wsl) ([article](https://gotabs.net/omarchy-wsl-cross-platform-theme-sync)) | 2025–2026 | Fork, terminal setup, and theme sync respectively. | Config and themes only. |
| Omakub-era: [Nuzair46/omakub-wsl](https://github.com/Nuzair46/omakub-wsl), [andreimaxim/omakub-on-wsl](https://github.com/andreimaxim/omakub-on-wsl), [tunacinsoy/omawsl](https://github.com/tunacinsoy/omawsl), [Ivan Morgillo's blog post](https://www.ivanmorgillo.com/2024/11/05/bringing-dhhs-omakub-to-wsl2/) | 2024–2026 | CLI-only ports. | No desktop. |

Official stance and signals:
- [omarchy discussion #473](https://github.com/basecamp/omarchy/discussions/473) (2025-08-03, nunix): WSL2 is possible but "(very) targeted at the terminal apps"; no maintainer reply.
- [omarchy-iso#150](https://github.com/omacom/omarchy-iso/issues/150) and [discussion #10748](https://github.com/omacom/omarchy/discussions/10748) ask for an official `.wsl`; no maintainer response.
- DHH on X (snippets, unverified): "WSL2 is not suitable to run Omarchy" ([2026-04-03](https://x.com/dhh/status/2040125734992126412)) and "Forget WSL, use WIO!" ([2026-08-27](https://x.com/dhh/status/2092998884519792717)).
- The **official Windows route is a VM**: [omacom/try-omarchy-windows](https://github.com/omacom/try-omarchy-windows) (516★, QEMU on Windows Hypervisor Platform, VirGL/Venus GPU), which grew out of [Chainfire/omarchy-windows-hyperv-gpu](https://github.com/Chainfire/omarchy-windows-hyperv-gpu).
- Omakub: DHH floated a `?wsl=true` mode in [omakub#16](https://github.com/omacom/omakub/issues/16) (2024), then declined a headless mode in [PR #72](https://github.com/basecamp/omakub/pull/72).
- `manual/49-omarchy-on.md` lists community ports (Asahi, Parallels, VirtualBox, VMware, Steam Deck, NixOS) but does not mention WSL.
- No repo named "womarchy" exists on GitHub.

**Takeaways for womarchy:**
- Follow taufderl's "real packages, upstream scripts, filtered" approach, not the checkout-at-`/usr/share/omarchy` approach, because of #12531.
- Nobody has yet shown **GPU-accelerated** Hyprland in WSL. The single working Hyprland demo uses CPU rendering plus a protocol bridge, so the compositor/GPU path is the critical risk, not the Omarchy install.

---

## 13. Key file index

- **Orchestration:** `bin/omarchy-apply-system`, `bin/omarchy-apply-hardware`, `bin/omarchy-provision-user`, `bin/omarchy-provision-first-run`, `bin/omarchy-provision-owner`, `install/helpers/logging.sh`, `install/{config,hardware,login,post-install,user}/all.sh`
- **Packages:** `install/omarchy-base.packages`, `install/omarchy-other.packages`, `default/pacman/*`
- **Session:** `default/wayland-sessions/omarchy.desktop`, `default/uwsm/env.d/10-omarchy`, `default/uwsm/default`, `default/bash/env-bootstrap`, `etc/sddm.conf.d/*`, `default/sddm/hyprland.lua`
- **Hyprland:** `config/hypr/*.lua`, `default/hypr/*.lua`, `default/hypr/bindings/*.lua`, `default/hypr/apps/*.lua`, `default/hypr/toggles/*.lua`, `default/omarchy/shortcuts`
- **Shell:** `shell/`, `docs/omarchy-shell.md`, `config/omarchy/shell.json`, `default/omarchy/omarchy-menu.jsonc`, `config/omarchy/extensions/omarchy-menu.jsonc`, `docs/menu.md`
- **Updates:** `bin/omarchy-update*`, `bin/omarchy-migrate*`, `bin/omarchy-snapshot`, `bin/omarchy-update-restart`, `docs/update-process.md`, `agents/skills/migrations.md`, `migrations/`
- **Legacy reference:** `bin/omarchy-upgrade-to-quattro` (installing v4 on an existing Arch system); tag `v3.8.4` (`boot.sh`, `install.sh`, `install/preflight/guard.sh`)
- **Docs:** `docs/file-layout.md`, `agents/skills/install-scripts.md`, `manual/07-hotkeys.md`, `manual/51-unattended-installs.md`
