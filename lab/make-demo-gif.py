#!/usr/bin/env python3
"""Turn a recorded demo run into the README's animated GIF.

    python lab/make-demo-gif.py RUN_DIR OUT.gif

RUN_DIR comes from lab/demo-gif.ps1 and contains:
  frame-<unix ms>.png   screenshots of the desktop taken inside the session (lab/demo-record.sh),
                        several per second; named by the Linux clock, which WSL keeps in step with
                        Windows'
  viewer.log            omarchy.exe's log, with "[omarchy] script: mark <unix ms> <scene>" lines from
                        lab/scripts-omarchy-demo.txt (each mark starts a captioned scene)

The GIF starts with a short title card (a terminal typing `omarchy`), then shows the frames from the
first mark to the "end" mark with a caption per scene. One palette for all frames keeps unchanged
areas identical between frames, which is what keeps a GIF small.
"""
import os
import re
import sys
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 960, 540
CAPTIONS = {
    "desktop": "Omarchy on Windows: full screen, on every monitor",
    "terminal": "Arch Linux + Hyprland, running in WSL 2",
    "menu": "Omarchy's menu and keyboard-first workflow",
    "theme": "Switch themes live",
    "apps": "OpenGL and Vulkan apps on your GPU",
}
FONTS = "C:/Windows/Fonts"


def font(name, size):
    try:
        return ImageFont.truetype(os.path.join(FONTS, name), size)
    except OSError:
        return ImageFont.load_default()


def caption(img, text):
    """A dark strip along the bottom with the scene's caption."""
    draw = ImageDraw.Draw(img, "RGBA")
    f = font("segoeuib.ttf", 26)
    w = draw.textlength(text, font=f)
    pad, h = 18, 50
    x0 = (WIDTH - w) / 2 - pad
    draw.rounded_rectangle((x0, HEIGHT - h - 22, x0 + w + 2 * pad, HEIGHT - 22), radius=12, fill=(15, 15, 25, 215))
    draw.text(((WIDTH - w) / 2, HEIGHT - h - 15), text, font=f, fill=(255, 255, 255, 255))
    return img


def title_frames():
    """A Windows-terminal-looking card typing `omarchy`: (image, duration ms) pairs."""
    mono, bold = font("CascadiaCode.ttf", 30), font("segoeuib.ttf", 34)
    frames = []
    command = "omarchy"
    for i in range(len(command) + 1):
        img = Image.new("RGB", (WIDTH, HEIGHT), (12, 12, 20))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((120, 150, WIDTH - 120, HEIGHT - 150), radius=14, fill=(30, 30, 46), outline=(80, 80, 110), width=2)
        d.text((150, 175), "Windows Terminal", font=font("segoeui.ttf", 20), fill=(160, 160, 190))
        d.text((150, 235), "PS C:\\> " + command[:i] + ("_" if i < len(command) else ""), font=mono, fill=(220, 220, 235))
        d.text((150, 300), "One command: the full Omarchy desktop." if i == len(command) else "", font=bold, fill=(137, 180, 250))
        frames.append((img, 140 if i < len(command) else 1600))
    return frames


def main():
    run, out = sys.argv[1], sys.argv[2]
    marks = []
    for line in open(os.path.join(run, "viewer.log"), encoding="utf-8", errors="replace"):
        m = re.search(r"script: mark (\d+) (\S+)", line)
        if m:
            marks.append((int(m.group(1)), m.group(2)))
    if not marks or marks[-1][1] != "end":
        sys.exit("viewer.log has no marks ending in 'end'; did the demo script finish?")
    shots = sorted((int(m.group(1)), os.path.join(run, f)) for f in os.listdir(run) if (m := re.fullmatch(r"frame-(\d+)\.png", f)))
    start, end = marks[0][0], marks[-1][0]
    shots = [s for s in shots if start <= s[0] <= end]
    if not shots:
        sys.exit("no captured frames between the first mark and 'end'")

    frames = title_frames()
    for i, (t, path) in enumerate(shots):
        scene = [name for at, name in marks if at <= t][-1]
        img = Image.open(path).convert("RGB").resize((WIDTH, HEIGHT), Image.LANCZOS)
        if scene in CAPTIONS:
            caption(img, CAPTIONS[scene])
        nxt = shots[i + 1][0] if i + 1 < len(shots) else t + 1500
        frames.append((img, max(80, min(nxt - t, 600))))

    # one palette from a sample of frames, then every frame mapped onto it (no dithering)
    sample = Image.new("RGB", (WIDTH, HEIGHT * 4))
    for k, idx in enumerate(range(0, len(frames), max(1, len(frames) // 4))[:4]):
        sample.paste(frames[idx][0], (0, HEIGHT * k))
    palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    images, durations = [], []
    for img, ms in frames:
        q = img.quantize(palette=palette, dither=Image.Dither.NONE)
        if images and q.tobytes() == images[-1].tobytes():
            durations[-1] += ms  # merge identical frames
            continue
        images.append(q)
        durations.append(ms)
    images[0].save(out, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"{out}: {len(images)} frames, {sum(durations) / 1000:.1f} s, {os.path.getsize(out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
