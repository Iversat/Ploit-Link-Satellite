"""Fetch fixed public diagnostic photographs into the test bundle, never the app."""
import hashlib
from pathlib import Path
from urllib.request import urlopen

FIXTURES = (
    ("house.jpg", "https://huggingface.co/datasets/hf-internal-testing/fixtures_ade20k/resolve/main/ADE_val_00000001.jpg",
     "99f7af15a7bd66f3d2ad8b98f1b41941c27407a35d303f9b70724cb231a36098"),
    ("room-comparison.png", "https://raw.githubusercontent.com/CSAILVision/semantic-segmentation-pytorch/master/teaser/ADE_val_00001519.png",
     "98fc507ff90ddc48572a6927428ad9800c3070a1ace8f5caa63cac5dd91a52a1"),
)

if __name__ == "__main__":
    destination = Path(__file__).resolve().parents[1] / "Tests" / "ModelFixtures"
    destination.mkdir(parents=True, exist_ok=True)
    for name, url, expected in FIXTURES:
        target = destination / name
        data = target.read_bytes() if target.exists() else urlopen(url, timeout=30).read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f"Fixture checksum mismatch: {name}")
        target.write_bytes(data)
        print(f"Diagnostic fixture: {name} ({len(data)} bytes)")
