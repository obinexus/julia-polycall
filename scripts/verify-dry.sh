#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if grep -E -n 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\(' \
    "$root/c_src/julia_polycall.c" "$root/src/JuliaPolycall.jl"; then
    echo "julia-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi

grep -F -q 'polycall_ffi_run_config(config_path, 1)' \
    "$root/c_src/julia_polycall.c"
grep -F -q 'ccall(' "$root/src/JuliaPolycall.jl"
grep -F -q '(Cstring,)' "$root/src/JuliaPolycall.jl"

echo "julia-polycall thin-adapter check: PASS"
