//! Finds the installed HailoRT (headers and libhailort) and compiles the C++ bridge.
//!
//! Environment variables (all optional):
//!     HAILORT_INCLUDE_DIR   directory with hailo/hailort.hpp (default: /usr/include, /usr/local/include,
//!                           Windows: %ProgramFiles%\HailoRT\include)
//!     HAILORT_LIB_DIR       directory with libhailort.so / hailort.lib (default: /usr/lib,
//!                           /usr/lib/<triple>, /usr/local/lib, Windows: %ProgramFiles%\HailoRT\lib)
//!     HAILORT_VERSION       version of the installed HailoRT (default: from libhailort.so.<version>)
//!
//! The headers must have the same version as the library (the C++ API is not stable between
//! versions). Raspberry Pi OS installs only the library: install.sh downloads the headers of the
//! installed version from the HailoRT repository.

use std::env;
use std::path::{Path, PathBuf};

fn include_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(dir) = env::var("HAILORT_INCLUDE_DIR") {
        dirs.push(PathBuf::from(dir));
    }
    dirs.extend(
        ["/usr/include", "/usr/local/include"]
            .iter()
            .map(PathBuf::from),
    );
    if let Ok(program_files) = env::var("ProgramFiles") {
        dirs.push(Path::new(&program_files).join("HailoRT").join("include"));
    }
    dirs
}

fn lib_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(dir) = env::var("HAILORT_LIB_DIR") {
        dirs.push(PathBuf::from(dir));
    }
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let triple = match arch.as_str() {
        "aarch64" => "aarch64-linux-gnu",
        "x86_64" => "x86_64-linux-gnu",
        _ => "",
    };
    dirs.push(PathBuf::from("/usr/lib"));
    if !triple.is_empty() {
        dirs.push(Path::new("/usr/lib").join(triple));
    }
    dirs.push(PathBuf::from("/usr/local/lib"));
    if let Ok(program_files) = env::var("ProgramFiles") {
        dirs.push(Path::new(&program_files).join("HailoRT").join("lib"));
    }
    dirs
}

/// Version of the installed libhailort: HAILORT_VERSION, else the newest libhailort.so.<x.y.z>
/// in the library directories, else `hailortcli --version`.
fn installed_version() -> Option<String> {
    if let Ok(version) = env::var("HAILORT_VERSION") {
        return Some(version);
    }
    let mut versions: Vec<(Vec<u32>, String)> = Vec::new();
    for dir in lib_dirs() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(version) = name.strip_prefix("libhailort.so.") {
                let numbers: Vec<u32> = version
                    .split('.')
                    .filter_map(|part| part.parse().ok())
                    .collect();
                if numbers.len() == 3 {
                    versions.push((numbers, version.to_owned()));
                }
            }
        }
    }
    if let Some((_, version)) = versions.into_iter().max() {
        return Some(version);
    }
    let output = std::process::Command::new("hailortcli")
        .arg("--version")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .find(|word| word.matches('.').count() == 2)
        .map(str::to_owned)
}

/// (directory, link argument) of libhailort: libhailort.so if there is one, otherwise
/// libhailort.so.<version> (Raspberry Pi OS ships only the versioned file).
fn find_library(version: Option<&str>) -> Option<(PathBuf, String)> {
    let windows = env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "windows")
        .unwrap_or(false);
    for dir in lib_dirs() {
        if windows {
            if dir.join("libhailort.lib").is_file() {
                return Some((dir, "dylib=libhailort".into()));
            }
            if dir.join("hailort.lib").is_file() {
                return Some((dir, "dylib=hailort".into()));
            }
            continue;
        }
        if let Some(version) = version {
            let name = format!("libhailort.so.{version}");
            if dir.join(&name).is_file() {
                return Some((dir, format!("dylib:+verbatim={name}")));
            }
        }
        if dir.join("libhailort.so").exists() {
            return Some((dir, "dylib=hailort".into()));
        }
    }
    None
}

fn main() {
    println!("cargo:rerun-if-env-changed=HAILORT_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=HAILORT_LIB_DIR");
    println!("cargo:rerun-if-env-changed=HAILORT_VERSION");
    println!("cargo:rerun-if-changed=cpp/shim.hpp");
    println!("cargo:rerun-if-changed=cpp/shim.cpp");
    println!("cargo:rerun-if-changed=src/lib.rs");

    let include = include_dirs().into_iter().find(|dir| dir.join("hailo").join("hailort.hpp").is_file()).unwrap_or_else(|| {
        panic!(
            "HailoRT headers (hailo/hailort.hpp) not found. Install HailoRT and its headers, or set \
             HAILORT_INCLUDE_DIR to the include directory of the HailoRT source of the installed version \
             (git clone --depth 1 --branch v<version> https://github.com/hailo-ai/hailort; \
             HAILORT_INCLUDE_DIR=hailort/hailort/libhailort/include). install.sh does this."
        )
    });
    let version = installed_version();
    let (lib_dir, link) = find_library(version.as_deref()).unwrap_or_else(|| {
        panic!(
            "libhailort{} not found: install HailoRT (Raspberry Pi OS: sudo apt install hailo-all, AI HAT+ 2: \
             hailo-h10-all) or set HAILORT_LIB_DIR",
            version.as_deref().map(|v| format!(".so.{v}")).unwrap_or_default()
        )
    });
    println!(
        "cargo:rustc-env=HAILORT_COMPILED_VERSION={}",
        version.as_deref().unwrap_or("unknown")
    );
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib={link}");
    println!("cargo:include={}", include.display());
    println!("cargo:lib_dir={}", lib_dir.display()); // DEP_HAILORT_LIB_DIR for the Python module
    let windows = env::var("CARGO_CFG_TARGET_OS")
        .map(|os| os == "windows")
        .unwrap_or(false);
    if !windows && !lib_dir.starts_with("/usr") {
        // a library outside the system directories (for instance built from source): find it at run time
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
    }

    cxx_build::bridge("src/lib.rs")
        .file("cpp/shim.cpp")
        .include(&include)
        .std("c++17")
        .flag_if_supported("-Wno-unused-parameter")
        .flag_if_supported("-Wno-deprecated-declarations")
        .compile("hailo_runtime_shim");
}
