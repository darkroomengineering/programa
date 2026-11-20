//! `programa-host.exe`: owns the terminals' ConPTYs and shells so they outlive the app (src/host.rs).
//! The app starts it with `PROGRAMA_HOST_PIPE` and `PROGRAMA_HOST_TOKEN`, which stay out of the
//! command line and are removed before any shell starts.
#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    let (Ok(pipe), Ok(token)) = (
        std::env::var("PROGRAMA_HOST_PIPE"),
        std::env::var("PROGRAMA_HOST_TOKEN"),
    ) else {
        eprintln!("programa-host is started by Programa");
        std::process::exit(2);
    };
    std::env::remove_var("PROGRAMA_HOST_PIPE");
    std::env::remove_var("PROGRAMA_HOST_TOKEN");
    #[cfg(windows)]
    if let Err(error) =
        programa_terminal::host::serve(&pipe, &token, Some(programa_terminal::host::IDLE_EXIT))
    {
        eprintln!("programa-host: {error}");
        std::process::exit(1);
    }
    #[cfg(not(windows))]
    let _ = (pipe, token);
}
