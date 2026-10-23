"""Validate rendered Earth colors from the native screenshot fixtures."""
import argparse
import json
from pathlib import Path
from PIL import Image


def measure(path, globe=True):
    with Image.open(path) as source:
        assert source.size == (1320, 2868), (path.name, source.size)
        image = source.convert("RGB").resize((440, 956), Image.Resampling.BOX)
    pixels = image.load()
    count = purple = lights = brightness = 0
    for y in range(180 if globe else 220, 560 if globe else 920):
        for x in range(40 if globe else 0, 400 if globe else 440):
            if globe and (x - 220) ** 2 + (y - 956 * .37) ** 2 >= 176 ** 2:
                continue
            r, g, b = pixels[x, y]
            count += 1
            brightness += (r + g + b) / 3
            purple += r > g * 1.03 and b > g * 1.10 and r > 30 and b > 40
            lights += r > 100 and g > 75 and b <= g * 1.05
    return {"pixels": count, "purple_fraction": purple / count,
            "warm_light_pixels": lights, "mean_brightness": brightness / count}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("screenshots", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = {name: measure(args.screenshots / (name + ".png"), name != "home")
              for name in ["home", "orbits-day", "orbits-night"]}
    checks = {
        "night_has_no_broad_purple_tint": report["orbits-night"]["purple_fraction"] < .005,
        "home_has_no_broad_purple_tint": report["home"]["purple_fraction"] < .01,
        "city_lights_are_visible": report["orbits-night"]["warm_light_pixels"] > 100,
        "day_surface_is_visible": report["orbits-day"]["mean_brightness"] > 25,
        "night_is_darker_than_day": report["orbits-night"]["mean_brightness"] < report["orbits-day"]["mean_brightness"] * .8,
    }
    if (args.screenshots / "home-evening.png").exists() and (args.screenshots / "home-day.png").exists():
        # Compare the same unobscured surface above the cards, excluding UI glass.
        for name in ["home-evening", "home-day"]:
            with Image.open(args.screenshots / (name + ".png")) as image:
                width, height = image.size
                surface = image.convert("RGB").crop((int(width*.25), int(height*.30), int(width*.75), int(height*.36)))
                values = list(surface.getdata())
                report[name] = {"surface_brightness": sum(sum(p)/3 for p in values)/len(values)}
        checks["home_evening_darker_than_noon"] = report["home-evening"]["surface_brightness"] < report["home-day"]["surface_brightness"] * .8
    result = {"measurements": report, "checks": checks, "passed": all(checks.values())}
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    if not result["passed"]:
        raise SystemExit("Earth color regression: " + ", ".join(k for k, v in checks.items() if not v))


if __name__ == "__main__":
    main()
