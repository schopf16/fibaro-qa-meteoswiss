"""Render the marketplace image (1420x1000). Needs Pillow: pip install Pillow."""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(__file__).resolve().parent
OUT = ROOT / "meteoswiss-marketplace-1420x1000.png"
W, H = 1420, 1000


def font(size):
    return ImageFont.load_default(size=size)


def draw_text(draw, xy, value, size, fill, bold=False):
    f = font(size)
    draw.text(xy, value, font=f, fill=fill)
    if bold:
        draw.text((xy[0] + 2, xy[1]), value, font=f, fill=fill)


def gradient(size, top, bottom):
    width, height = size
    image = Image.new("RGB", size)
    pixels = image.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(width):
            pixels[x, y] = color
    return image


im = gradient((W, H), (249, 251, 252), (220, 235, 240)).convert("RGBA")
d = ImageDraw.Draw(im)
navy, blue, red = "#193956", "#327ca4", "#d52b2b"

# Swiss cross and geographic scope at the top of the left-hand copy block.
d.rounded_rectangle((96, 143, 184, 231), radius=9, fill=red)
d.rectangle((130, 159, 150, 215), fill="#ffffff")
d.rectangle((112, 177, 168, 197), fill="#ffffff")
draw_text(d, (211, 151), "SWITZERLAND ONLY", 27, navy, bold=True)
draw_text(d, (212, 190), "Forecasts for Swiss postal codes", 18, "#557084")

# Read a simplified outline derived from Natural Earth 1:10m country data.
# Natural Earth states its raster and vector data are in the public domain.
outline_data = json.loads((SOURCE / "switzerland-outline.json").read_text(encoding="utf-8"))
mw, mh = 700, 560
points = [(45 + x * 0.95, 55 + y * 0.95) for x, y in outline_data["outline"]]

# Original Alps and sunshine illustration, clipped to Switzerland's boundary.
scene = gradient((mw, mh), (103, 177, 203), (231, 240, 228)).convert("RGBA")
sd = ImageDraw.Draw(scene)
sd.ellipse((430, 90, 570, 230), fill="#ffd26b")
for box in [(125, 116, 238, 229), (190, 85, 326, 221), (284, 126, 394, 236)]:
    sd.ellipse(box, fill="#f8fbfb")
sd.rounded_rectangle((162, 159, 360, 235), radius=38, fill="#f8fbfb")
sd.polygon([(0, 354), (83, 278), (157, 334), (242, 218), (334, 337), (427, 239), (516, 352), (609, 260), (700, 353), (700, 560), (0, 560)], fill="#91b2bd")
sd.polygon([(194, 285), (242, 218), (289, 284), (265, 267), (242, 290), (220, 266)], fill="#f7f8f4")
sd.polygon([(386, 283), (427, 239), (468, 286), (447, 270), (427, 291), (408, 268)], fill="#f7f8f4")
sd.polygon([(0, 414), (111, 335), (212, 405), (335, 315), (449, 411), (554, 325), (700, 415), (700, 560), (0, 560)], fill="#537d88")
sd.polygon([(0, 477), (126, 397), (240, 472), (362, 384), (483, 485), (588, 400), (700, 466), (700, 560), (0, 560)], fill="#345f6b")
sd.polygon([(0, 520), (127, 470), (249, 518), (379, 451), (508, 529), (611, 467), (700, 513), (700, 560), (0, 560)], fill="#c5d9d4")

mask = Image.new("L", (mw, mh), 0)
ImageDraw.Draw(mask).polygon(points, fill=255)
masked_scene = Image.composite(scene, Image.new("RGBA", (mw, mh), (0, 0, 0, 0)), mask)
map_layer = Image.new("RGBA", (mw, mh), (0, 0, 0, 0))
map_layer.alpha_composite(masked_scene)
ImageDraw.Draw(map_layer).line(points + [points[0]], fill=(255, 255, 255, 238), width=7, joint="curve")

# Slight backward lean and a soft shadow give the map visual depth.
rotated = map_layer.rotate(5, resample=Image.Resampling.BICUBIC, expand=True)
shadow_mask = rotated.getchannel("A").filter(ImageFilter.GaussianBlur(18))
shadow = Image.new("RGBA", rotated.size, (30, 54, 70, 0))
shadow.putalpha(shadow_mask.point(lambda value: round(value * 0.25)))
im.alpha_composite(shadow, (693, 259))
im.alpha_composite(rotated, (675, 237))

# Product title on the left; the artwork stays the dominant right-hand element.
d = ImageDraw.Draw(im)
draw_text(d, (98, 390), "Swiss Weather", 69, navy, bold=True)
draw_text(d, (101, 470), "FORECAST", 42, blue, bold=True)
d.rounded_rectangle((102, 540, 225, 548), radius=4, fill="#74b6b1")
draw_text(d, (101, 584), "QuickApp for", 21, "#425e72")
draw_text(d, (101, 619), "FIBARO Home Center 3", 21, "#425e72")
draw_text(d, (98, 943), "Forecast data: MeteoSwiss · independent project, not affiliated with MeteoSwiss or FIBARO", 14, "#60758a")

im.convert("RGB").save(OUT, format="PNG", optimize=True)
print(f"Created {OUT} ({W}x{H})")
