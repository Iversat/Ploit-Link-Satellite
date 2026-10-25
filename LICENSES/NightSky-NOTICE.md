# Night sky data

`Resources/NightSky.json` is a collection of separately licensed astronomical data.
These data retain their upstream licenses and are excluded from the project's
custom source-available license and project-name restrictions.

## Stars

HYG Database v4.1, David Nash / Astronexus.
Source: https://github.com/astronexus/HYG-Database/blob/main/hyg/CURRENT/hygdata_v41.csv
License: Creative Commons Attribution-ShareAlike 4.0 International:
https://creativecommons.org/licenses/by-sa/4.0/

The `stars` array is an adaptation distributed under the same CC BY-SA 4.0 license.
Changes: exclude the Sun, select magnitude <= 6.0, keep 5070 records, convert RA
from hours to degrees, round coordinates, retain magnitude and B-V colour index,
translate selected proper names into Russian and omit unused columns.
Original CSV SHA256: d9f69fd86bbf90a4e4d52b4c5c53eacfa6dfc0bfdef85bfd94f095e0bebe4ebd.
The upstream license notice is included as `HYG-CC-BY-SA-4.0.md`.

## Constellations and Milky Way

d3-celestial, copyright (c) 2015 Olaf Frohn. BSD 3-Clause;
full notice and disclaimer: `d3-celestial-BSD.txt`.
Source: https://github.com/ofrohn/d3-celestial/tree/master/data
Files: `constellations.json`, `constellations.lines.json`, `mw.json`.
Changes: combine Russian labels and line figures, omit unused languages, reduce
closely spaced Milky Way contour vertices, convert the GeoJSON wrapper to arrays.
The two Serpens figures are retained separately (89 figures for 88 constellations).

The Milky Way is a contrast-enhanced schematic. The app does not measure naked-eye
visibility or identify stars from camera images. AR alignment depends on the
device's compass and attitude. The catalogue contains fixed stars, not planets.

Sidereal rotation reference: https://aa.usno.navy.mil/faq/GAST
Coordinates use J2000 with approximate precession to the observation date.
Atmospheric refraction, proper motion, aberration and nutation are not modelled;
the map is intended for visual learning and approximate pointing.
