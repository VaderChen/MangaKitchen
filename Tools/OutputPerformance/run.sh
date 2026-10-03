#!/bin/bash
set -euo pipefail

# 用相同工具鏈編譯基準版本與工作目錄版本，再分別以 time 量測 process peak RSS。
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline_ref="${1:-519ebc2}"
result_dir="${2:-$project_root/Artifacts/output-performance}"
mkdir -p "$result_dir"
result_dir="$(cd "$result_dir" && pwd)"
cd "$project_root"
git show "$baseline_ref:Sources/MangaKitchenApp/PSDExporter.swift" > "$result_dir/LegacyPSDExporter.swift"
sed '/^import MangaKitchenCore$/d' Sources/MangaKitchenApp/PSDExporter.swift > "$result_dir/CurrentPSDExporter.swift"
swiftc -O "$result_dir/LegacyPSDExporter.swift" Tools/OutputPerformance/benchmark.swift -o "$result_dir/baseline"
swiftc -O -D STREAMING_OUTPUT Sources/MangaKitchenCore/AtomicFileWriter.swift \
    "$result_dir/CurrentPSDExporter.swift" Tools/OutputPerformance/benchmark.swift -o "$result_dir/current"

for run in 1 2 3; do
    for variant in baseline current; do
        /usr/bin/time -l "$result_dir/$variant" psd "$result_dir/$variant.psd" 2048 3072 6 \
            > "$result_dir/run-$run-$variant-psd.log" 2>&1
        /usr/bin/time -l "$result_dir/$variant" copy "$result_dir/baseline.psd" "$result_dir/$variant-copy.psd" \
            > "$result_dir/run-$run-$variant-copy.log" 2>&1
    done
done
cmp "$result_dir/baseline.psd" "$result_dir/current.psd"
cmp "$result_dir/baseline.psd" "$result_dir/baseline-copy.psd"
cmp "$result_dir/baseline.psd" "$result_dir/current-copy.psd"
awk '/mode=|maximum resident set size/ {print FILENAME ": " $0}' "$result_dir/"run-*.log
