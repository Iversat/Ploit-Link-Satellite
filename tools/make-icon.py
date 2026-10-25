"""Render the approved vector with an optically centered app-icon composition."""
from pathlib import Path
import json
import math
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
folder = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
folder.mkdir(parents=True, exist_ok=True)
scale = 16
# Preserve the approved vector, enlarging only its app-icon presentation.
# The white silhouette's centroid includes the orbit arc and the panel cutouts.
icon_scale = 1.14
optical_center = (131.60, 134.05)
image = Image.new('RGB', (256 * scale, 256 * scale), '#030507')
draw = ImageDraw.Draw(image)

def pixel_point(x, y):
    return (round((128 + (x-optical_center[0])*icon_scale)*scale),
            round((128 + (y-optical_center[1])*icon_scale)*scale))

def stroke(points, width, color):
    pixels = [pixel_point(x,y) for x,y in points]
    draw.line(pixels, fill=color, width=round(width * icon_scale * scale), joint='curve')
    radius = width * icon_scale * scale / 2
    for x, y in (pixels[0], pixels[-1]):
        draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=color)

for element in ET.parse(root / 'docs/brand/pls-symbol.svg').getroot():
    tag = element.tag.split('}')[-1]
    if tag in ('polygon', 'polyline'):
        points = [tuple(map(float, p.split(','))) for p in element.attrib['points'].split()]
        if tag == 'polygon':
            draw.polygon([pixel_point(x,y) for x,y in points], fill=element.attrib['fill'])
        else:
            stroke(points, float(element.attrib['stroke-width']), element.attrib['stroke'])
    elif tag == 'path':
        assert element.attrib['d'] == 'M 224.8366 148.5833 A 99 99 0 0 1 100.7119 223.1649'
        angles = [math.radians(12 + 94 * i / 720) for i in range(721)]
        stroke([(128+99*math.cos(t), 128+99*math.sin(t)) for t in angles], 4, '#f4f6f8')

image.resize((1024, 1024), Image.Resampling.LANCZOS).save(folder / 'AppIcon.png')
(folder / 'Contents.json').write_text(json.dumps({
    'images': [{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],
    'info': {'author':'xcode','version':1}}, indent=2) + '\n')
