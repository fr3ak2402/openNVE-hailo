#!/usr/bin/env bash
# Builds opennve_hailo against the HailoRT installed on this computer and installs it into the
# active Python (virtual environment), for instance on a Raspberry Pi 5 with AI Kit / AI HAT+ /
# AI HAT+ 2.
#
#     sudo apt install dkms hailo-all       # Hailo-8 / 8L (AI HAT+ 2, Hailo-10H: hailo-h10-all)
#     sudo apt install git g++              # C++ compiler
#     curl https://sh.rustup.rs -sSf | sh   # Rust
#     source ~/opennve/.venv/bin/activate
#     bash install.sh
#
# Environment variables (optional):
#     PYTHON=/path/to/python    Python to install into (default: the active venv, else python3)
#     HAILORT_VERSION=4.23.0    version of the installed HailoRT (default: hailortcli / dpkg)
#     HAILORT_INCLUDE_DIR=...   HailoRT headers of that version (default: /usr/include if it has
#                               them, else downloaded from github.com/hailo-ai/hailort)
#     HAILORT_LIB_DIR=...       directory of libhailort.so.<version> (default: /usr/lib, ...)
#     CACHE=~/.cache/opennve-hailo
#
# Run it again after a HailoRT update: the package is compiled for one HailoRT version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${CACHE:-$HOME/.cache/opennve-hailo}"
fail() { echo "error: $*" >&2; exit 1; }

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    PYTHON="${PYTHON:-$VIRTUAL_ENV/bin/python}"
fi
PYTHON="$(command -v "${PYTHON:-python3}")" || fail "python not found"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || fail "$PYTHON is older than 3.11"

command -v cargo >/dev/null || fail "Rust (cargo) is missing: curl https://sh.rustup.rs -sSf | sh, then open a new terminal"
command -v g++ >/dev/null || command -v c++ >/dev/null || fail "C++ compiler missing: sudo apt install g++"
command -v git >/dev/null || fail "git missing: sudo apt install git"

# installed HailoRT version
if [[ -z "${HAILORT_VERSION:-}" ]] && command -v hailortcli >/dev/null; then
    HAILORT_VERSION="$(hailortcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [[ -z "${HAILORT_VERSION:-}" ]] && command -v dpkg-query >/dev/null; then
    for package in hailort h10-hailort; do  # Hailo-8 / 8L, Hailo-10H
        HAILORT_VERSION="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
        [[ -n "$HAILORT_VERSION" ]] && break
    done
fi
[[ -n "${HAILORT_VERSION:-}" ]] || fail "HailoRT not found: sudo apt install hailo-all (AI HAT+ 2: hailo-h10-all), or set HAILORT_VERSION"
case "${HAILORT_VERSION%%.*}" in
    4) CHIPS="Hailo-8, Hailo-8L" ;;
    5) CHIPS="Hailo-10H, Hailo-15" ;;
    *) fail "HailoRT $HAILORT_VERSION is not supported (4.x or 5.x)" ;;
esac
export HAILORT_VERSION

# headers of exactly this version (the C++ API changes between versions)
if [[ -z "${HAILORT_INCLUDE_DIR:-}" ]]; then
    SOURCE="$CACHE/hailort-$HAILORT_VERSION"
    if [[ ! -f "$SOURCE/hailort/libhailort/include/hailo/hailort.hpp" ]]; then
        rm -rf "$SOURCE"
        mkdir -p "$CACHE"
        echo "downloading the HailoRT $HAILORT_VERSION headers"
        git clone --quiet --depth 1 --branch "v$HAILORT_VERSION" --filter=blob:none --sparse \
            https://github.com/hailo-ai/hailort.git "$SOURCE"
        git -C "$SOURCE" sparse-checkout set hailort/libhailort/include
    fi
    HAILORT_INCLUDE_DIR="$SOURCE/hailort/libhailort/include"
fi
export HAILORT_INCLUDE_DIR

echo "Python      $PYTHON ($("$PYTHON" -c 'import platform; print(platform.python_version())'))"
echo "HailoRT     $HAILORT_VERSION ($CHIPS)"
echo "headers     $HAILORT_INCLUDE_DIR"

"$PYTHON" -m pip --version >/dev/null 2>&1 || "$PYTHON" -m ensurepip --upgrade >/dev/null
"$PYTHON" -m pip install --quiet --upgrade "maturin>=1.8,<2"
rm -rf "$HERE/python/dist"
(cd "$HERE/python" && "$PYTHON" -m maturin build --release --interpreter "$PYTHON" --out dist)
"$PYTHON" -m pip install --force-reinstall "$HERE"/python/dist/opennve_hailo-*.whl

"$PYTHON" - <<'EOF'
import opennve_hailo

print(f"opennve_hailo {opennve_hailo.__version__} with HailoRT {opennve_hailo.hailort_version()}")
devices = opennve_hailo.scan()
print("Hailo devices:", ", ".join(f"{d.id} ({d.chip or 'in use'})" for d in devices) if devices else "none found")
EOF
