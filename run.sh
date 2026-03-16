#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f "vendor/onnxruntime/lib/libonnxruntime.dylib" ]; then
  echo "ONNX Runtime not found. Running setup..."
  ./scripts/setup.sh
fi

swift build

# Make icon available next to the binary
cp -f Resources/LocalTalker.icns .build/debug/ 2>/dev/null || true
cp -f Resources/Commander.icns .build/debug/ 2>/dev/null || true

export DYLD_LIBRARY_PATH="$(pwd)/vendor/onnxruntime/lib:${DYLD_LIBRARY_PATH:-}"
exec .build/debug/LocalTalker "$@"
