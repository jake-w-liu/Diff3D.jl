# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_clipping

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function clipping_scene(; include_helpers::Bool=true)
    scene = Scene(background=Color3(0.035, 0.038, 0.045),
                  fog=Fog(color=Color3(0.035, 0.038, 0.045), near=6.0, far=14.0))
    add!(scene, AmbientLight(color=Color3(0.80, 0.80, 0.80), intensity=0.75))
    add!(scene, SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=3.2,
                          position=Vec3(2.0, 3.0, 3.0),
                          angle=pi / 5, penumbra=0.2, cast_shadow=true))
    add!(scene, DirectionalLight(color=Color3(0.34, 0.31, 0.36), intensity=2.0,
                                 position=Vec3(0.0, 3.0, 0.0), cast_shadow=true))

    object = Mesh(TorusKnotGeometry(radius=0.4, tube=0.08,
                                    tubular_segments=95, radial_segments=20),
                  MeshPhongMaterial(color=Color3(0.50, 0.93, 0.06),
                                    shininess=100.0, side=:double);
                  name="clipped_torus_knot",
                  cast_shadow=true, receive_shadow=true)
    object.position = Vec3(0.0, 1.0, 0.0)
    add!(scene, object)

    ground = Mesh(PlaneGeometry(width=9.0, height=9.0),
                  MeshPhongMaterial(color=Color3(0.63, 0.68, 0.69),
                                    shininess=150.0, side=:double);
                  name="clipping_ground", receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, ground)

    if include_helpers
        add!(scene, PlaneHelper(Plane(Vec3(-1.0, 0.0, 0.0), 0.1), 2.4;
                                color=Color3(1.0, 0.52, 0.18)))
        helper_y = PlaneHelper(Plane(Vec3(0.0, -1.0, 0.0), 1.18), 2.4;
                               color=Color3(0.24, 0.70, 1.0))
        helper_y.position = Vec3(0.0, 1.0, 0.0)
        add!(scene, helper_y)
    end

    clip = AnimationClip("clipping_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(object, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    return scene, clip
end

function build_cases()
    base_scene, base_clip = clipping_scene(; include_helpers=false)
    global_scene, global_clip = clipping_scene()
    cap_scene, cap_clip = clipping_scene()

    return [
        WebGLExportCase("clipping-reference", "Clipping Reference",
                        "The unclipped torus knot and ground plane used as the Diff3D.jl clipping baseline.",
                        base_scene; target=Vec3(0.0, 0.9, 0.0), radius=6.0, height=1.4,
                        fov=36pi / 180, animations=[base_clip],
                        output_color_space=:srgb),
        WebGLExportCase("clipping-global", "Global Clipping Plane",
                        "Case-level browser clipping plane matching the upstream global x-axis clipping concept.",
                        global_scene; target=Vec3(0.0, 0.9, 0.0), radius=6.0, height=1.4,
                        fov=36pi / 180, animations=[global_clip],
                        clipping_planes=[Plane(Vec3(-1.0, 0.0, 0.0), 0.1)],
                        output_color_space=:srgb),
        WebGLExportCase("clipping-cap", "Clipping Plane Pair",
                        "Two exported world clipping planes approximate the upstream local/global clipping controls without GUI mutation.",
                        cap_scene; target=Vec3(0.0, 0.9, 0.0), radius=6.0, height=1.4,
                        fov=36pi / 180, animations=[cap_clip],
                        clipping_planes=[Plane(Vec3(-1.0, 0.0, 0.0), 0.1),
                                         Plane(Vec3(0.0, -1.0, 0.0), 1.18)],
                        output_color_space=:srgb),
    ]
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_clipping.html"), build_cases())
    println("WEBGL_CLIPPING_OK $html")
end

main()
