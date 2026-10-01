# Troubleshooting

Start with `omarchy status` in a Windows terminal. It shows:
- the WSL version, the distro and whether its first-run setup is done;
- the GPU (`/dev/dxg`), the shared-memory mount, the monitors Windows reports, and our package versions.

## Where the logs are

| What | Where |
|---|---|
| The viewer (`omarchy.exe`) | Its terminal, when started from one. `omarchy --stats` adds frame rates. |
| The session and Hyprland | In the distro: `~/.cache/womarchy/session.log`, `~/.cache/womarchy/hyprland.log` (the previous session: `session.log.1`). |
| First-run setup | `/var/log/womarchy-oobe.log` (root only). |
| Omarchy's per-user setup | `~/.local/state/womarchy/provision-user.log`. |
| Services | `journalctl -b` and `journalctl --user -b`, inside the distro. |

To get a shell in the distro: `wsl -d Omarchy`.

## Installing

**"WSL is not installed" or "too old".**
Run the installer again (`irm https://raw.githubusercontent.com/sytelus/womarchy/main/install.ps1 | iex`). It installs or updates WSL and asks for administrator permission once. By hand, in an administrator terminal:
- `wsl --install --no-distribution`, then restart Windows;
- or `wsl --update`.

**The image download fails or is corrupt.** Run `omarchy install` again. To use a file you downloaded yourself: `omarchy install C:\path\to\Omarchy.wsl`.

**The first-run setup stopped half-way.** Run `omarchy` again; it resumes the setup. If it keeps failing, look at `/var/log/womarchy-oobe.log` (`wsl -d Omarchy -u root cat /var/log/womarchy-oobe.log`).

**"Omarchy's user setup is incomplete".** The per-user part of Omarchy's setup needs the network the first time. Open a terminal in the desktop (Super+Return) and run `womarchy-provision-user`.

## Starting

**"the desktop did not answer" / "could not connect to the desktop".** The compositor did not come up within a minute.
- Run `omarchy` again from a terminal and read the session log (above).
- If Hyprland crashed, `hyprland.log` says why.

**"a previous Omarchy session is still running".** The last desktop is still shutting down. Wait a few seconds, or run `wsl --terminate Omarchy` (this stops only the Omarchy distro).

**"no GPU acceleration available (/dev/dxg missing)": slow desktop, software rendering.**
- Update your GPU driver: current NVIDIA, AMD and Intel drivers support WSL.
- Inside a virtual machine, or on a GPU without a WSL driver, there is no `/dev/dxg`. Omarchy still runs, but slowly.

**`omarchy status` says "Shared mem: not mounted".** Frames then travel through the socket instead of shared memory: everything works, but uses more CPU. The shared memory comes from WSLg, which is on by default. Check that `%UserProfile%\.wslconfig` doesn't contain `guiApplications=false`.

**The first start is slow.** A stopped distro has to boot (a few seconds), and large monitors take longer to set up (three 4K monitors: about 5 s). Later starts are faster while the distro is still running.

**Nothing works after a Windows or WSL update.** Run `wsl --shutdown` (this stops all WSL distros), then `omarchy` again.

## Using the desktop

**A key does nothing.** Windows keeps some keys for itself, whatever has focus:
- **Win+L** locks Windows. Omarchy's Super+L is moved to **Super+Alt+L**.
- **Ctrl+Alt+Del** opens Windows' security screen. Omarchy's "close all windows" is on **Super+Ctrl+Alt+Backspace**.
- **Ctrl+Alt+End** minimises the Omarchy desktop, so you can get back to Windows at any time.

**Wrong keyboard layout.** The first-run setup copies Windows' keyboard layouts. If you have several, **Alt+Shift** switches between them. To change them:
- edit `XKBLAYOUT` (e.g. `us,de`) and `XKBOPTIONS` in `/etc/vconsole.conf`;
- then log out and start `omarchy` again.

**Copy/paste between Windows and Omarchy.** Text and images are shared, both ways. When the clipboard holds both, the text is sent. Anything a password manager marks as secret is not shared, in either direction.

**Web pages with 3D graphics (WebGL) don't work in Chromium.** Chromium can't share its GPU frames with the desktop here, so it falls back to drawing everything on the CPU, without WebGL. Everyday browsing works fine.

`--ignore-gpu-blocklist` alone makes WebGL report as working, but its output stays blank. For WebGL-heavy sites, either use a browser on Windows, or switch Chromium to X11:
1. In `~/.config/chromium-flags.conf`, change `--ozone-platform=wayland` to `--ozone-platform=x11` and add the line `--ignore-gpu-blocklist`.
2. Restart Chromium.

WebGL then works, but costs 2–4 CPU cores while a 3D page animates, and windows may look softer on scaled monitors.

**Microphone.** Windows' microphone reaches Linux as the `RDPSource` input (through WSLg). If apps hear nothing, check that Windows Settings → Privacy & security → Microphone allows desktop apps.

**Blurry or wrongly sized desktop.** Each monitor gets the scale Windows uses for it, rounded to a scale Hyprland supports (175% becomes 166.7%). After changing Windows' display settings, the desktop follows within a second. If it doesn't, log out and start again.

**Coming back to Windows.** Log out of Omarchy: Super+Escape opens the system menu. `omarchy` then returns to the prompt.

## Updating and undoing updates

**How to update.** Run `omarchy update` in a Windows terminal, or use "Update System" inside the desktop. Both run Omarchy's own updater. `omarchy update` also asks once whether to make a full backup before each update.

**Undoing an update:**

| Command | What it puts back | Cost |
|---|---|---|
| `omarchy rollback` | The package versions from before the last update (recorded automatically before every update) | Seconds, almost no disk |
| `omarchy rollback --list` | Shows the saved points; `--to N` picks an older one | |
| `omarchy restore` | The whole distro, as in the last `omarchy backup` (your files included) | A few minutes; disk about the size of the distro |

`omarchy backup` and `omarchy restore` need the desktop to be closed (log out first).

**Old packages:** rollback looks for them in pacman's cache first. If they aren't there, it asks before downloading them from the Arch and womarchy archives.

**An update stops with "breaks dependency … required by hyprland" (or aquamarine), or with a womarchy message about Mesa and LLVM.** Omarchy's package snapshot moved ahead of womarchy's own builds of Hyprland, aquamarine or Mesa. Nothing was changed: the update stopped before installing anything. womarchy's automatic check notices this within a day and opens a [rebuild-needed issue](https://github.com/sytelus/womarchy/issues?q=label%3Arebuild-needed). Once the rebuilt packages are published, run the update again.

**"Linux kernel has been updated. Reboot?" at the end of an update.** Answer **no**. WSL uses Microsoft's kernel, so there is nothing to reboot into; "yes" only stops the distro.

## Other WSL distros after the WSL update

Updating WSL changes it for every distro. On WSL 3.0.1 we saw two problems in Ubuntu distros. Neither is caused by Omarchy, and both are harmless but leave `systemctl is-system-running` reporting `degraded`.

**`systemd-binfmt.service` fails** ("Failed to flush binfmt_misc rules: Read-only file system"). WSL 3.0.1 no longer lets distros flush all binfmt rules. The rules still register, but systemd-binfmt exits with an error. Fix, inside the affected distro:
```
sudo mkdir -p /etc/systemd/system/systemd-binfmt.service.d
sudo tee /etc/systemd/system/systemd-binfmt.service.d/wsl-readonly-flush.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-binfmt
ExecStop=
ExecStop=-/usr/lib/systemd/systemd-binfmt --unregister
EOF
sudo systemctl daemon-reload && sudo systemctl reset-failed
```

**`getty@tty1.service` keeps failing** (start limit hit). WSL has no text consoles. Fix: `sudo systemctl mask getty@tty1.service && sudo systemctl reset-failed`.

## Removing Omarchy

`omarchy uninstall` removes:
- the distro (with everything inside it: it asks you to type its name);
- the Start menu entry, `omarchy.exe` and its PATH entry.

WSL itself and your other distros stay. If `omarchy` is already gone:
- `wsl --unregister Omarchy`;
- delete `%LOCALAPPDATA%\Programs\Omarchy` and the "Omarchy" Start menu shortcut;
- remove that folder from your user PATH (a backup of your PATH is in `path-backup.txt` there).

## Reporting a problem

Open an issue at https://github.com/sytelus/womarchy/issues. Include:
- the output of `omarchy status`;
- the last lines of `~/.cache/womarchy/session.log` and `hyprland.log`.

Check them for anything private first.
