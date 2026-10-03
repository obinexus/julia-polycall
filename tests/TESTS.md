# Julia tests

`test/runtests.jl` (run by `Pkg.test()`) exercises JuliaPolycall against the
REAL installed libpolycall — no mocks: version/ABI, load errors (missing
library, 1.0 library, ABI 2 — fake libraries from `test/fixtures/`),
`run_config` (valid, missing, invalid, strict, TLS unsupported), `describe`,
non-ASCII config path, `call` against `polycall start` and `polycall daemon
start` (plus concurrent calls), peers (both directions, payload sizes up to
1 MiB + 1, registry ownership, duplicates, auth, dead peer, timeouts,
too-small buffer, integer boundaries, cancel/close waking a blocked recv,
double close / use after close / forged handles, finalizer — deferred so it
never clobbers `polycall_last_error`, node-limit reclaim — concurrent
senders, gc_safe blocking) and interop with a `polycall peer serve` C node
both ways.

`tests/package.test.js` checks the npm source-package index.
