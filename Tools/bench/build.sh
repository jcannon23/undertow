#!/bin/sh
# Builds the benchmark CLI against the vendored llama.cpp static libs.
set -e
cd "$(dirname "$0")/../.."
L=Vendor/llama.cpp
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 Sources/Engine/*.swift Sources/Engine/Ported/*.swift Tools/bench/main.swift \
  -import-objc-header Sources/Bridging/Undertow-Bridging-Header.h \
  -I $L/include -I $L/ggml/include \
  -L $L/build/src -L $L/build/ggml/src -L $L/build/ggml/src/ggml-metal -L $L/build/ggml/src/ggml-blas \
  -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lc++ \
  -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
  -o build/bench
