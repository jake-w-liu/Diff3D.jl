# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_materials_variations_toon

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function add_toon_mesh!(group::Group, geometry, name::String, position::Vec3,
                        color::Color3, steps::Int)
    mesh = Mesh(geometry, MeshToonMaterial(color=color,
                                           emissive=color * 0.04,
                                           gradient_steps=steps,
                                           side=:double);
                name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.025, 0.028, 0.035),
                  fog=Fog(color=Color3(0.025, 0.028, 0.035), near=9.0, far=18.0))
    add!(scene, AmbientLight(color=Color3(0.55, 0.58, 0.65), intensity=0.35))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.95, 0.82), intensity=1.9,
                                 position=Vec3(3.0, 5.0, 4.0), cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.3, 0.55, 1.0), intensity=3.0,
                           distance=9.0, decay=2.0, position=Vec3(-3.0, 2.0, 2.0)))

    group = Group(name="toon_material_group")
    add!(scene, group)

    add_toon_mesh!(group,
                   TorusKnotGeometry(radius=0.7, tube=0.18,
                                     tubular_segments=96, radial_segments=12),
                   "toon_torus_knot", Vec3(-1.75, 0.75, 0.0),
                   Color3(0.95, 0.42, 0.22), 3)
    add_toon_mesh!(group,
                   SphereGeometry(radius=0.85, width_segments=40, height_segments=20),
                   "toon_sphere", Vec3(0.0, -0.45, 0.0),
                   Color3(0.25, 0.75, 0.95), 4)
    add_toon_mesh!(group,
                   BoxGeometry(width=1.25, height=1.25, depth=1.25),
                   "toon_box", Vec3(1.8, 0.65, 0.0),
                   Color3(0.75, 0.9, 0.32), 5)
    add_toon_mesh!(group,
                   IcosahedronGeometry(radius=0.75, detail=2),
                   "toon_icosahedron", Vec3(0.0, 1.45, -1.25),
                   Color3(0.95, 0.78, 0.28), 2)

    clip = AnimationClip("toon_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.3, pi, 0.25),
                                 quat_from_euler(0.6, 2pi, 0.5)])
    ]; loop=:repeat)

    WebGLExportCase("materials-variations-toon", "Materials Variations Toon",
                    "MeshToonMaterial uses quantized diffuse bands in the Three.jl WebGL exporter.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=7.0, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_variations_toon.html"), [build_case()])
    println("WEBGL_MATERIALS_VARIATIONS_TOON_OK $html")
end

main()
