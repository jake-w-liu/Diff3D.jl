# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_loader_stl

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function loaded_stl_geometry()
    mktempdir() do dir
        path = joinpath(dir, "diff3d_loader_stl_torus.stl")
        source = TorusKnotGeometry(radius=0.95, tube=0.24,
                                   tubular_segments=104, radial_segments=16)
        save_stl_binary(path, source)
        loaded = load_stl(path)
        compute_vertex_normals!(loaded)
        return loaded
    end
end

function build_case()
    scene = Scene(background=Color3(0.018, 0.022, 0.030),
                  fog=Fog(color=Color3(0.018, 0.022, 0.030), near=7.0, far=16.0))
    add!(scene, AmbientLight(color=Color3(0.34, 0.37, 0.45), intensity=0.55))
    add!(scene, HemisphereLight(color=Color3(0.58, 0.70, 0.90),
                                ground_color=Color3(0.19, 0.17, 0.14),
                                intensity=0.45))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.35,
                                 position=Vec3(-3.0, 5.5, 3.4),
                                 cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.30, 0.68, 1.0), intensity=6.5,
                           distance=7.0, position=Vec3(2.6, 2.0, -2.2)))

    floor = Mesh(PlaneGeometry(width=6.5, height=6.5, width_segments=4, height_segments=4),
                 MeshStandardMaterial(color=Color3(0.23, 0.25, 0.29),
                                      roughness=0.82);
                 name="stl_loader_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -1.05, 0.0)
    add!(scene, floor)
    add!(scene, GridHelper(6.5, 13; color=Color3(0.12, 0.15, 0.20)))

    mesh = Mesh(loaded_stl_geometry(),
                MeshPhongMaterial(color=Color3(0.74, 0.78, 0.82),
                                  specular=Color3(0.82, 0.90, 1.0),
                                  shininess=56.0);
                name="loaded_binary_stl", cast_shadow=true, receive_shadow=true)
    mesh.rotation = Euler(-0.22, 0.0, 0.38)
    add!(scene, mesh)

    clip = AnimationClip("stl_loader_turntable", AbstractKeyframeTrack[
        KeyframeTrack(mesh, :rotation, [0.0, 3.0, 6.0],
                      [Vec3(-0.22, 0.0, 0.38),
                       Vec3(0.18, pi, 0.12),
                       Vec3(-0.22, 2pi, 0.38)])
    ]; loop=:repeat)

    WebGLExportCase("loader-stl", "STL Loader",
                    "Binary STL geometry round-tripped through Diff3D.jl load_stl and exported to WebGL.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=6.2, height=2.2,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_stl.html"), [build_case()])
    println("WEBGL_LOADER_STL_OK $html")
end

main()
