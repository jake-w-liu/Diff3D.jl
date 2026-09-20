using Test
using Diff3D
using ForwardDiff

@testset "1.0 public API inventory" begin
    lines = strip.(readlines(joinpath(@__DIR__, "public_api.txt")))
    declared = Symbol[Symbol(line) for line in lines if !isempty(line) && !startswith(line, '#')]
    actual = filter(!=(:Diff3D), names(Diff3D))
    @test !isempty(declared)
    @test length(declared) == length(unique(declared))
    @test Set(declared) == Set(actual)
    @test all(name -> isdefined(Diff3D, name), declared)
end

@testset "1.0 public hierarchy and camera conventions" begin
    left, right, child = Group(), Group(), Object3D()
    left.position = Vec3(1.0, 0.0, 0.0)
    right.position = Vec3(4.0, 0.0, 0.0)
    child.position = Vec3(2.0, 0.0, 0.0)
    @test add!(left, child) === left
    @test get_parent(child) === left
    @test add!(right, child) === right
    @test isempty(get_children(left))
    @test get_parent(child) === right
    @test mat4_transform_point(compute_world_matrix(child), Vec3()).x == 6.0
    @test_throws ArgumentError add!(child, right)
    @test_throws ArgumentError add!(child, child)
    @test remove!(right, child) === right
    @test get_parent(child) === nothing
    camera = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=20.0)
    @test camera.fov ≈ pi / 3
    @test_throws ArgumentError PerspectiveCamera(near=0.0)
end

@testset "1.0 public CPU target and scene mutation" begin
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    mesh = Mesh(PlaneGeometry(width=2.0, height=2.0),
                MeshBasicMaterial(color=Color3(0.2, 0.4, 0.6)))
    add!(scene, mesh)
    camera = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=20.0)
    camera.position = Vec3(0.0, 0.0, 3.0)
    renderers = (
        (target, scene, camera) -> render!(target, scene, camera; cache=RenderCache()),
        (target, scene, camera) -> render_pooled!(target, scene, camera, RenderCache()),
        (target, scene, camera) -> render_tiled!(target, scene, camera; tiles=1, cache=[RenderCache()]),
    )
    for renderer in renderers
        target = RenderTarget(24, 24)
        @test renderer(target, scene, camera) === target
        @test target.color[12, 12, :] ≈ [0.2, 0.4, 0.6]
        @test all(isfinite, target.color)
    end
    target, cache = RenderTarget(24, 24), RenderCache()
    render!(target, scene, camera; cache)
    saved = copy(target.color)
    mesh.material = MeshBasicMaterial(color=Color3(0.7, 0.3, 0.1))
    render!(target, scene, camera; cache)
    @test target.color[12, 12, :] ≈ [0.7, 0.3, 0.1]
    @test saved[12, 12, :] ≈ [0.2, 0.4, 0.6]
    @test_throws ArgumentError RenderTarget(0, 24)
end

@testset "1.0 public soft workspace ownership" begin
    workspace = SoftRenderWorkspace()
    vertices, faces, colors = Vec3{Float64}[], NTuple{3,Int}[], Color3{Float64}[]
    first = soft_render(vertices, faces, colors, Mat4(), 2, 2,
                        SoftRasterizerConfig(bg_color=Color3(0.2, 0.4, 0.6)); workspace)
    saved = copy(first)
    second = soft_render(vertices, faces, colors, Mat4(), 2, 2,
                         SoftRasterizerConfig(bg_color=Color3(0.7, 0.3, 0.1)); workspace)
    @test first === second
    @test first[1, 1, :] ≈ [0.7, 0.3, 0.1]
    @test saved[1, 1, :] ≈ [0.2, 0.4, 0.6]
    @test_throws ArgumentError soft_render(vertices, faces, colors, Mat4(), 2, 2;
                                           workspace=SoftRenderWorkspace{Float32}())
end

function public_contract_setup(parameters)
    vertices = [Vec3(-0.7, -0.6, 0.0), Vec3(0.7, -0.6, 0.0), Vec3(0.0, 0.7, 0.0)]
    return vertices, [(1, 2, 3)], [Color3(parameters...)], Mat4(), Color3(0.0, 0.0, 0.0)
end

@testset "1.0 explicit differentiable render inputs" begin
    parameters = [0.2, 0.4, 0.6]
    objective(p) = sum(differentiable_render(p, public_contract_setup, 8, 8))
    image = differentiable_render(parameters, public_contract_setup, 8, 8)
    @test size(image) == (8, 8, 3)
    @test all(isfinite, image)
    # Finite differences use separate parameter copies and the public objective.
    step = 1e-5
    reference = map(eachindex(parameters)) do index
        plus, minus = copy(parameters), copy(parameters)
        plus[index] += step
        minus[index] -= step
        (objective(plus) - objective(minus)) / (2step)
    end
    @test all(value -> abs(value) > 1e-3, reference)
    @test ForwardDiff.gradient(objective, parameters) ≈ reference rtol=1e-7 atol=1e-8
    @test reverse_gradient(objective, parameters) ≈ reference rtol=1e-7 atol=1e-8
end

@testset "1.0 unsupported formats fail through public entry points" begin
    mktempdir() do directory
        for extension in ("KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu")
            path = joinpath(directory, extension * ".gltf")
            write(path, """{"asset":{"version":"2.0"},"extensionsUsed":["$extension"],"extensionsRequired":["$extension"],"scenes":[{"nodes":[]}],"scene":0}""")
            failure = try
                load_gltf_asset(path)
                nothing
            catch error_value
                error_value isa ErrorException || rethrow()
                error_value
            end
            @test failure isa ErrorException
            @test occursin("requires unsupported extension $extension", sprint(showerror, failure))
        end
        scene = Scene()
        add!(scene, Mesh(BoxGeometry(), ShaderMaterial()))
        path = joinpath(directory, "unsupported.html")
        @test_throws ArgumentError save_webgl_html(path, [
            WebGLExportCase("shader", "Shader", "Custom shader", scene)])
        @test !isfile(path)
    end
end
