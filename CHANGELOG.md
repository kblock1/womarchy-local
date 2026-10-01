# Changelog

## 0.2.0 (2026-10-01)

**New**
- **Undoing updates.** `omarchy rollback` puts back the package versions from before the last update; the distro records them automatically before every update. `omarchy backup` and `omarchy restore` save and restore the whole distro as one file. `omarchy update` runs Omarchy's updater and asks once whether to make a full backup first.
- **Clipboard images.** Images are now shared between Windows and Omarchy in both directions (PNG; Windows bitmaps are converted).
- **Signed package repository.** Updates of womarchy's packages (Hyprland, aquamarine, Mesa, the WSL overlay) come from a signed repository, and installs refuse unsigned databases. Installs from 0.1.0 move over automatically with their next update.
- **WSL overlay updates.** Fixes to the WSL adjustments (`womarchy-compat`) now reach installed systems through normal updates instead of needing a new image.
- **Safer updates.** An update that would break the GPU driver (an LLVM bump Mesa wasn't built for) now stops with a clear message instead of leaving a broken desktop. A daily check notices when Omarchy's package snapshot moves ahead of womarchy's builds.

**Project**
- Continuous integration, issue forms, contributing and security guides. Contributions come through issues; pull requests aren't accepted directly.
- A new README, and [the journey](docs/JOURNEY.md): how this was built, the bugs, and how each was found and fixed.
- New troubleshooting entries for browser 3D (WebGL), the microphone, and updates.

## 0.1.0 (2026-10-01)

First public preview:
- the one-step installer;
- a full-screen, GPU-composited Omarchy desktop on every monitor, with per-monitor DPI;
- text clipboard, audio and live display changes;
- `omarchy install`, `uninstall` and `status`.
