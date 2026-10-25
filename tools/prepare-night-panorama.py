"""Prepare the NASA/Gaia 16K galactic map for direct, bounded-memory GPU loading.

Usage: python prepare-night-panorama.py SOURCE.exr ASTCENC OUTPUT_DIR
Requires numpy, Pillow, OpenEXR and ARM astcenc 5.7.0. No invented stars or upscale.
Source and reuse terms: LICENSES/NASA-NightSky-NOTICE.md.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
import OpenEXR
from PIL import Image

source, encoder, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
output.mkdir(parents=True, exist_ok=True)
with OpenEXR.File(str(source)) as exr:
    rgb = exr.channels()['RGB'].pixels
    assert rgb.shape == (8192, 16384, 3), rgb.shape
    sample = rgb[::8, ::8].astype(np.float32)
    percentiles = np.percentile(sample, [0, 50, 90, 99, 99.5, 99.9, 100])
    print('Linear RGB percentiles:', percentiles, flush=True)
    exposure = 1.0 / max(float(percentiles[-2]), 1e-8)
    pixels = np.empty(rgb.shape, dtype=np.uint8)
    # Bounded working set; preserve colour ratios with luminance-independent scale.
    for y in range(0, 8192, 128):
        linear = np.maximum(rgb[y:y+128].astype(np.float32), 0) * exposure
        linear = linear / (1 + linear)
        srgb = np.where(linear <= .0031308, linear * 12.92, 1.055 * linear ** (1/2.4) - .055)
        pixels[y:y+128] = np.rint(np.clip(srgb, 0, 1) * 255).astype(np.uint8)
image = Image.fromarray(pixels)
del pixels, rgb, sample
image.resize((2048, 1024), Image.Resampling.LANCZOS).save(output/'preview.jpg', quality=96)
image.crop((3500, 3300, 5500, 5300)).resize((1000, 1000), Image.Resampling.LANCZOS).save(output/'detail.jpg', quality=96)
metadata = {'source': 'https://svs.gsfc.nasa.gov/4851/', 'width': 16384, 'height': 8192,
            'block': 5, 'source_sha256': hashlib.file_digest(source.open('rb'), 'sha256').hexdigest(),
            'exposure': exposure, 'levels': []}
level = 0
while True:
    png = output/'input.png'
    image.save(png, compress_level=1)
    asset = output/f'night-sky-{level}.astc'
    subprocess.run([encoder, '-cs', str(png), str(asset), '5x5', '-medium', '-silent'], check=True)
    metadata['levels'].append({'width': image.width, 'height': image.height,
                              'bytes': asset.stat().st_size,
                              'sha256': hashlib.file_digest(asset.open('rb'), 'sha256').hexdigest()})
    print('Finished level', level, image.size, asset.stat().st_size, flush=True)
    if image.size == (1, 1): break
    image = image.resize((max(1, image.width//2), max(1, image.height//2)), Image.Resampling.LANCZOS)
    level += 1
png.unlink()
(output/'night-sky-manifest.json').write_text(json.dumps(metadata, indent=2)+'\n')

# Separate image loader for Simulator; iPhone continues to use the ASTC chain.
sim = output/'simulator.png'
subprocess.run([encoder, '-ds', str(output/'night-sky-1.astc'), str(sim), '-silent'], check=True)
Image.open(sim).convert('RGB').save(output/'night-sky-simulator.jpg', quality=95, subsampling=0)
sim.unlink()
