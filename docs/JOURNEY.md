# The journey: how Omarchy got onto WSL, and what we learned

This is the story behind the code: the dead ends, the bugs, how each was found and fixed, and what
we'd tell someone attempting something similar. [WORKLOG.md](WORKLOG.md) has the full, dated
record; this page is the readable digest. Each story follows the same shape:

| | |
|---|---|
| **Symptom** | what we saw |
| **Debugging** | how we found the cause |
| **Root cause** | what was really happening |
| **Fix** | what we changed |
| **Lesson** | what to take away |

## The goal and the constraints

The goal: type `omarchy` in a Windows terminal and land in a full-screen, GPU-accelerated Omarchy (Arch + Hyprland) desktop on every monitor, then get the prompt back on logout.

The constraints, set by the machine's owner:
- **Leave the machine as we found it.** The owner's other WSL distros must keep working, nothing may destabilize Windows, and there are no global WSL settings.
- **No custom kernel or kernel modules.**
- **Ask before anything that touches the shared WSL VM.**

These constraints shaped almost every decision below.

## 1. Hyprland needs DRM, and WSL has none

**Symptom:** stock Hyprland wouldn't start in WSL:
- nested in WSLg: "Wayland backend cannot start: Missing protocols";
- on its own: "Cannot open backend: no allocator available".

**Debugging:** we tried the classic route first: load the `vgem` kernel module to get a fake DRM render node, then point GBM at it. Hyprland did render through Mesa's D3D12 driver.

**Root cause:** `modprobe vgem` is **VM-global**. Every WSL distro shares one kernel, so it exposed `/dev/dri` to the owner's Ubuntu too, and newer WSL kernels have no DRM support at all. A dead end.

**Fix:** a DRM-free design. Hyprland renders with EGL on a *surfaceless* platform (Mesa d3d12 works there). It draws into ordinary GL framebuffers and reads back only the damaged pixels into shared memory. A new aquamarine backend (`wsl`) hands those buffers to a Windows viewer. See [ARCHITECTURE.md](ARCHITECTURE.md).

**Lesson:** in WSL, "inside my distro" isn't always inside your distro. Kernel modules, `/usr/lib/modules`, `/mnt/wslg` and `/usr/lib/wsl` are shared by every distro in the VM. We wrote that down as a rule early and checked every later change against it.

## 2. Getting frames to Windows without copying them

**Symptom:** a 4K frame is 33 MB. Sending it through a socket would cost too much CPU every frame (hvsocket measures 1.2–1.6 GB/s).

**Debugging:** WSLg already shares memory between the VM and Windows: it exports a virtio-fs share with DAX, tag `wslg`. Our first attempt to use it failed every way possible:
- `readdir` gave ENOSYS;
- `ftruncate` gave EINVAL;
- files vanished;
- Windows couldn't open them.

We read WSLg's Weston source to see how *it* creates files there, then copied that exactly: `open(O_CREAT|O_EXCL)`, then `fallocate`, then `mmap`, and keep the fd open.

**Root cause:** the share is backed by Windows *sections*:
- a file lives only while something holds it open;
- sizes must be whole pages;
- Windows reaches a file as `OpenFileMappingW("WSL\<VM id>\wslg\<name>")`.

**Fix:** frame buffers live on that share. Linux writes, Windows reads the same memory, with no copy across the VM boundary, at about 6 GB/s.

**A trap we fell into later:**
- Every resolution we'd tested happened to be a whole number of pages (1280x720, 1920x1080, 3840x2160).
- The live display-change test, which uses odd sizes like 800x450, broke Hyprland outright: every mode was rejected.
- Buffers are now rounded up to whole pages.

**Lesson:** read the code of whoever already uses an undocumented mechanism, and test "unusual" sizes on purpose.

## 3. The 5 FPS mystery

**Symptom:** a GL demo ran at 61 FPS on plain WSLg but at **5 FPS** inside our Hyprland.

**Debugging:** we chased four plausible causes, all wrong:
- split socket writes;
- a nested event loop;
- Nagle-style delays on hvsocket: the raw ping-pong took 0.09 ms;
- Windows throttling hidden windows.

Then we sampled Hyprland's main thread with gdb every 100 ms (`lab/sample-stacks.sh`). Almost every sample sat in `_mesa_TexSubImage2D → util_copy_rect`: uploading one client frame took about 190 ms. Small C benchmarks (`lab/bench-*.c`) then isolated it.

**Root cause:** on WSL 3.0.1, CPU writes into D3D12 **write-combined upload heaps** run at about **9 MB/s**, against 6–18 GB/s for write-back memory. Mesa's d3d12 driver streams every texture upload through such heaps. A 1080p upload took 900 ms instead of about 1 ms.

**Fix:** a two-line idea in a Mesa patch ([patches/mesa/0002](../patches/mesa/0002-d3d12-write-back-upload-heaps-on-wsl.patch)): put CPU-write buffers in write-back heaps. Result: 60 FPS. We prepared a report for Microsoft.

**Lesson:** stop guessing and sample stacks. Four reasonable theories cost hours; ten gdb samples showed the answer.

## 4. A deadlock on the first line of text

**Symptom:** Hyprland froze forever the first time it drew text.

**Debugging:** gdb plus Arch's debuginfod gave a full symbolized backtrace of the hung thread (`lab/debug-hang.sh`, `lab/symbolize-hang.sh`).

**Root cause:** in Mesa's d3d12 driver, the slab allocator holds a mutex while creating a buffer. Buffer creation "helpfully" reclaimed old buffers. Freeing one of them took the same non-recursive mutex: the thread waited for itself.

**Fix:** reclaim outside the lock ([patches/mesa/0001](../patches/mesa/0001-d3d12-reclaim-outside-pb-manager-locks.patch)). The bug still exists in Mesa's main branch; the fix is prepared for submission.

**Lesson:** a hang with a clean single-thread backtrace is usually lock re-entry. Look for the same lock twice in one stack.

## 5. The event loop that remembered the wrong callback

**Found in code review, before it bit:** Hyprland's event loop keys file-descriptor callbacks by fd *number* and keeps the first callback it saw for that number. Our backend first reads a new connection as "pending" (waiting for the handshake), then promotes the *same* fd to "client". A reconnect also reuses numbers. Either way, events for the live client could have reached the pending-connection handler.

**Fix:** each callback looks up what that fd number means *now* (pending connection or live client) before acting.

**Lesson:** when a framework keys anything by fd number, assume numbers get reused, because they will.

## 6. Three monitors, mixed DPI

**Symptom:**
- Windows at 175% gave Hyprland a scale it refused;
- the generated layout overlapped two monitors;
- clicks on the third monitor landed on the second.

**Root causes and fixes:**
- **Scale:** Hyprland only accepts scales that divide the mode evenly in its 1/120 steps (175% of 3840 px isn't one). We now search for the nearest clean scale, the same way Hyprland does, so 175% becomes 166.7%.
- **Overlap:** placement now resolves monitors in Windows' left-to-right order, from already-placed positions.
- **Pointer:** absolute pointer motion was mapped onto the whole desktop instead of the monitor it came from. Our fix passes the monitor along. Hyprland upstream has since fixed it the same way.

**Lesson:** test on the real hardware. Two of these three bugs only appear with mixed DPI across several monitors.

## 7. A screenshot that crashed the desktop

**Symptom:** taking any screenshot killed Hyprland.

**Root cause:** without DRM, Hyprland doesn't create the linux-dmabuf protocol, but the screen-capture code called it unconditionally: a null pointer.

**Fix:** offer dmabuf only when the protocol exists, so clients use shared memory. Upstream Hyprland has the same bug whenever dmabuf isn't available; the fix is prepared for submission.

## 8. Five seconds per paste

**Symptom:** after copying in Windows, it took about 5 s before Linux saw the text, and the clipboard daemon was stuck meanwhile.

**Debugging:** the daemon's log said `wl-copy ... timed out after 5 seconds`, yet the copy had worked.

**Root cause:** `wl-copy` forks a background server that owns the clipboard. That server inherited the pipes our daemon had opened to capture output, and Python's `subprocess.run` waits until those pipes close: forever, cut short by our 5 s timeout.

**Fix:** don't capture output from `wl-copy` (send it to `/dev/null`).

**Lesson:** a daemonizing child keeps your pipes. Capture output only from programs that really exit.

## 9. "The desktop did not answer": three bugs in a trench coat

**Symptom:** full screen on three 4K monitors failed right after the distro had been stopped. The journal then showed a `poweroff` that nobody had asked for.

**Debugging, one layer at a time:**
1. The viewer said "connection closed", but the compositor's log showed it had accepted the viewer. Two contradicting stories.
2. The viewer's receive code reported *every* failure as "connection closed". It was actually a **timeout**: the handshake allowed 10 s, and the compositor needed 17 s to start.
3. The `poweroff` was WSL's own idle shutdown, 15 s after the viewer gave up and the distro had nothing left to do. A consequence, not a cause.
4. Why 17 s? Stack sampling again: about 14 s inside `mmap` and `memset` of the frame buffers.
   - A benchmark (`lab/bench-dax-alloc.c`) showed that first-touching DAX memory gets slower the more is already mapped: 0.24 s for one 4K buffer, about 1 s once 300 MB are mapped.
   - `MAP_POPULATE` made it worse: on a shared mapping it only read-faults, so every page faulted twice.

**Fix:**
- report timeouts as timeouts;
- give the handshake the rest of the 60 s startup budget;
- drop `MAP_POPULATE`;
- use two buffers per monitor instead of three: only one frame is ever in flight, so the third only cost memory and startup time.

Result: 3x 4K connects in about 5 s (was 17 s).

**Lesson:** when two logs disagree, one of them is lying. Here our own error message was. Make errors say what actually happened.

## 10. Shipping it: small things that would have hurt

- **A `.gitignore` line hid the viewer's source.** `src/` was meant for the top-level folder of upstream forks, but it also matched `windows/omarchy/src/`. The first public commit had no viewer source. We caught it only by checking `git status --ignored`. Ignore rules for top-level folders now start with `/`, and CI builds from a clean checkout.
- **GitHub release assets can't contain `:`,** and Mesa's package files do (`mesa-1:26.2.3...`, an epoch). Package files are now renamed; pacman downloads whatever name its database records.
- **Case-only renames on Windows.** git on NTFS saw `0003-pointer-CPU...` as a modification of `0003-pointer-cpu...`. That needed an explicit `git rm --cached` of the old name.
- **Privacy.** Before publishing, everything was scanned for the owner's user name, host name, email and local paths: files, commit metadata, screenshots and the image itself. Leaks were found more than once (a screenshot showing the host name, lab scripts with local paths, a work-log entry that spelled out the search terms), so the scan is now a script (`tools/check-secrets.py`, `lab/overlay/privacy-scan.sh`) and runs in CI.
- **Upstream rules about AI.** Hyprland and Mesa both have rules about AI-written contributions, so their submissions are prepared for a person to review and send.

## 11. Signing the package repository without stranding anyone

**Symptom (found by a test before it hit anyone):** once the repository was signed, every existing v0.1.0 install would fail to update. Their pacman trusted anything (`TrustAll`), but it still tries to verify a signature it sees, can't find our unknown key, and aborts.

**Fix:**
- The signed repository moved to a new address (release tag `packages`).
- The old one stays unsigned and frozen, carrying just the new overlay and keyring. A v0.1.0 install's next update picks those up and switches itself to the signed repository.
- Testing that migration on a real v0.1.0 install turned up one more wart: a one-time "missing required signature" message from the cached unsigned database. Fixed too.

**Lesson:** when you tighten security for a system that updates itself, test the update path from every version that's out there.

## 12. Chromium and the benchmark that lied

**Symptom:** web pages with 3D graphics (WebGL) don't work in Chromium under WSL.

**Debugging:**
- `chrome://gpu` showed everything in software. With `--ignore-gpu-blocklist`, our WebGL benchmark reported a perfect 60 FPS.
- A screenshot showed the canvas was **blank white**: frames were "rendered" but never reached the screen.
- Our first benchmark page drew nothing even in a real browser, so we rebuilt it to show visible colours.
- Only then were the results trustworthy:

| Flags | WebGL | CPU |
|---|---|---|
| Default | Off | |
| Wayland + `--ignore-gpu-blocklist` | Broken (blank) | |
| X11 + `--ignore-gpu-blocklist` | Correct | 2–4 CPU cores |

**Root cause:** Chromium shares GPU frames with the desktop through dmabuf, which needs DRM, which WSL doesn't have (see story 1).

**Fix:** no default change. TROUBLESHOOTING documents the X11 opt-in and its cost.

**Lesson:** verify graphics visually. A frame counter tells you something ran, not that anyone could see it.

## 13. Testing a desktop you can't touch

Most tests drive the real desktop through `omarchy.exe --input-script` (keys, typing, pointer moves, screenshots), alongside Windows-side screen captures. Lessons from the test harness itself:
- **Move the real cursor.** Our script moved only Hyprland's pointer. The next mouse move Windows generated snapped it back, and apps opened on the wrong monitor. `move` now places the real Windows cursor too.
- **Wait for readiness, not time.** A fixed 10 s wait was fine on a warm distro and flaky on a freshly installed one. Tests now wait for the clipboard channel to report "connected".
- **Know which compositor you're talking to.** Before our session is up, `grim` happily connects to WSLg's own compositor and fails with a confusing message.
- **Keep heavy tests opt-in.** Full-screen runs take over the monitors, image builds take 15–30 minutes, and downloads are 1.7 GB. They run when needed, not by reflex.

## 14. The release candidate that ran at 4 FPS

**Symptom:** while checking the v0.2.0 image, the clipboard test failed 5 of 5 and the OpenGL gears ran at 4 FPS instead of 60. The same packages had passed on the same machine a few hours earlier.

**Debugging:**
- Hyprland's log said "frame N was never acknowledged". The viewer received frames but answered late, so the compositor fell back to its 250 ms timeout: 4 frames a second.
- **A/B test:** the previous release's `omarchy.exe` gave the same 4 FPS. A package diff of the two images showed only our own packages had changed. The new code wasn't the cause.
- So what else had changed? The machine. A check of the Windows session showed the lock screen (`LogonUI`) running and no input for 34 minutes.

**Root cause:** while Windows is locked, nothing is shown on screen, so presenting a frame stalls far beyond one refresh, and the Windows clipboard can't be opened. Both symptoms came from the test environment, not the release.

**Fix:**
- Nothing to fix in the product: a locked desktop that draws 4 frames a second just saves power.
- The tests that show the desktop now stop with a clear message while Windows is locked (`lab/assert-desktop.ps1`).

**Lesson:** when a "regression" also shows up with the old version, it isn't in your diff. Check the environment, and make tests check it too.

## Tools and techniques that paid off

- **Stack sampling with gdb** (`lab/sample-stacks.sh`): cheap, works on optimized builds, and found the 5 FPS bug and the slow startup.
- **Micro-benchmarks** in plain C (`lab/bench-*.c`): tiny programs that isolate one cost, so a theory can be tested in minutes.
- **Frame dumps and screen captures** from both sides (`--dump-frame`, `lab/fullscreen-test.ps1`).
- **Throwaway distros** (`omarchy-test*`), installed from local images (no download) and deleted afterwards. No experiment ever touched the owner's distros.
- **Recording from inside the compositor** (`lab/demo-gif.ps1`): a scripted session, grim screenshots from inside it, and timestamps from the script to cut scenes. The README's GIF comes from it, with no screen recorder on Windows.
- **A written log** ([WORKLOG.md](WORKLOG.md)) of every finding, including false leads, so nothing was debugged twice.
