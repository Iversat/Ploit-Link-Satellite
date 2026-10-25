#!/usr/bin/env python3
"""Reproduce the bundled ADE20K scene model from the official OpenMMLab weights.

Conversion: Python 3.11, torch==2.7.0, coremltools==8.3.0, numpy==1.26.4,
Pillow==11.2.1 on macOS/Linux. Windows supports --verify-only inference.
No MMCV custom operators, training code or remote Python are loaded.

Architecture adapted from MMSegmentation, Copyright 2020 The MMSegmentation
Authors, Apache-2.0; see LICENSES/MMSegmentation-Apache-2.0.txt.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import urllib.request

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F


CHECKPOINT_NAME = "deeplabv3_m-v2-d8_512x512_160k_ade20k_20200825_223255-63986343.pth"
CHECKPOINT_URL = (
    "https://download.openmmlab.com/mmsegmentation/v0.5/mobilenet_v2/"
    "deeplabv3_m-v2-d8_512x512_160k_ade20k/" + CHECKPOINT_NAME
)
CHECKPOINT_SHA256 = "6398634362949fa37d4dc9004fe4f04a2b8bd2510efba750951f1652187ae905"
SOURCE = "https://github.com/open-mmlab/mmsegmentation/tree/v0.30.0"
INPUT_SIZE = 512


class ConvModule(nn.Module):
    """Inference subset of MMCV ConvModule, preserving checkpoint key names."""

    def __init__(self, inputs, outputs, kernel, *, stride=1, dilation=1,
                 groups=1, activation="relu"):
        super().__init__()
        self.conv = nn.Conv2d(inputs, outputs, kernel, stride=stride,
                              padding=0 if kernel == 1 else dilation,
                              dilation=dilation, groups=groups, bias=False)
        self.bn = nn.BatchNorm2d(outputs, eps=1e-5)
        self.activation = (nn.ReLU6(inplace=False) if activation == "relu6"
                           else nn.ReLU(inplace=False) if activation == "relu"
                           else nn.Identity())

    def forward(self, x):
        return self.activation(self.bn(self.conv(x)))


class InvertedResidual(nn.Module):
    def __init__(self, inputs, outputs, stride, expansion, dilation):
        super().__init__()
        hidden = inputs * expansion
        layers = []
        if expansion != 1:
            layers.append(ConvModule(inputs, hidden, 1, activation="relu6"))
        layers.extend([
            ConvModule(hidden, hidden, 3, stride=stride, dilation=dilation,
                       groups=hidden, activation="relu6"),
            ConvModule(hidden, outputs, 1, activation=None),
        ])
        self.conv = nn.Sequential(*layers)
        self.residual = stride == 1 and inputs == outputs

    def forward(self, x):
        y = self.conv(x)
        return x + y if self.residual else y


class MobileNetV2(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = ConvModule(3, 32, 3, stride=2, activation="relu6")
        arch = [(1, 16, 1), (6, 24, 2), (6, 32, 3), (6, 64, 4),
                (6, 96, 3), (6, 160, 3), (6, 320, 1)]
        strides = [1, 2, 2, 1, 1, 1, 1]
        dilations = [1, 1, 1, 2, 2, 4, 4]
        inputs = 32
        for i, (expansion, outputs, count) in enumerate(arch):
            blocks = []
            for j in range(count):
                # The official MMSeg backbone dilates only a stage's first block.
                blocks.append(InvertedResidual(inputs, outputs,
                    strides[i] if j == 0 else 1, expansion,
                    dilations[i] if j == 0 else 1))
                inputs = outputs
            self.add_module(f"layer{i + 1}", nn.Sequential(*blocks))

    def forward(self, x):
        x = self.conv1(x)
        for i in range(1, 8):
            x = getattr(self, f"layer{i}")(x)
        return x


class ASPPHead(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv_seg = nn.Conv2d(512, 150, 1)
        self.image_pool = nn.Sequential(nn.AdaptiveAvgPool2d(1),
                                        ConvModule(320, 512, 1))
        self.aspp_modules = nn.ModuleList([
            ConvModule(320, 512, 1 if d == 1 else 3, dilation=d)
            for d in [1, 12, 24, 36]
        ])
        self.bottleneck = ConvModule(512 * 5, 512, 3)

    def forward(self, x):
        pooled = F.interpolate(self.image_pool(x), size=x.shape[-2:],
                               mode="bilinear", align_corners=False)
        features = torch.cat([pooled] + [layer(x) for layer in self.aspp_modules], dim=1)
        # Training dropout is an identity in eval mode, so it is omitted.
        return self.conv_seg(self.bottleneck(features))


class SkyScene(nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = MobileNetV2()
        self.decode_head = ASPPHead()
        # RGB 0...255. Channel-specific normalization stays inside the model.
        self.register_buffer("mean", torch.tensor([123.675, 116.28, 103.53])
                             .view(1, 3, 1, 1), persistent=False)
        self.register_buffer("std", torch.tensor([58.395, 57.12, 57.375])
                             .view(1, 3, 1, 1), persistent=False)

    def forward(self, image):
        return self.decode_head(self.backbone((image - self.mean) / self.std))


def verified_checkpoint(work_dir: Path) -> Path:
    path = work_dir / CHECKPOINT_NAME
    if not path.exists():
        temporary = path.with_suffix(".download")
        with urllib.request.urlopen(CHECKPOINT_URL, timeout=90) as source, temporary.open("wb") as dest:
            while chunk := source.read(1024 * 1024):
                dest.write(chunk)
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
        raise ValueError("Official checkpoint SHA256 mismatch; refusing to load")
    return path


def load_model(path: Path) -> SkyScene:
    checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    state = checkpoint["state_dict"]
    # The auxiliary head is training-only, never used by EncoderDecoder inference.
    inference = {key: value for key, value in state.items()
                 if not key.startswith("auxiliary_head.")}
    model = SkyScene().eval()
    model.load_state_dict(inference, strict=True)
    return model


def image_tensor(image: Image.Image) -> torch.Tensor:
    pixels = np.asarray(image.convert("RGB").resize((INPUT_SIZE, INPUT_SIZE),
                                                    Image.Resampling.BILINEAR)).copy()
    return torch.from_numpy(pixels).permute(2, 0, 1).float().unsqueeze(0)


def verify_fixtures(model: SkyScene, directory: Path, work_dir: Path) -> dict:
    manifest = json.loads((directory / "fixture-sources.json").read_text(encoding="utf-8-sig"))
    report = {}
    for name in ("house", "room"):
        item = manifest[name]
        with Image.open(directory / item["file"]) as image:
            tensor = image_tensor(image)
        with torch.inference_mode():
            logits = model(tensor)
            probabilities = logits.softmax(dim=1)[0]
            labels = logits.argmax(dim=1)[0].numpy().astype(np.uint8)
        Image.fromarray(labels).save(work_dir / f"{name}-predicted-labels.png")
        points = item.get("samplePoints", item.get("manualPointsNormalized", {}))
        samples = {}
        for label, point in points.items():
            xy = point["xy"] if isinstance(point, dict) else point
            x, y = min(63, int(xy[0] * 64)), min(63, int(xy[1] * 64))
            values, classes = probabilities[:, y, x].topk(3)
            samples[label] = [{"class": int(c), "probability": float(p)}
                              for c, p in zip(classes, values)]
        report[name] = {"shape": list(logits.shape), "samples": samples,
                        "classFractions": {str(c): float((labels == c).mean())
                                           for c in np.unique(labels)}}
    # Ground-truth outdoor points exercise actual weights, RGB order and normalization.
    (work_dir / "fixture-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    for name, expected in [("sky", {2}), ("facade", {1, 25}),
                           ("roof", {1, 25}), ("grass", {9})]:
        if report["house"]["samples"][name][0]["class"] not in expected:
            raise AssertionError(f"Outdoor fixture semantic regression: {name}")
    # The manually supplied ceiling point falls on the ceiling light (class82).
    # Validate the actual ceiling area and independently labelled wall/window.
    room = report["room"]
    assert room["classFractions"].get("5", 0) > 0.05, "Indoor ceiling region missing"
    assert room["samples"]["wall"][0]["class"] == 0, "Indoor wall regression"
    assert room["samples"]["left_glazed_opening"][0]["class"] in (8, 14), "Glazed opening regression"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=Path("build/sky-model"))
    parser.add_argument("--output", type=Path, default=Path("Resources/SkyScene.mlpackage"))
    parser.add_argument("--fixture-dir", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(min(4, torch.get_num_threads()))
    model = load_model(verified_checkpoint(args.work_dir))
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.inference_mode():
        output = model(example)
    assert tuple(output.shape) == (1, 150, 64, 64)
    assert torch.isfinite(output).all()
    print(json.dumps({"parameters": sum(p.numel() for p in model.parameters()),
                      "input": list(example.shape), "output": list(output.shape)}))
    if args.fixture_dir:
        print(json.dumps(verify_fixtures(model, args.fixture_dir, args.work_dir), indent=2))
    if args.verify_only:
        return

    import coremltools as ct
    traced = torch.jit.trace(model, example, check_trace=True)
    converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
    )
    converted.author = "OpenMMLab; Core ML conversion for PLS"
    converted.license = "Apache-2.0; see LICENSES/SkyScene-NOTICE.md"
    converted.short_description = "ADE20K scene segmentation; optical classes do not establish radio visibility."
    converted.input_description["image"] = "RGB 512x512, 0...255; normalization is built in."
    converted.output_description["logits"] = "Unnormalized ADE20K logits [1,150,64,64], zero-based classes; sky=2, window=8."
    converted.user_defined_metadata.update({
        "checkpoint_sha256": CHECKPOINT_SHA256, "checkpoint_url": CHECKPOINT_URL,
        "source": SOURCE, "normalization": "RGB (x-[123.675,116.28,103.53])/[58.395,57.12,57.375]",
        "resize": "scaleFill", "classes": "ADE20K 150, zero-based; sky=2, building=1, wall=0, ceiling=5, window=8, door=14",
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))
    agreement = None
    if platform.system() == "Darwin":
        # Native inference validates channel order, output layout and FP16 conversion.
        y, x = np.mgrid[:INPUT_SIZE, :INPUT_SIZE]
        pixels = np.stack([x % 256, y % 256, (x + 2 * y) % 256], axis=-1).astype(np.uint8)
        image = Image.fromarray(pixels)
        with torch.inference_mode():
            reference = model(image_tensor(image)).numpy()
        native = converted.predict({"image": image})["logits"]
        assert native.shape == reference.shape
        assert np.isfinite(native).all()
        error = np.abs(reference - native)
        agreement = {"meanAbsoluteLogitError": float(error.mean()),
                     "maxAbsoluteLogitError": float(error.max()),
                     "argmaxAgreement": float((native.argmax(1) == reference.argmax(1)).mean())}
        assert error.mean() < 0.05, f"Core ML numerical mismatch: {agreement}"
        assert agreement["argmaxAgreement"] > 0.95, f"Core ML label mismatch: {agreement}"
    provenance = {
        "checkpoint_url": CHECKPOINT_URL, "checkpoint_sha256": CHECKPOINT_SHA256,
        "source": SOURCE, "torch": torch.__version__, "coremltools": ct.__version__,
        "python": platform.python_version(), "format": "ML Program FP16, iOS17",
        "input": "image RGB 512x512", "output": "logits float32 [1,150,64,64]",
        "nativeCoreMLAgreement": agreement,
    }
    (args.work_dir / "provenance.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    print(f"Saved {args.output}")


if __name__ == "__main__":
    main()
