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
| `install.sh` | Builds and installs the Python package on the computer with the Hailo (Raspberry Pi 5) |

The asynchronous InferModel API is the one HailoRT supports on all chips (the older C API with
vstreams works only on the Hailo-8 / 8L). It is a C++ API that changes between HailoRT versions,
so the package is compiled against the HailoRT installed on the computer (`install.sh`).

## Installation (Raspberry Pi 5)

```sh
sudo apt install dkms hailo-all          # AI Kit / AI HAT+ (AI HAT+ 2: hailo-h10-all); reboot afterwards
sudo apt install git g++                 # compiler for the C++ bridge
curl https://sh.rustup.rs -sSf | sh      # Rust, if it is not installed yet
source ~/opennve/.venv/bin/activate      # the Python environment of openNVE
git clone https://github.com/fr3ak2402/openNVE-hailo
bash openNVE-hailo/install.sh
```

`install.sh` finds the installed HailoRT version, downloads the HailoRT headers of exactly that
version (Raspberry Pi OS installs only the library), builds the wheel with
[maturin](https://www.maturin.rs) and installs it into the active Python. Run it again after a
HailoRT update. Check:

```sh
python -c "import opennve_hailo as h; print(h.hailort_version(), h.scan())"
# 4.23.0 [Device(id='0001:01:00.0', chip='Hailo-8L')]
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
