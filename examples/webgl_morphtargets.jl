# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_morphtargets

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function sphere_target(v::Vec3)
    x, y, z = v.x, v.y, v.z
    return Vec3(
        x * sqrt(max(0.0, 1.0 - y * y / 2.0 - z * z / 2.0 + y * y * z * z / 3.0)),
        y * sqrt(max(0.0, 1.0 - z * z / 2.0 - x * x / 2.0 + z * z * x * x / 3.0)),
        z * sqrt(max(0.0, 1.0 - x * x / 2.0 - y * y / 2.0 + x * x * y * y / 3.0)),
    )
end

function twist_target(v::Vec3)
    theta = pi * v.x / 2.0
    c, s = cos(theta), sin(theta)
    y = v.y * c - v.z * s
    z = v.y * s + v.z * c
    return Vec3(2.0 * v.x, y, z)
end

function add_face!(positions, normals, uvs, indices, normal::Vec3, u_axis::Vec3,
                   v_axis::Vec3, segments::Int)
    base = length(positions) ÷ 3
    half = 1.0
    for j in 0:segments, i in 0:segments
        u = -1.0 + 2.0 * i / segments
        v = -1.0 + 2.0 * j / segments
        p = normal * half + u_axis * (u * half) + v_axis * (v * half)
        append!(positions, (p.x, p.y, p.z))
        append!(normals, (normal.x, normal.y, normal.z))
        append!(uvs, (i / segments, j / segments))
    end
    stride = segments + 1
    for j in 0:(segments - 1), i in 0:(segments - 1)
        a = base + j * stride + i + 1
        b = a + 1
        c = a + stride
        d = c + 1
        append!(indices, (a, b, c, b, d, c))
    end
end

function morph_cube_geometry(; segments::Int=24)
    segments >= 1 || throw(ArgumentError("segments must be positive"))
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    faces = (
        (Vec3(1.0, 0.0, 0.0), Vec3(0.0, 0.0, -1.0), Vec3(0.0, 1.0, 0.0)),
        (Vec3(-1.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0), Vec3(0.0, 1.0, 0.0)),
        (Vec3(0.0, 1.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 0.0, -1.0)),
        (Vec3(0.0, -1.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0)),
        (Vec3(0.0, 0.0, 1.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0)),
        (Vec3(0.0, 0.0, -1.0), Vec3(-1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0)),
    )
    for (normal, u_axis, v_axis) in faces
        add_face!(positions, normals, uvs, indices, normal, u_axis, v_axis, segments)
    end

    geo = BufferGeometry(positions, normals, uvs, indices, length(positions) ÷ 3,
                         length(indices) ÷ 3)
    sphere_deltas = Float64[]
    twist_deltas = Float64[]
    for i in 1:geo.n_vertices
        base = 3(i - 1) + 1
        p = Vec3(positions[base], positions[base + 1], positions[base + 2])
        sphere = sphere_target(p)
        twist = twist_target(p)
        append!(sphere_deltas, (sphere.x - p.x, sphere.y - p.y, sphere.z - p.z))
        append!(twist_deltas, (twist.x - p.x, twist.y - p.y, twist.z - p.z))
    end
    set_attribute!(geo, :morphPosition0, sphere_deltas, 3)
    set_attribute!(geo, :morphPosition1, twist_deltas, 3)
    return geo
end

function build_case()
    sky = Color3(0x8f / 255, 0xbc / 255, 0xd4 / 255)
    scene = Scene(background=sky)
    add!(scene, AmbientLight(color=sky, intensity=1.5))
    add!(scene, PointLight(color=Color3(1.0, 1.0, 1.0), intensity=85.0,
                           distance=20.0, decay=2.0, position=Vec3(0.0, 0.0, 6.0)))

    mesh = Mesh(morph_cube_geometry(),
                MeshPhongMaterial(color=Color3(1.0, 0.0, 0.0),
                                  specular=Color3(0.35, 0.35, 0.35),
                                  shininess=48.0,
                                  side=:double);
                name="morphtargets_cube",
                morph_target_influences=[0.0, 0.0],
                morph_target_names=["Spherify", "Twist"])
    add!(scene, mesh)

    times = [0.0, 1.2, 2.4, 3.6, 4.8]
    values = [[0.0, 0.0], [1.0, 0.0], [0.15, 1.0], [0.85, 0.45], [0.0, 0.0]]
    clip = AnimationClip("morphtargets_cycle",
                         AbstractKeyframeTrack[
                             MorphWeightsKeyframeTrack(mesh, :morph_target_influences,
                                                        times, values),
                             QuaternionKeyframeTrack(mesh, :rotation, [0.0, 4.8],
                                                     [Quaternion(),
                                                      quat_from_euler(0.0, 2pi, 0.0)]),
                         ])

    WebGLExportCase("morph-targets", "Morph Targets",
                    "Position morph-target deltas animate a segmented cube through spherify and twist targets.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=1.0,
                    fov=pi / 4, animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_morphtargets.html"), [build_case()])
    println("WEBGL_MORPHTARGETS_OK $html")
end

main()
