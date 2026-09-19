using Test, Diff3D

@testset "Central differences avoid intermediate overflow" begin
    identity_objective(p) = p[1]
    for step in (1e-5, nextfloat(0.0), 1e308, floatmax(Float64), typemax(Int)),
        sign in (-1, 1)
        @test numerical_gradient(identity_objective, [0.0]; δ=sign * step) == [1.0]
    end
    for slope in (floatmax(Float64), -floatmax(Float64))
        @test numerical_gradient(p -> slope * p[1], [0.0]; δ=1.0) == [slope]
    end
    @test numerical_gradient(p -> 1e-308 * p[1], [0.0]; δ=1e308)[1] ≈ 1e-308 rtol=1e-14 atol=0.0

    narrow_slope = Float64(nextfloat(0.0f0)) / Float64(floatmax(Float32))
    @test numerical_gradient(p -> Float32(narrow_slope * p[1]), [0.0];
                             δ=floatmax(Float32))[1] ≈ narrow_slope rtol=1e-14 atol=0.0
    @test numerical_gradient(p -> BigFloat(p[1]), [0.0]; δ=1e308) == [1.0]

    # A finite integer difference must be formed before widening its large offset.
    integer_offset(p) = 2^precision(Float64) + (p[1] > 0.0 ? 1 : -1)
    @test numerical_gradient(integer_offset, [0.0]; δ=1e308)[1] ≈ 1e-308 rtol=1e-14 atol=0.0
    for T in (Int8, Int, Int128, UInt64, UInt128)
        objective(p) = p[1] > 0.0 ? typemin(T) : typemax(T)
        expected = Float64((big(typemin(T)) - big(typemax(T))) / 2)
        @test numerical_gradient(objective, [0.0]; δ=1.0) == [expected]
    end
    setprecision(BigFloat, 2048) do
        offset = BigFloat("1e400")
        @test numerical_gradient(p -> offset + BigFloat(p[1]), [0.0]; δ=1.0) == [1.0]
    end

    @test isnan(only(numerical_gradient(_ -> Inf, [0.0])))
    @test isnan(only(numerical_gradient(_ -> NaN, [0.0])))
    @test isempty(numerical_gradient(identity_objective, Float64[]))
    for step in (0.0, Inf, NaN, true)
        @test_throws ArgumentError numerical_gradient(identity_objective, [0.0]; δ=step)
    end
end

function numerical_range_allocations(parameters)
    objective(values) = sum(abs2, values)
    numerical_gradient(objective, parameters)
    return @allocated numerical_gradient(objective, parameters)
end

@testset "Central differences retain their workspace budget" begin
    if Base.JLOptions().opt_level > 0
        # Preserve the existing 64-parameter numerical_gradient budget.
        parameters = collect(range(0.1, 1.0; length=64))
        numerical_range_allocations(parameters)
        @test numerical_range_allocations(parameters) <= 1536
    end
end
