# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_custom_attributes_points3

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const CUSTOM_POINTS3_RANDOM_ATTEMPTS = 100_000
const CUSTOM_POINTS3_SHELL_RADIUS = 100.0
const CUSTOM_POINTS3_INNER_FRACTION = 0.6
const CUSTOM_POINTS3_FRAME_RADIUS = 200.0
const CUSTOM_POINTS3_FRAME_OFFSET = 110.0
const CUSTOM_POINTS3_MERGE_SCALE = 1_000_000_000.0
isdir(OUT) || mkpath(OUT)

custom_points3_fract(x::Float64) = x - floor(x)

function custom_points3_hash_noise(index::Int, salt::Float64)
    custom_points3_fract(sin((index + 1) * 23.719 + salt * 83.137) * 41719.217)
end

function custom_points3_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = custom_points3_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end
    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q
    function hue_to_rgb(t)
        t = custom_points3_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end
    return Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function custom_points3_position_key(positions::Vector{Float64}, base::Int)
    (round(Int, positions[base] * CUSTOM_POINTS3_MERGE_SCALE),
     round(Int, positions[base + 1] * CUSTOM_POINTS3_MERGE_SCALE),
     round(Int, positions[base + 2] * CUSTOM_POINTS3_MERGE_SCALE))
end

function custom_points3_unique_positions(geo::BufferGeometry)
    length(geo.positions) == 3geo.n_vertices ||
        error("points3 source geometry positions length does not match vertex count")

    seen = Set{NTuple{3,Int}}()
    positions = Float64[]
    sizehint!(positions, length(geo.positions))
    for i in 1:geo.n_vertices
        base = 3i - 2
        key = custom_points3_position_key(geo.positions, base)
        key in seen && continue
        push!(seen, key)
        append!(positions, (geo.positions[base],
                            geo.positions[base + 1],
                            geo.positions[base + 2]))
    end
    return positions
end

function custom_points3_ball_texture(; n::Int=40)
    data = zeros(Float64, n, n, 4)
    center = (n + 1) / 2
    radius = (n - 2) / 2
    for y in 1:n, x in 1:n
        dx = (x - center) / radius
        dy = (y - center) / radius
        r2 = dx * dx + dy * dy
        inside = r2 <= 1.0
        shade = inside ? clamp(1.0 - 0.65sqrt(r2), 0.0, 1.0) : 0.0
        highlight = inside ? clamp(1.0 - 10.0 * ((dx + 0.28)^2 + (dy + 0.32)^2), 0.0, 1.0) : 0.0
        data[y, x, 1] = shade + 0.22highlight
        data[y, x, 2] = shade + 0.22highlight
        data[y, x, 3] = shade + 0.22highlight
        data[y, x, 4] = inside ? 1.0 : 0.0
    end
    Texture(data; wrap_s=:repeat, wrap_t=:repeat, filter=:linear,
            min_filter=:linear_mipmap_linear, colorspace=:srgb)
end

function custom_points3_shell_positions()
    inner = CUSTOM_POINTS3_INNER_FRACTION * CUSTOM_POINTS3_SHELL_RADIUS
    positions = Float64[]
    sizehint!(positions, 3 * CUSTOM_POINTS3_RANDOM_ATTEMPTS)
    for i in 0:(CUSTOM_POINTS3_RANDOM_ATTEMPTS - 1)
        x = (2.0 * custom_points3_hash_noise(i, 0.11) - 1.0) *
            CUSTOM_POINTS3_SHELL_RADIUS
        y = (2.0 * custom_points3_hash_noise(i, 0.37) - 1.0) *
            CUSTOM_POINTS3_SHELL_RADIUS
        z = (2.0 * custom_points3_hash_noise(i, 0.73) - 1.0) *
            CUSTOM_POINTS3_SHELL_RADIUS
        (abs(x) > inner || abs(y) > inner || abs(z) > inner) &&
            append!(positions, (x, y, z))
    end
    return positions
end

function custom_points3_add_transformed_vertices!(positions::Vector{Float64},
                                                  source::Vector{Float64},
                                                  offset::Vec3{Float64},
                                                  y_rotation::Float64)
    c = cos(y_rotation)
    s = sin(y_rotation)
    for i in 1:(length(source) ÷ 3)
        base = 3i - 2
        x = source[base]
        y = source[base + 1]
        z = source[base + 2]
        append!(positions, (c * x + s * z + offset.x,
                            y + offset.y,
                            -s * x + c * z + offset.z))
    end
    return positions
end

function custom_points3_frame_positions()
    radius = CUSTOM_POINTS3_FRAME_RADIUS
    beam = custom_points3_unique_positions(
        BoxGeometry(width=radius, height=0.1 * radius, depth=0.1 * radius,
                    width_segments=50, height_segments=5, depth_segments=5))
    upright = custom_points3_unique_positions(
        BoxGeometry(width=0.1 * radius, height=1.2 * radius, depth=0.1 * radius,
                    width_segments=5, height_segments=60, depth_segments=5))

    positions = Float64[]
    sizehint!(positions, 12 * length(beam))
    for y in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET),
        z in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET)
        custom_points3_add_transformed_vertices!(
            positions, beam, Vec3(0.0, y, z), 0.0)
    end
    for x in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET),
        y in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET)
        custom_points3_add_transformed_vertices!(
            positions, beam, Vec3(x, y, 0.0), pi / 2)
    end
    for x in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET),
        z in (CUSTOM_POINTS3_FRAME_OFFSET, -CUSTOM_POINTS3_FRAME_OFFSET)
        custom_points3_add_transformed_vertices!(
            positions, upright, Vec3(x, 0.0, z), 0.0)
    end
    return positions
end

function custom_attributes_points3_geometry()
    shell_positions = custom_points3_shell_positions()
    frame_positions = custom_points3_frame_positions()
    positions = [shell_positions; frame_positions]

    shell_count = length(shell_positions) ÷ 3
    vertex_count = length(positions) ÷ 3
    shell_count > 0 || error("points3 shell produced no vertices")
    vertex_count > shell_count || error("points3 frame produced no vertices")

    colors = Vector{Float64}(undef, 3vertex_count)
    sizes = Vector{Float64}(undef, vertex_count)
    size_phases = Vector{Float64}(undef, vertex_count)
    shape_ids = Vector{Float64}(undef, vertex_count)
    for i in 1:vertex_count
        base = 3i - 2
        c = if i <= shell_count
            custom_points3_hsl_to_rgb(0.5 + 0.2 * ((i - 1) / shell_count),
                                      1.0, 0.5)
        else
            custom_points3_hsl_to_rgb(0.1, 1.0, 0.5)
        end
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b
        sizes[i] = i <= shell_count ? 10.0 : 40.0
        size_phases[i] = i <= shell_count ? 0.1 * (i - 1) : 0.0
        shape_ids[i] = i <= shell_count ? 0.0 : 1.0
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[], vertex_count, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :ca, colors, 3)
    set_attribute!(geo, :size, sizes, 1)
    set_attribute!(geo, :sizePhase, size_phases, 1)
    set_attribute!(geo, :shapeId, shape_ids, 1)
    return geo
end

function build_custom_attributes_points3_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0),
                  fog=Fog(color=Color3(0.0, 0.0, 0.0),
                          near=200.0, far=600.0))
    points = PointsObject(custom_attributes_points3_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                                         size=10.0,
                                         transparent=true,
                                         alpha_test=0.5,
                                         map=custom_points3_ball_texture());
                          name="custom_attributes_points3")
    add!(scene, points)

    clip = AnimationClip("custom_attributes_points3_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(points, :rotation, [0.0, 10.0, 20.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, 1.0, 1.0),
                                 quat_from_euler(0.0, 2.0, 2.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9,
                               near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 0.0, 500.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("custom-attributes-points3", "Custom Attributes Points 3",
                    "Alpha-tested billboard particles around a segmented box-frame point cloud.",
                    scene; camera=camera, target=camera.target,
                    radius=500.0, height=0.0, fov=40pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    case = build_custom_attributes_points3_case()
    html = save_webgl_html(joinpath(OUT, "webgl_custom_attributes_points3.html"),
                           [case];
                           title="Diff3D.jl webgl_custom_attributes_points3")
    points = only(filter(obj -> obj isa PointsObject, case.scene.children))
    shape_ids = get_attribute(points.geometry, :shapeId).data
    shell_count = count(==(0.0), shape_ids)
    frame_count = points.geometry.n_vertices - shell_count
    println("WEBGL_CUSTOM_ATTRIBUTES_POINTS3_OK $html vertices=$(points.geometry.n_vertices) shell_vertices=$shell_count frame_vertices=$frame_count")
end

main()
