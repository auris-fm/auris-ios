#!/usr/bin/env bash
# Builds CPU-only llama.cpp static libraries for iOS (simulator and device).
# Pin must match Android modules/services/voice/src/main/cpp/CMakeLists.txt.
set -euo pipefail

LLAMA_GIT_TAG="0eadefebd3f8f92a86d634a0e5b8fffc9dc792c0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="${TMPDIR:-/tmp}/auris-llama-cpp/${LLAMA_GIT_TAG}"
SRC_DIR="${CACHE_ROOT}"
BUILD_ROOT="${ROOT}/ThirdParty/llama-cpp-build"
LINK_PATH="${ROOT}/ThirdParty/llama.cpp"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  mkdir -p "$(dirname "${CACHE_ROOT}")"
  rm -rf "${SRC_DIR}"
  git clone --depth 1 "https://github.com/ggerganov/llama.cpp.git" "${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --depth 1 origin "${LLAMA_GIT_TAG}"
  git -C "${SRC_DIR}" checkout "${LLAMA_GIT_TAG}"
fi

mkdir -p "${ROOT}/ThirdParty"
ln -sfn "${SRC_DIR}" "${LINK_PATH}"

build_slice() {
  local name="$1"
  local sysroot="$2"
  local arch="$3"
  local build_dir="${BUILD_ROOT}/${name}"

  if [[ -f "${build_dir}/src/libllama.a" && -f "${build_dir}/ggml/src/libggml.a" ]]; then
    echo "[llama-ios] ${name} already built"
    return 0
  fi

  echo "[llama-ios] configuring ${name} (${arch})"
  cmake -S "${SRC_DIR}" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sysroot}" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DGGML_METAL=OFF \
    -DGGML_CUDA=OFF \
    -DGGML_VULKAN=OFF \
    -DGGML_BLAS=ON \
    -DBUILD_SHARED_LIBS=OFF

  cmake --build "${build_dir}" --target llama ggml ggml-cpu ggml-base ggml-blas -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
}

build_slice ios-sim "$(xcrun --sdk iphonesimulator --show-sdk-path)" arm64
build_slice ios-device "$(xcrun --sdk iphoneos --show-sdk-path)" arm64

echo "[llama-ios] done"
echo "[llama-ios] headers: ${LINK_PATH}/include"
echo "[llama-ios] libs:    ${BUILD_ROOT}/{ios-sim,ios-device}"
