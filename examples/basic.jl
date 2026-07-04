using JuliaPolycall

config_path = isempty(ARGS) ? DEFAULT_CONFIG : ARGS[1]
run_config_or_throw(config_path)
println("libpolycall completed '$config_path' successfully")
