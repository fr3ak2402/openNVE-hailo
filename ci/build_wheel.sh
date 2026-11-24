#!/usr/bin/env bash
# Builds the ready-made opennve_hailo package for one HailoRT version, inside a manylinux_2_28
# container (glibc 2.28: Raspberry Pi OS Bookworm and Trixie, Ubuntu 20.04 and newer):
#
#     docker run --rm -v "$PWD:/io" quay.io/pypa/manylinux_2_28_aarch64 bash /io/ci/build_wheel.sh 4.23.0
#
# The package links the libhailort.so.<version> of the system (installed with the driver), it
# does not contain it. Output: /io/dist/hailort-<version>_opennve_hailo-...whl
set -euo pipefail
VERSION="$1"
MACHINE="$(uname -m)"
LIB="/io/.cache/libhailort-$VERSION-$MACHINE"
PYTHON=/opt/python/cp311-cp311/bin/python

if [[ ! -f "$LIB/lib/libhailort.so.$VERSION" ]]; then
    echo "building libhailort $VERSION (only to link against)"
    "$PYTHON" -m pip install --quiet ninja
    export PATH="$(dirname "$PYTHON"):$PATH"
    rm -rf /tmp/hailort /tmp/hailort-build
    git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/hailo-ai/hailort.git /tmp/hailort
    cmake -S /tmp/hailort -B /tmp/hailort-build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/hailort-build --target libhailort
    rm -rf "$LIB" && mkdir -p "$LIB/lib"
    cp -a /tmp/hailort-build/hailort/libhailort/src/libhailort.so* "$LIB/lib/"
    cp -a /tmp/hailort/hailort/libhailort/include "$LIB/include"
fi

if ! command -v cargo >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    source "$HOME/.cargo/env"
fi
"$PYTHON" -m pip install --quiet "maturin>=1.8,<2"

export HAILORT_VERSION="$VERSION" HAILORT_INCLUDE_DIR="$LIB/include" HAILORT_LIB_DIR="$LIB/lib" OPENNVE_HAILO_NO_RPATH=1
export CARGO_TARGET_DIR="/io/.cache/target-$VERSION-$MACHINE"
OUT="/tmp/wheels-$VERSION"
rm -rf "$OUT"
(cd /io/python && "$PYTHON" -m maturin build --release --interpreter "$PYTHON" \
    --compatibility manylinux_2_28 --auditwheel skip --out "$OUT")
mkdir -p /io/dist
for wheel in "$OUT"/*.whl; do
    cp "$wheel" "/io/dist/hailort-${VERSION}_$(basename "$wheel")"
done
ls -l /io/dist
