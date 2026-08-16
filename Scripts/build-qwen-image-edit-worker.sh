#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}
worker_package="$project_root/RuntimeSupport/QwenImageEditWorker"

swift build \
  --package-path "$worker_package" \
  --configuration release

echo "Worker: $worker_package/.build/release/MangaKitchenQwenImageEditWorker"
