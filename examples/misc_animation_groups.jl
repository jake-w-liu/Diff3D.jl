# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_animation_groups

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const GRID_SIZE = 5
const BOX_SIZE = 5.0
const GRID_SPACING = 16.0
const KEY_TIMES = [0.0, 1.0, 2.0]

function build_animation_grid!()
    group = Group(name="animation_groups_grid")
    geometry = BoxGeometry(width=BOX_SIZE, height=BOX_SIZE, depth=BOX_SIZE)
    meshes = Mesh[]

    for i in 0:(GRID_SIZE - 1), j in 0:(GRID_SIZE - 1)
        material = MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0),
                                     transparent=true, opacity=1.0)
        mesh = Mesh(geometry, material; name="animation_group_box_$(i)_$(j)")
        mesh.position = Vec3(32.0 - GRID_SPACING * i, 0.0,
                             32.0 - GRID_SPACING * j)
        add!(group, mesh)
        push!(meshes, mesh)
    end

    return group, meshes
end

function build_group_animation(meshes)
    q_initial = Quaternion()
    q_final = quat_from_euler(pi, 0.0, 0.0)
    tracks = AbstractKeyframeTrack[]

    for mesh in meshes
        push!(tracks, QuaternionKeyframeTrack(mesh, "quaternion", KEY_TIMES,
                                              [q_initial, q_final, q_initial]))
        push!(tracks, KeyframeTrack(mesh, "material.color", KEY_TIMES,
                                    [Vec3(1.0, 0.0, 0.0),
                                     Vec3(0.0, 1.0, 0.0),
                                     Vec3(0.0, 0.0, 1.0)];
                                    interpolation=:step))
        push!(tracks, NumberKeyframeTrack(mesh, "material.opacity", KEY_TIMES,
                                          [1.0, 0.0, 1.0]))
    end

    return AnimationClip("default", 3.0, tracks)
end

function build_animation_groups_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    group, meshes = build_animation_grid!()
    add!(scene, group)
    clip = build_group_animation(meshes)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(50.0, 50.0, 100.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("misc-animation-groups", "Animation Groups",
                    "Twenty-five boxes sharing equivalent rotation, color, and opacity keyframes.",
                    scene; camera=camera, target=camera.target,
                    radius=120.0, height=20.0, fov=40pi / 180,
                    animations=[clip], tone_mapping=:linear,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_animation_groups.html"),
                           [build_animation_groups_case()];
                           title="Diff3D.jl misc_animation_groups")
    println("MISC_ANIMATION_GROUPS_OK $html")
end

main()
