const FILES: [&str; 3] = [
    "arch/x86_64/len.S",
    "arch/x86_64/arena.S",
    "arch/x86_64/speq.S",
];

fn main() {
    for file in FILES {
        println!("cargo:rerun-if-changed={file}");
    }

    nasm_rs::compile_library("libfasted.a", &FILES).unwrap();

    let out_dir = std::env::var("OUT_DIR").expect("Could not find env var OUT_DIR");

    println!("cargo:rustc-link-lib=static=fasted");
    println!("cargo:rustc-link-search=native={out_dir}");
}
