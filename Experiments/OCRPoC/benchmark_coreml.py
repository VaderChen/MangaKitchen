#!/usr/bin/env python3
"""Benchmark fixed-shape Core ML models and report planned compute devices."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from collections import Counter
from pathlib import Path

import coremltools as ct
import numpy as np


CONFIGURATIONS = {
    "all": ct.ComputeUnit.ALL,
    "ane": ct.ComputeUnit.CPU_AND_NE,
    "gpu": ct.ComputeUnit.CPU_AND_GPU,
    "cpu": ct.ComputeUnit.CPU_ONLY,
}


def planned_devices(model: ct.models.MLModel, unit: ct.ComputeUnit) -> dict[str, int]:
    plan = ct.models.compute_plan.MLComputePlan.load_from_path(
        model.get_compiled_model_path(),
        compute_units=unit,
    )
    program = plan.model_structure.program
    if program is None:
        return {}
    counts: Counter[str] = Counter()
    for operation in program.functions["main"].block.operations:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
        if usage is None:
            continue
        name = type(usage.preferred_compute_device).__name__
        counts[name] += 1
    return dict(counts)


def benchmark(
    name: str,
    path: Path,
    shape: tuple[int, ...],
    output_name: str,
    iterations: int,
) -> list[dict[str, object]]:
    rng = np.random.default_rng(20260822)
    sample = rng.normal(size=shape).astype(np.float32)
    rows: list[dict[str, object]] = []
    reference: np.ndarray | None = None

    for configuration, unit in CONFIGURATIONS.items():
        load_start = time.perf_counter()
        model = ct.models.MLModel(str(path), compute_units=unit)
        load_ms = (time.perf_counter() - load_start) * 1_000
        durations: list[float] = []
        output: np.ndarray | None = None
        for _ in range(iterations):
            start = time.perf_counter()
            output = model.predict({"x": sample})[output_name]
            durations.append((time.perf_counter() - start) * 1_000)
        assert output is not None

        if reference is None:
            reference = output.copy()
            maximum_delta = 0.0
        else:
            maximum_delta = float(np.max(np.abs(output - reference)))

        warm = durations[min(3, len(durations) - 1) :]
        row = {
            "model": name,
            "configuration": configuration,
            "load_ms": load_ms,
            "cold_ms": durations[0],
            "warm_median_ms": statistics.median(warm),
            "internal_ms": model.last_predict_duration_in_nano_seconds / 1_000_000,
            "maximum_delta_from_all": maximum_delta,
            "planned_devices": planned_devices(model, unit),
        }
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False))
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "models",
    )
    parser.add_argument("--iterations", type=int, default=12)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).parent / ".artifacts" / "benchmark.json",
    )
    args = parser.parse_args()

    rows: list[dict[str, object]] = []
    rows.extend(
        benchmark(
            "recognizer",
            args.model_dir / "ppocrv6-small-rec-macos14.mlpackage",
            (1, 3, 48, 320),
            "scores",
            args.iterations,
        )
    )
    rows.extend(
        benchmark(
            "detector",
            args.model_dir / "ppocrv6-small-det-640x416-macos14.mlpackage",
            (1, 3, 640, 416),
            "probability_map",
            args.iterations,
        )
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
