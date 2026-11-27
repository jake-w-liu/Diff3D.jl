using Test, Diff3D, ForwardDiff

# Round-2 regression tests for the camera-math-features package. Expected
# values come from three.js r186 (0.186.0) executed under node, or from the
# derivation noted next to each expectation.

_b3_close(a, b; atol=4e-16) = all(isapprox.(a, b; atol=atol, rtol=0))
_b3_mat(m::Mat4) = m.e

@testset "audit3b: interpolate_linear endpoints keep the interior type" begin
    # Clamped endpoints must return the same type as an interior evaluation;
    # integer and Float32 samples promote with the Float64 query weight.
    times = [0.0, 1.0, 2.0]
    for values in ([1, 3, 7], Float32[1, 3, 7])
        for t in (-1.0, 0.0, 0.5, 2.0, 3.0)
            result = @inferred interpolate_linear(times, values, t)
            @test result isa Float64
        end
        @test interpolate_linear(times, values, -1.0) === 1.0
        @test interpolate_linear(times, values, 3.0) === 7.0
        @test interpolate_linear(times, values, 1.5) === 5.0
    end
    vectors = [Vec3(1, 2, 3), Vec3(3, 4, 5)]
    @test (@inferred interpolate_linear([0.0, 1.0], vectors, -2.0)) ===
          Vec3(1.0, 2.0, 3.0)
    @test (@inferred interpolate_linear([0.0, 1.0], vectors, 0.5)) ===
          Vec3(2.0, 3.0, 4.0)
    @test (@inferred interpolate_linear([0, 1], [1, 3], 2)) === 3.0
    # A ForwardDiff query time clamped at an endpoint has zero derivative and
    # keeps the Dual type of interior evaluations.
    derivative(t) = ForwardDiff.derivative(x -> interpolate_linear(times, [1.0, 3.0, 7.0], x), t)
    @test derivative(-1.0) == 0.0
    @test derivative(0.5) == 2.0
    @test derivative(5.0) == 0.0
end
