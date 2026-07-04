module JuliaPolycall

export DEFAULT_CONFIG,
       PolycallError,
       run_config,
       run_config_or_throw

const DEFAULT_CONFIG = "julia-polycallrc"
const NATIVE_LIBRARY = get(ENV, "JULIA_POLYCALL_LIBRARY", "julia_polycall")

"""Error returned by `run_config_or_throw` for a non-zero core status."""
struct PolycallError <: Exception
    status::Int
    config_path::String
end

function Base.showerror(io::IO, error::PolycallError)
    print(
        io,
        "libpolycall failed with status ",
        error.status,
        " for config '",
        error.config_path,
        "'",
    )
end

"""
    run_config(config_path=DEFAULT_CONFIG) -> Int

Run a libpolycall configuration and return the unchanged core status.
"""
function run_config(config_path::AbstractString = DEFAULT_CONFIG)::Int
    path = String(config_path)
    status = ccall(
        (:julia_polycall_run_config, NATIVE_LIBRARY),
        Cint,
        (Cstring,),
        path,
    )
    return Int(status)
end

"""
    run_config_or_throw(config_path=DEFAULT_CONFIG) -> Nothing

Run a configuration and throw `PolycallError` when the core reports failure.
"""
function run_config_or_throw(config_path::AbstractString = DEFAULT_CONFIG)::Nothing
    path = String(config_path)
    status = run_config(path)
    status == 0 || throw(PolycallError(status, path))
    return nothing
end

end
