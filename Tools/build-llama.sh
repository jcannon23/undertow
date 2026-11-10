#!/bin/sh
# Fetches llama.cpp at the pinned commit and builds the static libraries the app links.
set -e
cd "$(dirname "$0")/.."
PIN=7c2653a
mkdir -p Vendor
[ -d Vendor/llama.cpp ] || git clone https://github.com/ggml-org/llama.cpp.git Vendor/llama.cpp
cd Vendor/llama.cpp
git fetch -q origin && git checkout -q "$PIN"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build -j 6 --target llama ggml ggml-base ggml-cpu ggml-metal ggml-blas
