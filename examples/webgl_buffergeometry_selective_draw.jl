# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_selective_draw

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SELECTIVE_NUM_LAT = 100
const SELECTIVE_NUM_LNG = 200
const SELECTIVE_TOTAL_LINES = SELECTIVE_NUM_LAT * SELECTIVE_NUM_LNG

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

selective_line_hidden(index::Int) = hash_noise(index, 0.75) > 0.75

function append_selective_line!(positions::Vector{Float64}, colors::Vector{Float64},
                                visible::Vector{Float64}, index::Int,
                                radius::Float64, hidden::Bool)
    lat_i = div(index, SELECTIVE_NUM_LNG)
    lng_i = index % SELECTIVE_NUM_LNG

    lat = hash_noise(index, 0.11) * pi / 50.0 +
          lat_i / SELECTIVE_NUM_LAT * pi
    lng = hash_noise(index, 0.37) * pi / 50.0 +
          lng_i / SELECTIVE_NUM_LNG * 2pi

    p0 = Vec3(0.0, 0.0, 0.0)
    p1 = Vec3(radius * sin(lat) * cos(lng),
              radius * cos(lat),
              radius * sin(lat) * sin(lng))
    c0 = hsl_to_rgb(lat / pi, 1.0, 0.2)
    c1 = hsl_to_rgb(lat / pi, 1.0, 0.7)
    v = hidden ? 0.0 : 1.0

    append!(positions, (p0.x, p0.y, p0.z, p1.x, p1.y, p1.z))
    append!(colors, (c0.r, c0.g, c0.b, c1.r, c1.g, c1.b))
    append!(visible, (v, v))
end

function selective_line_geometry(; radius::Float64=1.0, culled::Bool=false)
    positions = Float64[]
    colors = Float64[]
    visible = Float64[]
    sizehint!(positions, 6 * SELECTIVE_TOTAL_LINES)
    sizehint!(colors, 6 * SELECTIVE_TOTAL_LINES)
    sizehint!(visible, 2 * SELECTIVE_TOTAL_LINES)

    for index in 0:(SELECTIVE_TOTAL_LINES - 1)
        hidden = selective_line_hidden(index)
        culled && hidden && continue
        append_selective_line!(positions, colors, visible, index, radius, hidden)
    end

    geo = BufferGeometry(positions, Float64[], Float64[], Int[],
                         length(positions) ÷ 3, 0)
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :vertColor, colors, 3)
    set_attribute!(geo, :visible, visible, 1)
    return geo
end

function selective_culled_line_count()
    count(selective_line_hidden, 0:(SELECTIVE_TOTAL_LINES - 1))
end

function build_selective_draw_case(culled::Bool)
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    line = LineSegments(selective_line_geometry(culled=culled),
                        LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                        name=culled ? "selective_draw_visible_lines" :
                                      "selective_draw_all_lines")
    line.rotation = Euler(pi / 10, pi / 6, 0.0)
    add!(scene, line)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9,
                               near=0.01, far=10.0)
    camera.position = Vec3(0.0, 0.0, 3.5)
    camera.target = Vec3(0.0, 0.0, 0.0)

    hidden = selective_culled_line_count()
    visible = SELECTIVE_TOTAL_LINES - hidden
    id = culled ? "buffergeometry-selective-draw-culled" :
                  "buffergeometry-selective-draw-all"
    title = culled ? "BufferGeometry Selective Draw - Culled" :
                     "BufferGeometry Selective Draw - All"
    description = culled ?
        "Deterministic exported subset of $visible visible lines and $hidden culled lines." :
        "All $SELECTIVE_TOTAL_LINES colored line segments before visibility culling."

    WebGLExportCase(id, title, description,
                    scene; camera=camera, target=camera.target,
                    radius=3.5, height=0.0, fov=45pi / 180,
                    tone_mapping=:none, output_color_space=:srgb)
end

function build_selective_draw_cases()
    [build_selective_draw_case(false), build_selective_draw_case(true)]
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_selective_draw.html"),
                           build_selective_draw_cases();
                           title="Diff3D.jl webgl_buffergeometry_selective_draw")
    println("WEBGL_BUFFERGEOMETRY_SELECTIVE_DRAW_OK $html culled=$(selective_culled_line_count())")
end

main()
