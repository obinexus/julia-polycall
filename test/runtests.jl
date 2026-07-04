using Test
using JuliaPolycall

@testset "JuliaPolycall" begin
    @test run_config("julia-polycallrc") == 0
    @test run_config() == 0
    @test run_config("__status_37__") == 37

    captured = try
        run_config_or_throw("__status_37__")
        nothing
    catch error
        error
    end

    @test captured isa PolycallError
    @test captured.status == 37
    @test captured.config_path == "__status_37__"
end

println("julia-polycall Julia/ccall smoke test: PASS")
