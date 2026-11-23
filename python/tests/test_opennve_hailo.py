"""Tests that run without a Hailo device (the CI); with a device, test_device runs a model if
OPENNVE_HAILO_TEST_HEF points to a .hef."""

import os

import numpy as np
import pytest

import opennve_hailo


def test_versions():
    version = opennve_hailo.hailort_version()
    assert version.count(".") == 2
    # compiled for the installed HailoRT (the C++ API changes between versions)
    assert opennve_hailo.COMPILED_HAILORT_VERSION in (version, "unknown")
    info = opennve_hailo.info()
    assert info["hailort"] == version and isinstance(info["devices"], list)


def test_scan():
    devices = opennve_hailo.scan()
    assert all(isinstance(device, opennve_hailo.Device) for device in devices)
    assert opennve_hailo.scan(identify=False) == [opennve_hailo.Device(device.id, None) for device in devices]


def test_missing_file(tmp_path):
    with pytest.raises(RuntimeError, match="not found"):
        opennve_hailo.Model(tmp_path / "missing.hef")


@pytest.mark.skipif(bool(opennve_hailo.scan(identify=False)), reason="a Hailo device is connected")
def test_without_device(tmp_path):
    path = tmp_path / "model.hef"
    path.write_bytes(b"not a model")
    with pytest.raises(RuntimeError, match="no free Hailo device"):
        opennve_hailo.Model(path)
    assert not (tmp_path / "hailort.log").exists() and not os.path.exists("hailort.log")


@pytest.mark.skipif(not os.environ.get("OPENNVE_HAILO_TEST_HEF"), reason="OPENNVE_HAILO_TEST_HEF not set")
def test_device():
    with opennve_hailo.Model(os.environ["OPENNVE_HAILO_TEST_HEF"], batch_size=4) as model:
        rng = np.random.default_rng(0)
        batch = rng.random((10,) + model.input.shape, dtype=np.float32)
        outputs = model.run(batch)
        assert [output.shape[0] for output in outputs] == [10] * len(model.outputs)
        # the same frame gives the same result alone and in a batch
        single = model.run(batch[3])
        for a, b in zip(outputs, single):
            np.testing.assert_array_equal(a[3], b[0])
        assert model.run(np.zeros((0,) + model.input.shape, np.float32))[0].shape[0] == 0
        assert model.device_ids
