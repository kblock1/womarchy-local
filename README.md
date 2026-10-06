# Omarchy on WSL with full GUI and Graphics

> [!IMPORTANT]
> **This copy builds everything on your own PC.** It is [sytelus/womarchy](https://github.com/sytelus/womarchy)
> plus a few fixes, signed with your own key, with nothing downloaded from upstream's releases. Skip
> the `irm ... | iex` install below and follow **[LOCAL-BUILD.md](LOCAL-BUILD.md)**.

**Your [Omarchy](https://omarchy.org) desktop on Windows 11, one command away.** It runs in
[WSL](https://learn.microsoft.com/windows/wsl/about), full screen on every monitor, on your GPU. No
dual boot, no reboot: type `omarchy` at any Windows prompt to get the desktop, and log out to get your
prompt back.

![Demo: typing omarchy in Windows Terminal opens the Omarchy desktop: fastfetch on an NVIDIA GPU, tiling windows with btop, Omarchy's menu, the theme gallery switching themes live, and OpenGL gears with a Vulkan cube running through Direct3D 12](docs/img/demo.gif)

## Highlights

- 🖥️ **Every monitor, full screen.** Each monitor gets its native resolution and the scale Windows uses for it (mixed DPI is fine). Plug in or rearrange monitors while it runs. Tested on three 4K monitors.
- 🚀 **On your GPU.** Hyprland composites on your graphics card, and finished frames reach Windows through shared memory, without copies. OpenGL and Vulkan apps are GPU accelerated too.
- ⌨️ **One command in, log out to leave.** `omarchy` from any terminal, or **Omarchy** in the Start menu.
- 📋 **Clipboard both ways**, for text and images.
- 🔊 **Sound and microphone**, through WSL.
- 🛟 **Updates you can undo.** `omarchy update` runs Omarchy's own updater. A rollback point is recorded before every update, and `omarchy rollback` puts the previous versions back. womarchy's packages come from a signed repository.
- 💾 **Whole-distro backups** with `omarchy backup` and `omarchy restore`.
- 🧹 **Leaves Windows alone.** No custom kernel, no kernel modules, no global WSL settings. `omarchy uninstall` removes everything.

![Omarchy on three 4K monitors with mixed DPI, a GL and a Vulkan app running](docs/img/three-monitors.png)

## Install

**You need:** Windows 11 and a GPU driver with WSL support (any current NVIDIA, AMD or Intel driver).

This copy downloads nothing from upstream's releases: you build `omarchy.exe` and the Omarchy image
yourself, then install them. In **PowerShell** (no need to run it as administrator), in a clone of this
repository at a path without spaces:

```powershell
tools\local-setup.ps1    # once: the build distro and your own signing key
tools\local-build.ps1    # packages, signed repo, image, omarchy.exe; ends with the install command
```

[LOCAL-BUILD.md](LOCAL-BUILD.md) has the requirements and details. The installer (`install.ps1 -Image ...
-Exe ...`) explains what it will do and asks before changing anything. It then:
1. installs or updates WSL if needed;
2. imports your image as the `Omarchy` distro (it needs about 7 GB of disk);
3. asks you to choose a user name and password.

## Use

| | |
|---|---|
| Start the desktop | **Omarchy** in the Start menu, or `omarchy` in a terminal |
| Back to Windows | Log out (Super+Escape opens the system menu), or **Ctrl+Alt+End** to minimise |
| Omarchy's menu / keyboard shortcuts | Super+Space / Super+K |
| Update Omarchy | `omarchy update` (or "Update System" inside the desktop) |
| Undo the last update | `omarchy rollback` |
| Back up / restore everything | `omarchy backup` / `omarchy restore` |
| Check the installation | `omarchy status` |
| Remove everything | `omarchy uninstall` |

- Windows keeps **Win+L** and **Ctrl+Alt+Del** for itself, so Omarchy's shortcuts on those keys move to Super+Alt+L and Super+Ctrl+Alt+Backspace.
- To save download size, the image leaves out Omarchy's largest apps (LibreOffice, OBS, Kdenlive, ...). Install any of them from Omarchy's menu.

Problems? See [Troubleshooting](docs/TROUBLESHOOTING.md).

> [!WARNING]
> **Work in progress, and so far it "works on my machine".** It was developed and tested on one PC
> (Windows 11, NVIDIA RTX 5070, three 4K monitors). Expect rough edges elsewhere, and please
> [tell us](https://github.com/kblock1/womarchy-local/issues/new/choose) how it went.
> - **WSL gets upgraded.** womarchy needs WSL 3.0.1 or later, so the installer updates WSL (or installs it). Your other WSL distros keep their files, but WSL restarts and anything running in it stops. Windows asks for administrator permission and may need a restart.
> - Some Ubuntu distros then report a harmless `degraded` state; [here's the fix](docs/TROUBLESHOOTING.md#other-wsl-distros-after-the-wsl-update).
> - womarchy adds a WSL distro named "Omarchy", a Start menu entry and the `omarchy` command for your user. Nothing else on Windows changes.
>
> An unofficial project, not affiliated with Omarchy or Basecamp.

## How it works

```mermaid
flowchart LR
  subgraph wsl["WSL 2: Arch Linux + Omarchy"]
    apps["Apps<br/>(Wayland, X11, OpenGL, Vulkan)"] --> hypr["Hyprland<br/>+ a WSL display backend"]
  end
  hypr -- "renders with Mesa's Direct3D 12 driver" --> gpu[("Your GPU")]
  hypr -- "frames, through shared memory" --> exe["omarchy.exe<br/>a full-screen window per monitor"]
  exe -- "keyboard, mouse, clipboard, monitor changes" --> hypr
```

Hyprland normally needs display hardware, which WSL doesn't have. womarchy adds a display backend that
hands each finished frame to `omarchy.exe` on Windows through memory both sides can see, so nothing
is copied on the way. `omarchy.exe` shows each monitor's frames in a full-screen window and sends
keyboard, mouse and clipboard events back.

**Good to know:**
- **Chromium draws pages on the CPU.** Everyday browsing is fine, but 3D web pages (WebGL) need [a flag](docs/TROUBLESHOOTING.md#using-the-desktop).
- **Games:** OpenGL and Vulkan run through Direct3D 12, which suits apps and light 3D more than serious gaming.
- **Windows owns the hardware.** Wi-Fi, Bluetooth, power and the kernel are managed by Windows, so the matching Omarchy menu entries don't apply.

Want the details? Start with [the journey](docs/JOURNEY.md), the story of how this was built: the dead
ends, the bugs and how each was found. Then see [the architecture](docs/ARCHITECTURE.md).

## Documentation

| | |
|---|---|
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Logs, common problems, updates and rollback, fixes for other distros after the WSL update, manual removal |
| [The journey](docs/JOURNEY.md) | How it was built: insights, bugs, how they were debugged and fixed |
| [Architecture](docs/ARCHITECTURE.md) | Components, session lifecycle, frames, input, DPI, updates, security model |
| [Development](docs/DEVELOPMENT.md) | Building, testing, CI, changing the protocol, releasing |
| [Patches](patches/README.md) and [upstreaming](docs/UPSTREAMING.md) | What we change in aquamarine, Hyprland and Mesa, and how it goes upstream |
| [Feasibility study](docs/FEASIBILITY.md), [plan](docs/PLAN.md), [work log](docs/WORKLOG.md), [install notes](docs/INSTALL-NOTES.md) | The research, the plan and its status, the full dated record, and the distilled install requirements |

## Contributing

Problems with this copy (the local build, or the fixes listed in [LOCAL-BUILD.md](LOCAL-BUILD.md)):
[open an issue here](https://github.com/kblock1/womarchy-local/issues/new/choose). Problems in womarchy itself belong
[upstream](https://github.com/sytelus/womarchy), which takes issues rather than pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).
Security problems: [SECURITY.md](SECURITY.md).

## Thanks

womarchy stands on [Omarchy](https://github.com/omacom/omarchy), [Hyprland](https://hypr.land),
[Mesa](https://mesa3d.org) and [WSL](https://github.com/microsoft/WSL) with
[WSLg](https://github.com/microsoft/wslg). Our small patches to them are in [patches/](patches/).

## License

MIT (see [LICENSE](LICENSE)). The patches keep their upstream projects' licenses. Omarchy and the Arch
packages in the image are under their own licenses.
