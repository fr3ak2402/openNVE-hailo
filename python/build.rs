//! The Python module finds a libhailort outside the system directories (for instance built from
//! source with HAILORT_LIB_DIR) at run time through an rpath.
fn main() {
    let windows = std::env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "windows")
        .unwrap_or(false);
    if let Ok(dir) = std::env::var("DEP_HAILORT_LIB_DIR") {
        if !windows && !dir.starts_with("/usr") {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{dir}");
        }
    }
}
