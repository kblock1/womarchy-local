#!/usr/bin/env python3
"""Turn a recorded demo run into the README's animated GIF.

    python lab/make-demo-gif.py RUN_DIR OUT.gif [--clock-offset MS] [--width PX] [--max-fps N]
                                                [--max-hold MS] [--speed X]

RUN_DIR comes from lab/demo-gif.ps1 and contains:
  frame-<unix ms>.jpg   screenshots of the desktop taken inside the session (lab/demo-record.sh),
                        several per second, named by the Linux clock (--clock-offset: Linux minus
                        Windows time, measured by demo-gif.ps1)
  viewer.log            omarchy.exe's log, with "[omarchy] script: mark <unix ms> <scene>" lines from
                        lab/scripts-omarchy-demo.txt (each mark starts a captioned scene)

The GIF is a title card (a terminal typing `omarchy`), the frames from the first mark to the "end"
mark with a caption per scene, and a closing card with docs/img/three-monitors.png and the install
line.

Keeping it small:
- a palette per scene, shared by its frames, so unchanged areas stay identical between frames;
- identical frames are merged, and pauses (nothing or only a cursor changing) are cut to --max-hold;
- at most --max-fps frames per second (of the recording; --speed then plays it faster).
"""
import argparse
import os
import re
from PIL import Image, ImageChops, ImageDraw, ImageFont

CAPTIONS = {
    "desktop": "Omarchy, full screen on Windows 11",
    "terminal": "Arch Linux + Hyprland in WSL, on your GPU",
    "tiling": "Tiling windows, animations, the TUIs you know",
    "menu": "Omarchy's menus, keyboard first",
    "themes": "Browse and switch themes live",
    "gpu": "OpenGL and Vulkan, accelerated through Direct3D 12",
}
CLOSING = "And full screen on every monitor, each at its own DPI"
REPO = "github.com/sytelus/womarchy"
INSTALL = "irm https://raw.githubusercontent.com/sytelus/womarchy/main/install.ps1 | iex"
MINOR_CHANGE = 0.005  # a frame changing less than this share of the picture counts as still
FONTS = "C:/Windows/Fonts"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONTS, name), round(size))
    except OSError:
        return ImageFont.load_default()


def caption(img, text):
    """A dark rounded box near the bottom with the scene's caption."""
    w_img, h_img = img.size
    u = w_img / 960  # sizes below are for a 960-pixel-wide GIF
    draw = ImageDraw.Draw(img, "RGBA")
    f = font("segoeuib.ttf", 26 * u)
    w = draw.textlength(text, font=f)
    pad, h, bottom = 18 * u, 50 * u, 22 * u
    x0 = (w_img - w) / 2 - pad
    draw.rounded_rectangle((x0, h_img - h - bottom, x0 + w + 2 * pad, h_img - bottom), radius=12 * u, fill=(15, 15, 25, 215))
    draw.text(((w_img - w) / 2, h_img - h - bottom + 7 * u), text, font=f, fill=(255, 255, 255, 255))
    return img


def title_frames(width, height):
    """A Windows-terminal-looking card typing `omarchy`: (image, duration ms) pairs."""
    u = width / 960
    mono, bold, small = font("CascadiaCode.ttf", 30 * u), font("segoeuib.ttf", 34 * u), font("segoeui.ttf", 20 * u)
    frames = []
    command = "omarchy"
    for i in range(len(command) + 1):
        img = Image.new("RGB", (width, height), (12, 12, 20))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((120 * u, 150 * u, width - 120 * u, height - 150 * u), radius=14 * u, fill=(30, 30, 46), outline=(80, 80, 110), width=max(1, round(2 * u)))
        d.text((150 * u, 175 * u), "Windows Terminal", font=small, fill=(160, 160, 190))
        d.text((150 * u, 235 * u), "PS C:\\> " + command[:i] + ("_" if i < len(command) else ""), font=mono, fill=(220, 220, 235))
        if i == len(command):
            d.text((150 * u, 300 * u), "One command: the full Omarchy desktop.", font=bold, fill=(137, 180, 250))
        frames.append((img, 140 if i < len(command) else 1800))
    return frames


def closing_frame(width, height):
    """docs/img/three-monitors.png with a line of text and the repo's address, or None."""
    path = os.path.join(ROOT, "docs", "img", "three-monitors.png")
    if not os.path.exists(path):
        return None
    u = width / 960
    img = Image.new("RGB", (width, height), (12, 12, 20))
    shot = Image.open(path).convert("RGB")
    sw = width - round(60 * u)
    shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    top = (height - shot.height) // 2 - round(20 * u)
    img.paste(shot, ((width - sw) // 2, top))
    d = ImageDraw.Draw(img)
    for text, f, y, colour in (
        (CLOSING, font("segoeuib.ttf", 28 * u), top - 60 * u, (255, 255, 255)),
        (REPO, font("segoeui.ttf", 24 * u), top + shot.height + 30 * u, (137, 180, 250)),
        (INSTALL, font("CascadiaCode.ttf", 14 * u), top + shot.height + 75 * u, (150, 150, 175)),
    ):
        d.text(((width - d.textlength(text, font=f)) / 2, y), text, font=f, fill=colour)
    return img


def main():
    ap = argparse.ArgumentParser(description="Turn a recorded demo run into an animated GIF.")
    ap.add_argument("run")
    ap.add_argument("out")
    ap.add_argument("--clock-offset", type=int, default=0, help="Linux clock minus Windows clock, in ms")
    ap.add_argument("--width", type=int, default=960, help="GIF width; the height follows 16:9")
    ap.add_argument("--max-fps", type=float, default=12, help="drop frames beyond this rate")
    ap.add_argument("--max-hold", type=int, default=1000, help="longest a still frame is shown, in ms")
    ap.add_argument("--speed", type=float, default=1.4, help="play the recording this much faster")
    a = ap.parse_args()
    width, height = a.width, a.width * 9 // 16

    marks = []
    for line in open(os.path.join(a.run, "viewer.log"), encoding="utf-8", errors="replace"):
        m = re.search(r"script: mark (\d+) (\S+)", line)
        if m:
            marks.append((int(m.group(1)), m.group(2)))
    if not marks or marks[-1][1] != "end":
        raise SystemExit("viewer.log has no marks ending in 'end'; did the demo script finish?")
    # frame times on the Windows clock, like the marks
    shots = sorted((int(m.group(1)) - a.clock_offset, os.path.join(a.run, f))
                   for f in os.listdir(a.run) if (m := re.fullmatch(r"frame-(\d+)\.(?:jpg|png)", f)))
    start, end = marks[0][0], marks[-1][0]
    shots = [s for s in shots if start <= s[0] <= end]
    if not shots:
        raise SystemExit("no captured frames between the first mark and 'end'")

    # at most max-fps frames per second (a dropped frame's time goes to the one before it)
    kept, gap = [], 1000 / a.max_fps
    for t, path in shots:
        if not kept or t - kept[-1][0] >= gap:
            kept.append((t, path))

    # (group, image, recording ms): the title card, each scene, the closing card
    clips = [("title", img, ms) for img, ms in title_frames(width, height)]
    for i, (t, path) in enumerate(kept):
        scene = [name for at, name in marks if at <= t][-1]
        img = Image.open(path).convert("RGB").resize((width, height), Image.LANCZOS)
        if scene in CAPTIONS:
            caption(img, CAPTIONS[scene])
        nxt = kept[i + 1][0] if i + 1 < len(kept) else end
        clips.append((scene, img, max(60, nxt - t)))
    closing = closing_frame(width, height)
    if closing:
        clips.append(("closing", closing, 3500))

    # A palette per group, from six of its frames: a light theme, a dark one and the GPU apps need
    # different colours. Within a group all frames share it, so unchanged areas stay identical.
    palettes = {}
    for group in dict.fromkeys(g for g, _, _ in clips):
        imgs = [img for g, img, _ in clips if g == group]
        picks = [imgs[round(k * (len(imgs) - 1) / 5)] for k in range(6)] if len(imgs) > 6 else imgs
        sheet = Image.new("RGB", (width, height * len(picks)))
        for k, img in enumerate(picks):
            sheet.paste(img, (0, height * k))
        palettes[group] = sheet.quantize(colors=255, method=Image.Quantize.MEDIANCUT)

    # Pauses: a frame that changes only a small area (a blinking cursor, the clock) or nothing counts
    # as still. A still stretch is cut after --max-hold of GIF time; identical frames are merged.
    still_cap = a.max_hold * a.speed  # in recording time
    images, durations, groups, still = [], [], [], 0
    for group, img, ms in clips:
        q = img.quantize(palette=palettes[group], dither=Image.Dither.NONE)
        if images and group == groups[-1] and group not in ("title", "closing"):
            box = ImageChops.difference(q.convert("RGB"), images[-1].convert("RGB")).getbbox()
            if box is None or (box[2] - box[0]) * (box[3] - box[1]) < MINOR_CHANGE * width * height:
                if still + ms > still_cap:
                    continue
                still += ms
                if box is None:
                    durations[-1] += ms
                    continue
            else:
                still = 0
        else:
            still = 0
        images.append(q)
        durations.append(ms)
        groups.append(group)
    # play faster, except the title and closing cards (GIF delays are in 10 ms steps, and browsers slow
    # down anything under 20 ms)
    durations = [d if g in ("title", "closing") else max(20, round(min(d / a.speed, a.max_hold), -1))
                 for g, d in zip(groups, durations)]
    images[0].save(a.out, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"{a.out}: {width}x{height}, {len(images)} frames, {sum(durations) / 1000:.1f} s, {os.path.getsize(a.out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
