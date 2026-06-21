# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_glbufferattribute

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const GLBUFFER_PARTICLES = 300_000
const GLBUFFER_DRAW_COUNT_SNAPSHOT = 10_000
const GLBUFFER_SPREAD = 1000.0

glbuffer_fract(x::Float64) = x - floor(x)

function glbuffer_hash_noise(index::Int, salt::Float64)
    glbuffer_fract(sin((index + 1) * 14.937 + salt * 83.123) * 42817.219)
end

function glbuffer_position(index::Int)
    half_spread = GLBUFFER_SPREAD / 2
    Vec3(glbuffer_hash_noise(index, 0.11) * GLBUFFER_SPREAD - half_spread,
         glbuffer_hash_noise(index, 0.37) * GLBUFFER_SPREAD - half_spread,
         glbuffer_hash_noise(index, 0.73) * GLBUFFER_SPREAD - half_spread)
end

glbuffer_secondary_position(p::Vec3{Float64}) = Vec3(0.3p.z, 0.3p.x, 0.3p.y)

function glbuffer_color(p::Vec3{Float64})
    Color3(p.x / GLBUFFER_SPREAD + 0.5,
           p.y / GLBUFFER_SPREAD + 0.5,
           p.z / GLBUFFER_SPREAD + 0.5)
end

function glbufferattribute_geometry()
    positions = Vector{Float64}(undef, 3 * GLBUFFER_PARTICLES)
    positions2 = Vector{Float64}(undef, 3 * GLBUFFER_PARTICLES)
    colors = Vector{Float64}(undef, 3 * GLBUFFER_PARTICLES)
    color_bytes = Vector{UInt8}(undef, 3 * GLBUFFER_PARTICLES)

    for i in 0:(GLBUFFER_PARTICLES - 1)
        p = glbuffer_position(i)
        p2 = glbuffer_secondary_position(p)
        c = glbuffer_color(p)
        base = 3 * i + 1

        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
        positions2[base] = p2.x
        positions2[base + 1] = p2.y
        positions2[base + 2] = p2.z
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b
        color_bytes[base] = UInt8(round(Int, clamp(c.r, 0.0, 1.0) * 255))
        color_bytes[base + 1] = UInt8(round(Int, clamp(c.g, 0.0, 1.0) * 255))
        color_bytes[base + 2] = UInt8(round(Int, clamp(c.b, 0.0, 1.0) * 255))
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         GLBUFFER_PARTICLES, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :position2, positions2, 3)
    set_attribute!(geo, :colorBytes, color_bytes, 3)
    set_draw_range!(geo, 1, GLBUFFER_DRAW_COUNT_SNAPSHOT)
    geo
end

function build_glbufferattribute_case()
    scene = Scene(background=Color3(0.0196, 0.0196, 0.0196),
                  fog=Fog(color=Color3(0.0196, 0.0196, 0.0196), near=2000.0, far=3500.0))
    points = PointsObject(glbufferattribute_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=15.0);
                          name="glbufferattribute_points_snapshot")
    add!(scene, points)

    clip = AnimationClip("glbufferattribute_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(points, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(1.2, 2.4, 0.0)]),
        ]; loop=:repeat)

    camera = PerspectiveCamera(fov=27pi / 180, aspect=16 / 9, near=5.0, far=3500.0)
    camera.position = Vec3(0.0, 0.0, 2750.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-glbufferattribute", "BufferGeometry GLBufferAttribute",
                    "300000 particles with alternate position VBO data and a 10000-point draw-range snapshot.",
                    scene; camera=camera, target=camera.target,
                    radius=2750.0, height=0.0, fov=27pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_glbufferattribute.html"),
                           [build_glbufferattribute_case()];
                           title="Diff3D.jl webgl_buffergeometry_glbufferattribute")
    println("WEBGL_BUFFERGEOMETRY_GLBUFFERATTRIBUTE_OK $html particles=$GLBUFFER_PARTICLES draw_count=$GLBUFFER_DRAW_COUNT_SNAPSHOT")
end

main()
