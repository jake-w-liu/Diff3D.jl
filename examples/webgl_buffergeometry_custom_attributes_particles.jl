# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_custom_attributes_particles

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const PARTICLE_ATTR_COUNT = 100_000
const PARTICLE_ATTR_RADIUS = 200.0
const PARTICLE_ATTR_BASE_SIZE = 20.0

particle_attr_fract(x::Float64) = x - floor(x)

function particle_attr_hash_noise(index::Int, salt::Float64)
    particle_attr_fract(sin((index + 1) * 17.2357 + salt * 91.733) * 31583.1237)
end

function particle_attr_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = particle_attr_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end

    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q

    function hue_to_rgb(t)
        t = particle_attr_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end

    Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function particle_attr_spark_texture(; n::Int=32)
    data = zeros(Float64, n, n, 4)
    center = (n + 1) / 2
    radius = n / 2
    for y in 1:n, x in 1:n
        dx = (x - center) / radius
        dy = (y - center) / radius
        r = sqrt(dx * dx + dy * dy)
        alpha = clamp(1.0 - r, 0.0, 1.0)^2
        data[y, x, 1] = 1.0
        data[y, x, 2] = 0.92 + 0.08alpha
        data[y, x, 3] = 0.48 + 0.52alpha
        data[y, x, 4] = alpha
    end
    Texture(data; filter=:linear, min_filter=:linear_mipmap_linear,
            colorspace=:srgb)
end

particle_attr_animated_size(index::Int, time::Float64) =
    10.0 * (1.0 + sin(0.1 * index + time))

function particle_attributes_geometry()
    positions = Vector{Float64}(undef, 3 * PARTICLE_ATTR_COUNT)
    colors = Vector{Float64}(undef, 3 * PARTICLE_ATTR_COUNT)
    sizes = fill(PARTICLE_ATTR_BASE_SIZE, PARTICLE_ATTR_COUNT)
    size_phases = Vector{Float64}(undef, PARTICLE_ATTR_COUNT)

    for i in 0:(PARTICLE_ATTR_COUNT - 1)
        base = 3 * i + 1
        x = (2.0 * particle_attr_hash_noise(i, 0.11) - 1.0) * PARTICLE_ATTR_RADIUS
        y = (2.0 * particle_attr_hash_noise(i, 0.37) - 1.0) * PARTICLE_ATTR_RADIUS
        z = (2.0 * particle_attr_hash_noise(i, 0.73) - 1.0) * PARTICLE_ATTR_RADIUS
        positions[base] = x
        positions[base + 1] = y
        positions[base + 2] = z

        c = particle_attr_hsl_to_rgb(i / PARTICLE_ATTR_COUNT, 1.0, 0.5)
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b
        size_phases[i + 1] = 0.1 * i
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         PARTICLE_ATTR_COUNT, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :size, sizes, 1)
    set_attribute!(geo, :sizePhase, size_phases, 1)
    geo
end

function build_particle_attributes_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    points = PointsObject(particle_attributes_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                                         size=8.0,
                                         transparent=true,
                                         depth_test=false,
                                         map=particle_attr_spark_texture());
                          name="buffergeometry_custom_attributes_particles")
    add!(scene, points)

    clip = AnimationClip("buffergeometry_custom_attributes_particles_rotation",
                         AbstractKeyframeTrack[
                             QuaternionKeyframeTrack(points, :rotation,
                                                     [0.0, 12.0],
                                                     [Quaternion(),
                                                      quat_from_euler(0.0, 0.0, 0.6)]),
                         ]; loop=:repeat)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = Vec3(0.0, 0.0, 300.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-custom-attributes-particles",
                    "BufferGeometry Custom Attributes Particles",
                    "100000 particles with HSL colors, size, and sizePhase attributes.",
                    scene; camera=camera, target=camera.target,
                    radius=300.0, height=0.0, fov=40pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_custom_attributes_particles.html"),
                           [build_particle_attributes_case()];
                           title="Diff3D.jl webgl_buffergeometry_custom_attributes_particles")
    println("WEBGL_BUFFERGEOMETRY_CUSTOM_ATTRIBUTES_PARTICLES_OK $html particles=$PARTICLE_ATTR_COUNT")
end

main()
