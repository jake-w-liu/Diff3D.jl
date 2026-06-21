# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_attributes_none

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const ATTR_NONE_TRIANGLE_COUNT = 10_000
const ATTR_NONE_VERTEX_COUNT = 3 * ATTR_NONE_TRIANGLE_COUNT
const ATTR_NONE_JITTER_SCALE = 1 / 64

attr_none_fract(x::Float64) = x - floor(x)

function attr_none_hash_noise(index::Int, salt::Float64)
    attr_none_fract(sin((index + 1) * 12.9898 + salt * 78.233) * 43758.5453123)
end

function pseudo_random_vec3(lower::Float64, upper::Float64, index::Int)
    delta = upper - lower
    Vec3(lower + delta * attr_none_hash_noise(index, 0.13),
         lower + delta * attr_none_hash_noise(index, 0.47),
         lower + delta * attr_none_hash_noise(index, 0.79))
end

function attributes_none_geometry()
    positions = Vector{Float64}(undef, 3 * ATTR_NONE_VERTEX_COUNT)
    colors = Vector{Float64}(undef, 3 * ATTR_NONE_VERTEX_COUNT)

    for vertex_id in 0:(ATTR_NONE_VERTEX_COUNT - 1)
        triangle_id = vertex_id ÷ 3
        p = pseudo_random_vec3(-1.0, 1.0, triangle_id) +
            ATTR_NONE_JITTER_SCALE * pseudo_random_vec3(-1.0, 1.0, vertex_id)
        c = pseudo_random_vec3(0.25, 1.0, triangle_id)
        base = 3 * vertex_id + 1

        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
        colors[base] = c.x
        colors[base + 1] = c.y
        colors[base + 2] = c.z
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         ATTR_NONE_VERTEX_COUNT, ATTR_NONE_TRIANGLE_COUNT)
    set_attribute!(geo, :color, colors, 3)
    geo
end

function build_attributes_none_case()
    scene = Scene(background=Color3(0.0196, 0.0196, 0.0196),
                  fog=Fog(color=Color3(0.0196, 0.0196, 0.0196), near=2000.0, far=3500.0))
    mesh = Mesh(attributes_none_geometry(),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), vertex_colors=true,
                                  side=:double);
                name="attributes_none_materialized_vertexid_cloud")
    add!(scene, mesh)

    clip = AnimationClip("attributes_none_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(mesh, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(3.0, 6.0, 0.0)]),
        ]; loop=:repeat)

    camera = PerspectiveCamera(fov=27pi / 180, aspect=16 / 9, near=1.0, far=3500.0)
    camera.position = Vec3(0.0, 0.0, 4.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-attributes-none", "BufferGeometry Attributes None",
        "10,000 triangle positions/colors materialized from upstream gl_VertexID shader logic.",
        scene; camera=camera, target=camera.target, radius=4.0, height=0.0, fov=27pi / 180,
        animations=[clip], tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_attributes_none.html"),
                           [build_attributes_none_case()];
                           title="Diff3D.jl webgl_buffergeometry_attributes_none")
    println("WEBGL_BUFFERGEOMETRY_ATTRIBUTES_NONE_OK $html triangles=$ATTR_NONE_TRIANGLE_COUNT")
end

main()
