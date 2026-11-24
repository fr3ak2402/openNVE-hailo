#!/usr/bin/env bash
# Tests the system steps of install.sh on a fake Raspberry Pi 5 (fake /proc, /sys, /boot, and fake
# sudo / apt-get / dpkg-query / reboot). The build step runs for real (HailoRT from the environment).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fake_pi() {  # fake_pi <dir> <pci device id or ""> <config.txt content>
    local root="$1"
    mkdir -p "$root/proc/device-tree" "$root/boot/firmware" "$root/dev" "$root/bin"
    printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$root/proc/device-tree/model"
    printf '%s\n' "$3" >"$root/boot/firmware/config.txt"
    if [[ -n "$2" ]]; then
        mkdir -p "$root/sys/bus/pci/devices/0001:01:00.0"
        echo 0x1e60 >"$root/sys/bus/pci/devices/0001:01:00.0/vendor"
        echo "$2" >"$root/sys/bus/pci/devices/0001:01:00.0/device"
    fi
    # fake system tools: record the commands, dpkg-query knows the packages in $root/installed
    cat >"$root/bin/sudo" <<'S'
#!/usr/bin/env bash
"$@"
S
    cat >"$root/bin/apt-get" <<'S'
#!/usr/bin/env bash
echo "apt-get $*" >>"$OPENNVE_HAILO_ROOT/commands"
S
    cat >"$root/bin/dpkg-query" <<'S'
#!/usr/bin/env bash
package="${@: -1}"
grep -qx "$package" "$OPENNVE_HAILO_ROOT/installed" 2>/dev/null && echo "install ok installed" || exit 1
S
    cat >"$root/bin/reboot" <<'S'
#!/usr/bin/env bash
echo "reboot" >>"$OPENNVE_HAILO_ROOT/commands"
S
    chmod +x "$root/bin/"*
    touch "$root/commands" "$root/installed"
}

run() {  # run <root> <options...>; no ready-made packages unless RELEASES is set
    local root="$1"; shift
    OPENNVE_HAILO_RELEASES="${RELEASES:-file://$root/no-releases.json}" OPENNVE_HAILO_ROOT="$root" PATH="$root/bin:$PATH" bash "$HERE/install.sh" --yes "$@" >"$root/log" 2>&1 \
        || { cat "$root/log"; echo "install.sh failed"; exit 1; }
}

check() { if ! eval "$1"; then echo "FAILED: $1"; cat "$2/log"; exit 1; fi; echo "ok: $1"; }

# Hailo-8L on a fresh Pi: Gen 3 added, hailo-all installed, reboot requested
R="$WORK/h8"; fake_pi "$R" 0x2864 "dtparam=audio=on"
run "$R" --reboot
check 'grep -qx "dtparam=pciex1_gen=3" "$R/boot/firmware/config.txt"' "$R"
check '! grep -qx "dtparam=pciex1" "$R/boot/firmware/config.txt"' "$R"
check '[[ -f "$R/boot/firmware/config.txt.opennve-hailo.bak" ]]' "$R"
check 'grep -q "apt-get install -y dkms hailo-all" "$R/commands"' "$R"
check 'grep -q "Hailo-8 / Hailo-8L" "$R/log"' "$R"
check 'grep -qx reboot "$R/commands"' "$R"

# Hailo-10H, everything set up already: nothing changed, no reboot
R="$WORK/h10"; fake_pi "$R" 0x45c4 $'[all]\ndtparam=pciex1_gen=3'
echo hailo-h10-all >"$R/installed"; touch "$R/dev/hailo0"
run "$R" --reboot
check '[[ $(grep -c pciex1_gen "$R/boot/firmware/config.txt") == 1 ]]' "$R"
check '! grep -q "apt-get install" "$R/commands"' "$R"
check '! grep -qx reboot "$R/commands"' "$R"
check 'grep -q "hailo-h10-all is installed" "$R/log"' "$R"

# no module visible (PCIe connector off): pciex1 enabled, --no-gen3 respected
R="$WORK/off"; fake_pi "$R" "" "dtparam=audio=on"
run "$R" --no-gen3
check 'grep -qx "dtparam=pciex1" "$R/boot/firmware/config.txt"' "$R"
check '! grep -q "pciex1_gen" "$R/boot/firmware/config.txt"' "$R"
check 'grep -q "Reboot to load" "$R/log"' "$R"

# --no-system: no system changes at all
R="$WORK/nosys"; fake_pi "$R" 0x2864 "dtparam=audio=on"
run "$R" --no-system
check '[[ ! -s "$R/commands" ]] && ! grep -q pciex1 "$R/boot/firmware/config.txt"' "$R"

# ready-made package: install.sh downloads the asset for this HailoRT version and machine, no build
R="$WORK/ready"; fake_pi "$R" 0x2864 $'[all]\ndtparam=pciex1_gen=3'
echo hailo-all >"$R/installed"
BUILT="$(ls "$HERE"/python/dist/opennve_hailo-*.whl | head -1)"  # built by the tests above
VERSION="${BUILT##*/opennve_hailo-}"; VERSION="${VERSION%%-*}"
ASSET="hailort-${HAILORT_VERSION}_opennve_hailo-${VERSION}-cp311-abi3-manylinux_2_28_$(uname -m).whl"
mkdir -p "$R/assets"; cp "$BUILT" "$R/assets/$ASSET"
cat >"$R/releases.json" <<JSON
[{"tag_name": "v9.9.9", "draft": false, "assets": [
  {"name": "hailort-0.0.1_opennve_hailo-${VERSION}-cp311-abi3-manylinux_2_28_$(uname -m).whl", "browser_download_url": "file:///nonexistent"},
  {"name": "$ASSET", "browser_download_url": "file://$R/assets/$ASSET"}]}]
JSON
RELEASES="file://$R/releases.json" run "$R"
check 'grep -q "v9.9.9: $ASSET" "$R/log"' "$R"
check '! grep -q "maturin\|Compiling\|build for HailoRT" "$R/log"' "$R"
check 'grep -q "with HailoRT" "$R/log"' "$R"
# --build ignores the ready-made package
RELEASES="file://$R/releases.json" run "$R" --build
check 'grep -q "build for HailoRT" "$R/log" && ! grep -q "v9.9.9" "$R/log"' "$R"

echo "all install.sh tests passed"
