# TODO — julia-polycall (Julia)

Status: direct-`ccall` binding over the Polycall binding ABI v1
(polycall >= 1.1.0), tested against the real library on Linux (julia:1).

- [x] ccall straight to libpolycall; run-time resolution (POLYCALL_LIBRARY first)
- [x] ABI/symbol checks with `PolycallLoadError`; `PolycallError` with status, name, detail
- [x] `run_config`, `describe`, `call`, `Peer` (open/close/endpoint/node_id/register!/unregister!/peers/ping/send/recv/cancel/health)
- [x] `Pkg.test()` against the real core, interop with `polycall peer serve`
- [ ] Windows run (no Julia toolchain on the QA host)
- [ ] Register in the Julia General registry / publish the npm source package (not done by QA)
