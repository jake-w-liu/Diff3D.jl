# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_instancing

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function instanced_triangle_geometry()
    positions = Float64[
         0.0,   0.045, 0.0,
        -0.04, -0.035, 0.0,
         0.04, -0.035, 0.0,
    ]
    normals = Float64[0.0, 0.0, 1.0,
                      0.0, 0.0, 1.0,
                      0.0, 0.0, 1.0]
    return BufferGeometry(positions, normals, Float64[], Int[1, 2, 3], 3, 1)
end

function build_instanced_triangles(; rows::Int=30)
    count = rows * rows
    inst = InstancedMesh(instanced_triangle_geometry(),
                         MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                           side=:double),
                         count; name="buffergeometry_instanced_triangles")

    k = 0
    for iy in 1:rows, ix in 1:rows
        u = rows == 1 ? 0.0 : (ix - 1) / (rows - 1)
        v = rows == 1 ? 0.0 : (iy - 1) / (rows - 1)
        x = (u - 0.5) * 1.72
        y = (v - 0.5) * 1.72
        z = 0.18 * sin(5pi * u) * cos(4pi * v)
        spin = 2pi * (u + v)
        scale = 0.75 + 0.35 * sin(3pi * u + 2pi * v)
        k += 1
        set_instance_matrix!(inst, k,
                             mat4_translation(x, y, z) *
                             mat4_rotation_z(spin) *
                             mat4_scaling(scale, scale, scale))
        set_instance_color!(inst, k,
                            Color3(0.35 + 0.65u,
                                   0.25 + 0.55v,
                                   0.35 + 0.45sin(pi * u) * cos(pi * v)^2))
    end
    return inst
end

function build_case()
    scene = Scene(background=Color3(0.015, 0.017, 0.024))
    group = Group(name="buffergeometry_instancing_group")
    add!(scene, group)
    add!(group, build_instanced_triangles())

    clip = AnimationClip("buffergeometry_instancing_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=0.1, far=10.0)
    camera.position = Vec3(0.0, 0.0, 2.35)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-instancing", "BufferGeometry Instancing",
                    "Single-triangle InstancedMesh with deterministic instance colors.",
                    scene; camera=camera, target=camera.target, radius=2.35,
                    height=0.0, fov=50pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_instancing.html"),
                           [build_case()])
    println("WEBGL_BUFFERGEOMETRY_INSTANCING_OK $html")
end

main()
