// C++ bridge between Rust (cxx) and the HailoRT C++ API (libhailort 4.x / 5.x).
//
// Uses the asynchronous InferModel API, which works on Hailo-8 / Hailo-8L (HailoRT 4.x) and
// Hailo-10H / Hailo-15 (HailoRT 5.x). Inputs and outputs are float32: HailoRT quantizes and
// dequantizes them on the host.
#pragma once

#include <cstdint>
#include <memory>

#include "rust/cxx.h"

#include <hailo/hailort.hpp>

namespace hailo_runtime {

struct DeviceInfo;
struct StreamInfo;

class Model {
public:
    Model(std::shared_ptr<hailort::VDevice> vdevice, std::shared_ptr<hailort::InferModel> infer_model,
          hailort::ConfiguredInferModel configured, uint16_t batch_size, uint32_t timeout_ms);
    ~Model();

    rust::Vec<StreamInfo> inputs() const;
    rust::Vec<StreamInfo> outputs() const;
    rust::Vec<rust::String> device_ids() const;
    uint16_t batch_size() const;
    // input: count frames, frame after frame; output: for each output (in the order of outputs())
    // count frames, frame after frame
    void run(rust::Slice<const float> input, size_t count, rust::Slice<float> output);
    void shutdown();

private:
    // members are destroyed in reverse order: the configured model first, the device last
    std::shared_ptr<hailort::VDevice> m_vdevice;
    std::shared_ptr<hailort::InferModel> m_infer_model;
    hailort::ConfiguredInferModel m_configured;
    uint16_t m_batch_size;
    uint32_t m_timeout_ms;
    size_t m_queue_size;
    size_t m_input_frame;                 // floats per input frame
    std::vector<std::string> m_output_names;
    std::vector<size_t> m_output_frames;  // floats per output frame
    bool m_shut_down = false;
};

rust::String library_version();
rust::Vec<DeviceInfo> scan_devices(bool identify);
std::unique_ptr<Model> load_model(rust::Str path, uint16_t batch_size, uint32_t timeout_ms);

}  // namespace hailo_runtime
