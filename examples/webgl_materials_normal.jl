# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_materials_normal

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function add_normal_mesh!(group::Group, geometry, name::String, position::Vec3)
    mesh = Mesh(geometry, MeshNormalMaterial(side=:double); name=name)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.02, 0.025, 0.03),
                  fog=Fog(color=Color3(0.02, 0.025, 0.03), near=8.0, far=18.0))

    group = Group(name="normal_material_group")
    add!(scene, group)

    add_normal_mesh!(group,
                     TorusKnotGeometry(radius=0.7, tube=0.22,
                                       tubular_segments=96, radial_segments=14),
                     "normal_torus_knot", Vec3(-1.8, 0.9, 0.0))
    add_normal_mesh!(group,
                     SphereGeometry(radius=0.85, width_segments=48, height_segments=24),
                     "normal_sphere", Vec3(0.0, -0.6, 0.0))
    add_normal_mesh!(group,
                     BoxGeometry(width=1.35, height=1.35, depth=1.35),
                     "normal_box", Vec3(1.85, 0.75, 0.0))
    add_normal_mesh!(group,
                     IcosahedronGeometry(radius=0.78, detail=2),
                     "normal_icosahedron", Vec3(0.1, 1.35, -1.35))
    add_normal_mesh!(group,
                     TorusGeometry(radius=0.58, tube=0.18,
                                   radial_segments=18, tubular_segments=72),
                     "normal_torus", Vec3(-0.2, 0.55, 1.35))

    clip = AnimationClip("normal_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.55, pi, 0.35),
                                 quat_from_euler(1.1, 2pi, 0.7)]),
        KeyframeTrack(group, :position, [0.0, 1.5, 3.0, 4.5, 6.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(0.25, 0.12, 0.0),
                       Vec3(0.0, -0.05, 0.0), Vec3(-0.25, 0.12, 0.0),
                       Vec3(0.0, 0.0, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("materials-normal", "Materials Normal",
                    "MeshNormalMaterial colorizes generated Three.jl normals in the browser.",
                    scene; target=Vec3(0.0, 0.3, 0.0), radius=6.8, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_normal.html"), [build_case()])
    println("WEBGL_MATERIALS_NORMAL_OK $html")
end

main()
