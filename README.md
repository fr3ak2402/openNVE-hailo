# openNVE-hailo

Hailo accelerators for [openNVE](https://github.com/fr3ak2402/openNVE): runs compiled Hailo models
(`.hef`) with HailoRT through a Rust library and a Python module, the same way
[neuromorphic-drivers](https://github.com/fr3ak2402/neuromorphic-drivers) brings the event cameras
to openNVE.

| Chip | Boards | HailoRT | Raspberry Pi OS package |
|---|---|---|---|
| Hailo-8L | Raspberry Pi AI Kit, AI HAT+ 13 TOPS, M.2 modules | 4.x | `hailo-all` |
| Hailo-8 | Raspberry Pi AI HAT+ 26 TOPS, M.2 / PCIe cards | 4.x | `hailo-all` |
| Hailo-10H | Raspberry Pi AI HAT+ 2, M.2 modules | 5.x | `hailo-h10-all` |
| Hailo-15 | Hailo-15 vision processors (HailoRT runs on the Hailo-15) | 5.x | – |

Only one HailoRT generation can be installed on a computer. Platforms: Linux (aarch64, x86_64) and
Windows (x86_64, with the HailoRT Windows installer; not tested). Hailo has no driver for macOS.

## Parts

| Directory | What |
|---|---|
| `runtime/` | Rust crate `hailo-runtime`: C++ bridge ([cxx](https://cxx.rs)) to the asynchronous InferModel API of libhailort 4.x / 5.x, safe Rust API (`scan`, `Model::load`, `Model::run`) |
| `python/` | Python package `opennve_hailo` (PyO3, one wheel for Python 3.11 and newer): `scan()`, `Model(path).run(batch)` with numpy arrays |
| `install.sh` | Sets up the Raspberry Pi (PCIe, driver, HailoRT) and installs the Python package (ready-made, or built here) |
| `ci/build_wheel.sh` | Builds the ready-made package for one HailoRT version (manylinux_2_28 container, CI) |

The asynchronous InferModel API is the one HailoRT supports on all chips (the older C API with
vstreams works only on the Hailo-8 / 8L). It is a C++ API that changes between HailoRT versions,
so there is one package per HailoRT version; `install.sh` picks the one of the installed HailoRT.

## Installation (Raspberry Pi 5)

One command sets up everything on the Raspberry Pi, with the openNVE environment active:

```sh
source ~/opennve/.venv/bin/activate      # the Python environment of openNVE
opennve hailo install                    # openNVE 1.2.0 or newer; or: bash openNVE-hailo/install.sh
sudo reboot                              # if it says so
```

`install.sh` does only what is missing, and asks before changing the system (`--yes`: does not
ask):

1. finds the Hailo module on PCIe: Hailo-8 / 8L (AI Kit, AI HAT+) or Hailo-10H (AI HAT+ 2)
2. Raspberry Pi 5: enables the PCIe connector and PCIe Gen 3 in `/boot/firmware/config.txt`
   (backup: `config.txt.opennve-hailo.bak`; `--no-gen3` keeps Gen 2)
3. installs driver, firmware and HailoRT: `sudo apt install dkms hailo-all`, for the Hailo-10H
   `hailo-h10-all` (`--package=...` chooses)
4. installs the ready-made opennve_hailo package for the installed HailoRT version from the
   [releases](https://github.com/fr3ak2402/openNVE-hailo/releases) into the active Python – no
   Rust or compiler needed
5. only if there is no ready-made package for that version (or with `--build`): installs git,
   g++, curl and Rust (rustup, for the user), downloads the HailoRT headers of the installed
   version and builds opennve_hailo with [maturin](https://www.maturin.rs)

After steps 2 and 3 the Pi has to be restarted (`--reboot` does it). Run it again after a HailoRT
update: opennve_hailo is compiled for one HailoRT version.

Ready-made packages exist for HailoRT 4.23.0, 4.24.0 (Hailo-8 / 8L) and 5.1.1 to 5.5.0
(Hailo-10H / 15), Linux aarch64 and x86_64 (manylinux_2_28: Raspberry Pi OS Bookworm / Trixie,
Ubuntu 20.04 and newer), one file for every Python from 3.11. They use the libhailort installed
with the driver. Without the script: download the file for your HailoRT version
(`hailortcli --version`) and machine from the release, remove the `hailort-<version>_` prefix
from the name and `pip install` it. Other Linux computers: install HailoRT
from the Hailo Developer Zone first; `install.sh` then builds and installs opennve_hailo
(`--no-system` skips steps 2 to 4). Check:

```sh
opennve system      # HailoRT 4.23.0  1 Hailo device (Hailo-8L) (.hef models)
python -c "import opennve_hailo as h; print(h.hailort_version(), h.scan())"
```

## Python

```python
import numpy as np
import opennve_hailo

model = opennve_hailo.Model("unet_hailo8l.hef", batch_size=8)
print(model.input)             # Stream(name='unet/input_layer1', shape=(80, 80, 2), size=12800)
outputs = model.run(np.zeros((16, 80, 80, 2), np.float32))
print(outputs[0].shape)        # (16, 80, 80, 3)
```

- Inputs and outputs are float32, channels last; HailoRT quantizes and dequantizes them.
- All models of a program share one Hailo device; HailoRT's scheduler switches between them.
  `run` releases the GIL, several threads (one model each) keep the Hailo busy.
- HailoRT's `hailort.log` is not written (set `HAILORT_LOGGER_PATH` to get it).

In openNVE, agents with a `.hef` model use this package (backend `hailo`).

## Rust

```rust
let devices = hailo_runtime::scan(true)?;
let model = hailo_runtime::Model::load("unet_hailo8l.hef", 8, 10_000)?;
let input = vec![0.0f32; 16 * model.input().frame_size];
let outputs = model.run(&input, 16)?; // one Vec<f32> per output
```

`cargo run --example info [model.hef]` shows the HailoRT version, the devices and the streams of
a model. Build settings (environment variables): `HAILORT_INCLUDE_DIR` (headers of the installed
version), `HAILORT_LIB_DIR` (directory of `libhailort.so`), `HAILORT_VERSION`.

## Models

A `.hef` is compiled for one chip with the Hailo Dataflow Compiler (Hailo AI Software Suite,
Linux x86_64; Dataflow Compiler 3.x for Hailo-8 / 8L, 5.x for Hailo-10H / 15), from a `.tflite`
or ONNX model, with calibration data (tiles of your recordings). The compiler quantizes the
model: compare the results with the `.tflite` model.

## License

The bindings link libhailort, which is published by Hailo under the MIT license.
