# Development

How to build, change and test womarchy. Read [ARCHITECTURE.md](ARCHITECTURE.md) first for the big
picture.

## Repository layout

| Path | Contents |
|---|---|
| [install.ps1](../install.ps1) | The one-step installer for users (WSL check/update, download, `omarchy install`). |
| [windows/omarchy](../windows/omarchy) | `omarchy.exe` (Rust): viewer, launcher, installer. |
| [protocol/wdp.h](../protocol/wdp.h) | The display protocol between the compositor and the viewer: the reference for both sides. |
| [patches/](../patches/README.md) | Our patches to aquamarine, Hyprland and Mesa, plus the pinned versions. |
| [linux/packages](../linux/packages) | PKGBUILDs for the `[womarchy]` pacman repo (same package names as Arch, so they replace Arch's), and `womarchy-session`. |
| [linux/overlay](../linux/overlay), [linux/image](../linux/image/README.md) | The Omarchy WSL overlay and the `.wsl` image builder. |
| [lab/](../lab) | Experiments, benchmarks and end-to-end tests. |
| [tools/](../tools) | Developer helpers (`setup-src.sh`). |
| `src/`, `out/` | Not committed: the upstream forks, and build outputs (`out/repo`, images). |

## Prerequisites

- Windows 11 with WSL 3.0.1 or newer and a GPU driver with WSL support.
- [Rust](https://rustup.rs) (stable, MSVC toolchain) for `omarchy.exe`.
- An Arch Linux WSL distro for building packages and images. [linux/image/README.md](../linux/image/README.md) shows how to create it (`setup-build-distro.sh`).
- For testing, an installed Omarchy distro. Name test distros `omarchy-test*` and remove them when you're done.

## Building

**omarchy.exe**
```
cd windows/omarchy
cargo build --release                 # target/release/omarchy.exe
cargo test --release                  # protocol parsing and monitor-id unit tests
cargo clippy --release --all-targets -- -D warnings   # must stay clean
```

**Packages** (inside the Arch build distro, as a user with sudo; Mesa and Hyprland take a while and run under `nice`):
```
tools/setup-src.sh                              # once: the aquamarine and Hyprland forks in src/
linux/packages/refresh-patches.sh               # after committing in src/: export the patch series
linux/packages/regen-pkgbuilds.sh               # bump *_REL at its top when a package changes
linux/packages/build-all.sh                     # or: build-all.sh aquamarine hyprland womarchy-session
```
- `build-all.sh` writes `out/repo` (repo name `womarchy`) and installs what it built into the build distro.
- `womarchy-session` needs no fork: edit it in place and bump `pkgrel` in its PKGBUILD.

**Image** (needs `out/repo`):
```
wsl -d <build distro> -u root -e bash -c "LITE=1 bash <repo>/linux/image/build-image.sh"
```
The lite image leaves out Omarchy's large preinstalled apps (LibreOffice, OBS, ...) so that it fits in a GitHub release asset (2 GB limit).

## Trying a change quickly

Install the new packages into a test distro, then start it with the dev build:
```
wsl -d omarchy-test -u root -- pacman -U --noconfirm /mnt/<repo>/out/repo/<package>.pkg.tar.zst
windows\omarchy\target\release\omarchy.exe --distro omarchy-test --windowed 1600x900 --stats
```
- `--windowed WxH [--monitors N] [--scale S]` runs in windows instead of full screen; `--monitors 3` simulates three monitors.
- `--session PATH` runs another session script (e.g. the repo's copy of `womarchy-session`).
- `--input-script FILE` drives the session (keys, typing, pointer, screenshots; see `windows/omarchy/src/script.rs`).
- `--dump-frame FILE --dump-after FRAMES` saves what the first output shows.

## Tests

End-to-end tests run from Windows (PowerShell) against an installed distro (`-Distro omarchy-test`):

| Test | Checks |
|---|---|
| `lab/viewer-test.ps1` | Start, connect, frames, clean exit with the session's exit code; dumps the final frame. `-EndBy kill` ends it from the Linux side. |
| `lab/clipboard-test.ps1` | Text both ways, at connect and live, including line endings. |
| `lab/gpu-clients-test.ps1` | A GL (es2gears) and a Vulkan (vkcube) client render on the GPU inside the session. |
| `lab/display-change-test.ps1` | Live monitor add/remove/resize with fake monitors; outputs and monitor rules follow. |
| `lab/fullscreen-test.ps1` | The real thing on your monitors (takes over the screens for ~1.5 min): apps on each monitor, DPI, a Windows-side screen capture, frame rates and the viewer's CPU time. |
| `lab/installer-test.ps1` | `omarchy install`/`uninstall` on a throwaway distro. |
| `linux/image/test-image.ps1` | Installs a freshly built image as a throwaway distro and checks the system and user setup. |

Benchmarks behind design decisions (for example `bench-upload.c` for the Mesa upload-heap patch, `bench-dax-alloc.c` for shm buffer allocation) are listed in [lab/README.md](../lab/README.md). Their results are in [WORKLOG.md](WORKLOG.md).

## Changing the protocol

[protocol/wdp.h](../protocol/wdp.h) is the specification. A change touches all of these:
- `wdp.h` itself (bump `WDP_VERSION` for incompatible changes);
- its copy in the aquamarine backend (`src/backend/wsl/wdp.h`);
- `windows/omarchy/src/wdp.rs`;
- for the clipboard, `linux/packages/womarchy-session/womarchy-clipd`.

The viewer and the compositor refuse to talk across versions, so release them together. Adding a message type doesn't need a version bump: receivers skip types they don't know (that's how `CLIP_IMAGE` was added). Clipboard-only additions can wait for the next aquamarine change to reach its copy of the header, since aquamarine doesn't use them.

## Rules for working on a shared machine

WSL distros share one VM, kernel and memory. A mistake in a test distro can affect the user's other distros, so:
- Never write to paths the VM shares between distros: `/usr/lib/modules`, `/mnt/wslg`, `/usr/lib/wsl`, WSLg's `/tmp/.X11-unix`.
- No kernel modules, and no changes to `%UserProfile%\.wslconfig` or `.wslgconfig`.
- Install images only with `wsl --install --from-file`. A named `wsl --install <distro>` can trigger DISM to change Windows features.
- Avoid `wsl --shutdown`: it stops every distro. Use `wsl --terminate <distro>`.
- Build under `nice`, and stop build/test distros when done.

## Continuous integration

All of it runs on GitHub's free runners for public repositories; nothing runs on your machine.

| Workflow | When | What |
|---|---|---|
| [checks](../.github/workflows/checks.yml) | Every push and pull request | `omarchy.exe` build, unit tests and clippy; shellcheck and `bash -n`; Python and PowerShell parse checks; docs links ([tools/check-links.py](../tools/check-links.py)); secrets and personal paths ([tools/check-secrets.py](../tools/check-secrets.py)). A few minutes. |
| [packages](../.github/workflows/packages.yml) | On demand (Actions → packages → Run workflow) | Builds the listed packages in an Arch container on Omarchy's package snapshot. Then **waits for a maintainer's approval** before signing and publishing them to the `packages` release (the signed `[womarchy]` repository). |
| [snapshot watch](../.github/workflows/snapshot-watch.yml) | Daily | If Omarchy's snapshot moved: checks our packages still install and link on it, and opens or closes a `rebuild-needed` issue. Under a minute when nothing changed. |

The signing key exists only as the `womarchy-repo` environment's secret. That environment only runs on `main` and requires a reviewer's approval.

## Releasing

1. Change the code and push; `checks` must pass.
2. Rebuild packages whose sources changed: run the **packages** workflow with their names (e.g. `womarchy-session womarchy-compat`), then approve its publish step. Installed systems pick them up with their next `omarchy update`.
3. For a new image (when the overlay or the first-run experience changed):
   - fetch the signed repository: `linux/packages/fetch-signed-db.sh --fetch-packages --prune`;
   - build the lite image ([linux/image/README.md](../linux/image/README.md)) and test it with `linux/image/test-image.ps1`.
4. Build `omarchy.exe`, then create a GitHub release with:
   - `Omarchy.wsl` (the lite image), `omarchy.exe`, and a `.sha256` file for each (`sha256sum` format; the installers check them);
   - a copy of [install.ps1](../install.ps1).

   Release asset names must not contain `:`; `build-all.sh` already renames packages that would.
5. Add a [CHANGELOG.md](../CHANGELOG.md) entry, update the status in [PLAN.md](PLAN.md), and add a [WORKLOG.md](WORKLOG.md) entry.

The old `repo` release is the frozen, unsigned repository of v0.1.0. It only exists so those installs can move to the signed one: it holds just the `womarchy-compat`, `womarchy-keyring` and `womarchy-session` builds that make the move. Never add signatures to it (a v0.1.0 install has no key, so its pacman would refuse the database), and don't publish other updates there.
