"""Build the bundled 8K maps from higher-resolution NASA originals (no upscaling).

Run with Pillow installed. Downloaded originals stay outside the repository.
"""
from pathlib import Path
import hashlib
import urllib.request
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT.parent / "outputs" / "earth-originals"
SOURCES = {
    "night": "https://assets.science.nasa.gov/content/dam/science/esd/eo/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg",
    "day": "https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-topography-bathymetry/october/world.topo.bathy.200410.3x21600x10800.jpg",
}
Image.MAX_IMAGE_PIXELS = 250_000_000
CACHE.mkdir(parents=True, exist_ok=True)
for kind, url in SOURCES.items():
    original = CACHE / url.rsplit("/", 1)[-1]
    if not original.exists():
        urllib.request.urlretrieve(url, original)
    with Image.open(original) as source:
        assert source.width >= 8192 and source.height >= 4096
        result = source.resize((8192, 4096), Image.Resampling.LANCZOS)
        destination = ROOT / "Resources" / f"earth-{kind}.jpg"
        result.save(destination, quality=95, subsampling=0, optimize=True)
        print(kind, source.size, "->", result.size,
              hashlib.sha256(destination.read_bytes()).hexdigest(), flush=True)
