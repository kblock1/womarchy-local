# womarchy, built locally

This is [sytelus/womarchy](https://github.com/sytelus/womarchy) (Omarchy on WSL with a GPU-composited
Hyprland desktop) plus a few fixes, set up so that **everything that runs is built on your own PC from
source** and signed with a key only you hold. Nothing comes from upstream's GitHub releases.

| Piece | Built from | Where it's built |
|---|---|---|
| `omarchy.exe` (viewer/launcher) | `windows/omarchy` (Rust) | Windows, `cargo build --release` |
| aquamarine, Hyprland, Mesa | upstream release tarballs (sha256-pinned, same hashes as Arch's PKGBUILDs) + `patches/` | `womarchy-build` WSL distro |
| womarchy-session, -compat, -keyring | this repo | `womarchy-build` |
| The Omarchy image | official Omarchy packages (`pkgs.omarchy.org`, key pinned in `linux/image/omarchy-key.env`) + Omarchy's Arch snapshot + the packages above | `womarchy-build` |

## What differs from upstream

- **Your own `[womarchy]` repo and key.** `tools\local-setup.ps1` creates a signing key inside the
  `womarchy-build` distro (it never leaves it), puts its public half in `womarchy-keyring`, pins its
  fingerprint, and points the image's `WOMARCHY_REPO_URL` at this checkout's `out\repo`. Installed
  systems read new packages straight from that folder on `omarchy update`.
- **Monitors you can leave to Windows.** `omarchy.exe` honours two user environment variables:
  `OMARCHY_SKIP_MONITORS` (monitors Omarchy leaves alone, e.g. the one with the Windows taskbar and
  tray) and `OMARCHY_MAIN_MONITOR` (Omarchy's main output, workspace 1; default: Windows' primary).
  See [Monitors](#monitors).
- **Pick the GPU.** `WOMARCHY_GPU_ADAPTER` in `/etc/womarchy/config` sets
  `MESA_D3D12_DEFAULT_ADAPTER_NAME`. On a PC with an integrated GPU and a discrete card, Mesa can
  otherwise render on the integrated one.
- **WSL disks hidden from udisks.** Every WSL distro sees the VM's loop devices (Docker Desktop's
  ISOs) and virtual disks; without this, Omarchy's udiskie asks for a password to mount them at every
  login.
- **Keyboard:** right Shift works, and Windows' synthetic modifier keys (around AltGr and Num Lock
  navigation keys) no longer leak through.
- **No download fallback.** `omarchy install` needs a local image path.

## You need

- Windows 11 and a GPU driver with WSL support (any current NVIDIA, AMD or Intel driver).
- **WSL 3.0.1 or later.** Check with `wsl --version`; update with `wsl --update` (asks for admin).
  This updates WSL for all your distros: they keep their files, but WSL restarts.
- **Rust** for `omarchy.exe`: [rustup](https://rustup.rs) with the default MSVC toolchain, which needs
  the Visual Studio Build Tools ("Desktop development with C++").
- **git**, and about **35 GB free** on C: (build distro, build outputs and the installed desktop).
- Scripts allowed to run: if PowerShell refuses `tools\*.ps1`, run
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

The first build compiles aquamarine, Hyprland and Mesa from source, so give it a while.

## Build and install

Clone to a path without spaces (the image stores it as a `file://` URL):

```powershell
git clone <this repo's URL> C:\dev\womarchy-local
cd C:\dev\womarchy-local

tools\local-setup.ps1    # once: the womarchy-build distro and your signing key
tools\local-build.ps1    # packages, signed repo, image (out\Omarchy-*.wsl), omarchy.exe
```

`local-build.ps1` ends by printing the install command for what it built, along the lines of:

```powershell
& C:\dev\womarchy-local\install.ps1 -Image C:\dev\womarchy-local\out\Omarchy-<version>-womarchy-<date>.wsl `
    -Exe C:\dev\womarchy-local\windows\omarchy\target\release\omarchy.exe
```

The installer explains what it will do, asks before changing anything, then asks you to choose a user
name and password for Omarchy. Then start it with **Omarchy** in the Start menu or `omarchy` in a
terminal. The rest of [README.md](README.md) (use, shortcuts, troubleshooting) applies as written.

`local-setup.ps1` edits a few tracked files: the keyring (`womarchy.asc`, `womarchy-trusted`, its
`PKGBUILD`), `omarchy-key.env` and the image's `config`. Keep those edits: commit them on your own
branch if you like. Building and signing refuse to run until they are in place.

`local-build.ps1` can also do single steps: `-Packages <names>`, `-Image [-Lite]`, `-Exe`, and `-Sync`
(move the build distro to Omarchy's current Arch snapshot first). `-Lite` leaves out Omarchy's largest
apps (LibreOffice, OBS, Kdenlive, ...), which you can still install later from Omarchy's menu.

## Settings

**Image settings** live in `linux\image\rootfs\etc\womarchy\config`. Set them before building the
image (the installed system keeps them in `/etc/womarchy/config`):

- `WOMARCHY_DOCKER=1` (default): Omarchy's own Docker. Use `0` if Docker Desktop's WSL integration
  should serve the distro instead (Docker Desktop > Settings > Resources > WSL integration > Omarchy).
- `WOMARCHY_GPU_ADAPTER=`: part of the GPU's name, e.g. `NVIDIA`, if Mesa picks the wrong GPU. Check
  inside Omarchy with `eglinfo -B -p surfaceless | grep renderer`. It is read at login, so in an
  installed system you can edit `/etc/womarchy/config` and log out and back in.

### Monitors

`omarchy status` lists every monitor with its Windows name (`DISPLAY1`, ...), its device path, and
whether Omarchy uses it. Both variables take Windows names or any part of the device path (comma
separated). Device-path parts (such as `UID4100`, or the monitor's model code) survive reboots and
driver updates better than `DISPLAYn` numbers.

```powershell
[Environment]::SetEnvironmentVariable("OMARCHY_SKIP_MONITORS", "UID4100", "User")
[Environment]::SetEnvironmentVariable("OMARCHY_MAIN_MONITOR", "DISPLAY2", "User")
```

Start Omarchy again from a new terminal or the Start menu to pick them up.

## Updating

- **Omarchy itself:** `omarchy update`, as upstream. Omarchy's packages come from Omarchy; womarchy's
  come from your `out\repo`. `omarchy rollback` undoes the last update.
- **When `omarchy update` stops:** Omarchy's Arch snapshot moves, and when it moves Hyprland's
  libraries or LLVM, pacman refuses the update (womarchy's builds pin exact library versions; the LLVM
  guard says so explicitly). Then rebuild what broke against the new snapshot, and update again:

  ```powershell
  tools\local-build.ps1 -Sync -Packages mesa-womarchy       # or: aquamarine hyprland
  ```

  If the package's version didn't change, bump `pkgrel` in its `PKGBUILD` first so pacman sees it as
  newer.
- **Upstream changes:** `git remote add upstream https://github.com/sytelus/womarchy.git`,
  `git fetch upstream`, `git merge upstream/main`, then rebuild.

## Your signing key

The private key is in the `womarchy-build` distro (`/home/builder/.womarchy-gnupg`), unencrypted (no
passphrase) so that signing can run unattended. Anyone with a copy of it can sign packages your
installed Omarchy will trust, so treat everything that contains the build distro as containing the key:

- a `wsl --export` of `womarchy-build`;
- its virtual disk, `ext4.vhdx` in the `-Location` folder (`C:\WSL\womarchy-build` by default), and
  any copy of that folder;
- backups that include that folder (File History, OneDrive or other sync tools, disk images).

Keep those private and on encrypted storage (BitLocker or similar), and never put them in this
repository or anything you share. The key is outside this checkout, and `.gitignore` plus
`tools\check-secrets.py` guard against committing key material by accident, but neither can see the
build distro.

Your installed Omarchy trusts only that key for womarchy's packages, so keep the build distro. If you
lose it, `local-setup.ps1` makes a new key, and you then need a new image and a reinstall
(`omarchy backup` first).

## Removing it

`omarchy uninstall` removes the desktop, its Start menu entry and the `omarchy` command.
`wsl --unregister womarchy-build` removes the build distro (and with it your signing key).
