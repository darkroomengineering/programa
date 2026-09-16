#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.cargo/bin:${PATH}"
command -v cargo >/dev/null || { echo 'error: install the Rust toolchain to build Programa core' >&2; exit 1; }
CORE_OUTPUT="${BUILT_PRODUCTS_DIR:?Xcode BUILT_PRODUCTS_DIR is required}/programa-core"
export CARGO_TARGET_DIR="${TARGET_TEMP_DIR:?Xcode TARGET_TEMP_DIR is required}/rust-core"
# Keep host compiler plugins unstripped: stripping their Mach-O string tables
# can produce invalid LINKEDIT alignment with the macOS 27 toolchain.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=true
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
mkdir -p "$CORE_OUTPUT"
LIBRARIES=()
for architecture in ${ARCHS:?Xcode ARCHS is required}; do
  case "$architecture" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "error: unsupported core architecture: $architecture" >&2; exit 1 ;;
  esac
  cargo build --locked --release --manifest-path "$ROOT/core/Cargo.toml" -p programa-ffi --target "$target"
  LIBRARIES+=("$CARGO_TARGET_DIR/$target/release/libprograma_core.a")
done
if [[ ${#LIBRARIES[@]} == 1 ]]; then
  cp "${LIBRARIES[0]}" "$CORE_OUTPUT/libprograma_core.a"
else
  xcrun lipo -create "${LIBRARIES[@]}" -output "$CORE_OUTPUT/libprograma_core.a"
fi
