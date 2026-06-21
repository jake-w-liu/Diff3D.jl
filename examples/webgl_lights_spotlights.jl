# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lights_spotlights

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SPOTLIGHTS_FLOOR_SIZE = 100.0
const SPOTLIGHTS_BOX_SIZE = Vec3(0.3, 0.1, 0.2)
const SPOTLIGHTS_CAMERA_POSITION = Vec3(4.6, 2.2, -2.1)
const SPOTLIGHTS_TARGET = Vec3(0.0, 0.5, 0.0)
const SPOTLIGHTS_DURATION = 6.0

function spotlights_floor()
    floor = Mesh(PlaneGeometry(width=SPOTLIGHTS_FLOOR_SIZE,
                               height=SPOTLIGHTS_FLOOR_SIZE),
                 MeshPhongMaterial(color=Color3(0.502, 0.502, 0.502));
                 name="spotlights_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -0.05, 0.0)
    return floor
end

function spotlights_box()
    box = Mesh(BoxGeometry(width=SPOTLIGHTS_BOX_SIZE.x,
                           height=SPOTLIGHTS_BOX_SIZE.y,
                           depth=SPOTLIGHTS_BOX_SIZE.z),
               MeshPhongMaterial(color=Color3(0.667, 0.667, 0.667));
               name="spotlights_box", cast_shadow=true, receive_shadow=true)
    box.position = SPOTLIGHTS_TARGET
    return box
end

function create_spotlights_spot(name::String, color::Color3, position::Vec3)
    SpotLight(color=color, intensity=10.0, distance=50.0, angle=0.3,
              penumbra=0.2, decay=2.0, position=position,
              target=SPOTLIGHTS_TARGET, cast_shadow=true, name=name)
end

function spotlights_position_track(light::SpotLight, positions::Vector{Vec3{Float64}})
    KeyframeTrack(light, :position, [0.0, SPOTLIGHTS_DURATION / 2, SPOTLIGHTS_DURATION],
                  positions)
end

function spotlights_angle_track(light::SpotLight, mid::Float64)
    NumberKeyframeTrack(light, :angle, [0.0, SPOTLIGHTS_DURATION / 2, SPOTLIGHTS_DURATION],
                        [0.3, mid, 0.3])
end

function spotlights_penumbra_track(light::SpotLight, mid::Float64)
    NumberKeyframeTrack(light, :penumbra, [0.0, SPOTLIGHTS_DURATION / 2, SPOTLIGHTS_DURATION],
                        [0.2, mid, 0.2])
end

function build_lights_spotlights_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    add!(scene, spotlights_floor())
    add!(scene, spotlights_box())
    add!(scene, AmbientLight(color=Color3(0.267, 0.267, 0.267), intensity=1.0,
                             name="spotlights_ambient"))

    spot1 = create_spotlights_spot("spotLight1", Color3(1.0, 0.498, 0.0),
                                   Vec3(1.5, 4.0, 4.5))
    spot2 = create_spotlights_spot("spotLight2", Color3(0.0, 1.0, 0.498),
                                   Vec3(0.0, 4.0, 3.5))
    spot3 = create_spotlights_spot("spotLight3", Color3(0.498, 0.0, 1.0),
                                   Vec3(-1.5, 4.0, 4.5))

    for spot in (spot1, spot2, spot3)
        add!(scene, spot)
        add!(scene, SpotLightHelper(spot; color=spot.color))
    end

    clip = AnimationClip("spotlights_deterministic_tween", AbstractKeyframeTrack[
        spotlights_position_track(spot1, [Vec3(1.5, 4.0, 4.5),
                                          Vec3(1.2, 2.2, -1.3),
                                          Vec3(1.5, 4.0, 4.5)]),
        spotlights_position_track(spot2, [Vec3(0.0, 4.0, 3.5),
                                          Vec3(-0.8, 1.9, 1.0),
                                          Vec3(0.0, 4.0, 3.5)]),
        spotlights_position_track(spot3, [Vec3(-1.5, 4.0, 4.5),
                                          Vec3(1.1, 2.4, 0.2),
                                          Vec3(-1.5, 4.0, 4.5)]),
        spotlights_angle_track(spot1, 0.62),
        spotlights_angle_track(spot2, 0.46),
        spotlights_angle_track(spot3, 0.76),
        spotlights_penumbra_track(spot1, 0.75),
        spotlights_penumbra_track(spot2, 0.58),
        spotlights_penumbra_track(spot3, 0.92),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=35pi / 180, aspect=16 / 9, near=0.1, far=100.0)
    camera.position = SPOTLIGHTS_CAMERA_POSITION
    camera.target = SPOTLIGHTS_TARGET

    WebGLExportCase("lights-spotlights", "Lights SpotLights",
                    "Three animated colored spotlights over a shadowed floor and box.",
                    scene; camera=camera, target=camera.target, radius=5.2,
                    height=0.5, fov=35pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lights_spotlights.html"),
                           [build_lights_spotlights_case()])
    println("WEBGL_LIGHTS_SPOTLIGHTS_OK $html")
end

main()
