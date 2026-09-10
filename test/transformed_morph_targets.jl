using Test
using Diff3D

@testset "Affine geometry baking preserves morph deformation" begin
    geometry = PlaneGeometry()
    geometry.normals .= repeat([0.0, 0.0, 2.0], geometry.n_vertices)
    set_attribute!(geometry, :tangent, repeat([2.0, 0.0, 0.0, -1.0, 7.0], geometry.n_vertices), 5)
    set_attribute!(geometry, :morphPosition0, repeat([0.3, 0.1, 0.2], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphPosition1, repeat([-0.2, 0.4, 0.1], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphNormal0, repeat([0.5, 0.2, -0.1], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphNormal1, repeat([-0.1, 0.4, 0.2], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphTangent0, repeat([0.1, 0.6, 0.2], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphTangent1, repeat([0.2, -0.3, 0.1], geometry.n_vertices), 3)
    original = deepcopy(geometry)
    matrices = (Mat4(), mat4_translation(2.0, -1.0, 3.0),
                mat4_rotation_z(pi/2),
                mat4_rotation_y(0.4) * mat4_scaling(2.0, 0.5, 3.0),
                mat4_scaling(-2.0, 1.0, 0.5))
    for matrix in matrices, homogeneous_scale in (1.0, 2.0, -1.0)
        homogeneous = Mat4{Float64}(map(x -> x * homogeneous_scale, matrix.e))
        transformed = transform_geometry(geometry, homogeneous)
        normal_matrix = mat4_transpose(mat4_inverse(matrix))
        for weights in ([0.0, 0.0], [0.25, 0.5], [1.0, 0.0], [-0.2, 0.7])
            actual_positions = apply_morph_targets(transformed, weights)
            expected_positions = [mat4_transform_point(matrix, p) for p in apply_morph_targets(geometry, weights)]
            @test all(norm(a-b) <= 1e-12 for (a,b) in zip(actual_positions, expected_positions))
            original_normals = apply_morph_normals(geometry, weights)
            actual_normals = apply_morph_normals(transformed, weights)
            original_tangents = apply_morph_tangents(geometry, weights)
            actual_tangents = apply_morph_tangents(transformed, weights)
            for vertex in 1:geometry.n_vertices
                nbase, tbase = 3vertex-2, 5vertex-4
                n = normalize(mat4_transform_direction(normal_matrix, Vec3(original_normals[nbase:nbase+2]...)))
                t = normalize(mat4_transform_direction(matrix, Vec3(original_tangents[tbase:tbase+2]...)))
                @test actual_normals[nbase:nbase+2] ≈ [n.x,n.y,n.z] atol=1e-12
                @test actual_tangents[tbase:tbase+2] ≈ [t.x,t.y,t.z] atol=1e-12
                @test actual_tangents[tbase+4] == 7.0
            end
        end
        expected_w = Diff3D._mat4_linear_orientation_sign(matrix) < 0 ? 1.0 : -1.0
        @test all(==(expected_w), get_attribute(transformed,:tangent).data[4:5:end])
        @test transformed.indices == transform_geometry(geometry,matrix).indices
    end
    @test geometry.positions == original.positions
    @test geometry.normals == original.normals
    for name in keys(original.attributes)
        @test get_attribute(geometry,name).data == get_attribute(original,name).data
    end

    projective = Mat4{Float64}((1.0,0,0,1, 0,1,0,0, 0,0,1,0, 0,0,0,1))
    midpoint = mat4_transform_point(projective,Vec3(0.5,0.0,0.0))
    endpoint_average = (mat4_transform_point(projective,Vec3()) +
                        mat4_transform_point(projective,Vec3(1.0,0.0,0.0))) / 2
    @test midpoint.x ≈ 1/3
    @test endpoint_average.x == 1/4
    @test_throws "morph targets requires an affine matrix" transform_geometry(geometry,projective)

    malformed = deepcopy(geometry)
    malformed.attributes[:morphPosition0] = BufferAttribute([1.0,2.0,3.0],3)
    @test_throws ArgumentError transform_geometry(malformed,Mat4())
    for scale in (1e-300, 1e300)
        tiny = deepcopy(geometry)
        tiny.normals .*= 1e-300
        get_attribute(tiny,:tangent).data[1:5:end] .= 1e-300
        transformed = transform_geometry(tiny,mat4_scaling(scale,scale,scale))
        @test all(isfinite,transformed.normals)
        @test all(vertex -> norm(get_normal(transformed,vertex)) ≈ 1.0,1:tiny.n_vertices)
    end
end
