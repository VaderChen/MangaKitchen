#!/usr/bin/env python3
"""Build identical -O benchmark programs from a Git baseline and current source.

Only writes the output directory. No model downloads, package resolution, or app settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="519ebc2")
    parser.add_argument("--output", type=Path, default=root / "Artifacts/function-performance")
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(command, log):
        with log.open("w") as stream:
            subprocess.run([str(x) for x in command], cwd=root, stdout=stream,
                           stderr=subprocess.STDOUT, check=True)

    def source(relative, baseline=False):
        if baseline:
            return subprocess.check_output(["git", "show", f"{args.baseline}:{relative}"],
                                           cwd=root).decode()
        return (root / relative).read_text()

    # Both variants share the same unmodified domain types and image I/O.
    core = sorted(p for p in (root / "Sources/MangaKitchenCore").glob("*.swift")
                  if not p.name.startswith("."))
    run(["/usr/bin/swiftc", "-O", "-swift-version", "6", "-emit-library", "-emit-module",
         "-module-name", "MangaKitchenCore", "-emit-module-path", out / "MangaKitchenCore.swiftmodule",
         *core, "-o", out / "libMangaKitchenCore.dylib"], out / "build-core.log")
    manifest = source("Sources/MangaKitchenRuntime/ModelManifest.swift")
    error_file = out / "ModelRuntimeError.swift"
    error_file.write_text("import Foundation\nimport MangaKitchenCore\n" +
                          manifest[manifest.index("public enum ModelRuntimeError:"):])
    names = ["CPUBubbleCleaner", "MangaTextMaskRefiner", "MangaBubbleSegmentationCoreMLRuntime"]
    common = [root / f"Sources/MangaKitchenRuntime/{name}.swift"
              for name in ["CGImageIO", "MaskDilation", "MangaTextDirectionDetector"]]
    for variant in ["baseline", "current"]:
        directory = out / variant
        directory.mkdir(exist_ok=True)
        files = []
        for name in names:
            path = directory / f"{name}.swift"
            path.write_text(source(f"Sources/MangaKitchenRuntime/{name}.swift", variant == "baseline"))
            files.append(path)
        web = source("Sources/MangaKitchenApp/WebState.swift", variant == "baseline")
        path = directory / "WebBatchJob.swift"
        path.write_text("import Foundation\nimport MangaKitchenCore\n" +
                        web[web.index("struct WebBatchFailure:"):web.index("struct WebGlossaryEntry:")])
        files.append(path)
        flags = []
        if variant == "current":
            flags = ["-D", "OPTIMIZED_FUNCTIONS"]
            files.append(root / "Sources/MangaKitchenRuntime/SegmentationTensorReader.swift")
        run(["/usr/bin/swiftc", "-O", "-swift-version", "6", "-parse-as-library", *flags,
             "-I", out, "-L", out, "-lMangaKitchenCore", "-Xlinker", "-rpath", "-Xlinker", out,
             *common, error_file, *files, root / "Tools/FunctionPerformance/benchmark.swift",
             "-o", out / variant / "benchmark"], out / f"build-{variant}.log")

    results = {}
    for mode in ["clean-auto", "clean-fixed", "refine", "bubbles", "jobs"]:
        results[mode] = {}
        for run_index in range(1, args.runs + 1):
            expected = None
            for variant in ["baseline", "current"]:
                product = out / f"{variant}-{mode}.result"
                log = out / f"run-{run_index}-{variant}-{mode}.log"
                run(["/usr/bin/time", "-l", out / variant / "benchmark", mode, product, root], log)
                digest = hashlib.sha256(product.read_bytes()).hexdigest()
                if expected is None:
                    expected = digest
                if digest != expected:
                    raise RuntimeError(f"Output mismatch: {mode}, run {run_index}")
                text = log.read_text()
                sample = {
                    "seconds": float(re.search(r"seconds=([0-9.eE+-]+)", text)[1]),
                    "peak_rss_bytes": int(re.search(r"(\d+)\s+maximum resident set size", text)[1]),
                    "sha256": digest,
                }
                results[mode].setdefault(variant, []).append(sample)
                print(mode, run_index, variant, sample, flush=True)
        for variant, samples in results[mode].items():
            print(mode, variant, "median seconds", statistics.median(s["seconds"] for s in samples),
                  "median RSS", statistics.median(s["peak_rss_bytes"] for s in samples), flush=True)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
