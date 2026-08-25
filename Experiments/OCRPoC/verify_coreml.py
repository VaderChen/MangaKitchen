#!/usr/bin/env python3
"""Verify Core ML recognition and detector coverage on the reviewed samples."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import coremltools as ct
import cv2
import numpy as np
import torch
from PIL import Image
from transformers import AutoImageProcessor

from quality_check import match_lines


RECOGNIZER_ID = "PaddlePaddle/PP-OCRv6_small_rec_safetensors"
DETECTOR_ID = "PaddlePaddle/PP-OCRv6_small_det_safetensors"


def perspective_crop(source: np.ndarray, polygon: Any) -> Image.Image:
    points = np.asarray(polygon, dtype=np.float32)
    width = max(
        np.linalg.norm(points[0] - points[1]),
        np.linalg.norm(points[2] - points[3]),
    )
    height = max(
        np.linalg.norm(points[0] - points[3]),
        np.linalg.norm(points[1] - points[2]),
    )
    pixel_width = max(1, int(round(float(width))))
    pixel_height = max(1, int(round(float(height))))
    target = np.asarray(
        [
            [0, 0],
            [pixel_width - 1, 0],
            [pixel_width - 1, pixel_height - 1],
            [0, pixel_height - 1],
        ],
        dtype=np.float32,
    )
    transform = cv2.getPerspectiveTransform(points, target)
    crop = cv2.warpPerspective(
        source,
        transform,
        (pixel_width, pixel_height),
        borderMode=cv2.BORDER_REPLICATE,
    )
    if pixel_height / pixel_width >= 1.5:
        crop = np.rot90(crop)
    return Image.fromarray(crop)


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=Path, default=root / "Samples")
    parser.add_argument(
        "--truth",
        type=Path,
        default=Path(__file__).parent / "dialogue-lines.json",
    )
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "models",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "coreml-verification.json",
    )
    args = parser.parse_args()

    truth = json.loads(args.truth.read_text())
    recognizer_processor = AutoImageProcessor.from_pretrained(RECOGNIZER_ID)
    detector_processor = AutoImageProcessor.from_pretrained(DETECTOR_ID)
    recognizer = ct.models.MLModel(
        str(args.model_dir / "ppocrv6-small-rec-macos14.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    detector = ct.models.MLModel(
        str(args.model_dir / "ppocrv6-small-det-640x416-macos14.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )

    report: dict[str, Any] = {"pages": {}, "summary": {}}
    total_edits = 0
    total_characters = 0
    exact_lines = 0
    covered_lines = 0
    line_count = 0

    for filename, page_truth in truth.items():
        image = Image.open(args.samples / filename).convert("RGB")
        source = np.asarray(image)
        page: dict[str, Any] = {}

        detector_values = detector_processor(
            images=image,
            return_tensors="pt",
            limit_side_len=640,
            limit_type="max",
            max_side_limit=640,
        )
        shape = tuple(detector_values.pixel_values.shape)
        if shape != (1, 3, 640, 416):
            raise RuntimeError(f"Unexpected detector input shape for {filename}: {shape}")
        probability_map = detector.predict(
            {"x": detector_values.pixel_values.numpy()}
        )["probability_map"]
        detections = detector_processor.post_process_object_detection(
            SimpleNamespace(last_hidden_state=torch.from_numpy(probability_map)),
            target_sizes=detector_values.target_sizes,
        )[0]
        polygons = detections["boxes"].numpy()
        crops = [perspective_crop(source, polygon) for polygon in polygons]
        recognition_values = recognizer_processor(
            images=crops,
            return_tensors="pt",
        ).pixel_values
        recognized: list[dict[str, Any]] = []
        for values, polygon in zip(recognition_values, polygons):
            scores = recognizer.predict({"x": values.numpy()[None, ...]})["scores"]
            decoded = recognizer_processor.post_process_text_recognition(
                SimpleNamespace(last_hidden_state=torch.from_numpy(scores))
            )[0]
            recognized.append(
                {
                    "text": decoded["text"],
                    "score": decoded["score"],
                    "polygon": polygon.tolist(),
                }
            )

        boxes = [
            [
                float(np.min(polygon[:, 0])),
                float(np.min(polygon[:, 1])),
                float(np.max(polygon[:, 0])),
                float(np.max(polygon[:, 1])),
            ]
            for polygon in polygons
        ]
        matches = match_lines(
            page_truth,
            [item["text"] for item in recognized],
            boxes,
        )
        page_edits = sum(item["edits"] for item in matches)
        page_characters = sum(len(item["expected"]) for item in matches)
        page_exact = sum(item["expected"] == item["observed"] for item in matches)
        page_covered = sum(item["distance"] is not None for item in matches)
        total_edits += page_edits
        total_characters += page_characters
        exact_lines += page_exact
        line_count += len(matches)
        page["detector_boxes"] = len(polygons)
        page["covered_dialogue_lines"] = page_covered
        page["recognized_regions"] = recognized
        page["dialogue_matches"] = matches
        covered_lines += page_covered
        report["pages"][filename] = page

    report["summary"] = {
        "recognition_edits": total_edits,
        "recognition_characters": total_characters,
        "recognition_cer": total_edits / total_characters,
        "exact_recognition_lines": exact_lines,
        "covered_dialogue_lines": covered_lines,
        "dialogue_lines": line_count,
    }
    print(json.dumps(report["summary"], ensure_ascii=False))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
