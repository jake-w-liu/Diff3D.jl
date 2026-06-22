# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_custom_attributes_lines

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const CUSTOM_LINES_FONT_PATH = joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
const CUSTOM_LINES_TEXT = "three.js"
const CUSTOM_LINES_AMPLITUDE = 5.0
isdir(OUT) || mkpath(OUT)

custom_lines_fract(x::Float64) = x - floor(x)

function custom_lines_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = custom_lines_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end
    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q
    function hue_to_rgb(t)
        t = custom_lines_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end
    Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function custom_lines_hash_noise(index::Int, salt::Float64)
    custom_lines_fract(sin((index + 1) * 17.9898 + salt * 61.233) * 24634.6345)
end

function custom_lines_displacement(index::Int)
    Vec3(0.5 - custom_lines_hash_noise(index, 0.13),
         0.5 - custom_lines_hash_noise(index, 0.37),
         0.5 - custom_lines_hash_noise(index, 0.71))
end

function custom_lines_center_geometry!(geo::BufferGeometry)
    geo.n_vertices > 0 || error("custom attributes line text geometry is empty")
    bbox = compute_bounding_box(geo)
    center = Vec3((bbox.min.x + bbox.max.x) / 2,
                  (bbox.min.y + bbox.max.y) / 2,
                  (bbox.min.z + bbox.max.z) / 2)
    for i in 1:geo.n_vertices
        base = 3i - 2
        geo.positions[base] -= center.x
        geo.positions[base + 1] -= center.y
        geo.positions[base + 2] -= center.z
    end
    geo
end

function custom_attributes_line_geometry()
    isfile(CUSTOM_LINES_FONT_PATH) ||
        error("missing vendored Optimer font asset at $CUSTOM_LINES_FONT_PATH")
    font = FontLoader(CUSTOM_LINES_FONT_PATH)
    geo = TextGeometry(font, CUSTOM_LINES_TEXT; size=50.0, depth=15.0,
                       curve_segments=10, bevel_enabled=true,
                       bevel_thickness=5.0, bevel_size=1.5,
                       bevel_segments=10)
    custom_lines_center_geometry!(geo)

    colors = Vector{Float64}(undef, 3geo.n_vertices)
    displacements = Vector{Float64}(undef, 3geo.n_vertices)
    for i in 1:geo.n_vertices
        base = 3i - 2
        c = custom_lines_hsl_to_rgb((i - 1) / geo.n_vertices, 0.5, 0.5)
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b

        d = custom_lines_displacement(i)
        displacements[base] = d.x
        displacements[base + 1] = d.y
        displacements[base + 2] = d.z
        geo.positions[base] += CUSTOM_LINES_AMPLITUDE * d.x
        geo.positions[base + 1] += CUSTOM_LINES_AMPLITUDE * d.y
        geo.positions[base + 2] += CUSTOM_LINES_AMPLITUDE * d.z
    end
    set_attribute!(geo, :color, colors, 3)
    set_attribute!(geo, :customColor, colors, 3)
    set_attribute!(geo, :displacement, displacements, 3)
    return geo
end

function build_custom_attributes_lines_case()
    scene = Scene(background=Color3(5 / 255, 5 / 255, 5 / 255))
    line = LineObject(custom_attributes_line_geometry(),
                      LineBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                        opacity=0.3,
                                        depth_test=false,
                                        depth_write=false);
                      name="custom_attributes_lines_text")
    line.rotation = Euler(0.2, 0.0, 0.0)
    add!(scene, line)

    clip = AnimationClip("custom_attributes_lines_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(line, :rotation, [0.0, 6.0, 12.0],
                                [quat_from_euler(0.2, 0.0, 0.0),
                                 quat_from_euler(0.2, 1.5, 0.0),
                                 quat_from_euler(0.2, 3.0, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=30pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = Vec3(0.0, 0.0, 400.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("custom-attributes-lines", "Custom Attributes Lines",
                    "TextGeometry line strip with customColor and displacement attributes.",
                    scene; camera=camera,
                    target=camera.target,
                    radius=400.0,
                    height=0.0,
                    fov=30pi / 180,
                    animations=[clip],
                    tone_mapping=:none,
                    output_color_space=:srgb)
end

function main()
    case = build_custom_attributes_lines_case()
    html = save_webgl_html(joinpath(OUT, "webgl_custom_attributes_lines.html"),
                           [case];
                           title="Diff3D.jl webgl_custom_attributes_lines")
    line = only(filter(obj -> obj isa LineObject, case.scene.children))
    println("WEBGL_CUSTOM_ATTRIBUTES_LINES_OK $html vertices=$(line.geometry.n_vertices)")
end

main()
