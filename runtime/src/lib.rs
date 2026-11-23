//! Rust bindings for HailoRT: run compiled Hailo models (`.hef`) on Hailo accelerators.
//!
//! Works with libhailort 4.x (Hailo-8, Hailo-8L: Raspberry Pi AI Kit, AI HAT+) and 5.x
//! (Hailo-10H: AI HAT+ 2, Hailo-15) through the asynchronous InferModel API of HailoRT. Inputs and
//! outputs are `f32`, channels last (height × width × channels); HailoRT converts them to and from
//! the quantized values of the model.
//!
//! ```no_run
//! let devices = hailo_runtime::scan(true)?;
//! let model = hailo_runtime::Model::load("unet.hef", 8, 10_000)?;
//! let input = vec![0.0f32; 4 * model.input().frame_size];
//! let outputs = model.run(&input, 4)?; // one Vec<f32> per output, 4 frames each
//! # Ok::<(), hailo_runtime::Error>(())
//! ```

use std::sync::Mutex;

#[cxx::bridge(namespace = "hailo_runtime")]
mod ffi {
    /// A Hailo device: its id (PCIe address) and chip (Hailo-8, Hailo-8L, Hailo-10H, Hailo-15H, ...;
    /// empty if it was not identified, for instance because another program uses it).
    #[derive(Debug, Clone, PartialEq, Eq)]
    struct DeviceInfo {
        id: String,
        architecture: String,
    }

    /// An input or output of a model: name, shape (height × width × channels) and number of
    /// values per frame.
    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StreamInfo {
        name: String,
        height: u32,
        width: u32,
        channels: u32,
        frame_size: usize,
    }

    unsafe extern "C++" {
        include!("hailo-runtime/cpp/shim.hpp");

        type Model;

        fn library_version() -> Result<String>;
        fn scan_devices(identify: bool) -> Result<Vec<DeviceInfo>>;
        fn load_model(path: &str, batch_size: u16, timeout_ms: u32) -> Result<UniquePtr<Model>>;

        fn inputs(self: &Model) -> Vec<StreamInfo>;
        fn outputs(self: &Model) -> Vec<StreamInfo>;
        fn device_ids(self: &Model) -> Vec<String>;
        fn batch_size(self: &Model) -> u16;
        fn run(
            self: Pin<&mut Model>,
            input: &[f32],
            count: usize,
            output: &mut [f32],
        ) -> Result<()>;
        fn shutdown(self: Pin<&mut Model>) -> Result<()>;
    }
}

pub use ffi::{DeviceInfo, StreamInfo};

/// A HailoRT error (the message includes the HailoRT status).
#[derive(Debug, Clone)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<cxx::Exception> for Error {
    fn from(exception: cxx::Exception) -> Self {
        Error(exception.what().to_owned())
    }
}

/// Version of the libhailort this program runs with, for instance "4.23.0".
pub fn library_version() -> Result<String, Error> {
    Ok(ffi::library_version()?)
}

/// Version of the HailoRT headers this crate was compiled with.
pub const COMPILED_HAILORT_VERSION: &str = env!("HAILORT_COMPILED_VERSION");

/// The Hailo devices of this computer. identify: ask each device for its chip (opens it briefly).
pub fn scan(identify: bool) -> Result<Vec<DeviceInfo>, Error> {
    Ok(ffi::scan_devices(identify)?)
}

/// A compiled Hailo model (.hef), configured on the shared Hailo device of this process.
///
/// Several models (and threads) can share the device: HailoRT's scheduler switches between them.
/// `run` can be called from several threads; calls on one model run one after the other.
pub struct Model {
    inner: Mutex<cxx::UniquePtr<ffi::Model>>,
    input: StreamInfo,
    outputs: Vec<StreamInfo>,
    batch_size: u16,
}

// The C++ model is only used under the mutex; HailoRT objects can be used from any thread.
unsafe impl Send for Model {}
unsafe impl Sync for Model {}

impl Model {
    /// Loads a .hef: batch_size frames per Hailo batch, timeout_ms for one batch.
    pub fn load(
        path: impl AsRef<std::path::Path>,
        batch_size: u16,
        timeout_ms: u32,
    ) -> Result<Self, Error> {
        let path = path.as_ref();
        if !path.is_file() {
            return Err(Error(format!("{} not found", path.display())));
        }
        let inner = ffi::load_model(&path.to_string_lossy(), batch_size.max(1), timeout_ms)?;
        let input = inner
            .inputs()
            .into_iter()
            .next()
            .ok_or_else(|| Error("the model has no input".into()))?;
        let outputs = inner.outputs();
        let batch_size = inner.batch_size();
        Ok(Model {
            inner: Mutex::new(inner),
            input,
            outputs,
            batch_size,
        })
    }

    pub fn input(&self) -> &StreamInfo {
        &self.input
    }

    pub fn outputs(&self) -> &[StreamInfo] {
        &self.outputs
    }

    pub fn batch_size(&self) -> u16 {
        self.batch_size
    }

    /// Ids of the physical devices the model runs on.
    pub fn device_ids(&self) -> Vec<String> {
        self.inner.lock().unwrap().device_ids()
    }

    /// Runs `count` frames (`input`: frame after frame, `count * input().frame_size` values) and
    /// writes the outputs into `output`: for each output (in the order of `outputs()`) `count`
    /// frames.
    pub fn run_into(&self, input: &[f32], count: usize, output: &mut [f32]) -> Result<(), Error> {
        let mut inner = self.inner.lock().unwrap();
        let model = inner
            .as_mut()
            .ok_or_else(|| Error("the model is closed".into()))?;
        Ok(model.run(input, count, output)?)
    }

    /// Runs `count` frames and returns one vector per output.
    pub fn run(&self, input: &[f32], count: usize) -> Result<Vec<Vec<f32>>, Error> {
        let total: usize = self
            .outputs
            .iter()
            .map(|output| output.frame_size * count)
            .sum();
        let mut output = vec![0.0f32; total];
        self.run_into(input, count, &mut output)?;
        let mut result = Vec::with_capacity(self.outputs.len());
        let mut rest = output.as_slice();
        for info in &self.outputs {
            let (head, tail) = rest.split_at(info.frame_size * count);
            result.push(head.to_vec());
            rest = tail;
        }
        Ok(result)
    }

    /// Releases the model (also done when it is dropped).
    pub fn close(&self) -> Result<(), Error> {
        let mut inner = self.inner.lock().unwrap();
        if let Some(model) = inner.as_mut() {
            model.shutdown()?;
        }
        *inner = cxx::UniquePtr::null();
        Ok(())
    }
}
