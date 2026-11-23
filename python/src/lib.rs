//! Python module opennve_hailo._opennve_hailo (the opennve_hailo package wraps it with numpy).

use pyo3::buffer::PyBuffer;
use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::prelude::*;

fn error(error: hailo_runtime::Error) -> PyErr {
    PyRuntimeError::new_err(error.0)
}

type Stream = (String, u32, u32, u32, usize);

fn stream(info: &hailo_runtime::StreamInfo) -> Stream {
    (
        info.name.clone(),
        info.height,
        info.width,
        info.channels,
        info.frame_size,
    )
}

/// Version of the libhailort in use, for instance "4.23.0".
#[pyfunction]
fn library_version() -> PyResult<String> {
    hailo_runtime::library_version().map_err(error)
}

/// The Hailo devices: list of (id, chip); chip is "" if the device could not be identified.
#[pyfunction]
#[pyo3(signature = (identify = true))]
fn scan(py: Python<'_>, identify: bool) -> PyResult<Vec<(String, String)>> {
    let devices = py.detach(|| hailo_runtime::scan(identify)).map_err(error)?;
    Ok(devices
        .into_iter()
        .map(|device| (device.id, device.architecture))
        .collect())
}

struct SendPtr<T>(*mut T);
unsafe impl<T> Send for SendPtr<T> {}

/// A compiled Hailo model on the shared Hailo device of this process.
#[pyclass(name = "_Model", module = "opennve_hailo._opennve_hailo", frozen)]
struct Model {
    inner: hailo_runtime::Model,
}

#[pymethods]
impl Model {
    #[new]
    #[pyo3(signature = (path, batch_size = 8, timeout_ms = 10_000))]
    fn new(
        py: Python<'_>,
        path: std::path::PathBuf,
        batch_size: u16,
        timeout_ms: u32,
    ) -> PyResult<Self> {
        let inner = py
            .detach(|| hailo_runtime::Model::load(&path, batch_size, timeout_ms))
            .map_err(error)?;
        Ok(Model { inner })
    }

    /// (name, height, width, channels, values per frame)
    #[getter]
    fn input(&self) -> Stream {
        stream(self.inner.input())
    }

    #[getter]
    fn outputs(&self) -> Vec<Stream> {
        self.inner.outputs().iter().map(stream).collect()
    }

    #[getter]
    fn batch_size(&self) -> u16 {
        self.inner.batch_size()
    }

    fn device_ids(&self) -> Vec<String> {
        self.inner.device_ids()
    }

    /// Runs count frames: input is a C-contiguous float32 buffer with count frames, output a
    /// writable C-contiguous float32 buffer for all outputs (output after output, count frames
    /// each). Releases the GIL while the Hailo runs.
    fn run_into(
        &self,
        py: Python<'_>,
        input: &Bound<'_, PyAny>,
        count: usize,
        output: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let input = PyBuffer::<f32>::get(input)?;
        let output = PyBuffer::<f32>::get(output)?;
        if !input.is_c_contiguous() || !output.is_c_contiguous() {
            return Err(PyValueError::new_err(
                "input and output must be C-contiguous float32 arrays",
            ));
        }
        if output.readonly() {
            return Err(PyValueError::new_err("output must be writable"));
        }
        let input_slice = SendPtr(input.buf_ptr() as *mut f32);
        let input_len = input.item_count();
        let output_slice = SendPtr(output.buf_ptr() as *mut f32);
        let output_len = output.item_count();
        let inner = &self.inner;
        // the buffers stay alive (input / output hold them) while the GIL is released
        py.detach(move || {
            let input_slice = input_slice;
            let output_slice = output_slice;
            let input =
                unsafe { std::slice::from_raw_parts(input_slice.0 as *const f32, input_len) };
            let output = unsafe { std::slice::from_raw_parts_mut(output_slice.0, output_len) };
            inner.run_into(input, count, output)
        })
        .map_err(error)?;
        drop(input);
        drop(output);
        Ok(())
    }

    fn close(&self, py: Python<'_>) -> PyResult<()> {
        py.detach(|| self.inner.close()).map_err(error)
    }
}

#[pymodule]
fn _opennve_hailo(module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add("__version__", env!("CARGO_PKG_VERSION"))?;
    module.add(
        "COMPILED_HAILORT_VERSION",
        hailo_runtime::COMPILED_HAILORT_VERSION,
    )?;
    module.add_function(wrap_pyfunction!(library_version, module)?)?;
    module.add_function(wrap_pyfunction!(scan, module)?)?;
    module.add_class::<Model>()?;
    Ok(())
}
