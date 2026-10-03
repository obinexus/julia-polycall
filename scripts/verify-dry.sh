#!/usr/bin/env sh
# Thin-adapter check: JuliaPolycall only ccalls libpolycall; it never parses
# configuration or opens files/sockets itself, and never freezes the library
# path at precompile time.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/src/JuliaPolycall.jl"

if grep -E -n '(^|[^_A-Za-z0-9.])(fopen|open|socket|connect|sscanf|strtok)\(' "$src"; then
    echo "julia-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi
grep -F -q 'POLYCALL_LIBRARY' "$src"
grep -F -q 'polycall_ffi_abi_version' "$src"
grep -F -q 'ccall(fnptr(:polycall_ffi_run_config), Cint, (Cstring, Cint), path, 1)' "$src"
if grep -n 'const NATIVE_LIBRARY' "$src"; then
    echo "library path must be resolved at run time, not frozen in a const" >&2
    exit 1
fi

echo "julia-polycall thin-adapter check: PASS"
