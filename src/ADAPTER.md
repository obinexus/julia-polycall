# Julia adapter (scaffold)

Implement the Julia adapter here. It must call across the FFI boundary only:

    status = polycall_ffi_run_config("julia-polycallrc", /*run=*/1)

Return/raise a Julia-native error when `status` is non-zero. Do not parse
config or duplicate any core logic. See ../../../docs/adapter-pattern.md.
