#!/usr/bin/env bash
# Builds CPU-only llama.cpp static libraries for iOS (simulator and device),
# then packs llama + ggml + LFM into one archive that exports only the lfm_* C API.
# That keeps whisper.spm's ggml symbols from colliding at link time.
# Pin must match Android modules/services/voice/src/main/cpp/CMakeLists.txt.
set -euo pipefail

LLAMA_GIT_TAG="0eadefebd3f8f92a86d634a0e5b8fffc9dc792c0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="${TMPDIR:-/tmp}/auris-llama-cpp/${LLAMA_GIT_TAG}"
SRC_DIR="${CACHE_ROOT}"
BUILD_ROOT="${ROOT}/ThirdParty/llama-cpp-build"
LINK_PATH="${ROOT}/ThirdParty/llama.cpp"
NATIVE_DIR="${ROOT}/podcasts/VoiceControl/IntentRouter/Native"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

EXPORTS=(
  _lfm_last_error
  _lfm_load
  _lfm_tokenize
  _lfm_free_ints
  _lfm_classify
  _lfm_generate
  _lfm_free_string
  _lfm_reset
  _lfm_release
)

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
  else
    echo "[llama-ios] configuring ${name} (${arch})"
    # -fno-common turns ggml lookup tables into regular locals after ld -r export filtering,
    # avoiding coalesced commons with whisper.spm's older ggml.
    cmake -S "${SRC_DIR}" -B "${build_dir}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT="${sysroot}" \
      -DCMAKE_OSX_ARCHITECTURES="${arch}" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
      -DCMAKE_C_FLAGS="-fno-common" \
      -DCMAKE_CXX_FLAGS="-fno-common" \
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

    cmake --build "${build_dir}" --target llama ggml ggml-cpu ggml-base ggml-blas -j "${JOBS}"
  fi

  build_lfm_runtime "${name}" "${sysroot}" "${arch}"
}

build_lfm_runtime() {
  local name="$1"
  local sysroot="$2"
  local arch="$3"
  local build_dir="${BUILD_ROOT}/${name}"
  local out_dir="${build_dir}/lfm"
  local out_lib="${out_dir}/liblfm_runtime.a"
  local work_dir="${out_dir}/work"
  local min_flag
  local export_flags=()
  local sym

  if [[ "${name}" == "ios-sim" ]]; then
    min_flag="-mios-simulator-version-min=17.0"
  else
    min_flag="-miphoneos-version-min=17.0"
  fi

  for sym in "${EXPORTS[@]}"; do
    export_flags+=(-exported_symbol "${sym}")
  done

  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"
  echo "[llama-ios] building symbol-isolated lfm_runtime for ${name}"

  local sources=(
    "${NATIVE_DIR}/ClassifierHead.cpp"
    "${NATIVE_DIR}/LfmRuntime.cpp"
    "${NATIVE_DIR}/LfmRuntimeC.cpp"
  )
  local src
  for src in "${sources[@]}"; do
    local obj="${work_dir}/$(basename "${src}" .cpp).o"
    xcrun clang++ \
      -std=c++17 -O2 -fPIC -fexceptions -fvisibility=hidden -fno-common \
      -isysroot "${sysroot}" \
      -arch "${arch}" \
      "${min_flag}" \
      -I"${NATIVE_DIR}" \
      -I"${LINK_PATH}/include" \
      -I"${LINK_PATH}/ggml/include" \
      -c "${src}" \
      -o "${obj}"
  done

  local merged="${out_dir}/lfm_merged.o"
  # force_load is required: libllama.a / libggml-cpu.a contain duplicate member names,
  # so ar -x would drop objects and leave unresolved llama/ggml symbols.
  xcrun ld -r -arch "${arch}" -syslibroot "${sysroot}" \
    -o "${merged}" \
    "${export_flags[@]}" \
    "${work_dir}/ClassifierHead.o" \
    "${work_dir}/LfmRuntime.o" \
    "${work_dir}/LfmRuntimeC.o" \
    -force_load "${build_dir}/src/libllama.a" \
    -force_load "${build_dir}/ggml/src/libggml.a" \
    -force_load "${build_dir}/ggml/src/libggml-base.a" \
    -force_load "${build_dir}/ggml/src/libggml-cpu.a" \
    -force_load "${build_dir}/ggml/src/ggml-blas/libggml-blas.a"

  # Existing llama builds may still expose coalesced commons; privatize if present.
  local commons=()
  local common_sym
  for common_sym in _ggml_table_f32_e8m0_half _ggml_table_f32_f16 _ggml_table_f32_ue4m3; do
    if nm -gU "${merged}" 2>/dev/null | rg -q " ${common_sym}$"; then
      commons+=("${common_sym}")
    fi
  done
  if ((${#commons[@]} > 0)); then
    echo "[llama-ios] error: still-global commons after -fno-common merge: ${commons[*]}" >&2
    echo "[llama-ios] these collide with whisper.spm's ggml; rebuild failed closed." >&2
    exit 1
  fi

  xcrun libtool -static -o "${out_lib}" "${merged}"
  rm -rf "${work_dir}"

  echo "[llama-ios] wrote ${out_lib}"
  echo "[llama-ios] exported globals:"
  nm -gU "${out_lib}" | sed 's/^/[llama-ios]   /'
}

# arm64 only (min iOS 17); no x86_64 simulator slice.
build_slice ios-sim "$(xcrun --sdk iphonesimulator --show-sdk-path)" arm64
build_slice ios-device "$(xcrun --sdk iphoneos --show-sdk-path)" arm64

echo "[llama-ios] done (arm64 simulator + device)"
echo "[llama-ios] headers: ${LINK_PATH}/include"
echo "[llama-ios] lfm:     ${BUILD_ROOT}/{ios-sim,ios-device}/lfm/liblfm_runtime.a"
