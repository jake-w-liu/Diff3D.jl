# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_custom_attributes_points2

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const CUSTOM_POINTS2_RADIUS = 100.0
const CUSTOM_POINTS2_SPHERE_SEGMENTS = 68
const CUSTOM_POINTS2_SPHERE_RINGS = 38
const CUSTOM_POINTS2_BOX_SCALE = 0.8
const CUSTOM_POINTS2_BOX_SEGMENTS = 10
const CUSTOM_POINTS2_MERGE_SCALE = 1_000_000_000.0
isdir(OUT) || mkpath(OUT)

custom_points2_fract(x::Float64) = x - floor(x)

function custom_points2_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = custom_points2_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end
    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q
    function hue_to_rgb(t)
        t = custom_points2_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end
    return Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function custom_points2_position_key(positions::Vector{Float64}, base::Int)
    (round(Int, positions[base] * CUSTOM_POINTS2_MERGE_SCALE),
     round(Int, positions[base + 1] * CUSTOM_POINTS2_MERGE_SCALE),
     round(Int, positions[base + 2] * CUSTOM_POINTS2_MERGE_SCALE))
end

function custom_points2_unique_positions(geo::BufferGeometry)
    length(geo.positions) == 3geo.n_vertices ||
        error("points2 source geometry positions length does not match vertex count")

    seen = Set{NTuple{3,Int}}()
    positions = Float64[]
    sizehint!(positions, length(geo.positions))
    for i in 1:geo.n_vertices
        base = 3i - 2
        key = custom_points2_position_key(geo.positions, base)
        key in seen && continue
        push!(seen, key)
        append!(positions, (geo.positions[base],
                            geo.positions[base + 1],
                            geo.positions[base + 2]))
    end
    return positions
end

function custom_points2_disc_texture(; n::Int=32)
    data = zeros(Float64, n, n, 4)
    center = (n + 1) / 2
    radius = n / 2
    for y in 1:n, x in 1:n
        dx = (x - center) / radius
        dy = (y - center) / radius
        r2 = dx * dx + dy * dy
        alpha = clamp(1.0 - r2, 0.0, 1.0)^2
        data[y, x, 1] = 1.0
        data[y, x, 2] = 1.0
        data[y, x, 3] = 1.0
        data[y, x, 4] = alpha
    end
    Texture(data; wrap_s=:repeat, wrap_t=:repeat, filter=:linear,
            min_filter=:linear_mipmap_linear, colorspace=:srgb)
end

function custom_points2_depth_sorted_indices(positions::Vector{Float64})
    count = length(positions) ÷ 3
    sort(collect(1:count); by=i -> (positions[3i], i))
end

function custom_attributes_points2_geometry()
    sphere_positions = custom_points2_unique_positions(
        SphereGeometry(radius=CUSTOM_POINTS2_RADIUS,
                       width_segments=CUSTOM_POINTS2_SPHERE_SEGMENTS,
                       height_segments=CUSTOM_POINTS2_SPHERE_RINGS))
    box_size = CUSTOM_POINTS2_BOX_SCALE * CUSTOM_POINTS2_RADIUS
    box_positions = custom_points2_unique_positions(
        BoxGeometry(width=box_size, height=box_size, depth=box_size,
                    width_segments=CUSTOM_POINTS2_BOX_SEGMENTS,
                    height_segments=CUSTOM_POINTS2_BOX_SEGMENTS,
                    depth_segments=CUSTOM_POINTS2_BOX_SEGMENTS))

    positions = [sphere_positions; box_positions]
    sphere_count = length(sphere_positions) ÷ 3
    vertex_count = length(positions) ÷ 3
    sphere_count > 0 || error("points2 sphere geometry produced no vertices")
    vertex_count > sphere_count || error("points2 box geometry produced no vertices")

    colors = Vector{Float64}(undef, 3vertex_count)
    sizes = Vector{Float64}(undef, vertex_count)
    shape_ids = Vector{Float64}(undef, vertex_count)
    for i in 1:vertex_count
        base = 3i - 2
        y = positions[base + 1]
        c = if i <= sphere_count
            custom_points2_hsl_to_rgb(0.01 + 0.1 * ((i - 1) / sphere_count),
                                      0.99,
                                      (y + CUSTOM_POINTS2_RADIUS) /
                                      (4 * CUSTOM_POINTS2_RADIUS))
        else
            custom_points2_hsl_to_rgb(0.6, 0.75,
                                      0.25 + y / (2 * CUSTOM_POINTS2_RADIUS))
        end
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b
        sizes[i] = i <= sphere_count ? 10.0 : 40.0
        shape_ids[i] = i <= sphere_count ? 0.0 : 1.0
    end

    geo = BufferGeometry(positions, Float64[], Float64[],
                         custom_points2_depth_sorted_indices(positions),
                         vertex_count, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :ca, colors, 3)
    set_attribute!(geo, :size, sizes, 1)
    set_attribute!(geo, :shapeId, shape_ids, 1)
    return geo
end

function build_custom_attributes_points2_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    points = PointsObject(custom_attributes_points2_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                                         size=10.0,
                                         transparent=true,
                                         map=custom_points2_disc_texture());
                          name="custom_attributes_points2")
    add!(scene, points)

    clip = AnimationClip("custom_attributes_points2_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(points, :rotation, [0.0, 10.0, 20.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, 1.0, 1.0),
                                 quat_from_euler(0.0, 2.0, 2.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = Vec3(0.0, 0.0, 300.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("custom-attributes-points2", "Custom Attributes Points 2",
                    "Merged sphere and box vertices rendered as custom-colored billboard points.",
                    scene; camera=camera, target=camera.target,
                    radius=300.0, height=0.0, fov=45pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    case = build_custom_attributes_points2_case()
    html = save_webgl_html(joinpath(OUT, "webgl_custom_attributes_points2.html"),
                           [case];
                           title="Diff3D.jl webgl_custom_attributes_points2")
    points = only(filter(obj -> obj isa PointsObject, case.scene.children))
    shape_ids = get_attribute(points.geometry, :shapeId).data
    sphere_count = count(==(0.0), shape_ids)
    box_count = points.geometry.n_vertices - sphere_count
    println("WEBGL_CUSTOM_ATTRIBUTES_POINTS2_OK $html vertices=$(points.geometry.n_vertices) sphere_vertices=$sphere_count box_vertices=$box_count")
end

main()
