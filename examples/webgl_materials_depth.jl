# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_depth

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function add_depth_mesh!(group::Group, geometry, name::String, position::Vec3)
    mesh = Mesh(geometry, MeshDepthMaterial(near=2.5, far=11.0, side=:double); name=name)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.01, 0.012, 0.016),
                  fog=Fog(color=Color3(0.01, 0.012, 0.016), near=9.0, far=16.0))

    group = Group(name="depth_material_group")
    add!(scene, group)

    add_depth_mesh!(group,
                    TorusKnotGeometry(radius=0.55, tube=0.18,
                                      tubular_segments=72, radial_segments=12),
                    "depth_torus_knot_near", Vec3(-1.7, 0.7, 1.2))
    add_depth_mesh!(group,
                    SphereGeometry(radius=0.75, width_segments=40, height_segments=20),
                    "depth_sphere_mid", Vec3(0.0, -0.35, -0.4))
    add_depth_mesh!(group,
                    BoxGeometry(width=1.2, height=1.2, depth=1.2),
                    "depth_box_far", Vec3(1.7, 0.65, -1.8))
    add_depth_mesh!(group,
                    IcosahedronGeometry(radius=0.72, detail=2),
                    "depth_icosahedron", Vec3(0.0, 1.25, -3.0))

    clip = AnimationClip("depth_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.35, pi, -0.2),
                                 quat_from_euler(0.7, 2pi, -0.4)])
    ]; loop=:repeat)

    WebGLExportCase("materials-depth", "Materials Depth",
                    "MeshDepthMaterial maps camera distance to grayscale in the Diff3D.jl WebGL exporter.",
                    scene; target=Vec3(0.0, 0.25, -0.8), radius=7.0, height=1.8,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_depth.html"), [build_case()])
    println("WEBGL_MATERIALS_DEPTH_OK $html")
end

main()
