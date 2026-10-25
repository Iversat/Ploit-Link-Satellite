# Deep Star Maps 2020 — night sky background

Credit: NASA/Goddard Space Flight Center Scientific Visualization Studio.
Gaia DR2: ESA/Gaia/DPAC. Visualization: Ernie Wright (USRA).

Source: https://svs.gsfc.nasa.gov/4851/
File: https://svs.gsfc.nasa.gov/vis/a000000/a004800/a004851/starmap_2020_16k_gal.exr
Resolution: 16384 × 8192, galactic equirectangular projection; longitude zero
at the centre, longitude increasing to the left, galactic north at the top.
The corrected galactic projection published in January 2021 is used.

NASA media reuse guidelines:
https://www.nasa.gov/nasa-brand-center/images-and-media/
This factual, educational star map credits NASA and does not imply endorsement
of PLS by NASA, ESA or any data provider. No NASA or ESA insignia is used.
The map is based on catalogued star positions, brightness and colour, not a live
camera image or a measurement of present sky visibility.

PLS processing: global exposure normalization, Reinhard tone mapping, sRGB
encoding and ASTC 5×5 compression with a complete mip chain. The original
resolution is retained; no invented detail, upscaling or AI-generated stars.
Preparation script: `tools/prepare-night-panorama.py`.
Source checksum and processing parameters: `Resources/night-sky-manifest.json`.

The source image and its derived texture assets are excluded from the project's
custom source license and naming restrictions; the source's own terms apply.
The separately credited ESO panorama is retained only for simulators whose
graphics device cannot decode ASTC textures. It is not used on supported iPhones.
