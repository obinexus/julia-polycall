# julia --project=. examples/basic.jl [config-path]
using JuliaPolycall

println("polycall ", JuliaPolycall.version(), " (binding ABI ", abi_version(), ") from ", library_path())

config_path = isempty(ARGS) ? DEFAULT_CONFIG : ARGS[1]
run_config_or_throw(config_path)            # strict: valid for running with this build
println("'$config_path' is valid")

a = Peer("example-a")
b = Peer("example-b")
send(a, endpoint(b), "hello from Julia"; message_id = "example-1")
m = recv(b; timeout_ms = 5000)
println(m.sender, " -> ", endpoint(b), ": ", String(m.payload), " (", m.message_id, ")")
close(a); close(b)
