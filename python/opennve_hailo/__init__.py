"""Hailo accelerators for openNVE: run compiled Hailo models (.hef) with HailoRT, in Rust.

Works with HailoRT 4.x (Hailo-8, Hailo-8L: Raspberry Pi AI Kit, AI HAT+) and 5.x (Hailo-10H:
AI HAT+ 2; Hailo-15). Inputs and outputs are float32 numpy arrays, channels last
(frames x height x width x channels); HailoRT converts them to and from the quantized values.

    import numpy as np, opennve_hailo

    opennve_hailo.scan()                       # [Device(id='0001:01:00.0', chip='Hailo-8L')]
    model = opennve_hailo.Model("unet.hef", batch_size=8)
    model.input                                # Stream(name=..., shape=(80, 80, 2))
    outputs = model.run(np.zeros((16, 80, 80, 2), np.float32))   # [array (16, 80, 80, 3)]

All models of a program share one Hailo device; HailoRT's scheduler switches between them.
"""

from __future__ import annotations

import os
import typing

import numpy as np

# HailoRT writes hailort.log into the current directory; HAILORT_LOGGER_PATH set by the user wins
os.environ.setdefault("HAILORT_LOGGER_PATH", "NONE")

from . import _opennve_hailo  # noqa: E402

__version__: str = _opennve_hailo.__version__
COMPILED_HAILORT_VERSION: str = _opennve_hailo.COMPILED_HAILORT_VERSION

__all__ = ["Device", "Model", "Stream", "hailort_version", "info", "scan"]


class Device(typing.NamedTuple):
    id: str
    chip: typing.Optional[str]  # Hailo-8, Hailo-8L, Hailo-10H, Hailo-15H, ...; None if in use


class Stream(typing.NamedTuple):
    name: str
    shape: tuple[int, int, int]  # height, width, channels
    size: int  # values per frame

    @classmethod
    def _from(cls, values) -> "Stream":
        name, height, width, channels, size = values
        return cls(name, (height, width, channels), size)


def hailort_version() -> str:
    """Version of the libhailort in use, for instance "4.23.0"."""
    return _opennve_hailo.library_version()


def scan(identify: bool = True) -> list[Device]:
    """The Hailo devices of this computer. identify: ask each device for its chip (opens it
    briefly; chip None if another program uses it)."""
    return [Device(device_id, chip or None) for device_id, chip in _opennve_hailo.scan(identify)]


def info(identify: bool = True) -> dict[str, typing.Any]:
    """{"version", "hailort", "compiled_with", "devices": [{"id", "architecture"}]} (for opennve system)."""
    return {
        "version": __version__,
        "hailort": hailort_version(),
        "compiled_with": COMPILED_HAILORT_VERSION,
        "devices": [{"id": device.id, "architecture": device.chip} for device in scan(identify)],
    }


class Model:
    """A compiled Hailo model (.hef) on the Hailo device.

    batch_size: frames per Hailo batch; timeout_ms: time limit for one batch. run() may be called
    from several threads (calls on one model run one after the other; use one model per thread
    to keep the Hailo busy).
    """

    def __init__(self, path: typing.Union[str, os.PathLike], batch_size: int = 8, timeout_ms: int = 10_000):
        self.path = os.fspath(path)
        self._model = _opennve_hailo._Model(self.path, int(batch_size), int(timeout_ms))
        self.input = Stream._from(self._model.input)
        self.outputs = [Stream._from(output) for output in self._model.outputs]
        self.batch_size: int = self._model.batch_size

    @property
    def device_ids(self) -> list[str]:
        return self._model.device_ids()

    def run(self, batch: np.ndarray) -> list[np.ndarray]:
        """Runs a batch (frames x height x width x channels, or one frame) and returns one
        float32 array per output (frames x height x width x channels)."""
        batch = np.asarray(batch, dtype=np.float32)
        if batch.shape == self.input.shape:
            batch = batch[np.newaxis]
        if batch.shape[1:] != self.input.shape:
            raise ValueError(f"input shape {batch.shape[1:]} != {self.input.shape} of {os.path.basename(self.path)}")
        batch = np.ascontiguousarray(batch)
        count = len(batch)
        buffer = np.empty(sum(output.size for output in self.outputs) * count, np.float32)
        if count:
            self._model.run_into(batch, count, buffer)
        results, offset = [], 0
        for output in self.outputs:
            size = output.size * count
            values = buffer[offset : offset + size]
            offset += size
            if output.size == int(np.prod(output.shape)):
                results.append(values.reshape((count,) + output.shape))
            else:  # outputs without an image shape (for instance NMS): one row per frame
                results.append(values.reshape(count, output.size))
        return results

    def close(self) -> None:
        self._model.close()

    def __enter__(self) -> "Model":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def __repr__(self) -> str:
        return f"Model({os.path.basename(self.path)!r}, input={self.input.shape}, outputs={[o.shape for o in self.outputs]})"
