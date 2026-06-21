# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const SHADOWMAP_FONT_PATH =
    joinpath(@__DIR__, "assets", "fonts", "optimer_bold.typeface.json")
isdir(OUT) || mkpath(OUT)

const SHADOWMAP_WIDTH = 2048
const SHADOWMAP_HEIGHT = 1024
const SHADOWMAP_FLOOR = -250.0
const SHADOWMAP_NEAR = 10.0
const SHADOWMAP_FAR = 3000.0
const SHADOWMAP_BACKGROUND = Color3(89 / 255, 71 / 255, 43 / 255)
const SHADOWMAP_GROUND_COLOR = Color3(1.0, 221 / 255, 153 / 255)
const SHADOWMAP_CAMERA_POSITION = Vec3(700.0, 50.0, 1900.0)
const SHADOWMAP_TARGET = Vec3(0.0, -75.0, 25.0)
const SHADOWMAP_TEXT_VISUAL_HEIGHT = 200.0
const SHADOWMAP_TEXT_DEPTH = 50.0
const SHADOWMAP_TEXT_PROBE_DEPTH = 0.25
const SHADOWMAP_TEXT_BEVEL_THICKNESS_RATIO = 2.0 / SHADOWMAP_TEXT_VISUAL_HEIGHT
const SHADOWMAP_TEXT_BEVEL_SIZE_RATIO = 5.0 / SHADOWMAP_TEXT_VISUAL_HEIGHT
const SHADOWMAP_WRAP_MIN_X = -1000.0
const SHADOWMAP_WRAP_MAX_X = 2000.0
const SHADOWMAP_DURATION = 60.0
const SHADOWMAP_GAIT_KEYFRAME_COUNT = 481
const SHADOWMAP_RESET_EPSILON = 1e-3

function shadowmap_load_font()
    isfile(SHADOWMAP_FONT_PATH) ||
        error("missing vendored Optimer font asset at $SHADOWMAP_FONT_PATH")
    return FontLoader(SHADOWMAP_FONT_PATH)
end

function shadowmap_text_local_size(font::FontData)
    # Nonzero depth exercises the same extruded font-unit path as the final mesh.
    probe = TextGeometry(font, "THREE.JS"; size=1.0,
                         depth=SHADOWMAP_TEXT_PROBE_DEPTH,
                         curve_segments=12, bevel_enabled=true,
                         bevel_thickness=SHADOWMAP_TEXT_BEVEL_THICKNESS_RATIO,
                         bevel_size=SHADOWMAP_TEXT_BEVEL_SIZE_RATIO,
                         bevel_segments=1)
    probe.n_vertices > 0 || error("TextGeometry produced no vertices")
    bbox = compute_bounding_box(probe)
    height = bbox.max.y - bbox.min.y
    height > 0.0 || error("TextGeometry produced a non-positive height")
    return SHADOWMAP_TEXT_VISUAL_HEIGHT / height
end

function shadowmap_text_geometry(font::FontData)
    local_size = shadowmap_text_local_size(font)
    geo = TextGeometry(font, "THREE.JS"; size=local_size,
                       depth=SHADOWMAP_TEXT_DEPTH,
                       curve_segments=12, bevel_enabled=true,
                       bevel_thickness=SHADOWMAP_TEXT_BEVEL_THICKNESS_RATIO *
                                        local_size,
                       bevel_size=SHADOWMAP_TEXT_BEVEL_SIZE_RATIO * local_size,
                       bevel_segments=1)
    geo.n_vertices > 0 || error("TextGeometry produced no vertices")
    return geo
end

function shadowmap_text_center_offset(geo)
    bbox = compute_bounding_box(geo)
    return -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x
end

function shadowmap_gait_times()
    collect(range(0.0, stop=SHADOWMAP_DURATION,
                  length=SHADOWMAP_GAIT_KEYFRAME_COUNT))
end

function shadowmap_morph_x(t::Real, start_x::Real, speed::Real;
                           min_x::Real=SHADOWMAP_WRAP_MIN_X,
                           max_x::Real=SHADOWMAP_WRAP_MAX_X)
    span = Float64(max_x) - Float64(min_x)
    span > 0.0 || throw(ArgumentError("max_x must be greater than min_x"))
    return Float64(min_x) +
           mod(Float64(start_x) - Float64(min_x) + Float64(speed) * Float64(t),
               span)
end

function shadowmap_position_track(group::Group, start_x::Real, speed::Real,
                                  y::Real, z::Real)
    start = Float64(start_x)
    velocity = Float64(speed)
    velocity > 0.0 || throw(ArgumentError("speed must be positive"))
    span = SHADOWMAP_WRAP_MAX_X - SHADOWMAP_WRAP_MIN_X
    offset = mod(start - SHADOWMAP_WRAP_MIN_X, span)
    first_reset = (span - offset) / velocity
    times = Float64[0.0]

    reset_time = first_reset
    while reset_time < SHADOWMAP_DURATION
        if reset_time > SHADOWMAP_RESET_EPSILON
            push!(times, reset_time - SHADOWMAP_RESET_EPSILON)
        end
        if reset_time + SHADOWMAP_RESET_EPSILON < SHADOWMAP_DURATION
            push!(times, reset_time + SHADOWMAP_RESET_EPSILON)
        end
        reset_time += span / velocity
    end

    push!(times, SHADOWMAP_DURATION)
    unique_times = Float64[]
    for t in sort(times)
        if isempty(unique_times) || t > unique_times[end]
            push!(unique_times, t)
        end
    end

    values = [Vec3(shadowmap_morph_x(t, start, velocity), Float64(y), Float64(z))
              for t in unique_times]
    return KeyframeTrack(group, :position, unique_times, values)
end

function shadowmap_part!(parent::Group, geometry, material; name::String,
                         position=Vec3(), rotation=Euler(),
                         scale=Vec3(1.0, 1.0, 1.0),
                         cast_shadow::Bool=true, receive_shadow::Bool=true)
    part = Mesh(geometry, material; name=name, cast_shadow=cast_shadow,
                receive_shadow=receive_shadow)
    part.position = position
    part.rotation = rotation
    part.scale = scale
    add!(parent, part)
    return part
end

function shadowmap_horse_proxy(name::String, color::Color3)
    group = Group(name=name)
    group.rotation = Euler(0.0, pi / 2, 0.0)

    body_mat = MeshPhongMaterial(color=color, specular=Color3(0.14, 0.10, 0.07),
                                 shininess=24.0)
    dark_mat = MeshPhongMaterial(color=Color3(0.10, 0.065, 0.045),
                                 specular=Color3(0.08, 0.06, 0.05),
                                 shininess=18.0)

    shadowmap_part!(group, BoxGeometry(width=135.0, height=42.0, depth=40.0),
                    body_mat; name="$(name)_body", position=Vec3(0.0, 72.0, 0.0))
    shadowmap_part!(group, CapsuleGeometry(radius=9.0, length=48.0,
                                           cap_segments=6, radial_segments=14),
                    body_mat; name="$(name)_neck", position=Vec3(58.0, 96.0, 0.0),
                    rotation=Euler(0.0, 0.0, -0.72), scale=Vec3(0.82, 1.0, 0.82))
    shadowmap_part!(group, SphereGeometry(radius=1.0, width_segments=24,
                                          height_segments=12),
                    body_mat; name="$(name)_head", position=Vec3(88.0, 113.0, 0.0),
                    scale=Vec3(20.0, 15.0, 13.0))
    shadowmap_part!(group, ConeGeometry(radius=7.0, height=34.0, radial_segments=12),
                    dark_mat; name="$(name)_tail", position=Vec3(-80.0, 80.0, 0.0),
                    rotation=Euler(0.0, 0.0, pi / 2.8),
                    scale=Vec3(0.72, 1.0, 0.72))

    legs = Mesh[]
    for (label, x, z) in (("front_left", 45.0, 15.0),
                          ("front_right", 45.0, -15.0),
                          ("back_left", -45.0, 15.0),
                          ("back_right", -45.0, -15.0))
        leg = shadowmap_part!(
            group,
            CylinderGeometry(radius_top=5.0, radius_bottom=4.0,
                             height=70.0, radial_segments=10),
            dark_mat; name="$(name)_$(label)_leg",
            position=Vec3(x, 35.0, z),
        )
        push!(legs, leg)
    end

    return group, legs
end

function shadowmap_bird_proxy(name::String, color::Color3, wing_color::Color3;
                              long_neck::Bool=false)
    group = Group(name=name)
    group.rotation = Euler(0.0, pi / 2, 0.0)

    body_mat = MeshPhongMaterial(color=color, specular=Color3(0.16, 0.10, 0.09),
                                 shininess=30.0)
    wing_mat = MeshPhongMaterial(color=wing_color,
                                 specular=Color3(0.10, 0.08, 0.08),
                                 shininess=22.0)
    beak_mat = MeshPhongMaterial(color=Color3(1.0, 0.76, 0.24),
                                 specular=Color3(0.18, 0.13, 0.05),
                                 shininess=18.0)

    shadowmap_part!(group, SphereGeometry(radius=1.0, width_segments=24,
                                          height_segments=12),
                    body_mat; name="$(name)_body",
                    position=Vec3(0.0, 0.0, 0.0),
                    scale=Vec3(46.0, 17.0, 19.0))
    neck_y = long_neck ? 34.0 : 17.0
    neck_len = long_neck ? 46.0 : 24.0
    shadowmap_part!(group, CapsuleGeometry(radius=4.0, length=neck_len,
                                           cap_segments=6, radial_segments=12),
                    body_mat; name="$(name)_neck",
                    position=Vec3(31.0, neck_y, 0.0),
                    rotation=Euler(0.0, 0.0, -0.30))
    shadowmap_part!(group, SphereGeometry(radius=1.0, width_segments=18,
                                          height_segments=9),
                    body_mat; name="$(name)_head",
                    position=Vec3(51.0, neck_y + 12.0, 0.0),
                    scale=Vec3(10.0, 8.0, 8.0))
    shadowmap_part!(group, ConeGeometry(radius=3.5, height=17.0, radial_segments=12),
                    beak_mat; name="$(name)_beak",
                    position=Vec3(64.0, neck_y + 12.0, 0.0),
                    rotation=Euler(0.0, 0.0, -pi / 2),
                    receive_shadow=false)

    left_wing = shadowmap_part!(
        group, SphereGeometry(radius=1.0, width_segments=20, height_segments=8),
        wing_mat; name="$(name)_left_wing", position=Vec3(-6.0, 0.0, 18.0),
        rotation=Euler(0.0, 0.20, 0.25), scale=Vec3(42.0, 6.0, 2.5),
    )
    right_wing = shadowmap_part!(
        group, SphereGeometry(radius=1.0, width_segments=20, height_segments=8),
        wing_mat; name="$(name)_right_wing", position=Vec3(-6.0, 0.0, -18.0),
        rotation=Euler(0.0, -0.20, -0.25), scale=Vec3(42.0, 6.0, 2.5),
    )

    return group, (left_wing, right_wing)
end

function shadowmap_leg_tracks(legs::Vector{Mesh}, times::Vector{Float64};
                              duration::Real=1.0)
    tracks = AbstractKeyframeTrack[]
    phases = (0.0, pi, pi, 0.0)
    for (leg, phase) in zip(legs, phases)
        values = [0.38 * sin(2pi * t / Float64(duration) + phase) for t in times]
        push!(tracks, NumberKeyframeTrack(leg, "rotation.x", copy(times), values))
    end
    return tracks
end

function shadowmap_wing_tracks(wings, times::Vector{Float64}, duration::Real,
                               base_left::Real=0.25, base_right::Real=-0.25)
    period = Float64(duration)
    left, right = wings
    left_values = [Float64(base_left) + 0.55 * sin(2pi * t / period) for t in times]
    right_values = [Float64(base_right) - 0.55 * sin(2pi * t / period) for t in times]
    return AbstractKeyframeTrack[
        NumberKeyframeTrack(left, "rotation.z", copy(times), left_values),
        NumberKeyframeTrack(right, "rotation.z", copy(times), right_values),
    ]
end

function shadowmap_ground()
    ground = Mesh(PlaneGeometry(width=100.0, height=100.0),
                  MeshPhongMaterial(color=SHADOWMAP_GROUND_COLOR);
                  name="shadowmap_ground", receive_shadow=true)
    ground.position = Vec3(0.0, SHADOWMAP_FLOOR, 0.0)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    ground.scale = Vec3(100.0, 100.0, 100.0)
    return ground
end

function shadowmap_text(font::FontData)
    geo = shadowmap_text_geometry(font)
    material = MeshPhongMaterial(color=Color3(1.0, 0.0, 0.0),
                                 specular=Color3(1.0, 1.0, 1.0))
    text = Mesh(geo, material; name="shadowmap_text_three_js",
                cast_shadow=true, receive_shadow=true)
    bbox = compute_bounding_box(geo)
    text.position = Vec3(shadowmap_text_center_offset(geo),
                         SHADOWMAP_FLOOR + 67.0 - bbox.min.y, 0.0)
    return text
end

function shadowmap_block(width::Real, height::Real, depth::Real, name::String)
    block = Mesh(BoxGeometry(width=Float64(width), height=Float64(height),
                             depth=Float64(depth)),
                 MeshPhongMaterial(color=SHADOWMAP_GROUND_COLOR);
                 name=name, cast_shadow=true, receive_shadow=true)
    block.position = Vec3(0.0, SHADOWMAP_FLOOR - 50.0, 20.0)
    return block
end

function build_shadowmap_case()
    font = shadowmap_load_font()
    scene = Scene(background=SHADOWMAP_BACKGROUND,
                  fog=Fog(color=SHADOWMAP_BACKGROUND, near=1000.0,
                          far=SHADOWMAP_FAR))

    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                             name="shadowmap_ambient"))
    dir = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                           position=Vec3(0.0, 1500.0, 1000.0),
                           cast_shadow=true, shadow_bias=0.0001,
                           shadow_pcf_radius=1,
                           name="shadowmap_directional")
    add!(scene, dir)

    add!(scene, shadowmap_ground())
    add!(scene, shadowmap_text(font))
    add!(scene, shadowmap_block(1500.0, 220.0, 150.0, "shadowmap_block_low"))
    add!(scene, shadowmap_block(1600.0, 170.0, 250.0, "shadowmap_block_high"))

    tracks = AbstractKeyframeTrack[]
    gait_times = shadowmap_gait_times()

    horse_zs = (300.0, 450.0, 600.0, -300.0, -450.0, -600.0)
    horse_starts = (0.0, -180.0, -360.0, -540.0, -720.0, -900.0)
    horse_colors = (Color3(0.46, 0.25, 0.11), Color3(0.78, 0.58, 0.36),
                    Color3(0.30, 0.19, 0.12), Color3(0.66, 0.42, 0.22),
                    Color3(0.20, 0.15, 0.12), Color3(0.84, 0.70, 0.55))
    for idx in eachindex(horse_zs)
        horse, legs = shadowmap_horse_proxy("shadowmap_horse_$idx",
                                            horse_colors[idx])
        horse.position = Vec3(horse_starts[idx], SHADOWMAP_FLOOR, horse_zs[idx])
        add!(scene, horse)
        push!(tracks, shadowmap_position_track(horse, horse_starts[idx], 550.0,
                                               SHADOWMAP_FLOOR, horse_zs[idx]))
        append!(tracks, shadowmap_leg_tracks(legs, gait_times; duration=1.0))
    end

    birds = (
        ("shadowmap_flamingo", 280.0, 500.0, SHADOWMAP_FLOOR + 350.0, 40.0,
         Color3(1.0, 0.36, 0.50), Color3(0.88, 0.16, 0.26), true, 1.0),
        ("shadowmap_stork", 160.0, 350.0, SHADOWMAP_FLOOR + 350.0, 340.0,
         Color3(0.92, 0.88, 0.82), Color3(0.18, 0.18, 0.20), true, 1.0),
        ("shadowmap_parrot", 60.0, 450.0, SHADOWMAP_FLOOR + 300.0, 700.0,
         Color3(0.14, 0.68, 0.24), Color3(0.08, 0.34, 0.95), false, 0.5),
    )
    for (name, start_x, speed, y, z, body_color, wing_color, long_neck,
         wing_duration) in birds
        bird, wings = shadowmap_bird_proxy(name, body_color, wing_color;
                                           long_neck=long_neck)
        bird.position = Vec3(start_x, y, z)
        add!(scene, bird)
        push!(tracks, shadowmap_position_track(bird, start_x, speed, y, z))
        append!(tracks, shadowmap_wing_tracks(wings, gait_times, wing_duration))
    end

    clip = AnimationClip("shadowmap_morph_motion",
                         SHADOWMAP_DURATION, tracks; loop=:repeat)

    camera = PerspectiveCamera(fov=23pi / 180, aspect=16 / 9,
                               near=SHADOWMAP_NEAR, far=SHADOWMAP_FAR)
    camera.position = SHADOWMAP_CAMERA_POSITION
    camera.target = SHADOWMAP_TARGET

    WebGLExportCase("shadowmap", "Shadowmap",
                    "Directional shadow-map scene with beveled text, blocks, and animated horse/bird proxy morphs.",
                    scene; camera=camera, target=SHADOWMAP_TARGET,
                    radius=2050.0, height=-75.0, fov=23pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap.html"),
                           [build_shadowmap_case()])
    println("WEBGL_SHADOWMAP_OK $html")
end

main()
