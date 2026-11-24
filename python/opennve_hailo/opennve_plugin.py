"""openNVE plugin "hailo": agents with compiled Hailo models (.hef), `opennve hailo`, and the
Hailo section of `opennve system`.

openNVE finds it through the entry point "opennve.plugins" (pyproject.toml) and imports this
module only then; opennve_hailo itself does not need openNVE.

    opennve plugin install hailo     # installs opennve_hailo (and on a Raspberry Pi the system parts)
    opennve hailo                    # module on PCIe, driver, HailoRT, devices
"""

from __future__ import annotations

import os
import pathlib
import sys
import typing

import numpy as np

DEFAULT_BATCH_SIZE = 8
TIMEOUT_MS = 10_000
PCI_CHIPS = {"0x2864": "Hailo-8 / Hailo-8L", "0x45c4": "Hailo-10H"}


def plugin():
    """The plugin description for openNVE (called by openNVE when it loads its plugins)."""
    from opennve.plugins import Plugin

    from . import __version__

    return Plugin(
        name="hailo",
        description="Hailo accelerators (Hailo-8, 8L, 10H, 15): agents with compiled .hef models",
        version=__version__,
        register=register,
        commands=commands,
        system_info=system_info,
        system_lines=system_lines,
    )


# ---------------------------------------------------------------------------- backend
def register() -> None:
    from opennve.agents import register_backend

    # one model per workflow thread (HailoRT schedules them on the device), always an accelerator
    register_backend("hailo", create_backend, [".hef"], threads="planned", accelerator=True)


def _check_device(device) -> None:
    devices = device if isinstance(device, list) else [device]
    if any(item not in (None, "npu", "auto") for item in devices):
        raise ValueError(
            ".hef models run only on a Hailo accelerator: use \"device\": \"npu\" (or leave it out); "
            "for the CPU / GPU use the .tflite, .keras or PyTorch model the .hef was compiled from"
        )


def _backend_class():
    from opennve.agents.backends import Backend, ModelInput

    import opennve_hailo

    class HailoBackend(Backend):
        """Compiled Hailo model (.hef) on a Hailo accelerator (Hailo-8, Hailo-8L, Hailo-10H, Hailo-15).

        The model is quantized; HailoRT converts the float32 inputs and outputs on the CPU. Inputs
        and outputs are channels last (nhwc). batch_size: frames per Hailo batch (default 8).
        Several Hailo agents and workflow threads share one device; HailoRT schedules them.
        """

        layout = "nhwc"
        device = "npu"
        device_label = "Hailo"  # Agent.device_description(): "NPU Hailo (batch 8)"

        def __init__(self, path, device=None, batch_size: typing.Optional[int] = None, timeout_ms: int = TIMEOUT_MS):
            _check_device(device)
            self.path = pathlib.Path(path)
            self.batch_size = int(batch_size or DEFAULT_BATCH_SIZE)
            if not self.path.is_file():
                raise FileNotFoundError(f"model not found: {self.path}")
            self._model = opennve_hailo.Model(self.path, batch_size=self.batch_size, timeout_ms=timeout_ms)
            self.input = ModelInput(shape=(None,) + tuple(self._model.input.shape), dtype=np.dtype(np.float32))
            self.device_note = None

        def predict(self, batch: np.ndarray) -> list[np.ndarray]:
            outputs = self._model.run(np.ascontiguousarray(batch, dtype=np.float32))
            # classification heads come as 1 x 1 x classes: give them as (inputs, classes)
            return [output.reshape(len(output), -1) if output.ndim == 4 and output.shape[1:3] == (1, 1) else output
                    for output in outputs]

        def close(self):
            model, self._model = getattr(self, "_model", None), None
            if model is not None:
                try:
                    model.close()
                except Exception:
                    pass

    return HailoBackend


_HAILO_BACKEND = None


def backend_class():
    """The Backend class (created on first use: it derives from openNVE's Backend)."""
    global _HAILO_BACKEND
    if _HAILO_BACKEND is None:
        _HAILO_BACKEND = _backend_class()
    return _HAILO_BACKEND


def create_backend(config):
    """Backend factory for openNVE agents (backend "hailo", .hef models)."""
    return backend_class()(config.model_path, config.device, config.batch_size)


# ---------------------------------------------------------------------------- system information
def pci_modules(root: str = "") -> list[dict[str, str]]:
    """Hailo modules on PCIe (Linux), also without driver: [{"address", "chip"}]."""
    modules = []
    for device in sorted(pathlib.Path(root + "/sys/bus/pci/devices").glob("*")):
        try:
            if (device / "vendor").read_text().strip() != "0x1e60":
                continue
            device_id = (device / "device").read_text().strip()
        except OSError:
            continue
        modules.append({"address": device.name, "chip": PCI_CHIPS.get(device_id, f"Hailo ({device_id})")})
    return modules


def system_info(identify: bool = True) -> dict[str, typing.Any]:
    """{"opennve_hailo", "hailort", "devices": [{"id", "architecture"}], "pci", "driver"}"""
    import opennve_hailo

    info: dict[str, typing.Any] = {"opennve_hailo": opennve_hailo.__version__}
    try:
        runtime = opennve_hailo.info(identify)
        info.update(hailort=runtime["hailort"], devices=runtime["devices"])
    except Exception as error:  # libhailort missing, or another version than at build time
        info.update(hailort=None, devices=[], error=str(error).splitlines()[0] if str(error) else type(error).__name__)
    if sys.platform.startswith("linux"):
        info["pci"] = pci_modules()
        info["driver"] = os.path.exists("/dev/hailo0")
    return info


def system_lines(info: dict) -> list[str]:
    """Lines for `opennve system`."""
    if info.get("error"):
        return [f"HailoRT               not usable: {info['error']} (opennve plugin install hailo)"]
    devices = info.get("devices") or []
    chips = ", ".join(device.get("architecture") or "in use" for device in devices)
    state = f"{len(devices)} Hailo device{'s' if len(devices) != 1 else ''} ({chips})" if devices else "no Hailo device found"
    return [f"HailoRT {str(info.get('hailort')):<14}{state} (.hef models, plugin hailo {info.get('opennve_hailo')})"]


# ---------------------------------------------------------------------------- opennve hailo
def commands(subparsers) -> None:
    command = subparsers.add_parser("hailo", help="show the Hailo accelerator (plugin hailo)")
    command.add_argument("--json", action="store_true", help="output as JSON")
    command.set_defaults(function=_status_command)


def _status_command(args) -> int:
    info = system_info()
    if getattr(args, "json", False):
        import json

        print(json.dumps(info, indent=2))
        return 0
    if "pci" in info:
        modules = ", ".join(f"{module['chip']} ({module['address']})" for module in info["pci"])
        print(f"Hailo module (PCIe)   {modules or 'none found'}")
        print(f"Driver                {'loaded (/dev/hailo0)' if info['driver'] else 'not loaded'}")
    print(f"opennve_hailo         {info['opennve_hailo']}")
    if info.get("error"):
        print(f"HailoRT               not usable: {info['error']}")
    else:
        devices = info["devices"]
        chips = ", ".join(device.get("architecture") or "in use" for device in devices)
        print(f"HailoRT               {info['hailort']}")
        print(f"Devices               {f'{len(devices)} ({chips})' if devices else 'none found'}")
    ready = bool(info.get("devices")) and not info.get("error")
    if not ready:
        print("\nSet up: opennve plugin install hailo (reboot afterwards if it says so)")
    return 0 if ready else 1
