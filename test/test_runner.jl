using Test
using TOML
include("runner.jl")

@testset "Complete test shard partition" begin
    source = read(joinpath(@__DIR__, "suite.jl"), String)
    units = Diff3DTestRunner.inventory(source)
    @test any(unit -> startswith(unit.name, "include: "), units)
    @test any(unit -> !startswith(unit.name, "include: "), units)
    for count in (1, 2, 6, length(units))
        groups = [Diff3DTestRunner.selected_units(units, shard, count) for shard in 1:count]
        ids = [unit.id for group in groups for unit in group]
        @test sort(ids) == collect(1:length(units))
        @test length(unique(ids)) == length(ids)
        @test all(!isempty, groups)
    end
    @test_throws ArgumentError Diff3DTestRunner.selected_units(units, 1, length(units)+1)
    for argument in ("--shard=0/6", "--shard=7/6", "--shard=1/0", "--shard=a/6",
                     "--shard=1", "--shard=99999999999999999999999/6", "--report=", "--unknown")
        @test_throws ArgumentError Diff3DTestRunner.options([argument])
    end
    @test_throws ArgumentError Diff3DTestRunner.options(["--list", "--list"])
    @test_throws ArgumentError Diff3DTestRunner.inventory("using Test\n@test true")
    @test_throws ArgumentError Diff3DTestRunner.inventory("using Test\nif true\n@testset \"hidden\" begin end\nend")
    @test_throws ArgumentError Diff3DTestRunner.inventory("include(ARGS[1])")
end

@testset "Julia include mapping and shared declarations" begin
    mktempdir() do directory
        suite = joinpath(directory, "suite.jl")
        write(suite, """
            using Test
            const visits = Int[]
            twice(value) = 2value
            @testset "first" begin
                push!(visits, 1)
                @test twice(3) == 6
            end
            include("included.jl")
            later(value) = value + 3
            @testset "third" begin
                push!(visits, 3)
                @test later(twice(3)) == 9
            end
            """)
        write(joinpath(directory, "included.jl"), """
            @testset "included" begin
                push!(visits, 2)
                @test twice(4) == 8
            end
            """)
        for (shard, expected) in ((1, [1, 3]), (2, [2]))
            target = Core.eval(Main, Expr(:module, true, gensym(:ShardFixture), Expr(:block)))
            report_path = joinpath(directory, "report-$shard.toml")
            result = Diff3DTestRunner.run_tests(target,
                ["--shard=$shard/2", "--report=$report_path"]; suite)
            @test Base.invokelatest(getfield, target, :visits) == expected
            @test result["status"] == "passed"
            @test result["unit_ids"] == expected
            @test result["encountered_units"] == 3
            @test TOML.parsefile(report_path) == result
        end

        # A fresh process has the same top-level Test failure handling as Pkg.test.
        completed = joinpath(directory, "later-unit.txt")
        write(suite, """
            using Test
            @testset "intentional failure" begin
                @test false
            end
            @testset "later test still runs" begin
                write($(repr(completed)), "completed")
                @test true
            end
            """)
        report_path = joinpath(directory, "failed.toml")
        runner = joinpath(@__DIR__, "runner.jl")
        script = "include(ARGS[1]); Diff3DTestRunner.run_tests(Main, [\"--report=\" * ARGS[3]]; suite=ARGS[2])"
        command = `$(Base.julia_cmd()) --startup-file=no -e $script $runner $suite $report_path`
        @test !success(pipeline(command; stdout=devnull, stderr=devnull))
        @test TOML.parsefile(report_path)["status"] == "failed"
        @test TOML.parsefile(report_path)["encountered_units"] == 2
        @test read(completed, String) == "completed"
    end
end
