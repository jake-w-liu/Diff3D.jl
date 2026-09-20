module Diff3DTestRunner

using SHA
using TOML

function options(arguments)
    shard, shards, listing, report, require_optimized = 1, 1, false, nothing, false
    seen = Set{String}()
    for argument in arguments
        key = first(split(argument, '='; limit=2))
        key in seen && throw(ArgumentError("duplicate option: $key"))
        push!(seen, key)
        if startswith(argument, "--shard=")
            parts = split(argument[9:end], '/')
            length(parts) == 2 || throw(ArgumentError("shard must be I/N"))
            values = tryparse.(Int, parts)
            all(value -> value !== nothing, values) || throw(ArgumentError("shard must be I/N"))
            shard, shards = values
            1 <= shard <= shards || throw(ArgumentError("shard must satisfy 1 ≤ I ≤ N"))
        elseif argument == "--list"
            listing = true
        elseif argument == "--require-optimized"
            require_optimized = true
        elseif startswith(argument, "--report=")
            report = argument[10:end]
            isempty(report) && throw(ArgumentError("report path must not be empty"))
        else
            throw(ArgumentError("unknown test option: $argument"))
        end
    end
    return (; shard, shards, listing, report, require_optimized)
end

function contains_test_work(expression)
    expression isa Expr || return false
    expression.head in (:function, :macro, :quote) && return false
    if expression.head == :macrocall
        startswith(string(expression.args[1]), "@test") && return true
    elseif expression.head == :call && expression.args[1] == :include
        return true
    end
    return any(contains_test_work, expression.args)
end

function unit_name(expression)
    expression isa Expr || return nothing
    if expression.head == :macrocall && expression.args[1] == Symbol("@testset")
        return string(expression.args[3])
    elseif expression.head == :call && expression.args[1] == :include
        length(expression.args) == 2 && expression.args[2] isa String ||
            throw(ArgumentError("test includes must use a literal relative path"))
        return "include: " * expression.args[2]
    end
    contains_test_work(expression) &&
        throw(ArgumentError("test work must be a top-level @testset or include"))
    return nothing
end

function inventory(source)
    units = NamedTuple{(:id, :name, :line),Tuple{Int,String,Int}}[]
    line = 1
    for expression in Meta.parseall(source).args
        if expression isa LineNumberNode
            line = expression.line
        else
            name = unit_name(expression)
            name === nothing || push!(units, (; id=length(units)+1, name, line))
        end
    end
    isempty(units) && throw(ArgumentError("test suite has no test units"))
    return units
end

function selected_units(units, shard, shards)
    1 <= shard <= shards <= length(units) ||
        throw(ArgumentError("shard count must not exceed the number of test units"))
    return filter(unit -> mod(unit.id - 1, shards) == shard - 1, units)
end

function run_tests(target::Module, arguments; suite=joinpath(@__DIR__, "suite.jl"))
    config = options(arguments)
    source = read(suite, String)
    units = inventory(source)
    selected = selected_units(units, config.shard, config.shards)
    optimized = Base.JLOptions().opt_level > 0 &&
        Base.JLOptions().compile_enabled in (1, 2) &&
        get(ENV, "DIFF3D_ALLOC_ASSERTIONS", "1") != "0"
    config.require_optimized && !optimized &&
        error("release tests require optimization, compiled execution and allocation assertions")
    if config.listing
        foreach(unit -> println(unit.id, '\t', unit.line, '\t', unit.name), selected)
        return nothing
    end
    report = Dict{String,Any}(
        "status" => "failed", "shard" => config.shard, "shards" => config.shards,
        "suite_sha256" => bytes2hex(sha256(source)), "revision" => get(ENV, "GITHUB_SHA", "local"),
        "julia" => string(VERSION), "os" => string(Sys.KERNEL), "arch" => string(Sys.ARCH),
        "threads" => Threads.nthreads(), "opt_level" => Int(Base.JLOptions().opt_level),
        "compile_enabled" => Int(Base.JLOptions().compile_enabled),
        "allocation_assertions" => false, "all_units" => getproperty.(units, :name),
        "unit_ids" => getproperty.(selected, :id), "encountered_units" => 0,
    )
    started = time()
    count = 0
    select_expression = function (expression)
        name = unit_name(expression)
        name === nothing && return expression
        count += 1
        count <= length(units) && units[count].name == name ||
            error("test source changed after inventory")
        report["encountered_units"] = count
        mod(count - 1, config.shards) == config.shard - 1 || return nothing
        println(stderr, "DIFF3D_TEST_UNIT ", count, '/', length(units), ' ', name)
        flush(stderr)
        return expression
    end
    try
        Base.include(select_expression, target, suite)
        count == length(units) || error("test unit inventory was not fully encountered")
        read(suite, String) == source || error("test source changed during execution")
        report["allocation_assertions"] =
            Base.invokelatest(isdefined, target, :DIFF3D_ALLOC_ASSERTIONS_ENABLED) &&
            Base.invokelatest(getfield, target, :DIFF3D_ALLOC_ASSERTIONS_ENABLED)
        config.require_optimized && !report["allocation_assertions"] &&
            error("suite did not enable allocation assertions")
        report["status"] = "passed"
    finally
        report["seconds"] = time() - started
        if config.report !== nothing
            mkpath(dirname(abspath(config.report)))
            open(config.report, "w") do io
                TOML.print(io, report; sorted=true)
            end
        end
    end
    return report
end

end
