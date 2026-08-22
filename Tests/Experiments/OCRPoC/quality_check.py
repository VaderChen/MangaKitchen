#!/usr/bin/env python3
"""Run the official PaddleOCR pipeline and score manually reviewed dialogue lines."""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path
from typing import Any

from paddleocr import PaddleOCR


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for row, left_character in enumerate(left, 1):
        current = [row]
        for column, right_character in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def result_payload(result: Any) -> dict[str, Any]:
    payload = result.json
    if callable(payload):
        payload = payload()
    if isinstance(payload, str):
        payload = json.loads(payload)
    return payload["res"]


def match_lines(
    truth: dict[str, Any],
    texts: list[str],
    boxes: list[list[int]],
) -> list[dict[str, Any]]:
    width = truth["width"]
    height = truth["height"]
    available = set(range(len(texts)))
    matches: list[dict[str, Any]] = []

    for expected in truth["lines"]:
        x1, y1, x2, y2 = expected["box"]
        expected_x = (x1 + x2) / 2
        expected_y = (y1 + y2) / 2
        nearest: tuple[float, int] | None = None
        for index in available:
            bx1, by1, bx2, by2 = boxes[index]
            center_x = (bx1 + bx2) / 2
            center_y = (by1 + by2) / 2
            distance = math.hypot(
                (center_x - expected_x) / width,
                (center_y - expected_y) / height,
            )
            if nearest is None or distance < nearest[0]:
                nearest = (distance, index)
        if nearest is None or nearest[0] > 0.06:
            observed = ""
            distance = None
        else:
            distance, index = nearest
            available.remove(index)
            observed = texts[index]
        edits = edit_distance(expected["text"], observed)
        matches.append(
            {
                "expected": expected["text"],
                "observed": observed,
                "edits": edits,
                "distance": distance,
            }
        )
    return matches


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
        "--output",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "quality.json",
    )
    args = parser.parse_args()

    truth = json.loads(args.truth.read_text())
    ocr = PaddleOCR(
        text_detection_model_name="PP-OCRv6_small_det",
        text_recognition_model_name="PP-OCRv6_small_rec",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=True,
        device="cpu",
    )

    sample_paths = sorted(args.samples.glob("Gemini_Image_*.jpeg"))
    if sample_paths:
        list(ocr.predict(str(sample_paths[0])))

    report: dict[str, Any] = {"pages": {}, "summary": {}}
    total_edits = 0
    total_characters = 0
    exact_lines = 0
    line_count = 0
    for path in sample_paths:
        start = time.perf_counter()
        results = list(ocr.predict(str(path)))
        elapsed = time.perf_counter() - start
        payload = result_payload(results[0])
        page: dict[str, Any] = {
            "elapsed_seconds": elapsed,
            "texts": payload["rec_texts"],
            "scores": payload["rec_scores"],
            "boxes": payload["rec_boxes"],
        }
        if path.name in truth:
            matches = match_lines(
                truth[path.name],
                payload["rec_texts"],
                payload["rec_boxes"],
            )
            page["dialogue_matches"] = matches
            page_edits = sum(item["edits"] for item in matches)
            page_characters = sum(len(item["expected"]) for item in matches)
            page_exact = sum(item["expected"] == item["observed"] for item in matches)
            page["dialogue_cer"] = page_edits / page_characters
            page["exact_dialogue_lines"] = page_exact
            total_edits += page_edits
            total_characters += page_characters
            exact_lines += page_exact
            line_count += len(matches)
        report["pages"][path.name] = page
        print(f"{path.name}: {elapsed:.3f}s, {len(payload['rec_texts'])} regions")

    report["summary"] = {
        "dialogue_edits": total_edits,
        "dialogue_characters": total_characters,
        "dialogue_cer": total_edits / total_characters,
        "exact_dialogue_lines": exact_lines,
        "dialogue_lines": line_count,
    }
    print(json.dumps(report["summary"], ensure_ascii=False))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
