"""Tests of the openNVE plugin (backend "hailo", .hef agents) with a fake Hailo model.

Skipped if openNVE is not installed.
"""

import importlib.metadata
import sys
import typing

import numpy as np
import pytest

opennve = pytest.importorskip("opennve")
pytest.importorskip("opennve.plugins")

import opennve_hailo  # noqa: E402
from opennve_hailo import opennve_plugin  # noqa: E402

WEIGHTS = np.array([[0.0, 5.0, 0.0], [0.0, 0.0, 5.0]], np.float32)  # 1 x 1 convolution, 2 -> 3 classes
BIAS = np.array([1.0, 0.0, 0.0], np.float32)
PREDICTION = {"task": "segmentation", "activation": "softmax", "target_classes": [1, 2]}


class Stream(typing.NamedTuple):
    name: str
    shape: tuple
    size: int


class FakeModel:
    """Stands in for opennve_hailo.Model: the .hef "model" is a 1 x 1 convolution."""

    instances: list = []

    def __init__(self, path, batch_size=8, timeout_ms=10_000):
        if str(path).endswith("other_chip.hef"):
            raise RuntimeError("model.hef does not fit the Hailo device: a .hef is compiled for one chip")
        self.batch_size = batch_size
        self.input = Stream("input", (16, 16, 2), 512)
        self.outputs = [Stream("output", (16, 16, 3), 768)]
        self.closed = False
        FakeModel.instances.append(self)

    def run(self, batch):
        assert batch.dtype == np.float32 and batch.flags["C_CONTIGUOUS"] and batch.shape[1:] == (16, 16, 2)
        return [batch @ WEIGHTS + BIAS]

    def close(self):
        self.closed = True


@pytest.fixture
def plugin(monkeypatch):
    from opennve import plugins

    monkeypatch.setattr(opennve_hailo, "Model", FakeModel)
    entry_point = importlib.metadata.EntryPoint("hailo", "opennve_hailo.opennve_plugin:plugin", plugins.ENTRY_POINT_GROUP)
    monkeypatch.setattr(plugins, "_entry_points", lambda: [entry_point])
    plugins._reset()
    FakeModel.instances.clear()
    yield
    plugins._reset()


def _frame():
    rng = np.random.default_rng(0)
    events = np.zeros(500, dtype=[("t", "<u8"), ("x", "<u2"), ("y", "<u2"), ("on", "?")])
    events["t"] = np.sort(rng.integers(0, 40_000, 500))
    events["x"] = rng.integers(0, 40, 500)
    events["y"] = rng.integers(0, 24, 500)
    events["on"] = rng.random(500) < 0.6
    window = opennve.EventWindow(camera="left", start_t=0, end_t=40_000, width=40, height=24, polarity_events=events)
    return window.frame({"mode": "count", "tiles": {"size": 16, "min_events": 0}})


def test_plugin_is_found(plugin):
    installed = opennve.plugins.installed_plugins()["hailo"]
    assert installed.error is None and installed.version == opennve_hailo.__version__


def test_hef_agent(plugin, tmp_path):
    (tmp_path / "unet.hef").write_bytes(b"fake")
    config = opennve.AgentConfig(model="unet.hef", base_dir=tmp_path, batch_size=4, prediction=PREDICTION)
    assert config.resolved_backend == "hailo"
    agent = opennve.Agent(config)
    assert agent.layout == "nhwc" and agent.device == "npu"
    assert agent.device_description() == "NPU Hailo (batch 4)"
    assert FakeModel.instances[0].batch_size == 4
    frame = _frame()
    result = agent.predict(frame)
    reference = opennve.Agent.from_model(lambda batch: batch @ WEIGHTS + BIAS, prediction=PREDICTION).predict(frame)
    for a, b in zip(result.predictions, reference.predictions):
        np.testing.assert_array_equal(a.class_map, b.class_map)
    agent.close()
    assert FakeModel.instances[0].closed
    assert opennve.agents.backend_options("hailo") == {"threads": "planned", "accelerator": True}


def test_devices_and_errors(plugin, tmp_path):
    (tmp_path / "a.hef").write_bytes(b"fake")
    for device in ("cpu", "gpu", ["npu", "cpu"]):
        with pytest.raises(ValueError, match="only on a Hailo"):
            opennve.Agent(opennve.AgentConfig(model=str(tmp_path / "a.hef"), device=device)).load()
    (tmp_path / "other_chip.hef").write_bytes(b"fake")
    with pytest.raises(RuntimeError, match="compiled for one chip"):
        opennve.Agent(opennve.AgentConfig(model=str(tmp_path / "other_chip.hef"))).load()
    with pytest.raises(FileNotFoundError):
        opennve.Agent(opennve.AgentConfig(model=str(tmp_path / "missing.hef"))).load()


def test_classification_head(plugin, tmp_path, monkeypatch):
    class Head(FakeModel):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.input = Stream("input", (1, 1, 2), 2)

        def run(self, batch):
            return [np.ones((len(batch), 1, 1, 3), np.float32)]

    monkeypatch.setattr(opennve_hailo, "Model", Head)
    (tmp_path / "c.hef").write_bytes(b"fake")
    backend = opennve_plugin.backend_class()(tmp_path / "c.hef")
    assert backend.predict(np.ones((5, 1, 1, 2), np.float32))[0].shape == (5, 3)


def test_cli_and_system(plugin, capsys):
    from opennve.cli import main

    assert main(["plugin", "list"]) == 0
    assert "hailo" in capsys.readouterr().out
    main(["hailo"])  # 1 without a device
    out = capsys.readouterr().out
    assert "opennve_hailo" in out and "HailoRT" in out
    info = opennve.system_info()["plugins"]["hailo"]
    assert info["opennve_hailo"] == opennve_hailo.__version__
    assert opennve_plugin.system_lines(info)[0].startswith("HailoRT")


def test_pci_modules(tmp_path):
    for address, device in (("0001:01:00.0", "0x2864"), ("0002:01:00.0", "0x45c4"), ("0000:00:00.0", None)):
        folder = tmp_path / "sys/bus/pci/devices" / address
        folder.mkdir(parents=True)
        (folder / "vendor").write_text("0x1e60\n" if device else "0x14e4\n")
        (folder / "device").write_text(f"{device or '0x2712'}\n")
    assert opennve_plugin.pci_modules(str(tmp_path)) == [
        {"address": "0001:01:00.0", "chip": "Hailo-8 / Hailo-8L"},
        {"address": "0002:01:00.0", "chip": "Hailo-10H"},
    ]
