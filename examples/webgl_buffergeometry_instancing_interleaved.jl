# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_instancing_interleaved

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INTERLEAVED_INSTANCING_INSTANCES = 5_000
const INTERLEAVED_VERTEX_STRIDE = 8
const INTERLEAVED_POSITION_OFFSET = 0
const INTERLEAVED_UV_OFFSET = 4
const INTERLEAVED_OFFSET_SPREAD = 100.0
const INTERLEAVED_OFFSET_PADDING = 5.0

interleaved_fract(x::Float64) = x - floor(x)

function interleaved_hash_noise(index::Int, salt::Float64)
    interleaved_fract(sin((index + 1) * 29.417 + salt * 73.913) * 49201.337)
end

function interleaved_box_vertex_buffer()
    Float64[
        -1,  1,  1, 0, 0, 0, 0, 0,
         1,  1,  1, 0, 1, 0, 0, 0,
        -1, -1,  1, 0, 0, 1, 0, 0,
         1, -1,  1, 0, 1, 1, 0, 0,

         1,  1, -1, 0, 1, 0, 0, 0,
        -1,  1, -1, 0, 0, 0, 0, 0,
         1, -1, -1, 0, 1, 1, 0, 0,
        -1, -1, -1, 0, 0, 1, 0, 0,

        -1,  1, -1, 0, 1, 1, 0, 0,
        -1,  1,  1, 0, 1, 0, 0, 0,
        -1, -1, -1, 0, 0, 1, 0, 0,
        -1, -1,  1, 0, 0, 0, 0, 0,

         1,  1,  1, 0, 1, 0, 0, 0,
         1,  1, -1, 0, 1, 1, 0, 0,
         1, -1,  1, 0, 0, 0, 0, 0,
         1, -1, -1, 0, 0, 1, 0, 0,

        -1,  1,  1, 0, 0, 0, 0, 0,
         1,  1,  1, 0, 1, 0, 0, 0,
        -1,  1, -1, 0, 0, 1, 0, 0,
         1,  1, -1, 0, 1, 1, 0, 0,

         1, -1,  1, 0, 1, 0, 0, 0,
        -1, -1,  1, 0, 0, 0, 0, 0,
         1, -1, -1, 0, 1, 1, 0, 0,
        -1, -1, -1, 0, 0, 1, 0, 0,
    ]
end

function interleaved_box_indices()
    Int[
         1,  3,  2,
         3,  4,  2,
         5,  7,  6,
         7,  8,  6,
         9, 11, 10,
        11, 12, 10,
        13, 15, 14,
        15, 16, 14,
        17, 18, 19,
        19, 18, 20,
        21, 22, 23,
        23, 22, 24,
    ]
end

function interleaved_box_normals()
    normals = Float64[]
    for n in (Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, -1.0),
              Vec3(-1.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0),
              Vec3(0.0, 1.0, 0.0), Vec3(0.0, -1.0, 0.0))
        for _ in 1:4
            append!(normals, (n.x, n.y, n.z))
        end
    end
    return normals
end

function interleaved_box_geometry()
    raw = interleaved_box_vertex_buffer()
    positions = Vector{Float64}(undef, 24 * 3)
    uvs = Vector{Float64}(undef, 24 * 2)

    for vertex in 0:23
        raw_base = vertex * INTERLEAVED_VERTEX_STRIDE + 1
        pos_base = vertex * 3 + 1
        uv_base = vertex * 2 + 1
        positions[pos_base] = raw[raw_base + INTERLEAVED_POSITION_OFFSET]
        positions[pos_base + 1] = raw[raw_base + INTERLEAVED_POSITION_OFFSET + 1]
        positions[pos_base + 2] = raw[raw_base + INTERLEAVED_POSITION_OFFSET + 2]
        uvs[uv_base] = raw[raw_base + INTERLEAVED_UV_OFFSET]
        uvs[uv_base + 1] = raw[raw_base + INTERLEAVED_UV_OFFSET + 1]
    end

    geo = BufferGeometry(positions, interleaved_box_normals(), uvs,
                         interleaved_box_indices(), 24, 12)
    set_attribute!(geo, :interleavedVertexBuffer, raw, INTERLEAVED_VERTEX_STRIDE)
    return geo
end

function interleaved_crate_texture(; n::Int=64)
    data = zeros(Float64, n, n, 3)
    for y in 1:n, x in 1:n
        u = (x - 1) / (n - 1)
        v = (y - 1) / (n - 1)
        border = u < 0.08 || u > 0.92 || v < 0.08 || v > 0.92
        stripe = abs(u - v) < 0.035 || abs((1.0 - u) - v) < 0.035
        groove = mod(floor(Int, 8u) + floor(Int, 8v), 2) == 0
        base = groove ? Color3(0.58, 0.36, 0.18) : Color3(0.44, 0.26, 0.12)
        accent = border || stripe ? Color3(0.82, 0.62, 0.35) : base
        data[y, x, 1] = accent.r
        data[y, x, 2] = accent.g
        data[y, x, 3] = accent.b
    end
    Texture(data; filter=:linear, colorspace=:srgb)
end

function interleaved_instance_offset(index::Int)
    base = Vec3((interleaved_hash_noise(index, 0.11) - 0.5) * INTERLEAVED_OFFSET_SPREAD,
                (interleaved_hash_noise(index, 0.37) - 0.5) * INTERLEAVED_OFFSET_SPREAD,
                (interleaved_hash_noise(index, 0.73) - 0.5) * INTERLEAVED_OFFSET_SPREAD)
    base + normalize(base) * INTERLEAVED_OFFSET_PADDING
end

function interleaved_instance_orientation(index::Int)
    quat_normalize(Quaternion(2.0 * interleaved_hash_noise(index, 1.11) - 1.0,
                              2.0 * interleaved_hash_noise(index, 1.37) - 1.0,
                              2.0 * interleaved_hash_noise(index, 1.73) - 1.0,
                              2.0 * interleaved_hash_noise(index, 2.09) - 1.0))
end

function build_interleaved_instanced_mesh()
    inst = InstancedMesh(interleaved_box_geometry(),
                         MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                           map=interleaved_crate_texture()),
                         INTERLEAVED_INSTANCING_INSTANCES;
                         name="buffergeometry_instancing_interleaved")

    for i in 1:INTERLEAVED_INSTANCING_INSTANCES
        offset = interleaved_instance_offset(i - 1)
        orientation = interleaved_instance_orientation(i - 1)
        set_instance_matrix!(inst, i,
                             mat4_translation(offset.x, offset.y, offset.z) *
                             quat_to_mat4(orientation))
    end

    return inst
end

function build_instancing_interleaved_case()
    scene = Scene(background=Color3(0.0627, 0.0627, 0.0627))
    mesh = build_interleaved_instanced_mesh()
    add!(scene, mesh)

    clip = AnimationClip("buffergeometry_instancing_interleaved_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(mesh, :rotation, [0.0, 10.0, 20.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, 0.5, 0.0),
                                 quat_from_euler(0.0, 1.0, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 0.0, 120.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-instancing-interleaved",
                    "BufferGeometry Instancing Interleaved",
                    "Indexed instanced boxes materialized from an upstream-style interleaved vertex buffer.",
                    scene; camera=camera, target=camera.target, radius=120.0,
                    height=0.0, fov=50pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_instancing_interleaved.html"),
                           [build_instancing_interleaved_case()])
    println("WEBGL_BUFFERGEOMETRY_INSTANCING_INTERLEAVED_OK $html")
end

main()
