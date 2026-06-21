# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_attributes_integer

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INTEGER_ATTR_TRIANGLES = 10_000
const INTEGER_ATTR_VERTEX_COUNT = 3 * INTEGER_ATTR_TRIANGLES
const INTEGER_ATTR_SPREAD = 800.0
const INTEGER_ATTR_TRIANGLE_SIZE = 50.0

integer_attr_fract(x::Float64) = x - floor(x)

function integer_attr_noise(index::Int, salt::Float64)
    integer_attr_fract(sin((index + 1) * 24.9763 + salt * 113.417) * 12458.5453)
end

function integer_attr_offset(index::Int, salt::Float64, width::Float64)
    (integer_attr_noise(index, salt) - 0.5) * width
end

function integer_attr_texture_color(texture_index::Int16, u::Float64, v::Float64, triangle_id::Int)
    if texture_index == Int16(0)
        plank = 0.72 + 0.18 * integer_attr_noise(triangle_id, 0.12)
        grain = 0.75 + 0.25 * integer_attr_noise(floor(Int, 16u + 31v) + triangle_id, 0.28)
        Color3(0.58 * plank * grain, 0.34 * plank, 0.16 * plank)
    elseif texture_index == Int16(1)
        tile = isodd(floor(Int, 8u) + floor(Int, 8v))
        shade = tile ? 0.86 : 0.22
        Color3(shade, shade, shade)
    else
        blade = 0.55 + 0.35 * integer_attr_noise(triangle_id, 0.64)
        Color3(0.12 * blade, 0.52 * blade + 0.22, 0.08 * blade)
    end
end

function push_integer_attr_vertex!(positions::Vector{Float64}, uvs::Vector{Float64},
                                   colors::Vector{Float64}, texture_indices::Vector{Int16},
                                   x::Float64, y::Float64, z::Float64,
                                   u::Float64, v::Float64,
                                   texture_index::Int16, triangle_id::Int)
    push!(positions, x, y, z)
    push!(uvs, u, v)
    c = integer_attr_texture_color(texture_index, u, v, triangle_id)
    push!(colors, c.r, c.g, c.b)
    push!(texture_indices, texture_index)
end

function integer_attributes_geometry()
    positions = Vector{Float64}(undef, 0)
    uvs = Vector{Float64}(undef, 0)
    colors = Vector{Float64}(undef, 0)
    texture_indices = Vector{Int16}(undef, 0)
    sizehint!(positions, 3 * INTEGER_ATTR_VERTEX_COUNT)
    sizehint!(uvs, 2 * INTEGER_ATTR_VERTEX_COUNT)
    sizehint!(colors, 3 * INTEGER_ATTR_VERTEX_COUNT)
    sizehint!(texture_indices, INTEGER_ATTR_VERTEX_COUNT)

    half_spread = INTEGER_ATTR_SPREAD / 2
    for triangle_id in 0:(INTEGER_ATTR_TRIANGLES - 1)
        x = integer_attr_noise(triangle_id, 0.10) * INTEGER_ATTR_SPREAD - half_spread
        y = integer_attr_noise(triangle_id, 0.20) * INTEGER_ATTR_SPREAD - half_spread
        z = integer_attr_noise(triangle_id, 0.30) * INTEGER_ATTR_SPREAD - half_spread
        texture_index = Int16(triangle_id % 3)

        ax = x + integer_attr_offset(3triangle_id + 1, 0.11, INTEGER_ATTR_TRIANGLE_SIZE)
        ay = y + integer_attr_offset(3triangle_id + 1, 0.12, INTEGER_ATTR_TRIANGLE_SIZE)
        az = z + integer_attr_offset(3triangle_id + 1, 0.13, INTEGER_ATTR_TRIANGLE_SIZE)
        bx = x + integer_attr_offset(3triangle_id + 2, 0.21, INTEGER_ATTR_TRIANGLE_SIZE)
        by = y + integer_attr_offset(3triangle_id + 2, 0.22, INTEGER_ATTR_TRIANGLE_SIZE)
        bz = z + integer_attr_offset(3triangle_id + 2, 0.23, INTEGER_ATTR_TRIANGLE_SIZE)
        cx = x + integer_attr_offset(3triangle_id + 3, 0.31, INTEGER_ATTR_TRIANGLE_SIZE)
        cy = y + integer_attr_offset(3triangle_id + 3, 0.32, INTEGER_ATTR_TRIANGLE_SIZE)
        cz = z + integer_attr_offset(3triangle_id + 3, 0.33, INTEGER_ATTR_TRIANGLE_SIZE)

        push_integer_attr_vertex!(positions, uvs, colors, texture_indices,
                                  ax, ay, az, 0.0, 0.0, texture_index, triangle_id)
        push_integer_attr_vertex!(positions, uvs, colors, texture_indices,
                                  bx, by, bz, 0.5, 1.0, texture_index, triangle_id)
        push_integer_attr_vertex!(positions, uvs, colors, texture_indices,
                                  cx, cy, cz, 1.0, 0.0, texture_index, triangle_id)
    end

    geo = BufferGeometry(positions, Float64[], uvs, Int[],
                         INTEGER_ATTR_VERTEX_COUNT, INTEGER_ATTR_TRIANGLES)
    set_attribute!(geo, :textureIndex, texture_indices, 1)
    set_attribute!(geo, :color, colors, 3)
    geo
end

function build_integer_attributes_case()
    scene = Scene(background=Color3(0.0196, 0.0196, 0.0196),
                  fog=Fog(color=Color3(0.0196, 0.0196, 0.0196), near=2000.0, far=3500.0))
    mesh = Mesh(integer_attributes_geometry(),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), vertex_colors=true,
                                  side=:double);
                name="integer_texture_index_triangle_cloud")
    add!(scene, mesh)

    clip = AnimationClip("integer_attributes_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(mesh, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(3.0, 6.0, 0.0)]),
        ]; loop=:repeat)

    camera = PerspectiveCamera(fov=27pi / 180, aspect=16 / 9, near=1.0, far=3500.0)
    camera.position = Vec3(0.0, 0.0, 2500.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-attributes-integer", "BufferGeometry Integer Attributes",
        "10,000 triangles with upstream-style Int16 textureIndex attributes and UVs.",
        scene; camera=camera, target=camera.target, radius=2500.0, height=0.0, fov=27pi / 180,
        animations=[clip], tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_attributes_integer.html"),
                           [build_integer_attributes_case()];
                           title="Diff3D.jl webgl_buffergeometry_attributes_integer")
    println("WEBGL_BUFFERGEOMETRY_ATTRIBUTES_INTEGER_OK $html triangles=$INTEGER_ATTR_TRIANGLES")
end

main()
