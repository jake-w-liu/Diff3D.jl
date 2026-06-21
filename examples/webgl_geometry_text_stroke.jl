# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_text_stroke

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const FONT_PATH = joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
const STROKE_MESSAGE = ["   Three.js", "Stroke text."]
isdir(OUT) || mkpath(OUT)

function load_stroke_font()
    isfile(FONT_PATH) ||
        error("missing vendored Optimer font asset at $FONT_PATH")
    return FontLoader(FONT_PATH)
end

function text_center_offset(geo::BufferGeometry)
    geo.n_vertices > 0 || error("text geometry is empty")
    bbox = compute_bounding_box(geo)
    return -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function add_stroke_text!(group::Group, font::FontData)
    fill_material = MeshBasicMaterial(color=Color3(0.0, 0.40, 0.60),
                                      opacity=0.4, transparent=true,
                                      side=:double, depth_write=false)
    stroke_material = MeshBasicMaterial(color=Color3(0.0, 0.40, 0.60),
                                        side=:double)
    line_spacing = 1.12
    y_start = line_spacing * (length(STROKE_MESSAGE) - 1) / 2

    for (line_index, text_line) in enumerate(STROKE_MESSAGE)
        y = y_start - (line_index - 1) * line_spacing
        fill_geo = TextGeometry(font, text_line; size=1.0, curve_segments=8)
        x = text_center_offset(fill_geo)

        fill = Mesh(fill_geo, fill_material; name="text_stroke_fill_$line_index")
        fill.position = Vec3(x, y, -0.10)
        add!(group, fill)

        stroke_geometries = BufferGeometry[]
        for shape in font_text_shapes(font, text_line; size=1.0, curve_segments=8)
            stroke = points_to_stroke_geometry(shape; closed=true,
                                               stroke_width=0.065,
                                               linejoin=:round)
            stroke.n_faces > 0 && push!(stroke_geometries, stroke)
        end
        isempty(stroke_geometries) &&
            error("font_text_shapes produced no stroked geometry for $(repr(text_line))")
        stroke_geo = length(stroke_geometries) == 1 ?
                     stroke_geometries[1] :
                     merge_geometries(stroke_geometries; with_groups=false)
        stroke_mesh = Mesh(stroke_geo, stroke_material;
                           name="text_stroke_outline_$line_index")
        stroke_mesh.position = Vec3(x, y, 0.0)
        add!(group, stroke_mesh)
    end
    return group
end

function build_case()
    font = load_stroke_font()
    scene = Scene(background=Color3(0.941, 0.941, 0.941))
    group = Group(name="geometry_text_stroke_group")
    add!(scene, group)
    add_stroke_text!(group, font)

    camera = PerspectiveCamera(fov=pi / 4, aspect=16 / 9, near=0.05, far=50.0)
    camera.position = Vec3(0.0, -4.6, 7.2)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("geometry-text-stroke", "Geometry Text Stroke",
                    "FontLoader outlines converted to filled text and mesh-based stroked glyph contours.",
                    scene; camera=camera,
                    target=Vec3(0.0, 0.0, 0.0), radius=7.4, height=3.2,
                    fov=pi / 4,
                    tone_mapping=:none, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_text_stroke.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_TEXT_STROKE_OK $html")
end

main()
