# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_animation_keys

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const KEY_TIMES = [0.0, 1.0, 2.0]

function build_animation_keys_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, AxesHelper(10.0))

    mesh = Mesh(BoxGeometry(width=5.0, height=5.0, depth=5.0),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                  transparent=true, opacity=1.0);
                name="animation_keys_mesh")
    add!(scene, mesh)

    q_initial = Quaternion()
    q_final = quat_from_euler(pi, 0.0, 0.0)
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(mesh, :scale, KEY_TIMES,
                      [Vec3(1.0, 1.0, 1.0), Vec3(2.0, 2.0, 2.0),
                       Vec3(1.0, 1.0, 1.0)]),
        KeyframeTrack(mesh, :position, KEY_TIMES,
                      [Vec3(0.0, 0.0, 0.0), Vec3(30.0, 0.0, 0.0),
                       Vec3(0.0, 0.0, 0.0)]),
        QuaternionKeyframeTrack(mesh, "quaternion", KEY_TIMES,
                                [q_initial, q_final, q_initial]),
        KeyframeTrack(mesh, "material.color", KEY_TIMES,
                      [Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0),
                       Vec3(0.0, 0.0, 1.0)];
                      interpolation=:step),
        NumberKeyframeTrack(mesh, "material.opacity", KEY_TIMES, [1.0, 0.0, 1.0]),
    ]
    clip = AnimationClip("Action", 3.0, tracks)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(25.0, 25.0, 50.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("misc-animation-keys", "Animation Keys",
                    "Position, scale, quaternion, color, and opacity keyframes.",
                    scene; camera=camera, target=camera.target, radius=60.0,
                    animations=[clip], tone_mapping=:linear,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_animation_keys.html"),
                           [build_animation_keys_case()];
                           title="Diff3D.jl misc_animation_keys")
    println("MISC_ANIMATION_KEYS_OK $html")
end

main()
