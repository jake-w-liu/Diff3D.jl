# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_pointlight

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SHADOWMAP_POINTLIGHT_INTENSITY = 200.0
const SHADOWMAP_POINTLIGHT_DISTANCE = 20.0
const SHADOWMAP_POINTLIGHT_SHADOW_BIAS = -0.005
const SHADOWMAP_POINTLIGHT_PCF_RADIUS = 4
const SHADOWMAP_POINTLIGHT_SECOND_PHASE = 10000.0
const SHADOWMAP_POINTLIGHT_DURATION = 20pi
const SHADOWMAP_POINTLIGHT_KEYFRAME_COUNT = 97
const SHADOWMAP_POINTLIGHT_TARGET = Vec3(0.0, 10.0, 0.0)
const SHADOWMAP_POINTLIGHT_CAMERA_POSITION = Vec3(0.0, 10.0, 40.0)

function shadowmap_pointlight_position(t::Real; phase::Real=0.0)
    tau = Float64(t) + Float64(phase)
    Vec3(sin(0.6tau) * 9.0,
         sin(0.7tau) * 9.0 + 6.0,
         sin(0.8tau) * 9.0)
end

function shadowmap_pointlight_key_times()
    collect(range(0.0, stop=SHADOWMAP_POINTLIGHT_DURATION,
                  length=SHADOWMAP_POINTLIGHT_KEYFRAME_COUNT))
end

function shadowmap_pointlight_positions(times::Vector{Float64}, phase::Real)
    [shadowmap_pointlight_position(t; phase=phase) for t in times]
end

function shadowmap_pointlight_rotation_values(times::Vector{Float64}, phase::Real)
    [t + Float64(phase) for t in times]
end

function shadowmap_pointlight_alpha_texture()
    data = zeros(Float64, 2, 2, 3)
    data[2, :, :] .= 1.0
    CanvasTexture(data; repeat=Vec2(1.0, 4.5), wrap_s=:repeat, wrap_t=:repeat,
                  filter=:nearest, min_filter=:nearest, mag_filter=:nearest,
                  colorspace=:linear)
end

function create_shadowmap_pointlight(name::String, color::Color3, phase::Real)
    initial_position = shadowmap_pointlight_position(0.0; phase=phase)
    light = PointLight(color=color, intensity=SHADOWMAP_POINTLIGHT_INTENSITY,
                       distance=SHADOWMAP_POINTLIGHT_DISTANCE, decay=2.0,
                       position=initial_position, cast_shadow=true,
                       shadow_bias=SHADOWMAP_POINTLIGHT_SHADOW_BIAS,
                       shadow_pcf_radius=SHADOWMAP_POINTLIGHT_PCF_RADIUS,
                       name="$(name)_light")

    visual = Group(name="$(name)_visual")
    visual.position = initial_position
    visual.rotation = Euler(Float64(phase), 0.0, Float64(phase))

    marker = Mesh(SphereGeometry(radius=0.3, width_segments=12, height_segments=6),
                  MeshBasicMaterial(color=color * SHADOWMAP_POINTLIGHT_INTENSITY);
                  name="$(name)_emissive_marker")
    add!(visual, marker)

    shell = Mesh(SphereGeometry(radius=2.0, width_segments=32, height_segments=8),
                 MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                   side=:double,
                                   alpha_map=shadowmap_pointlight_alpha_texture(),
                                   alpha_test=0.5);
                 name="$(name)_alpha_shadow_shell",
                 cast_shadow=true, receive_shadow=true)
    add!(visual, shell)

    return light, visual
end

function shadowmap_pointlight_motion_tracks(light::PointLight, visual::Group,
                                            phase::Real)
    times = shadowmap_pointlight_key_times()
    positions = shadowmap_pointlight_positions(times, phase)
    rotations = shadowmap_pointlight_rotation_values(times, phase)
    AbstractKeyframeTrack[
        KeyframeTrack(light, :position, copy(times), copy(positions)),
        KeyframeTrack(visual, :position, copy(times), copy(positions)),
        NumberKeyframeTrack(visual, "rotation.x", copy(times), copy(rotations)),
        NumberKeyframeTrack(visual, "rotation.z", copy(times), copy(rotations)),
    ]
end

function shadowmap_pointlight_room()
    room = Mesh(BoxGeometry(width=30.0, height=30.0, depth=30.0),
                MeshPhongMaterial(color=Color3(0.627, 0.678, 0.686),
                                  shininess=10.0,
                                  specular=Color3(0.067, 0.067, 0.067),
                                  side=:back);
                name="shadowmap_pointlight_room", receive_shadow=true)
    room.position = Vec3(0.0, 10.0, 0.0)
    return room
end

function build_shadowmap_pointlight_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, AmbientLight(color=Color3(0.067, 0.067, 0.133), intensity=3.0,
                             name="shadowmap_pointlight_ambient"))

    blue_light, blue_visual =
        create_shadowmap_pointlight("shadowmap_blue_point",
                                    Color3(0.0, 0.533, 1.0), 0.0)
    red_light, red_visual =
        create_shadowmap_pointlight("shadowmap_red_point",
                                    Color3(1.0, 0.533, 0.533),
                                    SHADOWMAP_POINTLIGHT_SECOND_PHASE)

    add!(scene, blue_light)
    add!(scene, blue_visual)
    add!(scene, red_light)
    add!(scene, red_visual)
    add!(scene, shadowmap_pointlight_room())

    tracks = AbstractKeyframeTrack[]
    append!(tracks, shadowmap_pointlight_motion_tracks(blue_light, blue_visual, 0.0))
    append!(tracks, shadowmap_pointlight_motion_tracks(red_light, red_visual,
                                                       SHADOWMAP_POINTLIGHT_SECOND_PHASE))
    clip = AnimationClip("shadowmap_pointlight_motion",
                         SHADOWMAP_POINTLIGHT_DURATION, tracks; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = SHADOWMAP_POINTLIGHT_CAMERA_POSITION
    camera.target = SHADOWMAP_POINTLIGHT_TARGET

    WebGLExportCase("shadowmap-pointlight", "Shadowmap PointLight",
                    "Two animated colored point lights with dynamic shadows inside a back-sided Phong room.",
                    scene; camera=camera, target=SHADOWMAP_POINTLIGHT_TARGET,
                    radius=42.0, height=10.0, fov=45pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_pointlight.html"),
                           [build_shadowmap_pointlight_case()])
    println("WEBGL_SHADOWMAP_POINTLIGHT_OK $html")
end

main()
