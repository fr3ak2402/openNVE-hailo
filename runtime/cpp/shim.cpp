#include "hailo-runtime/cpp/shim.hpp"
#include "hailo-runtime/src/lib.rs.h"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <stdexcept>
#include <string>

namespace hailo_runtime {

namespace {

[[noreturn]] void fail(hailo_status status, const std::string &what) {
    const char *message = hailo_get_status_message(status);
    throw std::runtime_error(what + ": " + (message ? message : "error") + " (HailoRT status " +
                             std::to_string(static_cast<int>(status)) + ")");
}

void check(hailo_status status, const std::string &what) {
    if (status != HAILO_SUCCESS) {
        fail(status, what);
    }
}

template <typename T>
T take(hailort::Expected<T> &&expected, const std::string &what) {
    if (!expected) {
        fail(expected.status(), what);
    }
    return expected.release();
}

const char *architecture_name(hailo_device_architecture_t architecture) {
    switch (architecture) {
    case HAILO_ARCH_HAILO8_A0:
    case HAILO_ARCH_HAILO8:
        return "Hailo-8";
    case HAILO_ARCH_HAILO8L:
        return "Hailo-8L";
    case HAILO_ARCH_HAILO10H:
        return "Hailo-10H";
    case HAILO_ARCH_HAILO15H:
        return "Hailo-15H";
    case HAILO_ARCH_HAILO15M:
        return "Hailo-15M";
    case HAILO_ARCH_HAILO15L:
        return "Hailo-15L";
    default:
        return "Hailo";
    }
}

// one virtual device per process, shared by all models (the HailoRT scheduler switches between them)
std::mutex g_vdevice_mutex;
std::weak_ptr<hailort::VDevice> g_vdevice;

std::shared_ptr<hailort::VDevice> shared_vdevice() {
    std::lock_guard<std::mutex> lock(g_vdevice_mutex);
    auto vdevice = g_vdevice.lock();
    if (vdevice) {
        return vdevice;
    }
    hailo_vdevice_params_t params;
    check(hailo_init_vdevice_params(&params), "hailo_init_vdevice_params");
    params.scheduling_algorithm = HAILO_SCHEDULING_ALGORITHM_ROUND_ROBIN;
    vdevice = take(hailort::VDevice::create_shared(params),
                   "no free Hailo device (is the module connected, its driver loaded - hailortcli scan - "
                   "and no other program using it?)");
    g_vdevice = vdevice;
    return vdevice;
}

StreamInfo stream_info(const hailort::InferModel::InferStream &stream) {
    auto shape = stream.shape();
    StreamInfo info;
    info.name = rust::String(stream.name());
    info.height = shape.height;
    info.width = shape.width;
    info.channels = shape.features;
    info.frame_size = stream.get_frame_size() / sizeof(float);
    return info;
}

}  // namespace

Model::Model(std::shared_ptr<hailort::VDevice> vdevice, std::shared_ptr<hailort::InferModel> infer_model,
             hailort::ConfiguredInferModel configured, uint16_t batch_size, uint32_t timeout_ms)
    : m_vdevice(std::move(vdevice)), m_infer_model(std::move(infer_model)), m_configured(std::move(configured)),
      m_batch_size(batch_size), m_timeout_ms(timeout_ms) {
    auto queue = m_configured.get_async_queue_size();
    m_queue_size = queue ? std::max<size_t>(1, queue.value()) : batch_size;
    m_input_frame = m_infer_model->inputs().at(0).get_frame_size() / sizeof(float);
    for (const auto &output : m_infer_model->outputs()) {
        m_output_names.push_back(output.name());
        m_output_frames.push_back(output.get_frame_size() / sizeof(float));
    }
}

Model::~Model() {
    try {
        shutdown();
    } catch (...) {
    }
}

rust::Vec<StreamInfo> Model::inputs() const {
    rust::Vec<StreamInfo> result;
    for (const auto &input : m_infer_model->inputs()) {
        result.push_back(stream_info(input));
    }
    return result;
}

rust::Vec<StreamInfo> Model::outputs() const {
    rust::Vec<StreamInfo> result;
    for (const auto &output : m_infer_model->outputs()) {
        result.push_back(stream_info(output));
    }
    return result;
}

rust::Vec<rust::String> Model::device_ids() const {
    rust::Vec<rust::String> result;
    auto ids = m_vdevice->get_physical_devices_ids();
    if (ids) {
        for (const auto &id : ids.value()) {
            result.push_back(rust::String(id));
        }
    }
    return result;
}

uint16_t Model::batch_size() const {
    return m_batch_size;
}

void Model::run(rust::Slice<const float> input, size_t count, rust::Slice<float> output) {
    if (m_shut_down) {
        throw std::runtime_error("the model is closed");
    }
    if (input.size() != count * m_input_frame) {
        throw std::runtime_error("input size " + std::to_string(input.size()) + " != " + std::to_string(count) +
                                 " frames x " + std::to_string(m_input_frame));
    }
    size_t output_total = 0;
    for (auto frame : m_output_frames) {
        output_total += frame * count;
    }
    if (output.size() != output_total) {
        throw std::runtime_error("output size " + std::to_string(output.size()) + " != " + std::to_string(output_total));
    }
    const auto timeout = std::chrono::milliseconds(m_timeout_ms);
    const size_t chunk = std::max<size_t>(1, std::min<size_t>(m_batch_size, m_queue_size));
    for (size_t start = 0; start < count; start += chunk) {
        const size_t frames = std::min(chunk, count - start);
        std::vector<hailort::ConfiguredInferModel::Bindings> bindings;
        bindings.reserve(frames);
        for (size_t index = start; index < start + frames; index++) {
            auto binding = take(m_configured.create_bindings(), "create_bindings");
            auto *input_data = const_cast<float *>(input.data() + index * m_input_frame);
            check(take(binding.input(), "bindings input")
                      .set_buffer(hailort::MemoryView(input_data, m_input_frame * sizeof(float))),
                  "set input buffer");
            size_t offset = 0;
            for (size_t number = 0; number < m_output_names.size(); number++) {
                float *data = output.data() + offset + index * m_output_frames[number];
                check(take(binding.output(m_output_names[number]), "bindings output " + m_output_names[number])
                          .set_buffer(hailort::MemoryView(data, m_output_frames[number] * sizeof(float))),
                      "set output buffer " + m_output_names[number]);
                offset += m_output_frames[number] * count;
            }
            bindings.push_back(std::move(binding));
        }
        check(m_configured.wait_for_async_ready(timeout, static_cast<uint32_t>(frames)), "wait_for_async_ready");
        auto job = take(m_configured.run_async(bindings), "run_async");
        check(job.wait(timeout), "inference");
    }
}

void Model::shutdown() {
    if (!m_shut_down) {
        m_shut_down = true;
        m_configured.shutdown();
    }
}

rust::String library_version() {
    hailo_version_t version;
    check(hailo_get_library_version(&version), "hailo_get_library_version");
    return rust::String(std::to_string(version.major) + "." + std::to_string(version.minor) + "." +
                        std::to_string(version.revision));
}

rust::Vec<DeviceInfo> scan_devices(bool identify) {
    rust::Vec<DeviceInfo> result;
    auto ids = hailort::Device::scan();
    if (!ids) {
        if (ids.status() == HAILO_DRIVER_NOT_INSTALLED) {
            return result;  // no driver: no device
        }
        fail(ids.status(), "Device::scan");
    }
    for (const auto &id : ids.value()) {
        DeviceInfo info;
        info.id = rust::String(id);
        info.architecture = rust::String("");
        if (identify) {
            auto device = hailort::Device::create(id);  // fails if another program uses the device
            if (device) {
                auto identity = device.value()->identify();
                if (identity) {
                    info.architecture = rust::String(architecture_name(identity.value().device_architecture));
                }
            }
        }
        result.push_back(std::move(info));
    }
    return result;
}

std::unique_ptr<Model> load_model(rust::Str path, uint16_t batch_size, uint32_t timeout_ms) {
    const std::string hef(path.data(), path.size());
    auto vdevice = shared_vdevice();
    auto infer_model = vdevice->create_infer_model(hef);
    if (!infer_model) {
        auto status = infer_model.status();
        if (status == HAILO_HEF_NOT_COMPATIBLE_WITH_DEVICE || status == HAILO_INVALID_HEF) {
            fail(status, hef + " does not fit the Hailo device: a .hef is compiled for one chip (hailo8 / hailo8l "
                               "with the Dataflow Compiler 3.x, hailo10h / hailo15h with 5.x)");
        }
        fail(status, "loading " + hef);
    }
    auto model = infer_model.release();
    if (model->inputs().size() != 1) {
        throw std::runtime_error(hef + ": models with " + std::to_string(model->inputs().size()) +
                                 " inputs are not supported");
    }
    model->set_batch_size(batch_size);
    take(model->input(), "input").set_format_type(HAILO_FORMAT_TYPE_FLOAT32);
    for (const auto &name : model->get_output_names()) {
        take(model->output(name), "output " + name).set_format_type(HAILO_FORMAT_TYPE_FLOAT32);
    }
    auto configured = take(model->configure(), "configuring " + hef);
    return std::make_unique<Model>(vdevice, model, std::move(configured), batch_size, timeout_ms);
}

}  // namespace hailo_runtime
