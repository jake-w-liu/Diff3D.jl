# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_custom_attributes_points

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CUSTOM_POINTS_AMOUNT = 100_000
const CUSTOM_POINTS_RADIUS = 200.0

fract(x) = x - floor(x)
hash_noise(i::Int, salt::Float64) = fract(sin((i + 1) * 12.9898 + salt * 78.233) * 43758.5453123)

function hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end

    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q

    function hue_to_rgb(t)
        t = fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end

    return Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function spark_texture(; n::Int=32)
    data = zeros(Float64, n, n, 4)
    center = (n + 1) / 2
    radius = n / 2
    for y in 1:n, x in 1:n
        dx = (x - center) / radius
        dy = (y - center) / radius
        r2 = dx * dx + dy * dy
        alpha = clamp(1.0 - r2, 0.0, 1.0)^2
        data[y, x, 1] = 1.0
        data[y, x, 2] = 0.95
        data[y, x, 3] = 0.60 + 0.40alpha
        data[y, x, 4] = alpha
    end
    Texture(data; filter=:linear, min_filter=:linear_mipmap_linear,
            colorspace=:srgb)
end

function custom_attribute_points_geometry()
    positions = Vector{Float64}(undef, 3CUSTOM_POINTS_AMOUNT)
    colors = Vector{Float64}(undef, 3CUSTOM_POINTS_AMOUNT)
    sizes = Vector{Float64}(undef, CUSTOM_POINTS_AMOUNT)

    for i in 0:(CUSTOM_POINTS_AMOUNT - 1)
        base = 3i + 1
        x = (2.0 * hash_noise(i, 0.11) - 1.0) * CUSTOM_POINTS_RADIUS
        y = (2.0 * hash_noise(i, 0.37) - 1.0) * CUSTOM_POINTS_RADIUS
        z = (2.0 * hash_noise(i, 0.73) - 1.0) * CUSTOM_POINTS_RADIUS
        positions[base] = x
        positions[base + 1] = y
        positions[base + 2] = z

        hue = x < 0 ? 0.5 + 0.1 * (i / CUSTOM_POINTS_AMOUNT) :
                      0.0 + 0.1 * (i / CUSTOM_POINTS_AMOUNT)
        saturation = x < 0 ? 0.7 : 0.9
        c = hsl_to_rgb(hue, saturation, 0.5)
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b

        sizes[i + 1] = 14.0 + 13.0 * sin(0.1 * i)
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         CUSTOM_POINTS_AMOUNT, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :customColor, colors, 3)
    set_attribute!(geo, :size, sizes, 1)
    return geo
end

function build_custom_attributes_points_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    points = PointsObject(custom_attribute_points_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                                         size=8.0,
                                         transparent=true,
                                         depth_test=false,
                                         map=spark_texture());
                          name="custom_attributes_points")
    add!(scene, points)

    clip = AnimationClip("custom_attributes_points_rotation",
                         AbstractKeyframeTrack[
                             QuaternionKeyframeTrack(points, :rotation,
                                                     [0.0, 12.0],
                                                     [Quaternion(),
                                                      quat_from_euler(0.0, 0.0, 2pi)]),
                         ]; loop=:repeat)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = Vec3(0.0, 0.0, 300.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("custom-attributes-points", "Custom Attributes Points",
                    "100000 deterministic particles with customColor and size attributes.",
                    scene; camera=camera, target=camera.target,
                    radius=300.0, height=0.0, fov=40pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_custom_attributes_points.html"),
                           [build_custom_attributes_points_case()];
                           title="Diff3D.jl webgl_custom_attributes_points")
    println("WEBGL_CUSTOM_ATTRIBUTES_POINTS_OK $html amount=$CUSTOM_POINTS_AMOUNT")
end

main()
