using Diff3D
using Base64
using Pkg
using SHA
using Test
using TOML

length(ARGS) == 4 || error("usage: consumer_acceptance.jl OUTPUT CHECKOUT COMMIT TREE")
output, checkout, revision, tree = ARGS
mkpath(output)
package = only(info for info in values(Pkg.dependencies()) if info.name == "Diff3D")
evidence = Dict{String,Any}(
    "status" => "failed", "revision" => revision, "tree" => tree,
    "julia" => string(VERSION), "os" => string(Sys.KERNEL), "arch" => string(Sys.ARCH),
    "version" => string(package.version), "package_source" => package.source,
    "acceptance_sha256" => bytes2hex(sha256(read(@__FILE__))),
)

function triangle_asset(path)
    positions = [-0.75, -0.75, 0.0, 0.75, -0.75, 0.0, 0.0, 0.75, 0.0]
    buffer = IOBuffer()
    for coordinate in positions
        write(buffer, htol(reinterpret(UInt32, Float32(coordinate))))
    end
    # glTF indices are zero-based, and its binary component storage is little-endian.
    for index in (0, 1, 2)
        write(buffer, htol(UInt16(index)))
    end
    bytes = take!(buffer)
    document = """
    {"asset":{"version":"2.0"},"extensionsUsed":["KHR_materials_unlit"],
     "buffers":[{"byteLength":$(length(bytes)),"uri":"data:application/octet-stream;base64,$(base64encode(bytes))"}],
     "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},
                    {"buffer":0,"byteOffset":36,"byteLength":6}],
     "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
                   "min":[-0.75,-0.75,0],"max":[0.75,0.75,0]},
                  {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
     "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[0.2,0.4,0.6,1]},
                   "extensions":{"KHR_materials_unlit":{}}}],
     "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
     "nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}
    """
    write(path, document)
    return positions
end

function color_setup(parameters)
    vertices = [Vec3(-0.7, -0.6, 0.0), Vec3(0.7, -0.6, 0.0), Vec3(0.0, 0.7, 0.0)]
    return vertices, [(1, 2, 3)], [Color3(parameters...)], Mat4(), Color3(0.0, 0.0, 0.0)
end

try
    @testset "Independent installed consumer" begin
        @test package.is_direct_dep && package.is_tracking_repo && !package.is_tracking_path
        @test package.git_revision == revision
        @test package.tree_hash == tree
        @test realpath(pkgdir(Diff3D)) == realpath(package.source)
        @test realpath(pkgdir(Diff3D)) != realpath(checkout)
        @test LOAD_PATH == ["@", "@stdlib"]
        direct = sort([info.name for info in values(Pkg.dependencies()) if info.is_direct_dep])
        @test direct == ["Diff3D"]

        @testset "Import, image, and standalone export" begin
            path = joinpath(output, "triangle.gltf")
            positions = triangle_asset(path)
            asset = load_gltf_asset(path)
            @test isempty(asset.animations)
            meshes = collect_meshes(asset.scene)
            @test length(meshes) == 1
            @test meshes[1].geometry.positions == positions
            @test meshes[1].geometry.indices == [1, 2, 3]
            asset.scene.background = Color3(0.0, 0.0, 0.0)
            camera = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                                        near=0.1, far=10.0)
            camera.position = Vec3(0.0, 0.0, 2.0)
            target = RenderTarget(32, 32)
            render!(target, asset.scene, camera)
            @test target.color[16, 16, :] ≈ [0.2, 0.4, 0.6] atol=1e-12
            @test target.color[1, 1, :] == [0.0, 0.0, 0.0]
            @test all(isfinite, target.color)
            png = joinpath(output, "triangle.png")
            @test save_png(png, target) == png
            decoded = load_png(png)
            @test size(decoded) == (32, 32, 3)
            @test maximum(abs.(decoded .- target.color)) <= 0.5 / 255 + eps()
            @test decoded[16, 16, :] ≈ [51, 102, 153] ./ 255 atol=1e-12
            html = joinpath(output, "triangle.html")
            save_webgl_html(html, [WebGLExportCase("consumer", "Consumer", "Imported triangle",
                asset.scene; camera, tone_mapping=:none, output_color_space=:linear)])
            @test isfile(html) && filesize(html) > 0
            @test !occursin(r"<script\b[^>]*\bsrc\s*=", read(html, String))
            evidence["html_bytes"] = filesize(html)
            evidence["png_sha256"] = bytes2hex(sha256(read(png)))
        end

        @testset "Identifiable inverse color problem" begin
            render_color(p) = differentiable_render(p, color_setup, 8, 8)
            truth, initial = [0.2, 0.4, 0.6], [0.75, 0.15, 0.1]
            target = render_color(truth)
            weights = render_color(ones(3))[:, :, 1]
            @test minimum(weights) >= 0.0 && maximum(weights) > 0.1
            # Fixed geometry and black background make each color channel
            # linear in its own parameter. Derive the MSE gradient algebraically.
            coefficient = 2sum(abs2, weights) / length(target)
            expected = coefficient .* (initial .- truth)
            @test all(abs.(expected) .> 1e-4)
            objective(p) = loss_mse(render_color(p), target)
            reference = map(eachindex(initial)) do index
                plus, minus = copy(initial), copy(initial)
                plus[index] += 1e-5
                minus[index] -= 1e-5
                (objective(plus) - objective(minus)) / 2e-5
            end
            gradient = reverse_gradient(objective, initial)
            @test reference ≈ expected rtol=1e-8 atol=1e-10
            @test gradient ≈ expected rtol=1e-10 atol=1e-12
            evidence["gradient_max_error"] = maximum(abs.(gradient .- expected))
            for method in (:forward, :reverse)
                fitted, history = inverse_render_adam(initial, target, render_color, loss_mse;
                    ad=method, lr=0.04, n_iters=400, verbose=false)
                @test all(isfinite, history)
                @test fitted ≈ truth atol=1e-6 rtol=0.0
                @test objective(fitted) < 1e-12
                @test history[end] < history[1] * 1e-8
                @test initial == [0.75, 0.15, 0.1]
                evidence["inverse_$(method)"] = Dict("parameters" => fitted,
                    "initial_loss" => history[1], "final_loss" => objective(fitted))
            end
        end

        @testset "Documented rejection paths" begin
            for extension in ("KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu")
                path = joinpath(output, "unsupported.gltf")
                write(path, """{"asset":{"version":"2.0"},"extensionsUsed":["$extension"],"extensionsRequired":["$extension"]}""")
                @test_throws ErrorException load_gltf_asset(path)
            end
            scene = Scene()
            add!(scene, Mesh(BoxGeometry(), ShaderMaterial()))
            path = joinpath(output, "unsupported.html")
            @test_throws ArgumentError save_webgl_html(path, [
                WebGLExportCase("shader", "Shader", "Unsupported shader", scene)])
            @test !ispath(path)
        end
    end
    evidence["status"] = "passed"
finally
    open(joinpath(output, "consumer.toml"), "w") do io
        TOML.print(io, evidence; sorted=true)
    end
end
