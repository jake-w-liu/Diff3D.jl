using Diff3D
using SHA
using TOML

length(ARGS) == 2 || error("usage: browser.jl FIXTURE_TOML OUTPUT_DIRECTORY")
fixture = TOML.parsefile(ARGS[1])
fixture["schema"] == 1 || error("unsupported browser fixture schema")
output = abspath(ARGS[2])
mkpath(output)
for case in fixture["cases"]
    count = case["count"]
    count isa Int && count > 0 && length(case["centers"]) == 3count || error("invalid instance count")
    mode = case["mode"]
    mode in ("static", "instanced", "dynamic") || error("invalid browser mode")
    case["id"] == "$mode-$count" || error("invalid browser fixture ID")
    geometry = BufferGeometry(case["positions"], case["normals"], Float64[], case["indices"] .+ 1, 3, 1)
    material = MeshBasicMaterial(color=Color3(fixture["color"]...))
    scene = Scene(background=Color3(fixture["background"]...))
    centers = [Vec3(case["centers"][3i-2:3i]...) for i in 1:count]
    tracks = KeyframeTrack[]
    if mode == "instanced"
        matrices = [mat4_translation(center.x, center.y, center.z) for center in centers]
        add!(scene, InstancedMesh(geometry, material, matrices))
    else
        for (index, center) in enumerate(centers)
            mesh = Mesh(geometry, material; name="triangle_$index")
            mesh.position = center
            add!(scene, mesh)
            if mode == "dynamic"
                raised = center + Vec3(0.0, case["amplitude"], 0.0)
                push!(tracks, KeyframeTrack(mesh, :position, [0.0, 1.0, 2.0],
                                          [center, raised, center], :linear))
            end
        end
    end
    camera = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0, top=1.0, near=0.1, far=10.0)
    camera.position = Vec3(0.0, 0.0, 2.0)
    animations = isempty(tracks) ? AnimationClip[] : [AnimationClip("translation", 2.0, tracks)]
    export_case = WebGLExportCase(case["id"], "Matched triangles", case["id"], scene;
        camera, animations, tone_mapping=:none, output_color_space=:linear)
    save_webgl_html(joinpath(output, "diff3d-$(case["id"]).html"), [export_case])
    println("BROWSER_FIXTURE_OK diff3d ", case["id"])
    flush(stdout)
end
repository = normpath(joinpath(@__DIR__, "..", ".."))
open(joinpath(output, "diff3d-build.toml"), "w") do io
    TOML.print(io, Dict("revision" => strip(read(`git -C $repository rev-parse HEAD`, String)),
        "dirty" => !isempty(read(`git -C $repository status --porcelain`, String)),
        "julia" => string(VERSION), "version" => string(pkgversion(Diff3D)),
        "fixture_sha256" => bytes2hex(sha256(read(ARGS[1])))); sorted=true)
end
