using Test
using Diff3D
using ForwardDiff

function mixed_soft_allocations(vertices, faces, colors, view_projection, config, workspace)
    soft_render(vertices, faces, colors, view_projection, 2, 2, config; workspace)
    return @allocated soft_render(vertices, faces, colors, view_projection, 2, 2, config; workspace)
end

@testset "Mixed numeric soft renders reuse workspace storage" begin
    dual = ForwardDiff.Dual(0.0, 1.0)
    for mode in (:narrow, :vertices, :colors, :camera, :config), count in (1, 100)
        vertices = [Vec3(-0.6, -0.5, 0.0), Vec3(0.5, -0.4, 0.0), Vec3(0.1, 0.6, 0.0)]
        colors = fill(Color3(0.8, 0.2, 0.1), count)
        faces = fill((1, 2, 3), count)
        projection = Mat4()
        config = SoftRasterizerConfig()
        if mode === :narrow
            vertices = [convert(Vec3{Float32}, vertex) for vertex in vertices]
            colors = [Color3(Float32(color.r), Float32(color.g), Float32(color.b)) for color in colors]
        elseif mode === :vertices
            vertices = [Vec3(vertex.x + dual, vertex.y + zero(dual), vertex.z + zero(dual)) for vertex in vertices]
        elseif mode === :colors
            colors = [Color3(color.r + dual, color.g + zero(dual), color.b + zero(dual)) for color in colors]
        elseif mode === :camera
            projection = mat4_translation(dual, zero(dual), zero(dual))
        else
            config = SoftRasterizerConfig(sigma=one(dual) + dual)
        end
        T = mode === :narrow ? Float64 : typeof(dual)
        workspace = SoftRenderWorkspace{T}()
        expected_vertices = [Vec3(T(vertex.x), T(vertex.y), T(vertex.z)) for vertex in vertices]
        expected_colors = [Color3(T(color.r), T(color.g), T(color.b)) for color in colors]
        expected = soft_render(expected_vertices, faces, expected_colors,
                               convert(Mat4{T}, projection), 2, 2, config)
        actual = soft_render(vertices, faces, colors, projection, 2, 2, config; workspace)
        @test actual === workspace.image
        @test actual == expected
        @test all(isfinite, actual)
        @test any(x -> Diff3D._primal_value(x) > 0.0, actual)
        if Base.JLOptions().opt_level > 0
            mixed_soft_allocations(vertices, faces, colors, projection, config, workspace)
            # A warmed render must not recreate input-sized promotion buffers.
            @test mixed_soft_allocations(vertices, faces, colors, projection, config, workspace) <= 256
        end
    end
end

function mixed_soft_objective(parameters; workspace=nothing)
    T = eltype(parameters)
    vertices = Vec3{T}[Vec3(parameters[1], -0.5, 0.0), Vec3(0.5, -0.4, 0.0), Vec3(0.1, 0.6, 0.0)]
    colors = [Color3(parameters[3], 0.2, 0.1)]
    projection = mat4_translation(parameters[2], 0.0, 0.0)
    config = SoftRasterizerConfig(sigma=parameters[4], gamma=parameters[5])
    return sum(soft_render(vertices, [(1, 2, 3)], colors, projection, 2, 2, config; workspace))
end

@testset "Mixed soft promotion preserves numeric derivatives" begin
    parameters = [-0.6, 0.05, 0.8, 0.7, 0.8]
    forward = ForwardDiff.gradient(mixed_soft_objective, parameters)
    finite = numerical_gradient(mixed_soft_objective, parameters)
    @test all(isfinite, forward)
    @test forward ≈ finite rtol=1e-5 atol=1e-7
    @test reverse_gradient(mixed_soft_objective, parameters) ≈ forward rtol=1e-10 atol=1e-12
    workspace = SoftRenderWorkspace{ADVar}()
    for shift in (0.0, 0.1, -0.1)
        shifted = parameters .+ shift
        expected = ForwardDiff.gradient(mixed_soft_objective, shifted)
        actual = reverse_gradient(p -> mixed_soft_objective(p; workspace), shifted)
        @test actual ≈ expected rtol=1e-10 atol=1e-12
    end
    @test mixed_soft_objective(BigFloat.(parameters)) ≈ mixed_soft_objective(parameters) rtol=1e-12

    # Fixed Float64 geometry/colors still promote correctly for heap-backed AD.
    vertices = [Vec3(-0.6, -0.5, 0.0), Vec3(0.5, -0.4, 0.0), Vec3(0.1, 0.6, 0.0)]
    colors = [Color3(0.8, 0.2, 0.1)]
    camera_objective(p; workspace=nothing) = sum(soft_render(
        vertices, [(1, 2, 3)], colors, mat4_translation(p[1], 0.0, 0.0),
        2, 2; workspace))
    for shift in (0.05, -0.1)
        expected = ForwardDiff.gradient(camera_objective, [shift])
        @test reverse_gradient(p -> camera_objective(p; workspace), [shift]) ≈ expected rtol=1e-10 atol=1e-12
    end
end
