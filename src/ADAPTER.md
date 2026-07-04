# Julia adapter

The implementation lives in `JuliaPolycall.jl`. It crosses the `ccall`/FFI
boundary only through:

    status = polycall_ffi_run_config("julia-polycallrc", /*run=*/1)

`run_config` returns the status and `run_config_or_throw` raises
`PolycallError`. No configuration parsing or core runtime logic belongs in this
binding.
