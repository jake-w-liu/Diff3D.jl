# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_performance

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const PERFORMANCE_FONT_PATH =
    joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
isdir(OUT) || mkpath(OUT)

const PERFORMANCE_SHADOW_MAP_WIDTH = 2048
const PERFORMANCE_SHADOW_MAP_HEIGHT = 1024
const PERFORMANCE_FLOOR = -250.0
const PERFORMANCE_NEAR = 5.0
const PERFORMANCE_FAR = 3000.0
const PERFORMANCE_ANIMATION_GROUPS = 25
const PERFORMANCE_HORSE_COUNT = 601
const PERFORMANCE_SHADOW_CASTING_GROUPS = 5
const PERFORMANCE_HORSE_SPEED = 550.0
const PERFORMANCE_WRAP_MIN_X = -1000.0
const PERFORMANCE_WRAP_MAX_X = 2000.0
const PERFORMANCE_WRAP_SPAN = PERFORMANCE_WRAP_MAX_X - PERFORMANCE_WRAP_MIN_X
const PERFORMANCE_DURATION = PERFORMANCE_WRAP_SPAN / PERFORMANCE_HORSE_SPEED
const PERFORMANCE_RESET_EPSILON = 1e-3
const PERFORMANCE_BACKGROUND = Color3(89 / 255, 71 / 255, 43 / 255)
const PERFORMANCE_GROUND_COLOR = Color3(1.0, 221 / 255, 153 / 255)
const PERFORMANCE_CAMERA_POSITION = Vec3(700.0, 50.0, 1900.0)
const PERFORMANCE_TARGET = Vec3(0.0, -75.0, 25.0)
const PERFORMANCE_TEXT_VISUAL_HEIGHT = 200.0
const PERFORMANCE_TEXT_DEPTH = 50.0
const PERFORMANCE_TEXT_PROBE_DEPTH = 0.25
const PERFORMANCE_TEXT_BEVEL_THICKNESS_RATIO =
    2.0 / PERFORMANCE_TEXT_VISUAL_HEIGHT
const PERFORMANCE_TEXT_BEVEL_SIZE_RATIO = 5.0 / PERFORMANCE_TEXT_VISUAL_HEIGHT

performance_fract(x::Float64) = x - floor(x)

function performance_load_font()
    isfile(PERFORMANCE_FONT_PATH) ||
        error("missing vendored Optimer font asset at $PERFORMANCE_FONT_PATH")
    return FontLoader(PERFORMANCE_FONT_PATH)
end

function performance_text_local_size(font::FontData)
    probe = TextGeometry(font, "THREE.JS"; size=1.0,
                         depth=PERFORMANCE_TEXT_PROBE_DEPTH,
                         curve_segments=12, bevel_enabled=true,
                         bevel_thickness=PERFORMANCE_TEXT_BEVEL_THICKNESS_RATIO,
                         bevel_size=PERFORMANCE_TEXT_BEVEL_SIZE_RATIO,
                         bevel_segments=1)
    probe.n_vertices > 0 || error("TextGeometry produced no vertices")
    bbox = compute_bounding_box(probe)
    height = bbox.max.y - bbox.min.y
    height > 0.0 || error("TextGeometry produced a non-positive height")
    return PERFORMANCE_TEXT_VISUAL_HEIGHT / height
end

function performance_text_geometry(font::FontData)
    local_size = performance_text_local_size(font)
    geo = TextGeometry(font, "THREE.JS"; size=local_size,
                       depth=PERFORMANCE_TEXT_DEPTH,
                       curve_segments=12, bevel_enabled=true,
                       bevel_thickness=PERFORMANCE_TEXT_BEVEL_THICKNESS_RATIO *
                                        local_size,
                       bevel_size=PERFORMANCE_TEXT_BEVEL_SIZE_RATIO * local_size,
                       bevel_segments=1)
    geo.n_vertices > 0 || error("TextGeometry produced no vertices")
    return geo
end

function performance_text_center_offset(geo)
    bbox = compute_bounding_box(geo)
    return -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function performance_horse_z(index::Integer)
    1 <= index <= PERFORMANCE_HORSE_COUNT ||
        throw(ArgumentError("horse index must be in 1:$PERFORMANCE_HORSE_COUNT"))
    return -600.0 + 2.0 * (index - 1)
end

function performance_horse_local_x(index::Integer)
    1 <= index <= PERFORMANCE_HORSE_COUNT ||
        throw(ArgumentError("horse index must be in 1:$PERFORMANCE_HORSE_COUNT"))
    return 120.0 *
           (performance_fract(sin(12.9898 * index) * 43758.5453) - 0.5)
end

function performance_horse_color(index::Integer)
    u = performance_fract(sin(78.233 * index) * 9514.721)
    v = performance_fract(sin(31.416 * index) * 1842.997)
    Color3(0.33 + 0.35u, 0.20 + 0.24v, 0.11 + 0.16 * (1.0 - u))
end

function performance_group_indices(group_index::Integer)
    1 <= group_index <= PERFORMANCE_ANIMATION_GROUPS ||
        throw(ArgumentError("group index must be in 1:$PERFORMANCE_ANIMATION_GROUPS"))
    [i for i in 1:PERFORMANCE_HORSE_COUNT
     if mod(i - 1, PERFORMANCE_ANIMATION_GROUPS) + 1 == group_index]
end

function performance_group_x(t::Real, group_index::Integer)
    1 <= group_index <= PERFORMANCE_ANIMATION_GROUPS ||
        throw(ArgumentError("group index must be in 1:$PERFORMANCE_ANIMATION_GROUPS"))
    phase = (group_index - 1) / PERFORMANCE_ANIMATION_GROUPS *
            PERFORMANCE_WRAP_SPAN
    PERFORMANCE_WRAP_MIN_X +
        mod(phase + PERFORMANCE_HORSE_SPEED * Float64(t),
            PERFORMANCE_WRAP_SPAN)
end

function performance_group_position_track(group::Group, group_index::Integer)
    phase = (group_index - 1) / PERFORMANCE_ANIMATION_GROUPS *
            PERFORMANCE_WRAP_SPAN
    first_reset = (PERFORMANCE_WRAP_SPAN - phase) / PERFORMANCE_HORSE_SPEED
    times = Float64[0.0]
    if 0.0 < first_reset < PERFORMANCE_DURATION
        push!(times, max(0.0, first_reset - PERFORMANCE_RESET_EPSILON))
        push!(times, min(PERFORMANCE_DURATION,
                         first_reset + PERFORMANCE_RESET_EPSILON))
    end
    push!(times, PERFORMANCE_DURATION)
    sort!(unique!(times))
    values = [Vec3(performance_group_x(t, group_index), PERFORMANCE_FLOOR, 0.0)
              for t in times]
    return KeyframeTrack(group, :position, times, values)
end

function performance_horse_proxy_geometry()
    box(width, height, depth, position; rotation=Mat4()) =
        transform_geometry(BoxGeometry(width=width, height=height, depth=depth),
                           mat4_translation(position.x, position.y, position.z) *
                           mat4_rotation_y(pi / 2) *
                           rotation)

    geos = BufferGeometry[
        box(135.0, 42.0, 40.0, Vec3(0.0, 72.0, 0.0)),
        box(18.0, 50.0, 18.0, Vec3(58.0, 96.0, 0.0);
            rotation=mat4_rotation_z(-0.72)),
        box(36.0, 24.0, 24.0, Vec3(88.0, 113.0, 0.0)),
    ]

    return merge_geometries(geos; with_groups=false)
end

function performance_instanced_horses(group_index::Integer, geometry, material)
    indices = performance_group_indices(group_index)
    inst = InstancedMesh(geometry, material, length(indices);
                         name="shadowmap_performance_group_$(group_index)_horses",
                         cast_shadow=group_index <= PERFORMANCE_SHADOW_CASTING_GROUPS,
                         receive_shadow=true)
    for (slot, index) in enumerate(indices)
        set_instance_matrix!(inst, slot,
                             mat4_translation(performance_horse_local_x(index),
                                              0.0,
                                              performance_horse_z(index)))
        set_instance_color!(inst, slot, performance_horse_color(index))
    end
    return inst
end

function performance_horse_group(group_index::Integer, geometry)
    group = Group(name="shadowmap_performance_anim_group_$group_index")
    group.position = Vec3(performance_group_x(0.0, group_index),
                          PERFORMANCE_FLOOR, 0.0)

    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 specular=Color3(0.14, 0.10, 0.07),
                                 shininess=24.0)
    add!(group, performance_instanced_horses(group_index, geometry, material))

    return group
end

function performance_ground()
    ground = Mesh(PlaneGeometry(width=100.0, height=100.0),
                  MeshPhongMaterial(color=PERFORMANCE_GROUND_COLOR);
                  name="shadowmap_performance_ground", receive_shadow=true)
    ground.position = Vec3(0.0, PERFORMANCE_FLOOR, 0.0)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    ground.scale = Vec3(100.0, 100.0, 100.0)
    return ground
end

function performance_text(font::FontData)
    geo = performance_text_geometry(font)
    material = MeshPhongMaterial(color=Color3(1.0, 0.0, 0.0),
                                 specular=Color3(1.0, 1.0, 1.0))
    text = Mesh(geo, material; name="shadowmap_performance_text_three_js",
                cast_shadow=true, receive_shadow=true)
    bbox = compute_bounding_box(geo)
    text.position = Vec3(performance_text_center_offset(geo),
                         PERFORMANCE_FLOOR + 67.0 - bbox.min.y, 0.0)
    return text
end

function performance_block(width::Real, height::Real, depth::Real, name::String)
    block = Mesh(BoxGeometry(width=Float64(width), height=Float64(height),
                             depth=Float64(depth)),
                 MeshPhongMaterial(color=PERFORMANCE_GROUND_COLOR);
                 name=name, cast_shadow=true, receive_shadow=true)
    block.position = Vec3(0.0, PERFORMANCE_FLOOR - 50.0, 20.0)
    return block
end

function build_shadowmap_performance_case()
    font = performance_load_font()
    scene = Scene(background=PERFORMANCE_BACKGROUND,
                  fog=Fog(color=PERFORMANCE_BACKGROUND, near=1000.0,
                          far=PERFORMANCE_FAR))

    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                             name="shadowmap_performance_ambient"))
    dir = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                           position=Vec3(0.0, 1500.0, 1000.0),
                           cast_shadow=true, shadow_bias=0.0001,
                           shadow_pcf_radius=1,
                           name="shadowmap_performance_directional")
    add!(scene, dir)

    add!(scene, performance_ground())
    add!(scene, performance_text(font))
    add!(scene, performance_block(1500.0, 220.0, 150.0,
                                  "shadowmap_performance_block_low"))
    add!(scene, performance_block(1600.0, 170.0, 250.0,
                                  "shadowmap_performance_block_high"))

    tracks = AbstractKeyframeTrack[]
    horse_geometry = performance_horse_proxy_geometry()
    for group_index in 1:PERFORMANCE_ANIMATION_GROUPS
        group = performance_horse_group(group_index, horse_geometry)
        add!(scene, group)
        push!(tracks, performance_group_position_track(group, group_index))
    end
    clip = AnimationClip("shadowmap_performance_group_motion",
                         PERFORMANCE_DURATION, tracks; loop=:repeat)

    camera = PerspectiveCamera(fov=23pi / 180, aspect=16 / 9,
                               near=PERFORMANCE_NEAR, far=PERFORMANCE_FAR)
    camera.position = PERFORMANCE_CAMERA_POSITION
    camera.target = PERFORMANCE_TARGET

    WebGLExportCase("shadowmap-performance", "Shadowmap Performance",
                    "High-count instanced horse shadow scene with deterministic animation groups.",
                    scene; camera=camera, target=PERFORMANCE_TARGET,
                    radius=2050.0, height=-75.0, fov=23pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_performance.html"),
                           [build_shadowmap_performance_case()])
    println("WEBGL_SHADOWMAP_PERFORMANCE_OK $html")
end

main()
