# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_vsm

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SHADOWMAP_VSM_BACKGROUND = Color3(0.133, 0.133, 0.267)
const SHADOWMAP_VSM_SHADOW_RADIUS = 4
const SHADOWMAP_VSM_DURATION = 40pi
const SHADOWMAP_VSM_KEYFRAME_COUNT = 121
const SHADOWMAP_VSM_CAMERA_POSITION = Vec3(0.0, 10.0, 30.0)
const SHADOWMAP_VSM_TARGET = Vec3(0.0, 2.0, 0.0)

function shadowmap_vsm_key_times()
    collect(range(0.0, stop=SHADOWMAP_VSM_DURATION,
                  length=SHADOWMAP_VSM_KEYFRAME_COUNT))
end

function shadowmap_vsm_directional_position(t::Real)
    yaw = 0.7 * Float64(t)
    local_z = 17.0 + sin(Float64(t)) * 5.0
    Vec3(cos(yaw) * 3.0 + sin(yaw) * local_z,
         12.0,
         -sin(yaw) * 3.0 + cos(yaw) * local_z)
end

function shadowmap_vsm_phong_material(; color::Color3=Color3(0.6, 0.6, 0.6),
                                      specular::Color3=Color3(0.133, 0.133, 0.133))
    MeshPhongMaterial(color=color, shininess=0.0, specular=specular)
end

function build_shadowmap_vsm_case()
    scene = Scene(background=SHADOWMAP_VSM_BACKGROUND,
                  fog=Fog(color=SHADOWMAP_VSM_BACKGROUND, near=50.0, far=100.0))

    add!(scene, AmbientLight(color=Color3(0.267, 0.267, 0.267), intensity=1.0,
                             name="shadowmap_vsm_ambient"))

    spot = SpotLight(color=Color3(1.0, 0.533, 0.533), intensity=400.0,
                     angle=pi / 5, penumbra=0.3, decay=2.0,
                     position=Vec3(8.0, 10.0, 5.0), target=Vec3(0.0, 0.0, 0.0),
                     cast_shadow=true, shadow_bias=-0.002,
                     shadow_pcf_radius=SHADOWMAP_VSM_SHADOW_RADIUS,
                     name="shadowmap_vsm_spot")
    add!(scene, spot)

    dir = DirectionalLight(color=Color3(0.533, 0.533, 1.0), intensity=3.0,
                           position=shadowmap_vsm_directional_position(0.0),
                           cast_shadow=true, shadow_bias=-0.0005,
                           shadow_pcf_radius=SHADOWMAP_VSM_SHADOW_RADIUS,
                           name="shadowmap_vsm_directional")
    add!(scene, dir)

    shared_material = shadowmap_vsm_phong_material()

    torus = Mesh(TorusKnotGeometry(radius=25.0, tube=8.0,
                                   tubular_segments=75, radial_segments=20),
                 shared_material; name="shadowmap_vsm_torus_knot",
                 cast_shadow=true, receive_shadow=true)
    torus.scale = Vec3(1 / 18, 1 / 18, 1 / 18)
    torus.position = Vec3(0.0, 3.0, 0.0)
    add!(scene, torus)

    cylinder_geometry = CylinderGeometry(radius_top=0.75, radius_bottom=0.75,
                                         height=7.0, radial_segments=32)
    for (idx, pos) in enumerate((Vec3(8.0, 3.5, 8.0),
                                 Vec3(8.0, 3.5, -8.0),
                                 Vec3(-8.0, 3.5, 8.0),
                                 Vec3(-8.0, 3.5, -8.0)))
        pillar = Mesh(cylinder_geometry, shared_material;
                      name="shadowmap_vsm_pillar_$idx",
                      cast_shadow=true, receive_shadow=true)
        pillar.position = pos
        add!(scene, pillar)
    end

    ground = Mesh(PlaneGeometry(width=600.0, height=600.0),
                  shadowmap_vsm_phong_material(specular=Color3(0.067, 0.067, 0.067));
                  name="shadowmap_vsm_ground", cast_shadow=true, receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, ground)

    times = shadowmap_vsm_key_times()
    clip = AnimationClip("shadowmap_vsm_motion", SHADOWMAP_VSM_DURATION,
                         AbstractKeyframeTrack[
        NumberKeyframeTrack(torus, "rotation.x", copy(times), [0.25t for t in times]),
        NumberKeyframeTrack(torus, "rotation.y", copy(times), [0.5t for t in times]),
        NumberKeyframeTrack(torus, "rotation.z", copy(times), [t for t in times]),
        KeyframeTrack(dir, :position, copy(times),
                      [shadowmap_vsm_directional_position(t) for t in times]),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = SHADOWMAP_VSM_CAMERA_POSITION
    camera.target = SHADOWMAP_VSM_TARGET

    WebGLExportCase("shadowmap-vsm", "Shadowmap VSM",
                    "VSM shadow scene port with supported dynamic spot and directional shadows.",
                    scene; camera=camera, target=SHADOWMAP_VSM_TARGET,
                    radius=32.0, height=6.0, fov=45pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_vsm.html"),
                           [build_shadowmap_vsm_case()])
    println("WEBGL_SHADOWMAP_VSM_OK $html")
end

main()
