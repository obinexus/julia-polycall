# TODO — julia-polycall

Status: implemented thin Julia adapter for libpolycall 1.5.

- [x] Publishable `@obinexusltd/julia-polycall` npm source package
- [x] Standard Julia `Project.toml` and module layout
- [x] `ccall` status and exception APIs with checked `Cstring` marshalling
- [x] Exact `polycall_ffi_run_config(config_path, 1)` forwarding
- [x] Runnable example under `examples/`
- [x] Native forwarding test and Julia smoke test
- [x] Thin-adapter source audit for Windows and POSIX shells
- [ ] Exercise the Julia smoke test in release CI across supported platforms
- [ ] Publish signed platform-native artifacts alongside the source package

Do not add configuration parsing or runtime policy here; adapt the core only.
