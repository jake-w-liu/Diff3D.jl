using Test
using Diff3D

@testset "Area-weighted normals across geometry scales" begin
    function reference_normals(geometry)
        setprecision(BigFloat, 256) do
            sums = zeros(BigFloat, 3, geometry.n_vertices)
            points = reshape(BigFloat.(geometry.positions), 3, geometry.n_vertices)
            for face in 1:geometry.n_faces
                a, b, c = get_face(geometry, face)
                u = points[:, b] - points[:, a]
                v = points[:, c] - points[:, a]
                area = [u[2] * v[3] - u[3] * v[2],
                        u[3] * v[1] - u[1] * v[3],
                        u[1] * v[2] - u[2] * v[1]]
                for vertex in (a, b, c)
                    sums[:, vertex] += area
                end
            end
            for vertex in 1:geometry.n_vertices
                length = sqrt(sum(abs2, sums[:, vertex]))
                if iszero(length)
                    sums[:, vertex] .= (0, 0, 1)
                else
                    sums[:, vertex] /= length
                end
            end
            return vec(Float64.(sums))
        end
    end

    positions = [0.0, 0.0, 0.0, 0.0, 2.0, 0.0,
                 0.0, 0.0, 1.0, 3.0, 0.0, 0.0]
    for scale in (nextfloat(0.0), 1e-200, 1e-160, 1e-12, 1e-5,
                  1.0, -2.0, 1e150, 1e200, 1e307)
        geometry = BufferGeometry(positions .* scale, Float64[], Float64[],
                                  [1, 2, 3, 1, 3, 4], 4, 2)
        expected = reference_normals(geometry)
        original = copy(geometry.positions)
        compute_vertex_normals!(geometry)
        @test geometry.normals ≈ expected rtol=2e-14
        @test geometry.positions == original
        @test all(i -> norm(get_normal(geometry, i)) ≈ 1.0, 1:4)
        buffer = geometry.normals
        compute_vertex_normals!(geometry)
        @test geometry.normals === buffer
        @test geometry.normals ≈ expected rtol=2e-14
    end

    # Separate components of the same mesh require independent exponent ranges.
    mixed = BufferGeometry(vcat(positions .* 1e-200, positions .* 1e200),
                           Float64[], Float64[],
                           [1, 2, 3, 1, 3, 4, 5, 6, 7, 5, 7, 8], 8, 4)
    expected = reference_normals(mixed)
    compute_vertex_normals!(mixed)
    @test mixed.normals ≈ expected rtol=2e-14

    scale = sqrt(1.5e308)
    overflowing_length = BufferGeometry(
        [0.0, 0.0, 0.0, 0.0, scale, -scale, -scale, scale, 0.0],
        Float64[], Float64[], [1, 2, 3], 3, 1)
    expected = reference_normals(overflowing_length)
    compute_vertex_normals!(overflowing_length)
    @test overflowing_length.normals ≈ expected rtol=2e-14

    for scale in (1e-200, 1e-160, 1e-12, 1.0, 1e200), slices in (1, 3)
        geometry = ParametricGeometry((u, v) -> Vec3(0.0, scale * u, scale * v),
                                      slices, 2)
        @test all(i -> get_normal(geometry, i) == Vec3(1.0, 0.0, 0.0),
                  1:geometry.n_vertices)
        slanted = ParametricGeometry((u, v) -> Vec3(scale * u, scale * v,
                                                   scale * (u + v)), slices, 2)
        @test slanted.normals ≈ reference_normals(slanted) rtol=2e-14
    end

    empty_geometry = BufferGeometry()
    @test compute_vertex_normals!(empty_geometry) === empty_geometry
    @test isempty(empty_geometry.normals)
    for indices in ([1, 2, 3], [1, 2, 3, 1, 3, 2])
        geometry = BufferGeometry([0.0, 0.0, 0.0, 1.0, 1.0, 1.0,
                                   2.0, 2.0, 2.0], Float64[], Float64[],
                                   indices, 3, length(indices) ÷ 3)
        compute_vertex_normals!(geometry)
        @test geometry.normals == repeat([0.0, 0.0, 1.0], 3)
    end
    flat = ParametricGeometry((u, v) -> Vec3(u, 0.0, 0.0), 2, 2)
    @test all(iszero, flat.normals)
end
