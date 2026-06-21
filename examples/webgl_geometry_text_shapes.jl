# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_text_shapes

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const FONT_PATH = joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
const TEXT_SHAPES_MESSAGE = ["   Three.js", "Simple text."]
isdir(OUT) || mkpath(OUT)

function load_shape_font()
    isfile(FONT_PATH) ||
        error("missing vendored Optimer font asset at $FONT_PATH")
    return FontLoader(FONT_PATH)
end

function line_loop_geometry(shape::Vector{<:Vec2})
    length(shape) >= 2 ||
        throw(ArgumentError("line_loop_geometry needs at least two points"))
    positions = Float64[]
    for pt in shape
        append!(positions, (pt.x, pt.y, 0.0))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], length(shape), 0)
end

function text_center_offset(geo::BufferGeometry)
    geo.n_vertices > 0 || error("text geometry is empty")
    bbox = compute_bounding_box(geo)
    return -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function add_text_shapes!(group::Group, font::FontData)
    fill_material = MeshBasicMaterial(color=Color3(0.0, 0.40, 0.60),
                                      opacity=0.4, transparent=true,
                                      side=:double, depth_write=false)
    line_material = LineBasicMaterial(color=Color3(0.0, 0.40, 0.60),
                                      linewidth=2.0)

    line_spacing = 1.18
    y_start = line_spacing * (length(TEXT_SHAPES_MESSAGE) - 1) / 2

    for (line_index, text_line) in enumerate(TEXT_SHAPES_MESSAGE)
        y = y_start - (line_index - 1) * line_spacing
        geo = TextGeometry(font, text_line; size=1.0, curve_segments=6)
        x = text_center_offset(geo)

        fill = Mesh(geo, fill_material; name="text_shapes_fill_$line_index")
        fill.position = Vec3(x, y, -0.08)
        add!(group, fill)

        for (shape_index, shape) in enumerate(font_text_shapes(font, text_line;
                                                              size=1.0,
                                                              curve_segments=6))
            length(shape) >= 2 || continue
            outline = LineLoop(line_loop_geometry(shape), line_material;
                               name="text_shapes_outline_$(line_index)_$(shape_index)")
            outline.position = Vec3(x, y, 0.0)
            add!(group, outline)
        end
    end
    return group
end

function build_case()
    font = load_shape_font()
    scene = Scene(background=Color3(0.941, 0.941, 0.941))
    group = Group(name="geometry_text_shapes_group")
    add!(scene, group)
    add_text_shapes!(group, font)

    camera = PerspectiveCamera(fov=pi / 4, aspect=16 / 9, near=0.05, far=40.0)
    camera.position = Vec3(0.0, -3.9, 5.7)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("geometry-text-shapes", "Geometry Text Shapes",
                    "FontLoader outlines rendered as translucent text fills plus visible line loops.",
                    scene; camera=camera,
                    target=Vec3(0.0, 0.0, 0.0), radius=6.0, height=3.0,
                    fov=pi / 4,
                    tone_mapping=:none, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_text_shapes.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_TEXT_SHAPES_OK $html")
end

main()
