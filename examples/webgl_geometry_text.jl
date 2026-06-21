# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_text

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const FONT_PATH = joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
isdir(OUT) || mkpath(OUT)

function load_text_font()
    isfile(FONT_PATH) ||
        error("missing vendored Optimer font asset at $FONT_PATH")
    return FontLoader(FONT_PATH)
end

function centered_text_geometry(font::FontData, text::String)
    geo = TextGeometry(font, text; size=1.0, depth=0.28, curve_segments=4,
                       bevel_enabled=true, bevel_size=0.025,
                       bevel_thickness=0.045, bevel_segments=1)
    geo.n_vertices > 0 || error("TextGeometry produced no vertices for $(repr(text))")
    return geo
end

function text_center_offset(geo)
    bbox = compute_bounding_box(geo)
    return -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function add_text_pair!(group::Group, font::FontData)
    geo = centered_text_geometry(font, "three.js")
    center_offset = text_center_offset(geo)
    hover = 0.35
    depth = 0.28

    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 specular=Color3(0.23, 0.23, 0.23),
                                 shininess=36.0, side=:double)
    text_mesh = Mesh(geo, material; name="geometry_text_primary",
                     cast_shadow=true, receive_shadow=false)
    text_mesh.position = Vec3(center_offset, hover, 0.0)
    text_mesh.rotation = Euler(0.0, 2pi, 0.0)
    add!(group, text_mesh)

    mirror_mesh = Mesh(geo, material; name="geometry_text_mirror",
                       cast_shadow=false, receive_shadow=false)
    mirror_mesh.position = Vec3(center_offset, -hover, depth)
    mirror_mesh.rotation = Euler(pi, 2pi, 0.0)
    add!(group, mirror_mesh)
    return geo
end

function add_reflection_plane!(scene::Scene, y::Float64)
    plane = Mesh(PlaneGeometry(width=9.5, height=9.5),
                 MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                   opacity=0.32, transparent=true,
                                   side=:double);
                 name="geometry_text_reflection_plane",
                 receive_shadow=true)
    plane.position = Vec3(0.0, y, 0.0)
    plane.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, plane)
    return plane
end

function build_case()
    font = load_text_font()
    scene = Scene(background=Color3(0.0, 0.0, 0.0),
                  fog=Fog(color=Color3(0.0, 0.0, 0.0), near=3.0, far=13.5))

    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=0.42,
                                 position=Vec3(0.0, 0.0, 1.0)))
    add!(scene, PointLight(color=Color3(0.20, 0.72, 1.0), intensity=5.2,
                           distance=0.0, position=Vec3(0.0, 1.6, 1.45)))

    group = Group(name="geometry_text_group")
    group.position = Vec3(0.0, 0.55, 0.0)
    add!(scene, group)
    add_text_pair!(group, font)
    add_reflection_plane!(scene, group.position.y)

    clip = AnimationClip("text_drag_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [quat_from_euler(0.0, -0.35, 0.0),
                                 quat_from_euler(0.0, 0.35, 0.0),
                                 quat_from_euler(0.0, -0.35, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-text", "Geometry Text",
                    "Optimer bold typeface JSON loaded through FontLoader and rendered as beveled mirrored TextGeometry.",
                    scene; target=Vec3(0.0, 0.55, 0.1), radius=5.8, height=2.2,
                    fov=pi / 6, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_text.html"), [build_case()])
    println("WEBGL_GEOMETRY_TEXT_OK $html")
end

main()
