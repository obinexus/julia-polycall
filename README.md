# julia-polycall (`JuliaPolycall`)

Julia binding for the [Polycall](https://github.com/obinexus/polycall) C
library, **binding ABI v1** (`polycall >= 1.1.0`). Every call is a direct
`ccall` into libpolycall — there is no C shim to build. npm source package:
`@obinexusltd/julia-polycall` (not yet published).

## Loading

The library is resolved **at run time on first use** (never frozen at
precompile time): `ENV["POLYCALL_LIBRARY"]` first, then `libpolycall.so.1`
(Linux), `polycall.dll` / `libpolycall.dll` (Windows) or
`libpolycall.1.dylib` (macOS). All 19 ABI symbols are resolved up front and
`polycall_ffi_abi_version()` must be 1. A missing library, an old 1.0 library
(missing symbols) or another ABI throws `PolycallLoadError` naming the
library and the problem — never a crash.

## API

```julia
using JuliaPolycall

abi_version()                       # 1
JuliaPolycall.version()             # "1.1.0"

run_config("julia-polycallrc")      # legacy: polycall_ffi_run_config(path, 1) -> status Int
run_config_or_throw("julia-polycallrc"; strict = true)   # throws PolycallError
describe("Polycallfile")            # JSON text

# one RPC round trip to `polycall start` / `polycall daemon start`
out = call("127.0.0.1:7000", "inventory", "get", "{\"item_id\":\"widget-a\"}"; timeout_ms = 5000)

# peers
a = Peer("alpha"; token = token)    # bind = "127.0.0.1:0" by default, bind = nothing: send-only
b = Peer("beta"; token = token)
register!(a, "beta", endpoint(b))
send(a, "beta", "hello"; message_id = "m1")
m = recv(b; timeout_ms = 5000)      # Message(sender, message_id, payload::Vector{UInt8})
close(a); close(b)
```

Also: `node_id`, `unregister!`, `peers` (registry JSON), `ping`, `cancel`
(wakes blocked `recv` with `POLYCALL_E_CANCELLED`), `health` (JSON), `isopen`.
`recv(p; max_payload = n)` throws `POLYCALL_E_TOO_LARGE` with `info` = needed
bytes and leaves the message queued. Errors are `PolycallError(status, name,
detail, config_path, info)`: the status code, `polycall_strerror`, and
`polycall_last_error` read on the same thread right after the failure.

A `Peer` that is garbage collected without `close` is closed by its
finalizer. Calls after `close` (including a second `close`) throw
`POLYCALL_E_INVALID_HANDLE`.

**Threads.** Blocking calls (`recv`, `send`, `ping`, `call`, `close`, …) are
plain ccalls on the calling thread; run them in `Threads.@spawn` to keep other
tasks going. On Julia ≥ 1.12 they are `gc_safe`, so a thread blocked in `recv`
does not stall garbage collection on other threads; on 1.10/1.11 it can (GC
waits until the call returns).

## Tests

```sh
JULIA_NUM_THREADS=4 julia --project=. -e 'using Pkg; Pkg.test()'    # or: make test
```

`test/runtests.jl` runs against the **real** library: the
`docs/BINDING_ABI.md` checklist, load errors (fake libraries built from
`test/fixtures/fake_polycall.c`), `call` against a `polycall start`
runtime, and interop with a `polycall peer serve` C node in both directions.
It needs `polycall` on PATH (or `POLYCALL_CLI`); checks that cannot run print
`SKIP` and are never counted as passes.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Nnamdi Michael Okpala
<okpalan@protonmail.com>.
