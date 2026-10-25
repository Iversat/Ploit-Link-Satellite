# SkyScene model

The bundled `Resources/SkyScene.mlpackage` is an FP16 Core ML conversion of
OpenMMLab's MobileNetV2 / DeepLabV3 model trained on the 150-class ADE20K scene
segmentation dataset. Architecture and published checkpoint are provided by
the MMSegmentation project under its Apache License 2.0. The original license
is retained in [MMSegmentation-Apache-2.0.txt](MMSegmentation-Apache-2.0.txt).

Copyright 2020 The MMSegmentation Authors. All rights reserved.

- [Official model table and checkpoint](https://github.com/open-mmlab/mmsegmentation/blob/v0.30.0/configs/mobilenet_v2/README.md)
- [Official model configuration](https://github.com/open-mmlab/mmsegmentation/blob/v0.30.0/configs/mobilenet_v2/deeplabv3_m-v2-d8_512x512_160k_ade20k.py)
- [Original checkpoint](https://download.openmmlab.com/mmsegmentation/v0.5/mobilenet_v2/deeplabv3_m-v2-d8_512x512_160k_ade20k/deeplabv3_m-v2-d8_512x512_160k_ade20k_20200825_223255-63986343.pth)
- [ADE20K dataset and terms](https://ade20k.csail.mit.edu/terms)

Checkpoint SHA-256:
`6398634362949fa37d4dc9004fe4f04a2b8bd2510efba750951f1652187ae905`.

The conversion removes the training-only auxiliary head and dropout, preserves
the published inference weights, embeds RGB channel normalization, fixes the
input size to 512 × 512, and stores model computations and weights in FP16.
It does not retrain the model. The inference network has 18,442,646 parameters.

Input `image` is RGB, 512 × 512. Output `logits` contains unnormalized scores
with shape `[1, 150, 64, 64]`. ADE20K labels are zero-based after removal of the
ignored dataset label; for example, sky is 2, building is 1, window is 8,
door is 14, and house is 25. Preprocessing is performed inside the model:
`(RGB - [123.675, 116.28, 103.53]) / [58.395, 57.12, 57.375]`.

The model identifies visual scene classes. It does not measure radio
attenuation, establish satellite connectivity, or determine whether a window
is open or glazed. Low confidence and unavailable results remain unknown.
Training photographs and local diagnostic fixtures are not distributed with
the application.

To reproduce the conversion on macOS or Linux, install Python 3.11,
`torch==2.7.0`, `coremltools==8.3.0`, `numpy==1.26.4`, and `Pillow==11.2.1`, then
run `python tools/export-sky-model.py --work-dir build/sky-model`.
The exporter verifies the checkpoint checksum, loads tensors with
`weights_only=True`, rejects missing or unexpected inference weights, and on
macOS compares native Core ML inference with the PyTorch model. The generated
`build/sky-model/provenance.json` records conversion versions and numerical
agreement. Windows can run the same source with `--verify-only` for PyTorch
inference; Core ML conversion uses macOS or Linux.
