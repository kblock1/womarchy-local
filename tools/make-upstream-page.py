#!/usr/bin/env python3
"""Write out/upstream/index.html: the prepared upstream submissions (PRs and issues), each ready for a
person to review and submit. Nothing is submitted by this script.

    python3 tools/make-upstream-page.py

The texts live below; docs/UPSTREAMING.md tracks what was submitted.
"""
import html
import os
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "out", "upstream")
REPO = "https://github.com/sytelus/womarchy"

ENV = """### Windows Version
Microsoft Windows 11 Pro 10.0.26200

### WSL Version
3.0.1.0

### Are you using WSL 1 or WSL 2?
- [x] WSL 2
- [ ] WSL 1

### Kernel Version
6.18.40.1-microsoft-standard-WSL2
"""

ITEMS = []


def item(**kw):
    ITEMS.append(kw)


# --- 1. Omarchy: kernel reboot prompt -------------------------------------------------------------
item(
    project="Omarchy (basecamp/omarchy)",
    kind="Pull request (ready)",
    title="Only offer a kernel reboot when pacman manages a kernel",
    url="https://github.com/basecamp/omarchy/compare/quattro...sytelus:omarchy:kernel-reboot-prompt-without-pacman-kernel?expand=1&"
    + urllib.parse.urlencode({"title": "Only offer a kernel reboot when pacman manages a kernel"}),
    fields=[("Description (paste into the PR body)", """`omarchy-update-restart` decides "Linux kernel has been updated" whenever no pacman-owned `vmlinuz` matches the running kernel. On systems that boot a kernel pacman doesn't manage there is none, so every `omarchy update` ends with "Linux kernel has been updated. Reboot?" although nothing changed. That's the case on WSL (Microsoft's kernel), in containers and with self-built kernels. On WSL, answering yes only stops the distro.

This change shows the prompt only when at least one pacman-owned kernel exists and none of them is the running one. Regular installs behave as before.

**Testing**
- The new loop, checked against fake `/usr/lib/modules` layouts and a stubbed `pacman -Qo`:
  - running kernel installed → no prompt;
  - only a newer kernel installed → prompt;
  - two kernels installed, running one among them → no prompt;
  - no pacman-owned kernel (WSL) → no prompt.
- On WSL 3.0.1 (no pacman-owned kernel), `OMARCHY_UPDATE_UNATTENDED=1 omarchy-update-restart --reboot-only`:
  - before: "Linux kernel has been updated. Reboot? Run omarchy-system-reboot when ready.";
  - after: no reboot message.

AI disclosure: prepared with Claude (AI); I reviewed and tested the change.""")],
    notes="One commit on your fork (branch kernel-reboot-prompt-without-pacman-kernel). Omarchy has no AI restriction; the disclosure line is there for transparency.",
)

# --- 2. Hyprland: screen capture without linux-dmabuf -------------------------------------------
item(
    project="Hyprland (hyprwm/Hyprland)",
    kind="Pull request: you write and open it",
    title="protocols: screen capture without linux-dmabuf",
    url="https://github.com/hyprwm/Hyprland/compare/main...sytelus:Hyprland:fix/screencopy-without-dmabuf",
    fields=[("Facts for your own description (Hyprland asks contributors to write PR text themselves)", """- When the renderer has no dmabuf formats, ProtocolManager doesn't create linux-dmabuf ("Not binding linux-dmabuf and MesaDRM: DMABUF not available"), so PROTO::linuxDma is null.
- ext-image-copy-capture (ImageCopyCapture.cpp) called PROTO::linuxDma->getMainDevice() unconditionally: any screenshot tool (grim) then crashes the compositor. ToplevelExport.cpp and Screencopy.cpp advertised linux_dmabuf the same way.
- The fix advertises dmabuf formats and the dmabuf device only when the protocol exists, so clients fall back to shm.
- Found running Hyprland without DRM (Mesa d3d12 on WSL2); the commit applies cleanly to current main (3 files, +33/-23).
- Tested on 0.56.2: taking screenshots with grim (the crash case) works, no crash. Not compile-tested on main.""")],
    notes="""Before opening it, please read Hyprland's AI policy: https://github.com/hyprwm/.github/blob/main/policies/AI_USAGE.md and the issue guidelines: https://wiki.hypr.land/contributing-and-debugging/issue-guidelines/.
Their rules: AI tools may not open PRs or write their text; you must disclose AI use in the PR template; PRs from contributors they haven't vouched for are closed automatically (see https://wiki.hypr.land/contributing-and-debugging/). GitHub pre-fills the PR body with the commit message, so replace it with your own words.
The other Hyprland fix (absolute pointer motion per output) is already in Hyprland's main: nothing to submit.""",
)

# --- 3. Mesa: d3d12 deadlock -------------------------------------------------------------------
item(
    project="Mesa (gitlab.freedesktop.org/mesa/mesa)",
    kind="Merge request: you submit it on GitLab",
    title="d3d12: reclaim completed BOs outside of pb manager locks",
    url="https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/new",
    fields=[
        ("Patch file (already applies cleanly to Mesa main)", os.path.join(ROOT, "patches", "mesa", "0001-d3d12-reclaim-outside-pb-manager-locks.patch")),
        ("Suggested merge request description", """d3d12_bo_new() is the pb provider behind the slab and cache managers. pb_slab_manager_create_buffer() holds the slab manager mutex while it calls pb_slab_create() → provider->create_buffer() → d3d12_bo_new(), which called d3d12_screen_reclaim_completed(). Reclaiming can drop a slab sub-allocation whose destroy path, pb_slab_buffer_destroy(), takes the same non-recursive mutex: the thread deadlocks on itself.

Seen on WSL2 (RTX 5070, Mesa 26.2.3) with Hyprland: the first glTexImage2D() of a text texture hangs forever (full backtrace in the commit message).

This moves the proactive reclaim and the out-of-memory retry to init_buffer(), where no pb manager lock is held.

The patch carries a `Generated-by: LLM` trailer, as Mesa's contribution guidelines ask. I reviewed it and tested it with Hyprland and GL clients on WSL2."""),
    ],
    notes="""Mesa's rules for AI tools forbid them from interacting with its GitLab, so this one is all yours:
1. Sign in at gitlab.freedesktop.org (new accounts may need approval before they can fork).
2. Fork mesa/mesa.
3. `git am` the patch on a branch from main and push it to your fork.
4. Open the merge request with the description above, and apply the d3d12 label if you can.

The second Mesa patch (write-back upload heaps) waits for Microsoft's answer to the WSL report below.""",
)

# --- 4-6. Microsoft WSL -----------------------------------------------------------------------
def wsl_issue(title, body, notes=""):
    item(
        project="Microsoft WSL (microsoft/WSL)",
        kind="Issue (pre-filled)",
        title=title,
        url="https://github.com/microsoft/WSL/issues/new?" + urllib.parse.urlencode({"title": title, "body": body}),
        fields=[("Body (already in the form; here to read or copy)", body)],
        notes="Searched for duplicates before writing this. " + notes,
    )


wsl_issue(
    "WSL 3.0.1: systemd-binfmt.service fails on every boot (\"Failed to flush binfmt_misc rules: Read-only file system\")",
    ENV + """
### Distro Version
Ubuntu 26.04 and Ubuntu 24.04, systemd enabled

### Other Software
None needed.

### Repro Steps
1. On WSL 3.0.1, start a distro that has systemd enabled (`[boot] systemd=true` in /etc/wsl.conf).
2. Run `systemctl --failed` and `systemctl is-system-running`.

### Expected Behavior
`systemd-binfmt.service` succeeds as on earlier WSL versions, and the system reports `running`.

### Actual Behavior
`systemd-binfmt.service` fails on every boot and the system reports `degraded`. The unit logs:

```
Failed to flush binfmt_misc rules: Read-only file system
```

systemd-binfmt first removes all registered rules (writes `-1` to `/proc/sys/fs/binfmt_misc/status`), which WSL 3.0.1 refuses. It then registers the binfmt.d rules but exits non-zero. Running `/usr/lib/systemd/systemd-binfmt` again by hand succeeds, and Windows interop keeps working. This looks related to the binfmt_misc changes in 3.0.1 discussed in #41739.

Workaround (drop-in `/etc/systemd/system/systemd-binfmt.service.d/wsl-readonly-flush.conf`):
```
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-binfmt
ExecStop=
ExecStop=-/usr/lib/systemd/systemd-binfmt --unregister
```

### Diagnostic Logs
(`journalctl -b -u systemd-binfmt` from an affected distro can be added here.)
""",
    notes="Related: #41739 (a different 3.0.1 binfmt symptom). Consider pasting `journalctl -b -u systemd-binfmt` from one of your Ubuntu distros into the last section.",
)

wsl_issue(
    "WSL 3.0.1: CPU writes to D3D12 UPLOAD-heap mappings via /dev/dxg run at ~9 MB/s (Mesa d3d12 texture uploads ~700x slower than on 2.7.10)",
    ENV + """
### Distro Version
Arch Linux, Mesa 26.2.3 (Gallium d3d12 driver, `GALLIUM_DRIVER=d3d12`)

### Other Software
NVIDIA GeForce RTX 5070, driver 610.60 (32.0.16.1060)

### Repro Steps
1. In a WSL 2 distro with Mesa's d3d12 driver (`GALLIUM_DRIVER=d3d12`), build and run `bench-upload.c` from https://github.com/sytelus/womarchy/tree/main/lab: it times a 1920x1080 `glTexSubImage2D` on a surfaceless EGL context.
2. Optionally:
   - `bench-copypattern.c` measures CPU copies into the mapped upload buffer;
   - `bench-faults.c` counts page faults per upload.

### Expected Behavior
Write-combined upload mappings take sequential CPU stores at GB/s, as on WSL 2.7.10, where a 1920x1080 `glTexSubImage2D` took 1.25 ms.

### Actual Behavior
On WSL 3.0.1:
- **Store throughput:** our benchmarks see about **9 MB/s** for CPU stores into Mesa's UPLOAD-heap (write-combined) mappings, against 6–18 GB/s into write-back custom heaps.
- **Uploads:** a 1920x1080 `glTexSubImage2D` through stock Mesa takes 860–930 ms. It's not page faults: about 3 per upload.
- **Impact:** every GL app using Mesa d3d12 under WSL 3.0.1 is affected. For example, a Wayland compositor uploading client buffers drops a 60 FPS GL client to 5 FPS.
- **Workaround:** putting CPU-write buffers in write-back custom heaps fixes it: https://github.com/sytelus/womarchy/blob/main/patches/mesa/0002-d3d12-write-back-upload-heaps-on-wsl.patch

### Diagnostic Logs
Benchmark output can be attached on request.
""",
)

wsl_issue(
    "`wsl --install <distro>` elevates and runs DISM to enable VirtualMachinePlatform although WSL 2 distros already run",
    ENV + """
### Distro Version
n/a (installing the official archlinux distribution)

### Other Software
None.

### Repro Steps
1. On a machine where WSL 2 distros already start and run normally, run:
   `wsl --install archlinux --name test --location D:\\WSL\\test --no-launch`

### Expected Behavior
The distribution is installed, as `wsl --install --from-file <image> --name test` does on the same machine.

### Actual Behavior
- wsl.exe printed "The requested operation requires elevation", relaunched itself elevated (UAC), then reported success "not effective until the system is rebooted". It did not create the distribution.
- The Windows Setup event log shows DISM enabling the `VirtualMachinePlatform` optional feature at that moment (event IDs 7 and 9).
- From the source: a named `wsl --install` first checks optional components (`WslClient.cpp` `InstallPrerequisites`, `WslInstall::CheckForMissingOptionalComponents`). Here that check reported VirtualMachinePlatform missing although WSL 2 was working, so wsl.exe ran `dism /Online /NoRestart /enable-feature /featurename:VirtualMachinePlatform`.
- `--from-file` skips the check and works.

Suggestion: don't change Windows features when a WSL 2 VM is already running, or ask before doing it.

### Diagnostic Logs
The relevant Windows Setup event log entries can be provided.
""",
)

# --- 7. WSLg feature request ------------------------------------------------------------------
wslg_fields = [
    ("Is your feature request related to a problem", """We display a Wayland compositor running in a WSL 2 distro with a native Windows app, so full-screen frames must cross from Linux to Windows every frame. The only zero-copy path we found is WSLg's `wslg` virtio-fs share:
- mounted a second time in the distro with DAX;
- Windows opens the files with `OpenFileMappingW("WSL\\<VM id>\\wslg\\<name>")`.

It works very well (about 6 GB/s, no copies), but nothing about it is documented or promised:
- the tag;
- the section names;
- that file sizes must be whole pages (otherwise EINVAL);
- that files vanish when the last fd/mapping closes.

It could change with any WSLg update."""),
    ("Describe the solution you'd like", """A documented, supported way to share memory between a WSL 2 distro and Windows. Either:
- a stable contract for the `wslg` DAX share (tag, naming, sizing rules), or
- a small dedicated API.

Separately: the first write to DAX-mapped pages gets slower the more is mapped. Preparing a 33 MB buffer takes 0.24 s with nothing else mapped, but about 1 s once ~300 MB are mapped, so a 3x 4K desktop spends seconds at startup just touching its buffers. Reproducer: https://github.com/sytelus/womarchy/blob/main/lab/bench-dax-alloc.c"""),
    ("Describe alternatives you've considered", """- Sending pixels over hvsocket: works, but copies every frame (1.2–1.6 GB/s) and costs CPU.
- RDP through WSLg: Weston's RDP path re-encodes, and doesn't fit a full-screen desktop with its own window management."""),
    ("Additional context", f"""The project: {REPO} (docs/ARCHITECTURE.md describes the frame path). Measured on Windows 11 Pro 10.0.26200, WSL 3.0.1, WSLg 1.0.79, RTX 5070."""),
]
item(
    project="Microsoft WSLg (microsoft/wslg)",
    kind="Feature request (copy each part into the form)",
    title="Supported zero-copy shared memory between a WSL distro and Windows",
    url="https://github.com/microsoft/wslg/issues/new?template=feature_request.yml",
    fields=wslg_fields,
    notes="WSLg's issue form can't be pre-filled from a link; use the Copy buttons, one per field. Title: \"Supported zero-copy shared memory between a WSL distro and Windows\".",
)

# --- page --------------------------------------------------------------------------------------
os.makedirs(OUT, exist_ok=True)
parts = []
for n, it in enumerate(ITEMS, 1):
    blocks = []
    for k, (label, text) in enumerate(it["fields"]):
        tid = f"t{n}_{k}"
        if os.path.isfile(text):
            blocks.append(f'<p class="label">{html.escape(label)}</p><p><code>{html.escape(text)}</code></p>')
            continue
        blocks.append(
            f'<p class="label">{html.escape(label)} <button onclick="copyText(\'{tid}\')">Copy</button></p>'
            f'<textarea id="{tid}" rows="{min(22, text.count(chr(10)) + 3)}">{html.escape(text)}</textarea>'
        )
    parts.append(f"""<section>
<h2>{n}. {html.escape(it['title'])}</h2>
<p class="meta">{html.escape(it['project'])} &middot; {html.escape(it['kind'])}</p>
<p><a class="open" href="{html.escape(it['url'])}" target="_blank" rel="noopener">Open on {html.escape(it['project'].split(' (')[0])}</a></p>
<p class="notes">{html.escape(it.get('notes', '')).replace(chr(10), '<br>')}</p>
{''.join(blocks)}
</section>""")

page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>womarchy: upstream submissions</title>
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#666; --card:#f5f5f7; --accent:#0a66c2; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#111; --fg:#eee; --muted:#aaa; --card:#1c1c1e; --accent:#4ea1ff; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, sans-serif; max-width:900px; margin:0 auto; padding:16px; }}
section {{ background:var(--card); border-radius:10px; padding:4px 16px 12px; margin:16px 0; }}
.meta,.notes {{ color:var(--muted); }} .label {{ font-weight:600; margin-bottom:4px; }}
textarea {{ width:100%; box-sizing:border-box; font:13px/1.4 ui-monospace, monospace; background:var(--bg); color:var(--fg); border:1px solid #8884; border-radius:6px; padding:8px; }}
a.open {{ display:inline-block; background:var(--accent); color:#fff; padding:6px 14px; border-radius:6px; text-decoration:none; }}
button {{ font-size:12px; }}
</style></head><body>
<h1>Upstream submissions: ready for your review</h1>
<p>Nothing here has been submitted. For each item: open it, read and adjust the text, then press the submit button yourself.</p>
{''.join(parts)}
<script>function copyText(id) {{ const t = document.getElementById(id); navigator.clipboard.writeText(t.value).catch(() => {{ t.select(); document.execCommand('copy'); }}); }}</script>
</body></html>"""
open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(page)
print(os.path.join(OUT, "index.html"), "with", len(ITEMS), "items")
