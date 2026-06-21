# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lights_spotlight

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SPOTLIGHT_ORBIT_RADIUS = 2.5
const SPOTLIGHT_HEIGHT = 5.0
const SPOTLIGHT_PERIOD = 6pi
const SPOTLIGHT_GROUND_SIZE = 10.0
const SPOTLIGHT_CAMERA_POSITION = Vec3(7.0, 4.0, 1.0)
const SPOTLIGHT_TARGET = Vec3(0.0, 1.0, 0.0)

spotlight_position(theta::Float64) =
    Vec3(cos(theta) * SPOTLIGHT_ORBIT_RADIUS,
         SPOTLIGHT_HEIGHT,
         sin(theta) * SPOTLIGHT_ORBIT_RADIUS)

function spotlight_ground()
    ground = Mesh(PlaneGeometry(width=SPOTLIGHT_GROUND_SIZE,
                                height=SPOTLIGHT_GROUND_SIZE),
                  MeshLambertMaterial(color=Color3(0.737, 0.737, 0.737));
                  name="spotlight_ground", receive_shadow=true)
    ground.position = Vec3(0.0, -1.0, 0.0)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    return ground
end

function build_lucy_proxy()
    material = MeshLambertMaterial(color=Color3(0.86, 0.82, 0.74))
    sculpture = Mesh(TorusKnotGeometry(radius=0.62, tube=0.16,
                                       tubular_segments=128,
                                       radial_segments=16,
                                       p_val=2, q_val=3),
                     material; name="spotlight_lucy_proxy",
                     cast_shadow=true, receive_shadow=true)
    sculpture.position = Vec3(0.0, 0.8, 0.0)
    sculpture.rotation = Euler(0.0, -pi / 2, 0.0)
    sculpture.scale = Vec3(1.0, 1.28, 1.0)
    return sculpture
end

function spotlight_motion_track(spot::SpotLight)
    samples = 16
    times = [SPOTLIGHT_PERIOD * (i - 1) / samples for i in 1:(samples + 1)]
    positions = [spotlight_position(2pi * (i - 1) / samples) for i in 1:(samples + 1)]
    KeyframeTrack(spot, :position, times, positions)
end

function build_lights_spotlight_case()
    scene = Scene(background=Color3(0.03, 0.032, 0.038))

    ambient = HemisphereLight(color=Color3(1.0, 1.0, 1.0),
                              ground_color=Color3(0.553, 0.553, 0.553),
                              intensity=0.25, name="spotlight_hemisphere_ambient")
    add!(scene, ambient)

    spot = SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=100.0,
                     distance=0.0, angle=pi / 6, penumbra=1.0, decay=2.0,
                     position=spotlight_position(0.0), target=SPOTLIGHT_TARGET,
                     cast_shadow=true, shadow_bias=-0.003,
                     name="spotLight")
    add!(scene, spot)
    helper = SpotLightHelper(spot; color=Color3(1.0, 0.92, 0.35))
    helper.visible = false
    add!(scene, helper)

    add!(scene, spotlight_ground())
    add!(scene, build_lucy_proxy())

    clip = AnimationClip("spotlight_orbit", AbstractKeyframeTrack[
        spotlight_motion_track(spot)
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9, near=0.1, far=100.0)
    camera.position = SPOTLIGHT_CAMERA_POSITION
    camera.target = SPOTLIGHT_TARGET

    WebGLExportCase("lights-spotlight", "Lights Spotlight",
                    "Animated shadow-casting spotlight over a receiving plane and procedural Lucy proxy.",
                    scene; camera=camera, target=camera.target, radius=7.5,
                    height=1.0, fov=40pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lights_spotlight.html"),
                           [build_lights_spotlight_case()])
    println("WEBGL_LIGHTS_SPOTLIGHT_OK $html")
end

main()
