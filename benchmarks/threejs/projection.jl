using Diff3D
using ForwardDiff
using SHA
using Statistics
using TOML

struct ProjectionObjective
    x::Vector{Float64}
    y::Vector{Float64}
    target_x::Vector{Float64}
    target_y::Vector{Float64}
    matrix::Mat4{Float64}
end

function (problem::ProjectionObjective)(parameters::AbstractVector{T}) where {T}
    length(parameters) == length(problem.x) || throw(DimensionMismatch("point parameter count"))
    total = zero(T)
    @inbounds for i in eachindex(parameters)
        projected = mat4_transform_point(problem.matrix, Vec3(problem.x[i], problem.y[i], parameters[i]))
        total += (projected.x - problem.target_x[i])^2 + (projected.y - problem.target_y[i])^2
    end
    return total / (2length(parameters))
end

projection_reverse(objective, parameters) = reverse_gradient(objective, parameters)
projection_forward(objective, parameters) = ForwardDiff.gradient(objective, parameters)
projection_finite(objective, parameters) = numerical_gradient(objective, parameters; δ=1e-5)
gradient_allocated(operation::F, objective, parameters) where {F} = @allocated operation(objective, parameters)

function check_projection_gradient(name, gradient, reference)
    length(gradient) == length(reference) || error("$name gradient length mismatch")
    error_value = maximum(abs(actual - expected) for (actual, expected) in zip(gradient, reference))
    isfinite(error_value) && error_value < 1e-9 ||
        error("$name gradient oracle failed: $error_value")
    return error_value
end

function measure_projection(name, operation::F, case, matrix, samples, warmup) where {F}
    count = Int(case["count"])
    count > 0 || error("positive point count required")
    fields = ("x", "y", "parameters", "target_x", "target_y", "expected_gradient", "truth")
    all(length(case[field]) == count for field in fields) || error("invalid fixture lengths")
    all(all(isfinite, case[field]) for field in fields) && isfinite(case["expected_loss"]) ||
        error("projection fixture values must be finite")
    problem = ProjectionObjective(case["x"], case["y"], case["target_x"], case["target_y"], matrix)
    parameters = Vector{Float64}(case["parameters"])
    loss = problem(parameters)
    isapprox(loss, case["expected_loss"]; atol=1e-15, rtol=1e-12) || error("projection value oracle failed")
    started = time_ns()
    result = operation(problem, parameters)
    first_ns = Int(time_ns() - started)
    gradient_error = check_projection_gradient(name, result, case["expected_gradient"])
    for _ in 1:warmup
        check_projection_gradient(name, operation(problem, parameters), case["expected_gradient"])
    end
    gradient_allocated(operation, problem, parameters)
    allocated = gradient_allocated(operation, problem, parameters)
    GC.gc()
    timings = Vector{Int}(undef, samples)
    timed_gradient_error = 0.0
    for i in eachindex(timings)
        started = time_ns()
        measured_gradient = operation(problem, parameters)
        timings[i] = Int(time_ns() - started)
        # Consume the complete timed result, with validation outside its clock.
        timed_gradient_error = max(timed_gradient_error,
            check_projection_gradient(name, measured_gradient, case["expected_gradient"]))
    end
    evaluations = Ref(0)
    counted(p) = (evaluations[] += 1; problem(p))
    operation(counted, parameters)
    record = Dict{String,Any}("method" => name, "count" => count, "loss" => loss,
        "gradient" => result, "gradient_max_error" => gradient_error,
        "timed_gradient_max_error" => timed_gradient_error,
        "objective_evaluations" => evaluations[], "first_invocation_ns" => first_ns,
        "samples_ns" => timings, "allocated_bytes" => allocated)

    if count == 16
        fitted = copy(parameters)
        for _ in 1:1000
            gradient = operation(problem, fitted)
            fitted .= clamp.(fitted .- (8count) .* gradient, -5.0, -1.0)
        end
        parameter_error = maximum(abs.(fitted .- case["truth"]))
        parameter_error < 1e-6 || error("$name parameter recovery failed: $parameter_error")
        record["recovered_parameter_max_error"] = parameter_error
        record["fitted_loss"] = problem(fitted)
    end
    println("PROJECTION_OK ", name, " n=", count, " median_ns=", median(timings),
            " allocated_bytes=", allocated, " gradient_error=", gradient_error)
    flush(stdout)
    return record
end

function main(arguments)
    length(arguments) == 2 || error("usage: projection.jl FIXTURE_TOML OUTPUT_TOML")
    fixture = TOML.parsefile(arguments[1])
    fixture["schema"] == 1 || error("unsupported projection fixture schema")
    fixture["samples"] > 0 && fixture["warmup"] > 0 || error("positive sample/warmup counts required")
    length(fixture["matrix"]) == 16 || error("projection matrix must have 16 entries")
    all(isfinite, fixture["matrix"]) && !isempty(fixture["cases"]) || error("finite matrix and nonempty cases required")
    matrix = Mat4(Tuple(Float64.(fixture["matrix"])))
    repository = normpath(joinpath(@__DIR__, "..", ".."))
    realpath(pkgdir(Diff3D)) == realpath(repository) ||
        error("comparison must load Diff3D from the recorded checkout")
    report = Dict{String,Any}("status" => "failed", "julia" => string(VERSION),
        "diff3d_version" => string(pkgversion(Diff3D)),
        "forwarddiff_version" => string(pkgversion(ForwardDiff)),
        "package_source" => realpath(pkgdir(Diff3D)),
        "os" => string(Sys.KERNEL), "arch" => string(Sys.ARCH), "cpu" => Sys.CPU_NAME,
        "threads" => Threads.nthreads(), "fixture_sha256" => bytes2hex(sha256(read(arguments[1]))),
        "revision" => strip(read(`git -C $repository rev-parse HEAD`, String)),
        "dirty" => !isempty(read(`git -C $repository status --porcelain`, String)),
        "opt_level" => Int(Base.JLOptions().opt_level), "results" => Any[])
    report["opt_level"] > 0 && Base.JLOptions().compile_enabled in (1, 2) ||
        error("comparison requires normal optimized Julia compilation")
    mkpath(dirname(abspath(arguments[2])))
    try
        for case in fixture["cases"]
            for (name, operation) in (("reverse_ad", projection_reverse),
                                      ("forward_ad", projection_forward),
                                      ("central_difference", projection_finite))
                push!(report["results"], measure_projection(name, operation, case, matrix,
                    fixture["samples"], fixture["warmup"]))
            end
        end
        report["status"] = "passed"
    finally
        open(arguments[2], "w") do io
            TOML.print(io, report; sorted=true)
        end
    end
end

main(ARGS)
