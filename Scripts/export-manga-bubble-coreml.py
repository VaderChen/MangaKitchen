#!/usr/bin/env python3
"""將 manga109 氣泡分割權重匯出為 App 內建的 Core ML 模型。"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from ultralytics import YOLO


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Sources/MangaKitchenApp/Resources/Models/MangaBubbleSegmentation.mlpackage"),
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    weights = arguments.weights.expanduser().resolve()
    output = arguments.output.expanduser().resolve()
    if not weights.is_file():
        raise SystemExit(f"找不到模型權重：{weights}")

    exported = Path(
        YOLO(weights).export(
            format="coreml",
            imgsz=1600,
            batch=1,
            dynamic=False,
            half=True,
            nms=False,
        )
    )
    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(exported, output)
    print(f"已輸出 Core ML 氣泡分割模型：{output}")


if __name__ == "__main__":
    main()
