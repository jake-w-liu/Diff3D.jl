using Test
using Diff3D
using ForwardDiff
import LinearAlgebra

@testset "Subnormal normalization preserves direction" begin
    for T in (Float16, Float32, Float64), scale in (nextfloat(zero(T)), T(8) * nextfloat(zero(T)),
                                         floatmin(T), one(T), floatmax(T) / T(8))
        input = Vec3(T(1) * scale, T(-2) * scale, T(3) * scale)
        expected = normalize(Vec3(T(1), T(-2), T(3)))
        actual = normalize(input)
        @test [actual.x, actual.y, actual.z] ≈ [expected.x, expected.y, expected.z] rtol=4eps(T)
        @test norm(actual) ≈ one(T) rtol=4eps(T)

        q = quat_normalize(Quaternion(scale, -2scale, 3scale, zero(T)))
        @test [q.x, q.y, q.z, q.w] ≈ [expected.x, expected.y, expected.z, zero(T)] rtol=4eps(T)
        matrix = quat_to_mat4(q)
        rotation = [mat4_get(matrix, i, j) for i in 1:3, j in 1:3]
        @test rotation * transpose(rotation) ≈ Matrix{T}(LinearAlgebra.I, 3, 3) atol=16eps(T)

        plane = Diff3D._make_plane(scale, -2scale, 3scale, 2scale)
        @test [plane.normal.x, plane.normal.y, plane.normal.z] ≈
              [expected.x, expected.y, expected.z] rtol=4eps(T)
        @test plane.constant ≈ T(2) / sqrt(T(14)) rtol=4eps(T)
    end
    @test normalize(Vec3()) == Vec3()
    @test quat_normalize(Quaternion(0.0, 0.0, 0.0, 0.0)) == Quaternion(0.0, 0.0, 0.0, 1.0)
    @test Diff3D._make_plane(0.0, 0.0, 0.0, 2.0) == Plane(Vec3(), 2.0)

    for scale in (big"1e-400", big"1", big"1e400")
        input = Vec3(scale, 2scale, 3scale)
        expected = setprecision(BigFloat, 512) do
            components = BigFloat.([input.x, input.y, input.z])
            components / sqrt(sum(abs2, components))
        end
        actual = normalize(input)
        @test [actual.x, actual.y, actual.z] ≈ expected rtol=8eps(BigFloat)
        q = quat_normalize(Quaternion(scale, 2scale, 3scale, zero(scale)))
        @test q.x ≈ inv(sqrt(big"14"))
        plane = Diff3D._make_plane(scale, 2scale, 3scale, 4scale)
        @test plane.constant ≈ 4 / sqrt(big"14")
    end

    function normalized_components(values)
        n = normalize(Vec3(values...))
        [n.x, n.y, n.z]
    end
    values = [1.0, -2.0, 3.0]
    length = sqrt(sum(abs2, values))
    n = values / length
    expected_jacobian = (Matrix{Float64}(LinearAlgebra.I, 3, 3) - n * transpose(n)) / length
    @test ForwardDiff.jacobian(normalized_components, values) ≈ expected_jacobian
    @test reverse_gradient(v -> normalize(Vec3(v...)).x, values) ≈ expected_jacobian[1, :]
end
