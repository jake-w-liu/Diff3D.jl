# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_points_interleaved

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INTERLEAVED_POINTS_PARTICLES = 500_000
const INTERLEAVED_POINTS_STRIDE_BYTES = 16
const INTERLEAVED_POINTS_COLOR_OFFSET_BYTES = 12
const INTERLEAVED_POINTS_SPREAD = 1000.0

interleaved_points_fract(x::Float64) = x - floor(x)

function interleaved_points_hash_noise(index::Int, salt::Float64)
    interleaved_points_fract(sin((index + 1) * 21.923 + salt * 57.317) * 39119.271)
end

function interleaved_points_position(index::Int)
    half_spread = INTERLEAVED_POINTS_SPREAD / 2
    Vec3(interleaved_points_hash_noise(index, 0.11) * INTERLEAVED_POINTS_SPREAD - half_spread,
         interleaved_points_hash_noise(index, 0.37) * INTERLEAVED_POINTS_SPREAD - half_spread,
         interleaved_points_hash_noise(index, 0.73) * INTERLEAVED_POINTS_SPREAD - half_spread)
end

function interleaved_points_color(p::Vec3{Float64})
    Color3(p.x / INTERLEAVED_POINTS_SPREAD + 0.5,
           p.y / INTERLEAVED_POINTS_SPREAD + 0.5,
           p.z / INTERLEAVED_POINTS_SPREAD + 0.5)
end

function interleaved_points_geometry()
    positions = Vector{Float64}(undef, 3 * INTERLEAVED_POINTS_PARTICLES)
    colors = Vector{Float64}(undef, 3 * INTERLEAVED_POINTS_PARTICLES)
    color_bytes = Vector{UInt8}(undef, 4 * INTERLEAVED_POINTS_PARTICLES)

    for i in 0:(INTERLEAVED_POINTS_PARTICLES - 1)
        p = interleaved_points_position(i)
        c = interleaved_points_color(p)
        pbase = 3 * i + 1
        cbase = 4 * i + 1

        positions[pbase] = p.x
        positions[pbase + 1] = p.y
        positions[pbase + 2] = p.z
        colors[pbase] = c.r
        colors[pbase + 1] = c.g
        colors[pbase + 2] = c.b
        color_bytes[cbase] = UInt8(round(Int, clamp(c.r, 0.0, 1.0) * 255))
        color_bytes[cbase + 1] = UInt8(round(Int, clamp(c.g, 0.0, 1.0) * 255))
        color_bytes[cbase + 2] = UInt8(round(Int, clamp(c.b, 0.0, 1.0) * 255))
        color_bytes[cbase + 3] = 0x00
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         INTERLEAVED_POINTS_PARTICLES, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :interleavedColorBytes, color_bytes, 4)
    geo
end

function build_points_interleaved_case()
    scene = Scene(background=Color3(0.0196, 0.0196, 0.0196),
                  fog=Fog(color=Color3(0.0196, 0.0196, 0.0196), near=2000.0, far=3500.0))
    points = PointsObject(interleaved_points_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=15.0);
                          name="buffergeometry_points_interleaved_materialized")
    add!(scene, points)

    clip = AnimationClip("points_interleaved_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(points, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(3.0, 6.0, 0.0)]),
        ]; loop=:repeat)

    camera = PerspectiveCamera(fov=27pi / 180, aspect=16 / 9, near=5.0, far=3500.0)
    camera.position = Vec3(0.0, 0.0, 2750.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-points-interleaved", "BufferGeometry Points Interleaved",
                    "500000 particles with materialized positions, normalized colors, and raw interleaved color bytes.",
                    scene; camera=camera, target=camera.target,
                    radius=2750.0, height=0.0, fov=27pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_points_interleaved.html"),
                           [build_points_interleaved_case()];
                           title="Diff3D.jl webgl_buffergeometry_points_interleaved")
    println("WEBGL_BUFFERGEOMETRY_POINTS_INTERLEAVED_OK $html particles=$INTERLEAVED_POINTS_PARTICLES")
end

main()
