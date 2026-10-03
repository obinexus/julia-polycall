# Julia adapter

`JuliaPolycall.jl` ccalls the Polycall binding ABI v1 directly. The library
is located at run time (`POLYCALL_LIBRARY`, then the platform name), every
symbol is resolved up front and the ABI version is checked before first use.

The documented entry point is unchanged:

    run_config(path) == polycall_ffi_run_config(path, /*run=*/1)

No configuration parsing or core runtime logic belongs in this binding.
