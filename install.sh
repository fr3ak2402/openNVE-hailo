#!/usr/bin/env bash
# Sets up a Hailo accelerator for openNVE and installs opennve_hailo into the active Python.
#
#     source ~/opennve/.venv/bin/activate    # the Python environment of openNVE
#     bash install.sh                        # or: opennve hailo install
#
# On a Raspberry Pi (Raspberry Pi OS) it does everything that is needed, and only what is missing:
#   1. finds the Hailo module (PCIe): Hailo-8 / 8L (AI Kit, AI HAT+) or Hailo-10H (AI HAT+ 2)
#   2. enables the PCIe connector and PCIe Gen 3 in /boot/firmware/config.txt (Raspberry Pi 5)
#   3. installs driver, firmware and HailoRT: sudo apt install dkms hailo-all (Hailo-10H: hailo-h10-all)
#   4. installs the ready-made opennve_hailo package for the installed HailoRT version (releases
#      of openNVE-hailo) into the active Python
#   5. only if there is none (or with --build): installs git, g++, curl and Rust (rustup, for this
#      user) and builds opennve_hailo against the installed HailoRT
# Steps 2 and 3 need a reboot; the script says so at the end (--reboot: reboots itself).
# On other Linux computers steps 2 and 3 are skipped: install HailoRT from the Hailo Developer
# Zone first. Run it again after a HailoRT update.
#
# Options:
#     --yes          do not ask before installing system packages / changing config.txt
#     --no-system    only build and install opennve_hailo (HailoRT must be installed)
#     --no-gen3      do not enable PCIe Gen 3
#     --package P    HailoRT package for apt: hailo-all or hailo-h10-all (default: by the module found)
#     --reboot       reboot at the end if needed
#     --build        build opennve_hailo here instead of installing the ready-made package
#
# Environment variables (optional): PYTHON, HAILORT_VERSION, HAILORT_INCLUDE_DIR, HAILORT_LIB_DIR,
# CACHE (default ~/.cache/opennve-hailo), see the README.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${OPENNVE_HAILO_ROOT:-}"  # tests: a fake / with proc, sys and boot
CACHE="${CACHE:-$HOME/.cache/opennve-hailo}"
ASSUME_YES=0
SYSTEM=1
GEN3=1
PACKAGE=""
REBOOT=0
BUILD=0
for argument in "$@"; do
    case "$argument" in
        --yes | -y) ASSUME_YES=1 ;;
        --no-system) SYSTEM=0 ;;
        --no-gen3) GEN3=0 ;;
        --package=*) PACKAGE="${argument#--package=}" ;;
        --reboot) REBOOT=1 ;;
        --build) BUILD=1 ;;
        --help | -h) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $argument (--help)" >&2; exit 2 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
ask() {
    [[ $ASSUME_YES == 1 ]] && return 0
    local answer
    read -r -p "$1 [Y/n] " answer </dev/tty || answer=""
    [[ -z "$answer" || "$answer" =~ ^[YyJj] ]]
}
NEEDS_REBOOT=0
SUDO=""
if [[ $(id -u) != 0 ]]; then SUDO="sudo"; fi

if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    PYTHON="${PYTHON:-$VIRTUAL_ENV/bin/python}"
fi
PYTHON="$(command -v "${PYTHON:-python3}")" || fail "python not found"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || fail "$PYTHON is older than 3.11"
[[ "$(uname -s)" == Linux ]] || fail "install.sh is for Linux; on Windows install HailoRT with Hailo's installer and build with maturin (README)"

MODEL="$(tr -d '\0' <"$ROOT/proc/device-tree/model" 2>/dev/null || true)"
RASPBERRY_PI=0
[[ "$MODEL" == Raspberry\ Pi* ]] && RASPBERRY_PI=1

# ---------------------------------------------------------------- 1. Hailo module
# PCI ids: vendor 1e60 (Hailo), device 2864 = Hailo-8 / Hailo-8L, 45c4 = Hailo-10H
CHIP=""
for device in "$ROOT"/sys/bus/pci/devices/*; do
    [[ -f "$device/vendor" ]] || continue
    if [[ "$(cat "$device/vendor")" == 0x1e60 ]]; then
        case "$(cat "$device/device")" in
            0x2864) CHIP="Hailo-8 / Hailo-8L" ;;
            0x45c4) CHIP="Hailo-10H" ;;
            *) CHIP="Hailo ($(cat "$device/device"))" ;;
        esac
        break
    fi
done
step "Computer: ${MODEL:-$(uname -m) Linux}; Hailo module: ${CHIP:-not found on PCIe}"
if [[ -z "$PACKAGE" ]]; then
    case "$CHIP" in
        Hailo-10H) PACKAGE="hailo-h10-all" ;;
        *) PACKAGE="hailo-all" ;;
    esac
fi
[[ "$PACKAGE" == hailo-all || "$PACKAGE" == hailo-h10-all ]] || fail "--package must be hailo-all or hailo-h10-all"

if [[ $SYSTEM == 1 && $RASPBERRY_PI == 1 ]]; then
    # ------------------------------------------------------------ 2. PCIe (Raspberry Pi 5)
    CONFIG="$ROOT/boot/firmware/config.txt"
    [[ -f $CONFIG ]] || CONFIG="$ROOT/boot/config.txt"
    if [[ "$MODEL" == *"Raspberry Pi 5"* && -f $CONFIG ]]; then
        LINES=()
        grep -Eq '^[[:space:]]*dtparam=pciex1([[:space:]]|$|=on)' "$CONFIG" || [[ -n "$CHIP" ]] || LINES+=("dtparam=pciex1")
        if [[ $GEN3 == 1 ]] && ! grep -Eq '^[[:space:]]*dtparam=pciex1_gen=3' "$CONFIG"; then
            LINES+=("dtparam=pciex1_gen=3")
        fi
        if [[ ${#LINES[@]} -gt 0 ]]; then
            step "PCIe: ${LINES[*]} in $CONFIG"
            if ask "Add ${LINES[*]} to $CONFIG?"; then
                $SUDO cp "$CONFIG" "$CONFIG.opennve-hailo.bak"
                {
                    echo ""
                    echo "[all]"
                    echo "# openNVE-hailo: PCIe for the Hailo module"
                    printf '%s\n' "${LINES[@]}"
                } | $SUDO tee -a "$CONFIG" >/dev/null
                NEEDS_REBOOT=1
            fi
        fi
    fi

    # ------------------------------------------------------------ 3. driver, firmware, HailoRT
    if ! dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null | grep -q "install ok installed"; then
        step "HailoRT: sudo apt install dkms $PACKAGE"
        OTHER=$([[ $PACKAGE == hailo-all ]] && echo hailo-h10-all || echo hailo-all)
        if dpkg-query -W -f='${Status}' "$OTHER" 2>/dev/null | grep -q "install ok installed"; then
            echo "note: $OTHER is installed; apt replaces it with $PACKAGE (they cannot be installed together)"
        fi
        if ask "Install dkms $PACKAGE (driver, firmware, HailoRT)?"; then
            $SUDO apt-get update
            $SUDO apt-get install -y dkms "$PACKAGE"
            NEEDS_REBOOT=1
        else
            fail "HailoRT is needed: sudo apt install dkms $PACKAGE"
        fi
    else
        step "HailoRT: $PACKAGE is installed"
    fi
elif [[ $SYSTEM == 1 ]]; then
    step "Not a Raspberry Pi: PCIe and HailoRT are not set up by this script (Hailo Developer Zone packages)"
fi

# ---------------------------------------------------------------- HailoRT version
if [[ -z "${HAILORT_VERSION:-}" ]] && command -v hailortcli >/dev/null; then
    HAILORT_VERSION="$(hailortcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [[ -z "${HAILORT_VERSION:-}" ]] && command -v dpkg-query >/dev/null; then
    for package in hailort h10-hailort; do  # Hailo-8 / 8L, Hailo-10H
        HAILORT_VERSION="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
        [[ -n "$HAILORT_VERSION" ]] && break
    done
fi
[[ -n "${HAILORT_VERSION:-}" ]] || fail "HailoRT not found: sudo apt install dkms hailo-all (AI HAT+ 2: hailo-h10-all), or set HAILORT_VERSION"
case "${HAILORT_VERSION%%.*}" in
    4) CHIPS="Hailo-8, Hailo-8L" ;;
    5) CHIPS="Hailo-10H, Hailo-15" ;;
    *) fail "HailoRT $HAILORT_VERSION is not supported (4.x or 5.x)" ;;
esac
export HAILORT_VERSION

# ---------------------------------------------------------------- 4. opennve_hailo: ready-made package
# The releases of openNVE-hailo have ready-made packages for the HailoRT versions of Raspberry Pi OS
# and the Hailo Developer Zone (Linux aarch64 / x86_64, every Python from 3.11): no Rust needed.
"$PYTHON" -m pip --version >/dev/null 2>&1 || "$PYTHON" -m ensurepip --upgrade >/dev/null
install_wheel() {
    "$PYTHON" -m pip install --quiet "numpy>=1.26"
    "$PYTHON" -m pip install --force-reinstall --no-deps "$1"
}
WHEEL=""
if [[ $BUILD == 0 ]]; then
    step "opennve_hailo: ready-made package for HailoRT $HAILORT_VERSION ($CHIPS, $(uname -m))"
    mkdir -p "$CACHE/wheels"
    WHEEL="$("$PYTHON" - "$HAILORT_VERSION" "$(uname -m)" "$CACHE/wheels" "${OPENNVE_HAILO_RELEASES:-https://api.github.com/repos/fr3ak2402/openNVE-hailo/releases}" <<'EOF' || true
import json, pathlib, sys, urllib.request

version, machine, folder, url = sys.argv[1:5]
prefix = f"hailort-{version}_"
suffix = f"-cp311-abi3-manylinux_2_28_{machine}.whl"
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"}), timeout=30) as response:
        releases = json.load(response)
except Exception as error:
    print(f"no connection to the releases ({error})", file=sys.stderr)
    sys.exit(1)
for release in releases:  # newest first
    if release.get("draft"):
        continue
    for asset in release.get("assets", []):
        name = asset["name"]
        if name.startswith(prefix) and name.endswith(suffix):
            target = pathlib.Path(folder) / name[len(prefix):]
            target.unlink(missing_ok=True)
            urllib.request.urlretrieve(asset["browser_download_url"], target)
            print(f"{release['tag_name']}: {name}", file=sys.stderr)
            print(target)
            sys.exit(0)
print(f"no ready-made package for HailoRT {version} on {machine}", file=sys.stderr)
sys.exit(1)
EOF
)"
fi
if [[ -n "$WHEEL" ]]; then
    install_wheel "$WHEEL"
else
    [[ $BUILD == 1 ]] || echo "building it instead (needs Rust and a C++ compiler)"

    # ------------------------------------------------------------ 5. build tools, Rust
    if [[ $SYSTEM == 1 ]]; then
        MISSING=()
        command -v git >/dev/null || MISSING+=(git)
        command -v g++ >/dev/null || command -v c++ >/dev/null || MISSING+=(g++)
        command -v curl >/dev/null || MISSING+=(curl)
        if [[ ${#MISSING[@]} -gt 0 ]] && command -v apt-get >/dev/null; then
            step "Build tools: sudo apt install ${MISSING[*]}"
            ask "Install ${MISSING[*]}?" && $SUDO apt-get install -y "${MISSING[@]}"
        fi
    fi
    if ! command -v cargo >/dev/null && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    if ! command -v cargo >/dev/null; then
        [[ $SYSTEM == 1 ]] || fail "Rust (cargo) is missing: curl https://sh.rustup.rs -sSf | sh"
        step "Rust: rustup (for $(id -un), in ~/.cargo)"
        if ask "Install Rust with rustup?"; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
            export PATH="$HOME/.cargo/bin:$PATH"
        else
            fail "Rust is needed to build opennve_hailo"
        fi
    fi
    command -v g++ >/dev/null || command -v c++ >/dev/null || fail "C++ compiler missing: sudo apt install g++"
    command -v git >/dev/null || fail "git missing: sudo apt install git"

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

    step "opennve_hailo: build for HailoRT $HAILORT_VERSION ($CHIPS) and install into $PYTHON"
    "$PYTHON" -m pip install --quiet --upgrade "maturin>=1.8,<2"
    rm -rf "$HERE/python/dist"
    (cd "$HERE/python" && "$PYTHON" -m maturin build --release --interpreter "$PYTHON" --out dist)
    install_wheel "$(ls "$HERE"/python/dist/opennve_hailo-*.whl | head -1)"
fi

"$PYTHON" - <<'EOF'
import opennve_hailo

print(f"opennve_hailo {opennve_hailo.__version__} with HailoRT {opennve_hailo.hailort_version()}")
devices = opennve_hailo.scan()
print("Hailo devices:", ", ".join(f"{d.id} ({d.chip or 'in use'})" for d in devices) if devices else "none found")
EOF

if [[ $NEEDS_REBOOT == 1 || ( -n "$CHIP" && ! -e "$ROOT/dev/hailo0" ) ]]; then
    echo
    echo "Reboot to load the Hailo driver and the PCIe settings (sudo reboot)."
    if [[ $REBOOT == 1 ]]; then
        $SUDO reboot
    fi
fi
