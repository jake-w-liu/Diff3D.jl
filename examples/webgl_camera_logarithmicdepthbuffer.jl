# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_camera_logarithmicdepthbuffer

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const LOGDEPTH_FONT_PATH =
    joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
isdir(OUT) || mkpath(OUT)

const LOGDEPTH_NEAR = 1e-6
const LOGDEPTH_FAR = 1e27
const LOGDEPTH_INITIAL_SPLIT = 0.25
const LOGDEPTH_MIN_ZOOM_SPEED = 0.015
const LOGDEPTH_ZOOM_POS = -100.0
const LOGDEPTH_CANVAS_WIDTH = 800
const LOGDEPTH_CANVAS_HEIGHT = 360
const LOGDEPTH_VISUAL_MIN_Z = 4.0
const LOGDEPTH_VISUAL_MAX_Z = 120.0
const LOGDEPTH_CAMERA_TARGET = Vec3(0.0, 0.0, -62.0)
const LOGDEPTH_CAMERA_POSITION = Vec3(0.0, 12.0, 78.0)

const LOGDEPTH_LABEL_DATA = [
    (size=0.01, scale=0.0001, label="microscopic (1um)"),
    (size=0.01, scale=0.1, label="minuscule (1mm)"),
    (size=0.01, scale=1.0, label="tiny (1cm)"),
    (size=1.0, scale=1.0, label="child-sized (1m)"),
    (size=10.0, scale=1.0, label="tree-sized (10m)"),
    (size=100.0, scale=1.0, label="building-sized (100m)"),
    (size=1000.0, scale=1.0, label="medium (1km)"),
    (size=10000.0, scale=1.0, label="city-sized (10km)"),
    (size=3.4e6, scale=1.0, label="moon-sized (3,400 Km)"),
    (size=1.2e7, scale=1.0, label="planet-sized (12,000 km)"),
    (size=1.4e9, scale=1.0, label="sun-sized (1,400,000 km)"),
    (size=7.47e12, scale=1.0, label="solar system-sized (50Au)"),
    (size=9.4605284e15, scale=1.0, label="gargantuan (1 light year)"),
    (size=3.08567758e16, scale=1.0, label="ludicrous (1 parsec)"),
    (size=1e19, scale=1.0, label="mind boggling (1000 light years)"),
]

function logdepth_load_font()
    isfile(LOGDEPTH_FONT_PATH) ||
        error("missing vendored Optimer font asset at $LOGDEPTH_FONT_PATH")
    return FontLoader(LOGDEPTH_FONT_PATH)
end

logdepth_raw_extent(entry) = Float64(entry.size) * Float64(entry.scale)

function logdepth_visual_z(entry)
    lo = log10(logdepth_raw_extent(first(LOGDEPTH_LABEL_DATA)))
    hi = log10(logdepth_raw_extent(last(LOGDEPTH_LABEL_DATA)))
    span = hi - lo
    span > 0.0 || error("logarithmic depth label span must be positive")
    t = (log10(logdepth_raw_extent(entry)) - lo) / span
    -(LOGDEPTH_VISUAL_MIN_Z +
      (LOGDEPTH_VISUAL_MAX_Z - LOGDEPTH_VISUAL_MIN_Z) * t)
end

function logdepth_color(index::Integer)
    r = 0.28 + 0.58 * (0.5 + 0.5sin(1.71 * index))
    g = 0.28 + 0.58 * (0.5 + 0.5sin(2.13 * index + 1.4))
    b = 0.28 + 0.58 * (0.5 + 0.5sin(2.77 * index + 2.2))
    Color3(r, g, b)
end

function logdepth_text_geometry(font::FontData, label::String)
    geo = TextGeometry(font, label; size=0.55, depth=0.055,
                       curve_segments=4)
    geo.n_vertices > 0 ||
        error("TextGeometry produced no vertices for $(repr(label))")
    return geo
end

function logdepth_center_offset(geo)
    bbox = compute_bounding_box(geo)
    -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function logdepth_label_group(font::FontData, index::Integer, entry)
    material = MeshPhongMaterial(color=logdepth_color(index),
                                 specular=Color3(5 / 255, 5 / 255, 5 / 255),
                                 shininess=50.0)
    group = Group(name="logdepth_label_group_$index")
    group.position = Vec3(0.0, 0.0, logdepth_visual_z(entry))

    label_geo = logdepth_text_geometry(font, entry.label)
    text = Mesh(label_geo, material; name="logdepth_text_$index")
    text.position = Vec3(logdepth_center_offset(label_geo), 0.38, 0.0)
    add!(group, text)

    normalized = (index - 1) / (length(LOGDEPTH_LABEL_DATA) - 1)
    dot = Mesh(SphereGeometry(radius=0.5, width_segments=24, height_segments=12),
               material; name="logdepth_dot_$index")
    dot.position = Vec3(0.0, -0.38, 0.0)
    dot.scale = Vec3(0.20 + 0.85normalized,
                     0.20 + 0.85normalized,
                     0.20 + 0.85normalized)
    add!(group, dot)
    return group
end

function build_logdepth_scene()
    font = logdepth_load_font()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, AmbientLight(color=Color3(119 / 255, 119 / 255, 119 / 255),
                             intensity=1.0,
                             name="logdepth_ambient"))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0),
                                 intensity=3.0,
                                 position=Vec3(100.0, 100.0, 100.0),
                                 name="logdepth_directional"))

    for (index, entry) in enumerate(LOGDEPTH_LABEL_DATA)
        add!(scene, logdepth_label_group(font, index, entry))
    end

    return scene
end

function logdepth_split_camera()
    left_width = round(Int, LOGDEPTH_CANVAS_WIDTH * LOGDEPTH_INITIAL_SPLIT)
    right_width = LOGDEPTH_CANVAS_WIDTH - left_width
    left_aspect = left_width / LOGDEPTH_CANVAS_HEIGHT
    right_aspect = right_width / LOGDEPTH_CANVAS_HEIGHT

    normal = PerspectiveCamera(fov=50pi / 180, aspect=left_aspect,
                               near=LOGDEPTH_NEAR, far=LOGDEPTH_FAR,
                               name="logdepth_normal_zbuffer_camera")
    normal.position = LOGDEPTH_CAMERA_POSITION
    normal.target = LOGDEPTH_CAMERA_TARGET

    logz = PerspectiveCamera(fov=50pi / 180, aspect=right_aspect,
                             near=LOGDEPTH_NEAR, far=LOGDEPTH_FAR,
                             name="logdepth_logarithmic_zbuffer_camera")
    logz.position = LOGDEPTH_CAMERA_POSITION
    logz.target = LOGDEPTH_CAMERA_TARGET

    ArrayCamera([normal, logz],
                [(0, 0, left_width, LOGDEPTH_CANVAS_HEIGHT),
                 (left_width, 0, right_width, LOGDEPTH_CANVAS_HEIGHT)])
end

function build_logdepth_case()
    WebGLExportCase("camera-logarithmicdepthbuffer",
                    "Camera Logarithmic Depth Buffer",
                    "Compressed scale-label scene with normal/logarithmic z-buffer split-view proxy cameras.",
                    build_logdepth_scene();
                    camera=logdepth_split_camera(),
                    target=LOGDEPTH_CAMERA_TARGET,
                    radius=140.0,
                    height=12.0,
                    fov=50pi / 180,
                    tone_mapping=:linear,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_camera_logarithmicdepthbuffer.html"),
                           [build_logdepth_case()])
    println("WEBGL_CAMERA_LOGARITHMICDEPTHBUFFER_OK $html")
end

main()
