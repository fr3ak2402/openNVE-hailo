//! cargo run --example info [model.hef]: HailoRT version, Hailo devices and the streams of a model.
fn main() -> Result<(), hailo_runtime::Error> {
    println!(
        "libhailort {} (compiled with {})",
        hailo_runtime::library_version()?,
        hailo_runtime::COMPILED_HAILORT_VERSION
    );
    for device in hailo_runtime::scan(true)? {
        println!("device {} {}", device.id, device.architecture);
    }
    if let Some(path) = std::env::args().nth(1) {
        let model = hailo_runtime::Model::load(&path, 8, 10_000)?;
        println!("input {:?}", model.input());
        for output in model.outputs() {
            println!("output {output:?}");
        }
        let count = 16;
        let input = vec![0.0f32; count * model.input().frame_size];
        let start = std::time::Instant::now();
        let outputs = model.run(&input, count)?;
        println!(
            "{count} frames in {:?}, {} outputs",
            start.elapsed(),
            outputs.len()
        );
    }
    Ok(())
}
