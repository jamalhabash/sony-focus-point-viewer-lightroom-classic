fn main() {
    // The `libc` crate (via memmap2 / mozjpeg-sys) asks to link libiconv on
    // Apple targets. Nothing uses it, and in a Nix build it would resolve to
    // a /nix/store dylib, which must not leak into the plugin bundle. Drop
    // unused dylibs so the binary links only the system's libSystem.
    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        println!("cargo:rustc-link-arg=-Wl,-dead_strip_dylibs");
    }
}
