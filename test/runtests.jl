# Tests of JuliaPolycall against the REAL installed libpolycall (no mocks):
# the docs/BINDING_ABI.md checklist, `polycall_call` against `polycall start`
# and `polycall daemon start`, and interop with a `polycall peer serve` C node
# in both directions.
#
# Needs libpolycall (POLYCALL_LIBRARY or the loader path) and, for the RPC and
# interop checks, the `polycall` CLI (POLYCALL_CLI or PATH). Checks that need
# something unavailable print "SKIP <name>: <reason>" and record no passes.
# Thread-dependent checks need JULIA_NUM_THREADS >= 2.

using Test
using JuliaPolycall
using JuliaPolycall: POLYCALL_E_INVALID_ARGUMENT, POLYCALL_E_INVALID_HANDLE, POLYCALL_E_TIMEOUT,
                     POLYCALL_E_TRANSPORT, POLYCALL_E_PROTOCOL, POLYCALL_E_NOT_FOUND, POLYCALL_E_AUTH,
                     POLYCALL_E_REMOTE, POLYCALL_E_TOO_LARGE, POLYCALL_E_CANCELLED, POLYCALL_E_CONFIG,
                     POLYCALL_E_UNSUPPORTED, POLYCALL_E_CLOSED

const MIB = 1 << 20
const SKIPPED = String[]
skip(name, reason) = (push!(SKIPPED, "$name: $reason"); println("SKIP  $name: $reason"))

const TOKEN = let t = get(ENV, "POLYCALL_DEV_TOKEN", "")
    isempty(t) ? "jl-test-" * string(rand(UInt64); base = 16) : t
end
ENV["POLYCALL_DEV_TOKEN"] = TOKEN          # the CLI node reads it from here
ENV["POLYCALL_TELEMETRY"] = "off"

const CLI = let c = get(ENV, "POLYCALL_CLI", "")
    isempty(c) ? Sys.which("polycall") : c
end
const TMP = mktempdir()
const PROCS = Base.Process[]

function status_of(f)
    try
        f()
        return :ok
    catch e
        e isa PolycallError && return e.status
        rethrow()
    end
end
caught(f) = try f(); nothing catch e; e end

utf8_text() = "héllo — 世界 \U1f30d"
bytes_0_255() = UInt8.(0:255)
node(id; kw...) = Peer(id; token = TOKEN, kw...)

function start_cli(name, args...)
    epfile = joinpath(TMP, name * ".ep")
    log = joinpath(TMP, name * ".log")
    p = run(pipeline(`$CLI $args --endpoint-file $epfile`; stdout = log, stderr = log); wait = false)
    push!(PROCS, p)
    for _ in 1:100
        isfile(epfile) && filesize(epfile) > 0 && return strip(read(epfile, String))
        sleep(0.1)
    end
    error("$name did not write its endpoint: $(read(log, String))")
end

function run_cli(args...)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(`$CLI $args`); stdout = out, stderr = out))
    return p.exitcode, String(take!(out))
end

# RFC 4648 base64 decoder for the CLI output (keeps the test target to Test only)
function b64decode(s::AbstractString)::Vector{UInt8}
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    out = UInt8[]; acc = 0; bits = 0
    for c in s
        c == '=' && break
        v = findfirst(==(c), alphabet)
        v === nothing && throw(ArgumentError("invalid base64 character $(repr(c))"))
        acc = (acc << 6) | (v - 1); bits += 6
        if bits >= 8
            bits -= 8
            push!(out, UInt8((acc >> bits) & 0xff))
        end
    end
    return out
end

jfield(json, key) = (m = match(Regex("\"$key\":\"([^\"]*)\""), json); m === nothing ? nothing : m[1])

# Run f on another thread and return once it is running there (the main
# task busy-waits without yielding, so the spawned task cannot be on our
# thread). The wait loops pass GC safepoints: a loop without one would stall
# a GC started by any other thread (e.g. by a finalizer) until it ends.
function busy_wait(cond, seconds)
    deadline = time() + seconds
    while !cond() && time() < deadline
        GC.safepoint()
        Libc.systemsleep(0.005)
    end
    return cond()
end

function spawn_running(f)
    started = Threads.Atomic{Bool}(false)
    t = Threads.@spawn begin
        started[] = true
        f()
    end
    busy_wait(() -> started[], 10) || error("spawned task did not start")
    busy_wait(() -> false, 0.2)        # let it enter the blocking call
    return t
end

# Open a peer and drop every reference to it (only its endpoint escapes).
@noinline unreferenced_peer_endpoint(id) = endpoint(Peer(id))

RPC = nothing
CLI_NODE = nothing
if CLI === nothing
    skip("rpc + interop fixtures", "polycall CLI not found (set POLYCALL_CLI or PATH)")
else
    global RPC = start_cli("rpc", "start", "--endpoint", "127.0.0.1:0")
    global CLI_NODE = start_cli("cli-node", "peer", "serve", "--node-id", "cli-node", "--endpoint", "127.0.0.1:0")
end

try
@testset verbose = true "JuliaPolycall (real libpolycall)" begin

@testset "version and ABI check" begin
    @test abi_version() == 1
    @test JuliaPolycall.version() == "1.1.0"
    @test startswith(strerror(-4), "POLYCALL_E_TIMEOUT")
    @test startswith(strerror(0), "POLYCALL_OK")
    @test occursin("UNKNOWN", strerror(-999))
    @test all(c -> startswith(strerror(c), "POLYCALL_"), -18:0)
    @test !isempty(library_path())
end

@testset "load errors (missing library, 1.0 library, ABI 2)" begin
    cc = something(Sys.which("cc"), Sys.which("gcc"), Some(nothing))
    fixture = joinpath(@__DIR__, "fixtures", "fake_polycall.c")
    if !Sys.islinux() || cc === nothing
        skip("load errors", "needs Linux and a C compiler to build the fake libraries")
    else
        dir = mktempdir()
        v10 = joinpath(dir, "v10.so"); abi2 = joinpath(dir, "abi2.so")
        run(`$cc -shared -fPIC -DFAKE_V10 $fixture -o $v10`)
        run(`$cc -shared -fPIC -DFAKE_ABI=2 $fixture -o $abi2`)
        project = dirname(@__DIR__)
        probe(lib) = begin
            code = """
            using JuliaPolycall
            try
                JuliaPolycall.version(); println("LOADED")
            catch e
                e isa PolycallLoadError || rethrow()
                println("LOADERROR ", sprint(showerror, e))
            end
            """
            out = IOBuffer()
            p = run(pipeline(ignorestatus(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`,
                                                 "POLYCALL_LIBRARY" => lib)); stdout = out, stderr = out))
            (p.exitcode, String(take!(out)))
        end
        rc, out = probe(joinpath(dir, "missing", "libpolycall.so.1"))
        println("  missing: ", strip(out))
        @test rc == 0 && occursin("LOADERROR", out) && occursin("cannot load libpolycall", out)
        rc, out = probe(v10)
        println("  1.0 library: ", strip(out))
        @test rc == 0 && occursin("LOADERROR", out) && occursin("does not export polycall_ffi_abi_version", out)
        rc, out = probe(abi2)
        println("  ABI 2: ", strip(out))
        @test rc == 0 && occursin("LOADERROR", out) && occursin("binding ABI 2", out)
    end
end

@testset "run_config" begin
    rc(name, text) = (p = joinpath(TMP, name); write(p, text); p)
    root = dirname(@__DIR__)
    # valid: legacy run_config returns the status, run_config_or_throw throws nothing
    @test run_config(joinpath(root, "julia-polycallrc")) == 0
    @test run_config(joinpath(root, "examples", "julia-polycallrc")) == 0
    @test run_config_or_throw(joinpath(root, "julia-polycallrc")) === nothing
    # missing
    missing_path = joinpath(TMP, "does-not-exist-polycallrc")
    @test run_config(missing_path) == POLYCALL_E_NOT_FOUND
    e = caught(() -> run_config_or_throw(missing_path))
    @test e isa PolycallError && e.status == POLYCALL_E_NOT_FOUND && e.config_path == missing_path
    @test startswith(e.name, "POLYCALL_E_NOT_FOUND")
    # invalid
    bad = rc("bad-polycallrc", "max_connections=lots\n")
    e = caught(() -> run_config_or_throw(bad; strict = false))
    @test e isa PolycallError && e.status == POLYCALL_E_CONFIG && occursin("max_connections", e.detail)
    # strict: unknown key is a warning, strict an error
    unk = rc("unknown-polycallrc", "log_level=info\nmystery_key=1\n")
    @test run_config_or_throw(unk; strict = false) === nothing
    @test status_of(() -> run_config_or_throw(unk; strict = true)) == POLYCALL_E_CONFIG
    # TLS refused rather than served as plaintext
    tls = rc("tls-polycallrc", "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n")
    @test run_config_or_throw(tls; strict = false) === nothing
    @test status_of(() -> run_config_or_throw(tls)) == POLYCALL_E_UNSUPPORTED
    # argument errors
    @test run_config("") == POLYCALL_E_INVALID_ARGUMENT
    @test_throws ArgumentError run_config("a\0b")
    # describe
    pf = rc("Polycallfile", "server node 8080:8084\nnetwork start\nworkspace_root=/opt/x\n" *
                            "log_directory=/var/log/x\ndaemon_endpoint=127.0.0.1:0\n" *
                            "auth_token_env=POLYCALL_DEV_TOKEN\npeer_node_id=alpha\npeer beta 127.0.0.1:9002\n")
    @test run_config_or_throw(pf) === nothing
    d = describe(pf)
    @test occursin("\"beta\":\"127.0.0.1:9002\"", d) && startswith(d, "{")
end

@testset "non-ASCII (UTF-8) config path" begin
    dir = joinpath(TMP, "ünïcødé-конфиг-設定")
    mkpath(dir)
    path = joinpath(dir, "julia-polycallrc-ß")
    write(path, read(joinpath(dirname(@__DIR__), "julia-polycallrc")))
    @test run_config(path) == 0
    @test run_config_or_throw(path) === nothing
    @test occursin("max_connections", describe(path))
    gone = joinpath(dir, "fehlt-ü-polycallrc")
    e = caught(() -> run_config_or_throw(gone))
    @test e isa PolycallError && e.status == POLYCALL_E_NOT_FOUND && e.config_path == gone
end

@testset "call (polycall start)" begin
    if RPC === nothing
        skip("call", "polycall CLI not found")
    else
        out = call(RPC, "inventory", "get", "{\"item_id\":\"widget-a\"}")
        @test occursin("\"quantity\":42", out) && occursin("\"in_stock\":true", out)
        out = call(RPC, "debug", "echo", "{\"text\":\"$(utf8_text())\"}")
        @test out == "{\"echo\":{\"text\":\"$(utf8_text())\"}}"
        @test call(RPC, "debug", "echo") == "{\"echo\":null}"
        e = caught(() -> call(RPC, "inventory", "nope"))
        @test e isa PolycallError && e.status == POLYCALL_E_NOT_FOUND && occursin("operation.unknown", e.info)
        e = caught(() -> call(RPC, "inventory", "get", "{\"item_id\":\"nope\"}"))
        @test e isa PolycallError && e.status == POLYCALL_E_REMOTE && occursin("item.unknown", e.info)
        t0 = time()
        @test status_of(() -> call(RPC, "debug", "sleep", "{\"ms\":3000}"; timeout_ms = 300)) == POLYCALL_E_TIMEOUT
        @test time() - t0 < 2.9
        @test status_of(() -> call(RPC, "debug", "echo", "{bad")) == POLYCALL_E_INVALID_ARGUMENT
        @test status_of(() -> call(RPC, "debug", "echo"; timeout_ms = 0)) == POLYCALL_E_INVALID_ARGUMENT
        @test status_of(() -> call(RPC, "debug", "echo"; timeout_ms = 600001)) == POLYCALL_E_INVALID_ARGUMENT
        @test status_of(() -> call("no-port", "debug", "echo")) == POLYCALL_E_INVALID_ARGUMENT
        probe = Peer("jl-probe"); free = endpoint(probe); close(probe)
        @test status_of(() -> call(free, "debug", "echo"; timeout_ms = 2000)) == POLYCALL_E_TRANSPORT
    end
end

@testset "call (polycall daemon start / stop)" begin
    if CLI === nothing
        skip("daemon call", "polycall CLI not found")
    else
        ddir = joinpath(TMP, "daemon"); mkpath(ddir)
        pf = joinpath(ddir, "Polycallfile"); write(pf, "log_level=info\n")
        state = joinpath(ddir, "state")
        rc, out = run_cli("daemon", "start", "--endpoint", "127.0.0.1:0", "--state-dir", state, pf)
        println("  ", strip(out))
        @test rc == 0
        statefile = joinpath(state, "daemon.json")
        ep = isfile(statefile) ? jfield(read(statefile, String), "endpoint") : nothing
        try
            @test ep !== nothing && startswith(ep, "127.0.0.1:") && ep != "127.0.0.1:0"
            @test call(ep, "inventory", "get", "{\"item_id\":\"widget-a\"}") ==
                  "{\"item_id\":\"widget-a\",\"quantity\":42,\"in_stock\":true}"
            @test call(ep, "debug", "echo", "[1,\"$(utf8_text())\",null]") == "{\"echo\":[1,\"$(utf8_text())\",null]}"
            e = caught(() -> call(ep, "inventory", "nope"))
            @test e isa PolycallError && e.status == POLYCALL_E_NOT_FOUND && occursin("operation.unknown", e.info)
            e = caught(() -> call(ep, "inventory", "get", "{}"))
            @test e isa PolycallError && e.status == POLYCALL_E_REMOTE && occursin("input.invalid", e.info)
            @test status_of(() -> call(ep, "debug", "sleep", "{\"ms\":2000}"; timeout_ms = 300)) == POLYCALL_E_TIMEOUT
            @test status_of(() -> call(ep, "debug", "echo", "{bad")) == POLYCALL_E_INVALID_ARGUMENT
        finally
            rc, out = run_cli("daemon", "stop", "--state-dir", state, pf)
            println("  ", strip(out))
            @test rc == 0
        end
        # the daemon is gone: no runtime -> transport error
        @test ep === nothing || status_of(() -> call(ep, "debug", "echo"; timeout_ms = 2000)) == POLYCALL_E_TRANSPORT
    end
end

@testset "concurrent calls (8 tasks x 10 calls) each get their own result" begin
    if RPC === nothing
        skip("concurrent calls", "polycall CLI not found")
    else
        tasks = [Threads.@spawn [call(RPC, "debug", "echo", "{\"t\":$i,\"j\":$j}") for j in 1:10] for i in 1:8]
        results = fetch.(tasks)
        @test all(results[i][j] == "{\"echo\":{\"t\":$i,\"j\":$j}}" for i in 1:8 for j in 1:10)
    end
end

@testset "peer open: endpoint, node id, send-only, invalid arguments" begin
    p = Peer("jl-open")
    ep = endpoint(p)
    @test startswith(ep, "127.0.0.1:") && ep != "127.0.0.1:0"
    @test node_id(p) == "jl-open"
    @test occursin("\"node_id\":\"jl-open\"", health(p))
    @test isopen(p)
    close(p)
    @test !isopen(p)
    s = Peer("jl-sendonly"; bind = nothing)
    @test endpoint(s) == ""
    close(s)
    @test status_of(() -> Peer("bad id!")) == POLYCALL_E_INVALID_ARGUMENT
    @test status_of(() -> Peer("a"^64)) == POLYCALL_E_INVALID_ARGUMENT
    @test status_of(() -> Peer("x"; bind = "nonsense")) == POLYCALL_E_INVALID_ARGUMENT
    @test status_of(() -> Peer("x"; bind = "0.0.0.0:0")) == POLYCALL_E_CONFIG
end

@testset "two Julia nodes exchange payloads both ways (bytes, sender, id)" begin
    a = node("jl-alpha"); b = node("jl-beta")
    send(a, endpoint(b), "hello beta"; message_id = "m-a2b")
    @test recv(b; timeout_ms = 3000) == Message("jl-alpha", "m-a2b", Vector{UInt8}("hello beta"))
    send(b, endpoint(a), UInt8[0x68, 0x69]; message_id = "m-b2a")
    @test recv(a; timeout_ms = 3000) == Message("jl-beta", "m-b2a", UInt8[0x68, 0x69])
    send(a, endpoint(b), "auto")
    m = recv(b; timeout_ms = 3000)
    @test !isempty(m.message_id) && m.payload == Vector{UInt8}("auto")
    close(a); close(b)
end

@testset "payloads: empty, UTF-8, binary with NUL, 1 MiB exact, 1 MiB + 1" begin
    a = node("jl-sizes-a"); b = node("jl-sizes-b"); epb = endpoint(b)
    big = rand(UInt8, MIB)
    for (id, bytes) in [("m-empty", UInt8[]), ("m-utf8", Vector{UInt8}(utf8_text())),
                        ("m-bin", bytes_0_255()), ("m-nul", UInt8[0, 0, 1, 0]), ("m-max", big)]
        send(a, epb, bytes; message_id = id, timeout_ms = 10000)
        @test recv(b; timeout_ms = 10000) == Message("jl-sizes-a", id, bytes)
    end
    @test status_of(() -> send(a, epb, vcat(big, UInt8[7]); message_id = "m-over")) == POLYCALL_E_TOO_LARGE
    @test status_of(() -> recv(b; timeout_ms = 300)) == POLYCALL_E_TIMEOUT
    close(a); close(b)
end

@testset "registry ownership: per node, explicit, never implied by receiving" begin
    a = node("jl-reg-a"); b = node("jl-reg-b"); epb = endpoint(b)
    @test peers(a) == "{}"
    register!(a, "jl-reg-b", epb)
    @test peers(a) == "{\"jl-reg-b\":\"$epb\"}"
    @test peers(b) == "{}"
    send(a, "jl-reg-b", "by id"; message_id = "m-id")
    @test recv(b; timeout_ms = 3000) == Message("jl-reg-a", "m-id", Vector{UInt8}("by id"))
    @test peers(b) == "{}"                              # receiving never registers the sender
    @test ping(a, "jl-reg-b"; timeout_ms = 2000) === nothing
    register!(a, "impostor", epb)                        # answered under another identity
    @test status_of(() -> ping(a, "impostor"; timeout_ms = 2000)) == POLYCALL_E_PROTOCOL
    @test status_of(() -> send(a, "impostor", "x")) == POLYCALL_E_PROTOCOL
    status_of(() -> recv(b; timeout_ms = 500))           # it may have been stored: "not known to be delivered"
    unregister!(a, "impostor"); unregister!(a, "jl-reg-b")
    @test status_of(() -> unregister!(a, "jl-reg-b")) == POLYCALL_E_NOT_FOUND
    @test status_of(() -> send(a, "jl-reg-b", "x")) == POLYCALL_E_NOT_FOUND
    @test status_of(() -> register!(a, "bad id", epb)) == POLYCALL_E_INVALID_ARGUMENT
    @test peers(a) == "{}"
    close(a); close(b)
end

@testset "duplicate message id is delivered once" begin
    a = node("jl-dup-a"); b = node("jl-dup-b")
    send(a, endpoint(b), "once"; message_id = "m-dup")
    send(a, endpoint(b), "once"; message_id = "m-dup")
    @test recv(b; timeout_ms = 3000) == Message("jl-dup-a", "m-dup", Vector{UInt8}("once"))
    @test status_of(() -> recv(b; timeout_ms = 500)) == POLYCALL_E_TIMEOUT
    @test occursin("\"duplicates\":1", health(b))
    close(a); close(b)
end

@testset "auth failure: wrong or missing token is refused, nothing queued" begin
    b = node("jl-auth-b")
    wrong = Peer("jl-mallory"; token = "not-the-token")
    anon = Peer("jl-anon"; bind = nothing)
    @test status_of(() -> send(wrong, endpoint(b), "x")) == POLYCALL_E_AUTH
    @test status_of(() -> send(anon, endpoint(b), "x")) == POLYCALL_E_AUTH
    @test status_of(() -> recv(b; timeout_ms = 300)) == POLYCALL_E_TIMEOUT
    @test ping(anon, endpoint(b)) === nothing            # /health needs no token
    close(b); close(wrong); close(anon)
end

@testset "send to a dead peer -> transport" begin
    a = node("jl-live"); d = node("jl-dead"); epd = endpoint(d); close(d)
    @test status_of(() -> send(a, epd, "void"; timeout_ms = 2000)) == POLYCALL_E_TRANSPORT
    @test status_of(() -> ping(a, epd; timeout_ms = 1000)) == POLYCALL_E_TRANSPORT
    close(a)
end

@testset "receive timeout and poll" begin
    a = node("jl-timeout")
    t0 = time()
    @test status_of(() -> recv(a; timeout_ms = 250)) == POLYCALL_E_TIMEOUT
    @test 0.2 <= time() - t0 < 3.0
    @test status_of(() -> recv(a; timeout_ms = 0)) == POLYCALL_E_TIMEOUT
    close(a)
end

@testset "too-small buffer -> TOO_LARGE with size, message stays queued" begin
    a = node("jl-small-a"); b = node("jl-small-b")
    payload = Vector{UInt8}(repeat("0123456789", 10))
    send(a, endpoint(b), payload; message_id = "m-small")
    e = caught(() -> recv(b; timeout_ms = 3000, max_payload = 10))
    @test e isa PolycallError && e.status == POLYCALL_E_TOO_LARGE && e.info == 100
    @test recv(b; timeout_ms = 1000) == Message("jl-small-a", "m-small", payload)
    close(a); close(b)
end

@testset "integer boundaries: buffer sizes, lengths, ids, timeouts" begin
    a = node("jl-bound-a"); b = node("jl-bound-b"); epb = endpoint(b)
    # receive capacity: exactly the payload size fits, one byte less does not
    payload = rand(UInt8, 100)
    send(a, epb, payload; message_id = "m-b100")
    e = caught(() -> recv(b; timeout_ms = 3000, max_payload = 99))
    @test e isa PolycallError && e.status == POLYCALL_E_TOO_LARGE && e.info == 100
    @test recv(b; timeout_ms = 1000, max_payload = 100) == Message("jl-bound-a", "m-b100", payload)
    send(a, epb, UInt8[]; message_id = "m-b0")
    @test recv(b; timeout_ms = 3000, max_payload = 0) == Message("jl-bound-a", "m-b0", UInt8[])
    big = rand(UInt8, MIB)
    send(a, epb, big; message_id = "m-bmib", timeout_ms = 10000)
    e = caught(() -> recv(b; timeout_ms = 10000, max_payload = MIB - 1))
    @test e isa PolycallError && e.status == POLYCALL_E_TOO_LARGE && e.info == MIB
    @test recv(b; timeout_ms = 1000, max_payload = MIB) == Message("jl-bound-a", "m-bmib", big)
    # Julia-side range checks (before any library call)
    @test_throws ArgumentError recv(b; max_payload = MIB + 1)
    @test_throws ArgumentError recv(b; max_payload = -1)
    @test_throws ArgumentError recv(b; timeout_ms = -1)
    @test_throws ArgumentError recv(b; timeout_ms = NaN)
    @test_throws ArgumentError send(a, epb, "x"; timeout_ms = -5)
    # timeouts >= 2^32 - 1 are UINT32_MAX ("wait until a message"); a queued message returns at once
    send(a, epb, "max"; message_id = "m-bmax")
    @test recv(b; timeout_ms = typemax(UInt32)).message_id == "m-bmax"
    send(a, epb, "over"; message_id = "m-bover")
    @test recv(b; timeout_ms = Int64(typemax(UInt32)) + 10).message_id == "m-bover"
    # identifiers: 63 bytes accepted, 64 refused
    send(a, epb, "id"; message_id = "i"^63)
    @test recv(b; timeout_ms = 3000).message_id == "i"^63
    @test status_of(() -> send(a, epb, "id"; message_id = "i"^64)) == POLYCALL_E_INVALID_ARGUMENT
    p63 = Peer("n"^63; bind = nothing)
    @test node_id(p63) == "n"^63
    close(p63)
    # call: timeout_ms 1..600000 in the library, 0..2^32-1 in Julia
    if RPC !== nothing
        @test call(RPC, "debug", "echo", "1"; timeout_ms = 600000) == "{\"echo\":1}"
        @test status_of(() -> call(RPC, "debug", "echo"; timeout_ms = 600001)) == POLYCALL_E_INVALID_ARGUMENT
        @test_throws ArgumentError call(RPC, "debug", "echo"; timeout_ms = -1)
        @test_throws ArgumentError call(RPC, "debug", "echo"; timeout_ms = Int64(typemax(UInt32)) + 1)
    end
    close(a); close(b)
end

@testset "cancel and close wake a blocked recv (threads)" begin
    if Threads.nthreads() < 2
        skip("cancel/close wake", "needs JULIA_NUM_THREADS >= 2 (got $(Threads.nthreads()))")
    else
        a = node("jl-cancel")
        # wait forever (UINT32_MAX); the watchdog turns a missing wake-up into a failure, not a hang
        watchdog = Timer(_ -> close(a), 15)
        t = spawn_running(() -> status_of(() -> recv(a)))
        t0 = time(); cancel(a)
        @test fetch(t) == POLYCALL_E_CANCELLED
        close(watchdog)
        @test time() - t0 < 5
        @test status_of(() -> recv(a; timeout_ms = 100)) == POLYCALL_E_TIMEOUT   # later calls wait normally
        t = spawn_running(() -> status_of(() -> recv(a; timeout_ms = 10000)))
        t0 = time(); close(a)
        @test fetch(t) == POLYCALL_E_CLOSED
        @test time() - t0 < 5
    end
end

@testset "double close, use after close, invalid handles are defined" begin
    a = node("jl-closed"); epa = endpoint(a)
    close(a)
    @test status_of(() -> close(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> send(a, epa, "x")) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> recv(a; timeout_ms = 0)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> endpoint(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> node_id(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> peers(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> health(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> register!(a, "x", epa)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> cancel(a)) == POLYCALL_E_INVALID_HANDLE
    @test status_of(() -> ping(a, epa)) == POLYCALL_E_INVALID_HANDLE
    # forged handles (never issued, or zero) are refused, never a crash
    forged = node("jl-forge"); h = forged.handle
    close(forged)
    forged.handle = h + Int32(1 << 8)                     # same slot, other generation
    @test status_of(() -> endpoint(forged)) == POLYCALL_E_INVALID_HANDLE
    forged.handle = 0
    @test status_of(() -> close(forged)) == POLYCALL_E_INVALID_HANDLE
end

@testset "finalizer closes a garbage-collected peer" begin
    ep = unreferenced_peer_endpoint("jl-gc")
    probe = Peer("jl-gc-probe"; bind = nothing)
    closed = false
    for _ in 1:50
        GC.gc(true)
        if status_of(() -> ping(probe, ep; timeout_ms = 500)) == POLYCALL_E_TRANSPORT
            closed = true; break
        end
        sleep(0.1)
    end
    @test closed
    close(probe)
end

@testset "a finalizer never clobbers this thread's polycall_last_error" begin
    # Regression: the finalizer used to call polycall_peer_close inside GC, on
    # the allocating thread, which cleared the detail of a failure about to be
    # reported (seen as PolycallError with an empty detail under load).
    bad = joinpath(TMP, "detail-polycallrc"); write(bad, "max_connections=lots\n")
    ran = 0; intact = 0
    for i in 1:20
        unreferenced_peer_endpoint("jl-fin-$i")     # garbage with a finalizer
        before = JuliaPolycall.FINALIZED_PEERS[]
        st = run_config(bad)                         # fails: this thread now holds a detail
        GC.gc(true)                                  # finalizers run in here, on this thread
        detail = JuliaPolycall.last_error_detail()
        if JuliaPolycall.FINALIZED_PEERS[] > before
            ran += 1
            intact += (st == POLYCALL_E_CONFIG && occursin("max_connections", detail))
        end
    end
    println("  finalizer ran inside GC.gc in $ran of 20 rounds; detail intact in $intact")
    @test ran > 0
    @test intact == ran
end

@testset "unclosed peers are reclaimed: 300 dropped nodes never exhaust the 255-node limit" begin
    opened = 0
    for i in 1:300
        Peer("jl-leak-$i"; bind = nothing)           # never closed
        opened += 1
    end
    @test opened == 300
    p = Peer("jl-after-leak")
    @test isopen(p) && startswith(endpoint(p), "127.0.0.1:")
    close(p)
end

@testset "concurrent senders (8 tasks x 25 messages) all delivered once" begin
    b = node("jl-conc-b"); epb = endpoint(b)
    nsend, per = 8, 25
    tasks = [Threads.@spawn begin
                 s = Peer("jl-conc-$i"; bind = nothing, token = TOKEN)
                 for j in 1:per
                     send(s, epb, string(i, ":", j); message_id = "c$i-$j")
                 end
                 close(s)
             end for i in 1:nsend]
    foreach(wait, tasks)
    got = Set{Tuple{String, String, String}}()
    for _ in 1:(nsend * per)
        m = recv(b; timeout_ms = 5000)
        push!(got, (m.sender, m.message_id, String(m.payload)))
    end
    @test status_of(() -> recv(b; timeout_ms = 200)) == POLYCALL_E_TIMEOUT
    @test got == Set(("jl-conc-$i", "c$i-$j", "$i:$j") for i in 1:nsend for j in 1:per)
    println("  concurrent senders ran on ", Threads.nthreads(), " thread(s)")
    close(b)
end

@testset "a blocked recv does not stall GC on other threads (gc_safe ccall)" begin
    if Threads.nthreads() < 2
        skip("gc_safe recv", "needs JULIA_NUM_THREADS >= 2 (got $(Threads.nthreads()))")
    elseif VERSION < v"1.12"
        skip("gc_safe recv", "gc_safe ccall needs Julia >= 1.12 (running $(VERSION))")
    else
        a = node("jl-gcsafe")
        t = spawn_running(() -> status_of(() -> recv(a; timeout_ms = 3000)))
        t0 = time(); GC.gc(true); dt = time() - t0
        println("  full GC while another thread blocks in recv: $(round(dt; digits = 3)) s")
        @test dt < 1.5
        @test fetch(t) == POLYCALL_E_TIMEOUT
        close(a)
    end
end

@testset "interop: Julia peer <-> C CLI node (polycall peer serve/send/recv)" begin
    if CLI_NODE === nothing
        skip("interop CLI", "polycall CLI not found")
    else
        a = node("jl-interop")
        for (id, bytes) in [("x-j2c-text", Vector{UInt8}("hello C node")),
                            ("x-j2c-utf8", Vector{UInt8}(utf8_text())),
                            ("x-j2c-bin", bytes_0_255()), ("x-j2c-empty", UInt8[])]
            send(a, CLI_NODE, bytes; message_id = id)
            rc, out = run_cli("peer", "recv", "--to", CLI_NODE, "-t", "5000")
            @test rc == 0
            @test jfield(out, "from") == "jl-interop" && jfield(out, "id") == id
            @test b64decode(something(jfield(out, "payload_b64"), "!")) == bytes
        end
        binfile = joinpath(TMP, "bin.in"); write(binfile, bytes_0_255())
        rc, _ = run_cli("peer", "send", "--from", "cli-node", "--to", endpoint(a), "--id", "x-c2j-text",
                        "--payload", "hello Julia")
        @test rc == 0
        @test recv(a; timeout_ms = 3000) == Message("cli-node", "x-c2j-text", Vector{UInt8}("hello Julia"))
        rc, _ = run_cli("peer", "send", "--from", "cli-node", "--to", endpoint(a), "--id", "x-c2j-bin",
                        "--payload-file", binfile)
        @test rc == 0
        @test recv(a; timeout_ms = 3000) == Message("cli-node", "x-c2j-bin", bytes_0_255())
        rc, out = run_cli("peer", "health", "--to", endpoint(a))
        @test rc == 0 && occursin("\"node_id\":\"jl-interop\"", out)
        @test ping(a, CLI_NODE) === nothing
        close(a)
    end
end

end # testset
finally
    foreach(kill, PROCS)
    isempty(SKIPPED) || println("SKIPPED checks ($(length(SKIPPED))): ", join(SKIPPED, "; "))
end
