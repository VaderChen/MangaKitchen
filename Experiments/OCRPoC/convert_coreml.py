#!/usr/bin/env python3
"""Convert official PP-OCRv6 Small safetensors models to fixed-shape Core ML."""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModelForObjectDetection, AutoModelForTextRecognition


RECOGNIZER_ID = "PaddlePaddle/PP-OCRv6_small_rec_safetensors"
DETECTOR_ID = "PaddlePaddle/PP-OCRv6_small_det_safetensors"


class RecognitionWrapper(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        return self.model(pixel_values=pixel_values).last_hidden_state


class DetectionWrapper(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        return self.model(pixel_values=pixel_values).last_hidden_state


def convert(
    model: torch.nn.Module,
    sample: torch.Tensor,
    output_name: str,
    output_path: Path,
) -> None:
    model.eval()
    with torch.no_grad():
        traced = torch.jit.trace(model, sample, strict=False)
        reference = model(sample)
        traced_result = traced(sample)
    trace_delta = float(torch.max(torch.abs(reference - traced_result)))
    if trace_delta > 1e-5:
        raise RuntimeError(f"Torch trace drift is too large: {trace_delta}")

    coreml_model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="x",
                shape=tuple(sample.shape),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name=output_name, dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(output_path)
    print(f"saved {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "models",
    )
    parser.add_argument("--detector-height", type=int, default=640)
    parser.add_argument("--detector-width", type=int, default=416)
    args = parser.parse_args()

    recognizer = RecognitionWrapper(
        AutoModelForTextRecognition.from_pretrained(RECOGNIZER_ID).eval()
    )
    convert(
        recognizer,
        torch.zeros(1, 3, 48, 320),
        "scores",
        args.output_dir / "ppocrv6-small-rec-macos14.mlpackage",
    )

    detector = DetectionWrapper(
        AutoModelForObjectDetection.from_pretrained(DETECTOR_ID).eval()
    )
    convert(
        detector,
        torch.zeros(1, 3, args.detector_height, args.detector_width),
        "probability_map",
        args.output_dir
        / (
            "ppocrv6-small-det-"
            f"{args.detector_height}x{args.detector_width}-macos14.mlpackage"
        ),
    )


if __name__ == "__main__":
    main()
