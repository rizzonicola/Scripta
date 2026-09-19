#!/usr/bin/env python3
"""Genera le icone di iOS, macOS e Windows dall'icona di Scripta.

Richiede Pillow (`pip install pillow`). Idempotente: sovrascrive sempre le
icone generate, mai altri file.

Sorgente: la miglior raster disponibile (linux/packaging/icons/512x512.png,
altrimenti assets/icons/app_icon.png, 64x64). ATTENZIONE: la sorgente attuale
è 512x512, quindi la voce 1024x1024 viene ingrandita; per un risultato
perfetto conviene esportare un PNG 1024x1024 dall'SVG e metterlo come
assets/icons/app_icon_1024.png (viene usato automaticamente se presente).
"""
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

CANDIDATES = [
    ROOT / "assets" / "icons" / "app_icon_1024.png",
    ROOT / "linux" / "packaging" / "icons" / "512x512.png",
    ROOT / "assets" / "icons" / "app_icon.png",
]


def log(msg):
    print(f"   [icone] {msg}")


def load_source():
    for c in CANDIDATES:
        if c.exists():
            img = Image.open(c).convert("RGBA")
            log(f"sorgente: {c.relative_to(ROOT)} ({img.width}x{img.height})")
            return img
    sys.exit("Nessuna icona sorgente trovata")


def resized(img, px):
    return img.resize((px, px), Image.LANCZOS)


def flatten_full_bleed(img):
    """iOS applica da solo la maschera ad angoli arrotondati e non ammette
    trasparenza: riempie gli angoli trasparenti con un gradiente diagonale
    campionato dall'icona stessa (nessun colore hard-coded)."""
    w, h = img.size
    c0 = img.getpixel((int(w * 0.08), int(h * 0.08)))
    c1 = img.getpixel((int(w * 0.92), int(h * 0.92)))
    bg = Image.new("RGBA", img.size)
    px = bg.load()
    for y in range(h):
        for x in range(w):
            t = (x + y) / float(w + h - 2)
            px[x, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)) + (255,)
    bg.alpha_composite(img)
    return bg.convert("RGB")


def px_from_entry(e):
    size = float(e["size"].split("x")[0])
    scale = int(e.get("scale", "1x").rstrip("x"))
    return int(round(size * scale))


def appiconset(dirpath, img, flatten):
    contents = dirpath / "Contents.json"
    if not contents.exists():
        log(f"ATTENZIONE: {contents.relative_to(ROOT)} non trovato, salto")
        return
    data = json.loads(contents.read_text(encoding="utf-8"))
    base = flatten_full_bleed(img) if flatten else img
    n = 0
    for e in data.get("images", []):
        fn = e.get("filename")
        if not fn:
            continue
        resized(base, px_from_entry(e)).save(dirpath / fn, "PNG")
        n += 1
    log(f"{dirpath.relative_to(ROOT)}: {n} file")


def windows_ico(img):
    out = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    if not out.parent.exists():
        log("ATTENZIONE: windows/runner/resources non trovato, salto")
        return
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    img.save(out, format="ICO", sizes=sizes)
    log(f"{out.relative_to(ROOT)} ({len(sizes)} dimensioni)")


def main():
    targets = sys.argv[1:] or ["all"]
    if "all" in targets:
        targets = ["ios", "macos", "windows"]
    img = load_source()
    if "ios" in targets and (ROOT / "ios").exists():
        appiconset(ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset", img, True)
    if "macos" in targets and (ROOT / "macos").exists():
        appiconset(ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset", img, False)
    if "windows" in targets and (ROOT / "windows").exists():
        windows_ico(img)


if __name__ == "__main__":
    main()
