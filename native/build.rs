use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=c/ebox_module.c");
    println!("cargo:rerun-if-changed=vendor/emacs-30/emacs-module.h");
    println!("cargo:rerun-if-env-changed=EMACS_MODULE_INCLUDE");

    let include = match env::var_os("EMACS_MODULE_INCLUDE") {
        Some(value) => {
            let path = PathBuf::from(value);
            assert!(
                path.join("emacs-module.h").is_file(),
                "EMACS_MODULE_INCLUDE must name a directory containing emacs-module.h"
            );
            path
        }
        None => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vendor/emacs-30"),
    };

    let mut build = cc::Build::new();
    build.file("c/ebox_module.c").include(include);
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        build.flag_if_supported("/W4");
    } else {
        build
            .flag_if_supported("-std=c11")
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror=implicit-function-declaration");
    }
    build.compile("ebox_module_shim");
}
