# @obinexusltd/julia-polycall

Julia `ccall` binding for
[libpolycall](https://github.com/obinexus/libpolycall) 1.5. The adapter maps
Julia calls to the single core entry point:

```c
polycall_ffi_run_config(config_path, 1)
```

Configuration parsing, validation, networking, and runtime policy remain in
libpolycall. This project only marshals the configuration path across the C
boundary and returns the core status unchanged.

## Install the source package

```shell
npm install @obinexusltd/julia-polycall
```

The npm package publishes the complete Julia and C source tree. It is a native
source distribution rather than a JavaScript implementation. Calling
`require('@obinexusltd/julia-polycall')` returns absolute paths to the packaged
Julia project, sources, headers, configuration, manifest, and Makefile.

For Julia development from a checkout or unpacked npm package:

```shell
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Requirements

- Julia 1.10 or newer
- libpolycall 1.5 development library and headers
- a C11 compiler and GNU Make

## Build

Build the standalone adapter archive without linking libpolycall:

```shell
make
```

Build the Julia-loadable shared library by supplying the linker flags for
libpolycall:

```shell
export POLYCALL_LDFLAGS='-L/path/to/lib -lpolycall'
make native
```

PowerShell uses the same variable:

```powershell
$env:POLYCALL_LDFLAGS = '-LC:\path\to\lib -lpolycall'
make native
```

Place `julia_polycall.dll`, `libjulia_polycall.so`, or
`libjulia_polycall.dylib` in the platform library search path. Alternatively,
set `JULIA_POLYCALL_LIBRARY` to the absolute shared-library path before loading
`JuliaPolycall`.

## API

```julia
using JuliaPolycall

status = run_config("julia-polycallrc")
run_config_or_throw("julia-polycallrc")
```

- `run_config` returns the exact libpolycall status as an `Int`.
- `run_config_or_throw` raises `PolycallError` for a non-zero status.
- Omitting the path uses `julia-polycallrc`.
- Julia's `Cstring` conversion rejects embedded NUL characters.

See [`examples/basic.jl`](examples/basic.jl) for a runnable example.

## Verification

The default suite needs only a C compiler, Make, Node.js, and PowerShell on
Windows:

```shell
npm test
```

It verifies exact path forwarding, the required validation flag, status
propagation, thin-adapter constraints, and npm package completeness.

With Julia installed, run the end-to-end `ccall` smoke test:

```shell
npm run test:julia
```

## Package layout

- `Project.toml` and `src/JuliaPolycall.jl` — standard Julia package
- `c_src/` — native adapter exported for `ccall`
- `include/` — adapter C header
- `generated/polycall/` — minimal generated core FFI declaration
- `examples/` — Julia example and sample configuration
- `test/` and `tests/` — Julia, native, and npm package tests

## Author and license

Copyright © 2026 Nnamdi Michael Okpala
<okpalan@protonmail.com>.

Released under the [MIT License](LICENSE).
