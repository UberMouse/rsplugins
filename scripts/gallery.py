#!/usr/bin/env python3
"""Mod.io gallery images for a plugin: crop its UI from the client, and compose 1920x1080 pages.

  gallery.py box --text T            print "L T W H": the window box of the top-level plugin
                                     layer whose subtree shows text T (via `rsdev.py ui`)
  gallery.py grab OUT --text T [--inset l,t,r,b] [--full PATH]
                                     shoot the client and crop that layer (minus the inset, for
                                     a frame drawn inside the layer's box) to OUT
  gallery.py compose DIR [NAME ...]  render DIR/specs.json to DIR/out/<name>.png

A media folder (e.g. media/chore-tracker/) holds specs.json, the raw crops it names and bg.png,
the backdrop. Pages are HTML screenshotted by headless Chrome; fonts come from Google Fonts.
Crops are upscaled with ImageMagick first, since Chrome's scaling softens pixel UI more.
Needs the dev shell (magick) and google-chrome-stable; box and grab also need the dev bridge.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
RSDEV = REPO / "scripts" / "rsdev.py"
BUILD = REPO / "dumps" / "gallery-build"  # scaled crops and HTML pages; gitignored
W, H = 1920, 1080
GOLD = "#e3b65a"

# One line of `rsdev.py ui`: "<indent>#12 LABEL at 1301,27 297x28 [cv] 'Chores'".
UI_LINE = re.compile(
    r"^(?P<indent> *)#\d+ (?P<type>\w+) at (?P<cx>-?\d+),(?P<cy>-?\d+) "
    r"(?P<w>\d+)x(?P<h>\d+) \[\w*\](?: '(?P<text>.*)')?$"
)


def layer_box(text: str) -> tuple[int, int, int, int]:
    """The window box (left, top, width, height) of the top-level layer showing `text`."""
    out = subprocess.run(
        [sys.executable, str(RSDEV), "ui"], check=True, capture_output=True, text=True
    ).stdout
    top = None
    for line in out.splitlines():
        m = UI_LINE.match(line)
        if not m:
            continue
        # Depth 1 (two spaces) is a child of the plugin layer: a window, strip or popup.
        if len(m["indent"]) == 2:
            top = m
        if top and m["text"] and text.lower() in m["text"].lower():
            w, h = int(top["w"]), int(top["h"])
            return int(top["cx"]) - w // 2, int(top["cy"]) - h // 2, w, h
    sys.exit(f"gallery: no plugin layer shows {text!r}")


def grab(out: pathlib.Path, text: str, inset: tuple[int, ...], full: str | None) -> None:
    left, top, w, h = layer_box(text)
    shot = subprocess.run(
        [sys.executable, str(RSDEV), "shot", "--max", "0"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()[-1]
    il, it, ir, ib = inset
    geom = f"{w - il - ir}x{h - it - ib}+{left + il}+{top + it}"
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["magick", shot, "-crop", geom, "+repage", str(out)], check=True)
    if full:
        subprocess.run(["cp", shot, full], check=True)
    print(out)


CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; background: #120e09; }}
body {{ position: relative; font-family: Inter, 'Liberation Sans', sans-serif; color: #efe4cc; }}
.bg {{ position: absolute; inset: 0; background: url(BG) center/cover; }}
.shade {{ position: absolute; inset: 0;
  background:
    radial-gradient(ellipse at 60% 55%, rgba(18,14,9,0.15) 0%, rgba(18,14,9,0.75) 75%),
    linear-gradient(180deg, rgba(18,14,9,0.55) 0%, rgba(18,14,9,0.35) 40%,
      rgba(18,14,9,0.7) 100%); }}
.eyebrow {{ font: 600 22px Inter; letter-spacing: 0.32em; color: {GOLD};
  text-transform: uppercase; }}
h1 {{ font: 700 64px Cinzel, 'TeX Gyre Pagella', serif; color: #f6ecd6; line-height: 1.1;
  text-shadow: 0 2px 12px rgba(0,0,0,0.6); }}
.rule {{ width: 120px; height: 3px; background: linear-gradient(90deg, {GOLD}, transparent); }}
.desc {{ font: 400 30px/1.4 Inter; color: #e6dbc3; text-shadow: 0 1px 8px rgba(0,0,0,0.7); }}
.shot {{ position: absolute; border-radius: 6px; overflow: hidden;
  box-shadow: 0 0 0 1px rgba(227,182,90,0.55), 0 24px 60px rgba(0,0,0,0.75),
    0 0 80px rgba(227,182,90,0.12); }}
.shot img {{ display: block; }}
.callout {{ position: absolute; transform: translateY(-50%); white-space: nowrap;
  padding: 10px 18px; border-radius: 8px; background: rgba(22,17,10,0.88);
  border: 1px solid rgba(227,182,90,0.7); font: 600 25px/1.3 Inter; color: #f3e8d0;
  box-shadow: 0 8px 24px rgba(0,0,0,0.5); }}
.callout.left {{ text-align: right; }}
svg.lines {{ position: absolute; inset: 0; }}
.note {{ position: absolute; left: 120px; bottom: 72px; width: 560px; font: 400 24px/1.45 Inter;
  color: #c9bea6; padding-left: 20px; border-left: 3px solid rgba(227,182,90,0.7);
  text-shadow: 0 1px 6px rgba(0,0,0,0.7); }}
.hero-text {{ position: absolute; left: 120px; top: 0; bottom: 0; width: 820px;
  display: flex; flex-direction: column; justify-content: center; gap: 28px; }}
.hero-text h1 {{ font-size: 112px; }}
.tagline {{ font: 400 38px/1.35 Inter; color: #f0e5cd; text-shadow: 0 1px 10px rgba(0,0,0,0.7); }}
.features {{ list-style: none; display: flex; flex-direction: column; gap: 18px; margin-top: 8px; }}
.features li {{ font: 500 30px/1.3 Inter; color: #e6dbc3; padding-left: 44px; position: relative;
  text-shadow: 0 1px 8px rgba(0,0,0,0.7); }}
.features li::before {{ content: ''; position: absolute; left: 4px; top: 9px; width: 16px;
  height: 16px; transform: rotate(45deg); background: {GOLD};
  box-shadow: 0 0 12px rgba(227,182,90,0.6); }}
.features b {{ color: #f8eeda; font-weight: 700; }}
"""

FONTS = (
    "https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700"
    "&family=Inter:wght@400;500;600;700&display=block"
)


def head(media: pathlib.Path) -> str:
    css = CSS.replace("BG", (media / "bg.png").as_uri())
    return (
        f'<!doctype html><html><head><meta charset="utf-8"><link href="{FONTS}" '
        f'rel="stylesheet"><style>{css}</style></head><body>'
        '<div class="bg"></div><div class="shade"></div>'
    )


def scaled(media: pathlib.Path, raw: str, scale: float) -> tuple[str, int, int]:
    """Upscale a raw crop into BUILD; return its file URI and its size."""
    src = media / raw
    dst = BUILD / f"{media.name}-{src.stem}@{scale}.png"
    resize = f"{scale * 100}%"
    subprocess.run(
        ["magick", str(src), "-filter", "Lanczos", "-resize", resize]
        + ["-unsharp", "0x0.6+0.4+0", str(dst)],
        check=True,
    )
    size = subprocess.run(
        ["magick", "identify", "-format", "%w %h", str(dst)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    return dst.as_uri(), int(size[0]), int(size[1])


def place(media: pathlib.Path, img: dict) -> tuple[str, tuple]:
    """One screenshot on the page; returns its HTML and (x, y, scale, w, h) for callouts."""
    uri, w, h = scaled(media, img["raw"], img["scale"])
    x = img.get("x", (W - w) // 2)
    y = img.get("y", (H - h) // 2)
    shot = (
        f'<div class="shot" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px">'
        f'<img src="{uri}" width="{w}" height="{h}"></div>'
    )
    return shot, (x, y, img["scale"], w, h)


def callouts(items: list, origin: tuple) -> str:
    """Labels beside a screenshot, each joined to a box drawn round its target (raw-crop pixels).

    The leader runs from the label to a gutter just outside the screenshot, along it to the
    target's height, then straight in, so it crosses the UI only on the target's own row.
    """
    ox, oy, s, iw, _ = origin
    labels, lines = [], []
    for c in items:
        bx, by, bw, bh = (v * s for v in c["box"])
        bx, by = ox + bx, oy + by
        ty = by + bh / 2
        ly = ty + c.get("dy", 0)
        lx = c["x"]  # the label's near edge on the page
        if c["side"] == "left":
            gx, tx = ox - 28, bx
            style = f"right:{W - lx}px;top:{ly}px"
            labels.append(f'<div class="callout left" style="{style}">{c["text"]}</div>')
        else:
            gx, tx = ox + iw + 28, bx + bw
            style = f"left:{lx}px;top:{ly}px"
            labels.append(f'<div class="callout" style="{style}">{c["text"]}</div>')
        lines.append(
            f'<path d="M{lx},{ly} H{gx} V{ty} H{tx}" fill="none" stroke="{GOLD}" '
            'stroke-width="2.5" stroke-linejoin="round"/>'
            f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="7" '
            f'fill="rgba(227,182,90,0.10)" stroke="{GOLD}" stroke-width="2.5"/>'
        )
    svg = f'<svg class="lines" width="{W}" height="{H}">{"".join(lines)}</svg>'
    return svg + "".join(labels)


def annotated(media: pathlib.Path, spec: dict) -> str:
    """A titled page: header band top left, screenshots with callouts, an optional note."""
    marks, shots = "", ""
    for img in spec["images"]:
        shot, origin = place(media, img)
        shots += shot
        marks += callouts(img.get("callouts", []), origin)
    header = (
        '<div style="position:absolute;left:120px;top:64px;right:120px;display:flex;'
        'flex-direction:column;gap:16px">'
        f'<div class="eyebrow">{spec["plugin"]}</div><h1>{spec["title"]}</h1>'
        f'<div class="rule"></div><div class="desc" style="max-width:'
        f'{spec.get("descWidth", 1100)}px">{spec["desc"]}</div></div>'
    )
    note = f'<div class="note">{spec["note"]}</div>' if "note" in spec else ""
    return head(media) + header + shots + marks + note + "</body></html>"


def hero(media: pathlib.Path, spec: dict) -> str:
    """The listing image: plugin name, tagline and features left, screenshots right."""
    shots = "".join(place(media, img)[0] for img in spec["images"])
    feats = "".join(f"<li>{f}</li>" for f in spec["features"])
    eyebrow = f'<div class="eyebrow">{spec["eyebrow"]}</div>' if "eyebrow" in spec else ""
    text = (
        f'<div class="hero-text">{eyebrow}'
        f'<h1>{spec["plugin"]}</h1><div class="rule"></div>'
        f'<div class="tagline">{spec["tagline"]}</div><ul class="features">{feats}</ul></div>'
    )
    return head(media) + text + shots + "</body></html>"


def compose(media: pathlib.Path, wanted: set[str]) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    (media / "out").mkdir(exist_ok=True)
    doc = json.loads((media / "specs.json").read_text())
    for spec in doc["pages"]:
        if wanted and spec["name"] not in wanted:
            continue
        spec = {"plugin": doc["plugin"], **spec}
        page = hero(media, spec) if spec["layout"] == "hero" else annotated(media, spec)
        src = BUILD / f"{media.name}-{spec['name']}.html"
        src.write_text(page)
        dst = media / "out" / f"{spec['name']}.png"
        subprocess.run(
            ["google-chrome-stable", "--headless=new", "--disable-gpu", "--hide-scrollbars"]
            + ["--virtual-time-budget=8000", f"--window-size={W},{H}"]
            + [f"--screenshot={dst}", src.as_uri()],
            check=True,
            capture_output=True,
        )
        print(dst)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("box", help="print the window box of the plugin layer showing a text")
    b.add_argument("--text", required=True)
    g = sub.add_parser("grab", help="shoot the client and crop the plugin layer showing a text")
    g.add_argument("out", type=pathlib.Path)
    g.add_argument("--text", required=True)
    g.add_argument("--inset", default="0,0,0,0", help="left,top,right,bottom pixels to trim")
    g.add_argument("--full", help="also keep the full shot here")
    c = sub.add_parser("compose", help="render a media folder's specs.json")
    c.add_argument("media", type=pathlib.Path)
    c.add_argument("names", nargs="*")
    args = ap.parse_args()
    if args.cmd == "box":
        print(*layer_box(args.text))
    elif args.cmd == "grab":
        inset = tuple(int(v) for v in args.inset.split(","))
        if len(inset) != 4:
            ap.error("--inset takes four numbers: left,top,right,bottom")
        grab(args.out, args.text, inset, args.full)
    else:
        compose(args.media.resolve(), set(args.names))


if __name__ == "__main__":
    main()
