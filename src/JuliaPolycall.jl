"""
    JuliaPolycall

Julia binding for the Polycall C library, binding ABI v1 (`polycall.h`,
`docs/BINDING_ABI.md` in https://github.com/obinexus/polycall). Every call is a
direct `ccall` into libpolycall; there is no C shim.

The library is resolved at run time on first use, never at precompile time:
`ENV["POLYCALL_LIBRARY"]` first, then `polycall.dll` / `libpolycall.dll`
(Windows), `libpolycall.1.dylib` (macOS) or `libpolycall.so.1` (Linux). Every
symbol is resolved up front and `polycall_ffi_abi_version()` must be 1; anything
else throws [`PolycallLoadError`](@ref).
"""
module JuliaPolycall

using Libdl

export DEFAULT_CONFIG, PolycallError, PolycallLoadError,
       abi_version, version, strerror, library_path,
       run_config, run_config_or_throw, describe, call,
       Peer, Message, endpoint, node_id, register!, unregister!, peers,
       ping, send, recv, cancel, health, isopen

const DEFAULT_CONFIG = "julia-polycallrc"
const ABI_VERSION = 1

# ---------------------------------------------------------------------------
# status codes (polycall.h)

const POLYCALL_OK = 0
const POLYCALL_E_INVALID_ARGUMENT = -1
const POLYCALL_E_NO_MEMORY = -2
const POLYCALL_E_INVALID_HANDLE = -3
const POLYCALL_E_TIMEOUT = -4
const POLYCALL_E_TRANSPORT = -5
const POLYCALL_E_PROTOCOL = -6
const POLYCALL_E_NOT_FOUND = -7
const POLYCALL_E_AUTH = -8
const POLYCALL_E_REMOTE = -9
const POLYCALL_E_TOO_LARGE = -10
const POLYCALL_E_BUSY = -11
const POLYCALL_E_CANCELLED = -12
const POLYCALL_E_CONFIG = -13
const POLYCALL_E_ADDRESS_IN_USE = -14
const POLYCALL_E_UNSUPPORTED = -15
const POLYCALL_E_PERMISSION = -16
const POLYCALL_E_CLOSED = -17
const POLYCALL_E_INTERNAL = -18

const PEER_ID_MAX = 64
const MESSAGE_ID_MAX = 64
const ENDPOINT_MAX = 128
const PEER_MAX_PAYLOAD = 1 << 20
const CALL_MAX_OUTPUT = 1 << 20
const WAIT_FOREVER = typemax(UInt32)

# ---------------------------------------------------------------------------
# errors

"""
    PolycallError(status, name, detail; config_path="", info=nothing)

A failed Polycall call: `status` is the negative `POLYCALL_E_*` code, `name`
is `polycall_strerror(status)`, `detail` is `polycall_last_error()` read on the
same thread right after the failure. `info` carries the remote error object
JSON for [`call`](@ref) and the needed payload size for a too-small
[`recv`](@ref) buffer.
"""
struct PolycallError <: Exception
    status::Int
    name::String
    detail::String
    config_path::String
    info::Any
end
PolycallError(status::Integer, name::AbstractString, detail::AbstractString;
              config_path::AbstractString = "", info = nothing) =
    PolycallError(Int(status), String(name), String(detail), String(config_path), info)

function Base.showerror(io::IO, e::PolycallError)
    print(io, "PolycallError: ", e.name, " (status ", e.status, ")")
    isempty(e.detail) || print(io, ": ", e.detail)
    isempty(e.config_path) || print(io, " [config '", e.config_path, "']")
end

"""Thrown when libpolycall cannot be loaded or is not binding ABI v1."""
struct PolycallLoadError <: Exception
    msg::String
end
Base.showerror(io::IO, e::PolycallLoadError) = print(io, "PolycallLoadError: ", e.msg)

# ---------------------------------------------------------------------------
# run-time library resolution

const SYMBOL_NAMES = (
    :polycall_ffi_abi_version, :polycall_ffi_version, :polycall_strerror,
    :polycall_last_error, :polycall_ffi_run_config, :polycall_ffi_describe,
    :polycall_call, :polycall_peer_open, :polycall_peer_close,
    :polycall_peer_endpoint, :polycall_peer_node_id, :polycall_peer_register,
    :polycall_peer_unregister, :polycall_peer_list, :polycall_peer_ping,
    :polycall_peer_send, :polycall_peer_recv, :polycall_peer_cancel,
    :polycall_peer_health,
)

struct Library
    handle::Ptr{Cvoid}
    path::String
    fn::NamedTuple{SYMBOL_NAMES, NTuple{length(SYMBOL_NAMES), Ptr{Cvoid}}}
end

# Published once with release/acquire ordering, so a thread that sees the
# Library also sees its fields (double-checked lazy initialisation).
mutable struct LibraryRef
    @atomic lib::Union{Nothing, Library}
end
const LIBRARY = LibraryRef(nothing)     # nothing until first use
const LIBRARY_LOCK = ReentrantLock()

function default_candidates()
    Sys.iswindows() && return ["polycall.dll", "libpolycall.dll"]
    Sys.isapple() && return ["libpolycall.1.dylib", "libpolycall.dylib"]
    return ["libpolycall.so.1"]
end

function load_library()
    explicit = get(ENV, "POLYCALL_LIBRARY", "")
    candidates = isempty(explicit) ? default_candidates() : [explicit]
    handle = C_NULL
    path = ""
    for c in candidates
        handle = Libdl.dlopen(c, Libdl.RTLD_NOW | Libdl.RTLD_LOCAL; throw_error = false)
        handle === nothing && (handle = C_NULL)
        if handle != C_NULL
            path = c
            break
        end
    end
    if handle == C_NULL
        where = isempty(explicit) ? "tried $(join(candidates, ", ")) on the loader path" :
                                    "POLYCALL_LIBRARY=$(explicit)"
        throw(PolycallLoadError("cannot load libpolycall ($where); install polycall " *
                                ">= 1.1.0 or set POLYCALL_LIBRARY to the library path"))
    end
    ptrs = Ptr{Cvoid}[]
    missing_syms = Symbol[]
    for s in SYMBOL_NAMES
        p = Libdl.dlsym(handle, s; throw_error = false)
        if p === nothing || p == C_NULL
            push!(missing_syms, s)
            push!(ptrs, C_NULL)
        else
            push!(ptrs, p)
        end
    end
    if !isempty(missing_syms)
        Libdl.dlclose(handle)
        throw(PolycallLoadError("$(path) does not export $(join(missing_syms, ", ")): " *
                                "it is not a binding-ABI-v1 library (polycall >= 1.1.0 " *
                                "required; an old 1.0 library?)"))
    end
    fn = NamedTuple{SYMBOL_NAMES}(Tuple(ptrs))
    abi = ccall(fn.polycall_ffi_abi_version, Cint, ())
    if abi != ABI_VERSION
        Libdl.dlclose(handle)
        throw(PolycallLoadError("$(path) reports binding ABI $(abi); JuliaPolycall " *
                                "requires ABI $(ABI_VERSION)"))
    end
    return Library(handle, path, fn)
end

"""The loaded library (loads it on first use; thread-safe)."""
function lib()::Library
    l = @atomic :acquire LIBRARY.lib
    l === nothing || return l
    lock(LIBRARY_LOCK) do
        l = @atomic :acquire LIBRARY.lib
        if l === nothing
            l = load_library()
            @atomic :release LIBRARY.lib = l
        end
        l
    end
end

@inline fnptr(name::Symbol) = getfield(lib().fn, name)

"""Path (or name) libpolycall was loaded from."""
library_path() = lib().path

# Blocking calls are made GC-safe on Julia >= 1.12 so that a thread blocked
# in recv/send/call does not stall garbage collection on other threads.
macro blocking(ex)
    (Meta.isexpr(ex, :call) && ex.args[1] === :ccall) ||
        error("@blocking expects ccall(f, R, (T...), args...)")
    @static if VERSION >= v"1.12"
        f, R, Ts = ex.args[2], ex.args[3], ex.args[4]
        args = ex.args[5:end]
        (Meta.isexpr(Ts, :tuple) && length(Ts.args) == length(args)) ||
            error("@blocking: argument types must be a literal tuple matching the arguments")
        typed = [Expr(:(::), a, T) for (a, T) in zip(args, Ts.args)]
        sig = Expr(:(::), Expr(:call, Expr(:$, f), typed...), R)
        return esc(Expr(:macrocall, Symbol("@ccall"), __source__, Expr(:(=), :gc_safe, true), sig))
    else
        return esc(ex)
    end
end

# ---------------------------------------------------------------------------
# helpers

function last_error_detail()::String
    buf = Vector{UInt8}(undef, 1024)
    ccall(fnptr(:polycall_last_error), Cint, (Ptr{UInt8}, Csize_t), buf, length(buf))
    n = something(findfirst(==(0x00), buf), length(buf) + 1) - 1
    return String(buf[1:n])
end

function polycall_error(status::Integer; config_path::AbstractString = "", info = nothing)
    # read the thread-local detail FIRST, before any other library call
    detail = last_error_detail()
    PolycallError(Int(status), strerror(status), detail; config_path, info)
end

check(status::Integer; kw...) = status == POLYCALL_OK ? nothing : throw(polycall_error(status; kw...))

cstr(buf::Vector{UInt8}) = String(buf[1:(something(findfirst(==(0x00), buf), length(buf) + 1) - 1)])

function check_cstring(s::AbstractString, what)
    occursin('\0', s) && throw(ArgumentError("$what must not contain NUL"))
    return String(s)
end

timeout_u32(t::Nothing) = WAIT_FOREVER
timeout_u32(t::Real) = !(t >= 0) ? throw(ArgumentError("timeout must be >= 0 (got $t)")) :   # also NaN
                       t >= WAIT_FOREVER ? WAIT_FOREVER : UInt32(round(t))

# ---------------------------------------------------------------------------
# library

"""`polycall_ffi_abi_version()` of the loaded library (always 1 after loading)."""
abi_version() = Int(ccall(fnptr(:polycall_ffi_abi_version), Cint, ()))

"""Library version string, e.g. `"1.1.0"`."""
function version()::String
    buf = Vector{UInt8}(undef, 64)
    n = ccall(fnptr(:polycall_ffi_version), Cint, (Ptr{UInt8}, Cint), buf, length(buf))
    n < 0 && throw(polycall_error(n))
    return cstr(buf)
end

"""`polycall_strerror(status)`: static name of any status code."""
strerror(status::Integer) =
    unsafe_string(ccall(fnptr(:polycall_strerror), Cstring, (Cint,), status))

# ---------------------------------------------------------------------------
# configuration

"""
    run_config(config_path=DEFAULT_CONFIG) -> Int

Legacy entry point: `polycall_ffi_run_config(config_path, 1)` (strict), returns
the status unchanged (0 = valid for running with this build).
"""
function run_config(config_path::AbstractString = DEFAULT_CONFIG)::Int
    path = check_cstring(config_path, "config_path")
    return Int(@blocking ccall(fnptr(:polycall_ffi_run_config), Cint, (Cstring, Cint), path, 1))
end

"""
    run_config_or_throw(config_path=DEFAULT_CONFIG; strict=true) -> Nothing

`polycall_ffi_run_config(config_path, strict)`; throws [`PolycallError`](@ref)
(`config_path` set) unless the file is valid. `strict=true` also rejects
unknown keys and settings this build cannot honour (`tls_enabled=true` →
`POLYCALL_E_UNSUPPORTED`).
"""
function run_config_or_throw(config_path::AbstractString = DEFAULT_CONFIG; strict::Bool = true)::Nothing
    path = check_cstring(config_path, "config_path")
    st = @blocking ccall(fnptr(:polycall_ffi_run_config), Cint, (Cstring, Cint), path, strict ? 1 : 0)
    check(st; config_path = path)
end

"""JSON description of a configuration file (secrets are never resolved)."""
function describe(config_path::AbstractString)::String
    path = check_cstring(config_path, "config_path")
    for _ in 1:4
        n = @blocking ccall(fnptr(:polycall_ffi_describe), Cint, (Cstring, Ptr{UInt8}, Cint), path, C_NULL, 0)
        n < 0 && throw(polycall_error(n; config_path = path))
        buf = Vector{UInt8}(undef, n + 1)
        m = @blocking ccall(fnptr(:polycall_ffi_describe), Cint, (Cstring, Ptr{UInt8}, Cint), path, buf, length(buf))
        m < 0 && throw(polycall_error(m; config_path = path))
        m <= n && return cstr(buf)
    end
    throw(PolycallError(POLYCALL_E_TOO_LARGE, strerror(POLYCALL_E_TOO_LARGE),
                        "configuration kept changing while being described"; config_path = path))
end

# ---------------------------------------------------------------------------
# RPC

"""
    call(endpoint, service, operation, input_json=nothing; timeout_ms=5000) -> String

One `polycall_rpc` v1 round trip (never retried) to a running `polycall start`
/ `polycall daemon` at `endpoint` (`"host:port"`). Returns the operation's
output JSON. On failure throws [`PolycallError`](@ref); `info` holds the
remote error object JSON (`{"code":..,"message":..}`) when there is one.
"""
function call(endpoint::AbstractString, service::AbstractString, operation::AbstractString,
              input_json::Union{Nothing, AbstractString} = nothing; timeout_ms::Integer = 5000)::String
    0 <= timeout_ms <= typemax(UInt32) || throw(ArgumentError("timeout_ms out of range"))
    out = Vector{UInt8}(undef, CALL_MAX_OUTPUT + 1)   # a too-small buffer would lose a result that ran
    out[1] = 0x00
    out_len = Ref{Csize_t}(0)
    input = input_json === nothing ? nothing : check_cstring(input_json, "input_json")
    ep = check_cstring(endpoint, "endpoint")
    svc = check_cstring(service, "service")
    op = check_cstring(operation, "operation")
    st = GC.@preserve input begin
        @blocking ccall(fnptr(:polycall_call), Cint,
                        (Cstring, Cstring, Cstring, Ptr{UInt8}, UInt32, Ptr{UInt8}, Csize_t, Ref{Csize_t}),
                        ep, svc, op, input === nothing ? Ptr{UInt8}(C_NULL) : pointer(input),
                        UInt32(timeout_ms), out, length(out), out_len)
    end
    text = cstr(out)
    st == POLYCALL_OK && return text
    throw(polycall_error(st; info = isempty(text) ? nothing : text))
end

# ---------------------------------------------------------------------------
# peers

"""
    Peer(node_id; bind="127.0.0.1:0", token=nothing)

A Polycall peer node (`polycall_peer_open`). `bind = nothing` opens a
send-only node. `token` is the shared secret (`nothing`/"" = none); a
non-loopback bind needs one. `close(peer)` stops it (a second close throws
`POLYCALL_E_INVALID_HANDLE`, as does any call after close).

Call `close` when done: the core allows at most 255 open nodes per process.
A peer that is garbage collected without `close` is closed by its finalizer
(on a separate task, see `finalize_peer`), and when `polycall_peer_open`
reports `POLYCALL_E_BUSY` the constructor runs the GC once, waits for those
deferred closes and retries.
"""
mutable struct Peer
    handle::Int32
    @atomic closed::Bool

    function Peer(node_id::AbstractString; bind::Union{Nothing, AbstractString} = "127.0.0.1:0",
                  token::Union{Nothing, AbstractString} = nothing)
        h = Ref{Int32}(0)
        id = check_cstring(node_id, "node_id")
        b = bind === nothing ? nothing : check_cstring(bind, "bind")
        t = token === nothing ? nothing : check_cstring(token, "token")
        open_once() = GC.@preserve b t begin
            @blocking ccall(fnptr(:polycall_peer_open), Cint, (Cstring, Ptr{UInt8}, Ptr{UInt8}, Ref{Int32}),
                            id, b === nothing ? Ptr{UInt8}(C_NULL) : pointer(b),
                            t === nothing ? Ptr{UInt8}(C_NULL) : pointer(t), h)
        end
        st = open_once()
        if st == POLYCALL_E_BUSY
            reclaim_unreachable_peers()
            st = open_once()        # the node limit may have been held by garbage
        end
        check(st)
        p = new(h[], false)
        finalizer(finalize_peer, p)
        return p
    end
end

# Peers closed by finalizers: scheduled, and not yet closed.
const DEFERRED_CLOSES = Threads.Atomic{Int}(0)
const FINALIZED_PEERS = Threads.Atomic{Int}(0)    # total, for tests

"""
    finalize_peer(p)

Finalizer of an unreachable, unclosed [`Peer`](@ref). It does NOT call into
libpolycall itself: finalizers run inside GC on whatever thread allocated,
possibly between a failed call and the `polycall_last_error()` read that
reports it, and a successful `polycall_peer_close` there would clear that
thread's error detail. The close runs on its own task instead.
"""
function finalize_peer(p::Peer)
    # never throws, never yields
    if (@atomicreplace p.closed false => true).success
        Threads.atomic_add!(DEFERRED_CLOSES, 1)
        Threads.atomic_add!(FINALIZED_PEERS, 1)
        h = p.handle
        Threads.@spawn close_finalized(h)
    end
    return nothing
end

function close_finalized(h::Int32)
    try
        l = @atomic :acquire LIBRARY.lib
        l === nothing || @blocking ccall(l.fn.polycall_peer_close, Cint, (Int32,), h)
    finally
        Threads.atomic_sub!(DEFERRED_CLOSES, 1)
    end
    return nothing
end

# Run the GC so unreachable peers are finalized, then wait (bounded) for the
# deferred closes to finish.
function reclaim_unreachable_peers(; timeout_s::Real = 5)::Nothing
    GC.gc(true)
    deadline = time() + timeout_s
    while DEFERRED_CLOSES[] > 0 && time() < deadline
        sleep(0.001)
    end
    return nothing
end

Base.isopen(p::Peer) = !(@atomic p.closed)

function Base.show(io::IO, p::Peer)
    print(io, "Peer(handle=", p.handle, isopen(p) ? "" : ", closed", ")")
end

"""Stop the listener and wake blocked receivers (`POLYCALL_E_CLOSED`)."""
function Base.close(p::Peer)::Nothing
    st = @blocking ccall(fnptr(:polycall_peer_close), Cint, (Int32,), p.handle)
    st == POLYCALL_OK && (@atomic p.closed = true)
    check(st)
end

function text_out(f::Symbol, p::Peer, initial::Int = 4096)::String
    cap = initial
    for _ in 1:4
        buf = Vector{UInt8}(undef, cap)
        len = Ref{Csize_t}(0)
        st = ccall(fnptr(f), Cint, (Int32, Ptr{UInt8}, Csize_t, Ref{Csize_t}), p.handle, buf, cap, len)
        st == POLYCALL_OK && return cstr(buf)
        st == POLYCALL_E_TOO_LARGE || throw(polycall_error(st))
        cap = Int(len[]) + 1
    end
    throw(polycall_error(POLYCALL_E_TOO_LARGE))
end

"""Bound `"host:port"` (`""` for a send-only node)."""
function endpoint(p::Peer)::String
    buf = Vector{UInt8}(undef, ENDPOINT_MAX)
    check(ccall(fnptr(:polycall_peer_endpoint), Cint, (Int32, Ptr{UInt8}, Csize_t), p.handle, buf, length(buf)))
    return cstr(buf)
end

function node_id(p::Peer)::String
    buf = Vector{UInt8}(undef, PEER_ID_MAX)
    check(ccall(fnptr(:polycall_peer_node_id), Cint, (Int32, Ptr{UInt8}, Csize_t), p.handle, buf, length(buf)))
    return cstr(buf)
end

"""Add or replace `peer_id => endpoint` in THIS node's registry."""
register!(p::Peer, peer_id::AbstractString, ep::AbstractString) =
    check(ccall(fnptr(:polycall_peer_register), Cint, (Int32, Cstring, Cstring), p.handle,
                check_cstring(peer_id, "peer_id"), check_cstring(ep, "endpoint")))

"""Remove `peer_id` (`POLYCALL_E_NOT_FOUND` when it is not registered)."""
unregister!(p::Peer, peer_id::AbstractString) =
    check(ccall(fnptr(:polycall_peer_unregister), Cint, (Int32, Cstring), p.handle,
                check_cstring(peer_id, "peer_id")))

"""THIS node's registry as JSON text `{"id":"host:port",...}`."""
peers(p::Peer) = text_out(:polycall_peer_list, p)

"""This node's health as JSON text."""
health(p::Peer) = text_out(:polycall_peer_health, p)

"""GET /health on `target` (registered id or `"host:port"`)."""
ping(p::Peer, target::AbstractString; timeout_ms::Real = 5000) =
    check(@blocking ccall(fnptr(:polycall_peer_ping), Cint, (Int32, Cstring, UInt32), p.handle,
                          check_cstring(target, "target"), timeout_u32(timeout_ms)))

"""
    send(peer, target, payload; message_id=nothing, timeout_ms=5000)

Deliver `payload` (bytes or a string, binary-safe, ≤ 1 MiB) to `target`
(registered id or `"host:port"`) with exactly one delivery attempt. Returns
`nothing` once the receiver acknowledged it; retry with the same
`message_id` after a timeout/transport/busy error (duplicates are dropped).
"""
function send(p::Peer, target::AbstractString, payload::Union{AbstractVector{UInt8}, AbstractString};
              message_id::Union{Nothing, AbstractString} = nothing, timeout_ms::Real = 5000)::Nothing
    data = payload isa AbstractString ? Vector{UInt8}(codeunits(String(payload))) : Vector{UInt8}(payload)
    mid = message_id === nothing ? nothing : check_cstring(message_id, "message_id")
    tgt = check_cstring(target, "target")
    GC.@preserve data mid begin
        st = @blocking ccall(fnptr(:polycall_peer_send), Cint,
                             (Int32, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, UInt32),
                             p.handle, tgt, isempty(data) ? Ptr{UInt8}(C_NULL) : pointer(data), length(data),
                             mid === nothing ? Ptr{UInt8}(C_NULL) : pointer(mid), timeout_u32(timeout_ms))
    end
    check(st)
end

"""A received message: sender node id, message id and the exact payload bytes."""
struct Message
    sender::String
    message_id::String
    payload::Vector{UInt8}
end
Base.:(==)(a::Message, b::Message) =
    a.sender == b.sender && a.message_id == b.message_id && a.payload == b.payload

"""
    recv(peer; timeout_ms=nothing, max_payload=1 MiB) -> Message

Take the oldest message. `timeout_ms = 0` polls, `nothing` waits until a
message, [`cancel`](@ref) (`POLYCALL_E_CANCELLED`) or `close`
(`POLYCALL_E_CLOSED`). A message larger than `max_payload` throws
`POLYCALL_E_TOO_LARGE` with `info` = needed bytes and stays queued.
"""
function recv(p::Peer; timeout_ms::Union{Nothing, Real} = nothing, max_payload::Integer = PEER_MAX_PAYLOAD)::Message
    0 <= max_payload <= PEER_MAX_PAYLOAD || throw(ArgumentError("max_payload must be 0..$(PEER_MAX_PAYLOAD)"))
    sender = zeros(UInt8, PEER_ID_MAX)
    mid = zeros(UInt8, MESSAGE_ID_MAX)
    buf = Vector{UInt8}(undef, max(max_payload, 1))
    len = Ref{Csize_t}(0)
    st = @blocking ccall(fnptr(:polycall_peer_recv), Cint,
                         (Int32, UInt32, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ref{Csize_t}),
                         p.handle, timeout_u32(timeout_ms), sender, length(sender), mid, length(mid),
                         buf, max_payload, len)
    st == POLYCALL_E_TOO_LARGE && throw(polycall_error(st; info = Int(len[])))
    check(st)
    return Message(cstr(sender), cstr(mid), resize!(buf, Int(len[])))
end

"""Wake every `recv` blocked on `peer` with `POLYCALL_E_CANCELLED`."""
cancel(p::Peer) = check(ccall(fnptr(:polycall_peer_cancel), Cint, (Int32,), p.handle))

end # module
