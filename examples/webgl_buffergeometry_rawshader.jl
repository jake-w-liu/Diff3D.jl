# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_rawshader

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const RAWSHADER_TRIANGLES = 200
const RAWSHADER_VERTEX_COUNT = 3 * RAWSHADER_TRIANGLES
const RAWSHADER_SNAPSHOT_TIME = 1.0

rawshader_fract(x::Float64) = x - floor(x)

function rawshader_hash_noise(index::Int, salt::Float64)
    rawshader_fract(sin((index + 1) * 31.416 + salt * 66.17) * 27342.513)
end

function rawshader_position(index::Int)
    Vec3(rawshader_hash_noise(index, 0.11) - 0.5,
         rawshader_hash_noise(index, 0.37) - 0.5,
         rawshader_hash_noise(index, 0.73) - 0.5)
end

function rawshader_color_byte(index::Int, channel::Int)
    round(Int, 255 * rawshader_hash_noise(index, 1.0 + channel))
end

function rawshader_snapshot_rgb(p::Vec3{Float64}, rgba::NTuple{4,Int};
                                time::Float64=RAWSHADER_SNAPSHOT_TIME)
    r = clamp(rgba[1] / 255 + sin(p.x * 10.0 + time) * 0.5, 0.0, 1.0)
    Color3(r, rgba[2] / 255, rgba[3] / 255)
end

function rawshader_geometry()
    positions = Vector{Float64}(undef, 3 * RAWSHADER_VERTEX_COUNT)
    colors = Vector{Float64}(undef, 4 * RAWSHADER_VERTEX_COUNT)
    raw_bytes = Vector{UInt8}(undef, 4 * RAWSHADER_VERTEX_COUNT)
    snapshot_colors = Vector{Float64}(undef, 3 * RAWSHADER_VERTEX_COUNT)

    for i in 0:(RAWSHADER_VERTEX_COUNT - 1)
        p = rawshader_position(i)
        rgba = (rawshader_color_byte(i, 1),
                rawshader_color_byte(i, 2),
                rawshader_color_byte(i, 3),
                rawshader_color_byte(i, 4))
        c = rawshader_snapshot_rgb(p, rgba)

        pbase = 3 * i + 1
        cbase = 4 * i + 1
        sbase = 3 * i + 1
        positions[pbase] = p.x
        positions[pbase + 1] = p.y
        positions[pbase + 2] = p.z
        colors[cbase] = rgba[1] / 255
        colors[cbase + 1] = rgba[2] / 255
        colors[cbase + 2] = rgba[3] / 255
        colors[cbase + 3] = rgba[4] / 255
        raw_bytes[cbase] = UInt8(rgba[1])
        raw_bytes[cbase + 1] = UInt8(rgba[2])
        raw_bytes[cbase + 2] = UInt8(rgba[3])
        raw_bytes[cbase + 3] = UInt8(rgba[4])
        snapshot_colors[sbase] = c.r
        snapshot_colors[sbase + 1] = c.g
        snapshot_colors[sbase + 2] = c.b
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         RAWSHADER_VERTEX_COUNT, RAWSHADER_TRIANGLES)
    set_attribute!(geo, :color, snapshot_colors, 3)
    set_attribute!(geo, :rawColorRGBA, colors, 4)
    set_attribute!(geo, :rawColorBytes, raw_bytes, 4)
    geo
end

function build_rawshader_case()
    scene = Scene(background=Color3(0.0627, 0.0627, 0.0627))
    mesh = Mesh(rawshader_geometry(),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                  vertex_colors=true,
                                  transparent=true,
                                  side=:double);
                name="rawshader_materialized_color_cloud")
    add!(scene, mesh)

    clip = AnimationClip("rawshader_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(mesh, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(0.0, 6.0, 0.0)]),
        ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=1.0, far=10.0)
    camera.position = Vec3(0.0, 0.0, 2.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-rawshader", "BufferGeometry Raw Shader",
                    "200 triangles with raw RGBA color attributes and materialized shader-time red modulation.",
                    scene; camera=camera, target=camera.target,
                    radius=2.0, height=0.0, fov=50pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_rawshader.html"),
                           [build_rawshader_case()];
                           title="Diff3D.jl webgl_buffergeometry_rawshader")
    println("WEBGL_BUFFERGEOMETRY_RAWSHADER_OK $html vertices=$RAWSHADER_VERTEX_COUNT")
end

main()
