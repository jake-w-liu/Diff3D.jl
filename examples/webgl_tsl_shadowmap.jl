# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_tsl_shadowmap

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const TSL_SHADOW_BACKGROUND = Color3(34 / 255, 34 / 255, 68 / 255)
const TSL_SHADOW_SHARED_COLOR = Color3(153 / 255, 153 / 255, 153 / 255)
const TSL_SHADOW_TORUS_SPECULAR = Color3(34 / 255, 34 / 255, 34 / 255)
const TSL_SHADOW_GROUND_SPECULAR = Color3(17 / 255, 17 / 255, 17 / 255)
const TSL_SHADOW_RADIUS = 4
const TSL_SHADOW_MAP_SIZE = 2048
const TSL_SHADOW_SPOT_NEAR = 8.0
const TSL_SHADOW_SPOT_FAR = 200.0
const TSL_SHADOW_DIR_NEAR = 0.1
const TSL_SHADOW_DIR_FAR = 500.0
const TSL_SHADOW_DIR_EXTENT = 17.0
const TSL_SHADOW_DURATION = 40pi
const TSL_SHADOW_KEYFRAME_COUNT = 121
const TSL_SHADOW_CAMERA_POSITION = Vec3(0.0, 10.0, 20.0)
const TSL_SHADOW_TARGET = Vec3(0.0, 2.0, 0.0)

function tsl_shadow_key_times()
    collect(range(0.0, stop=TSL_SHADOW_DURATION,
                  length=TSL_SHADOW_KEYFRAME_COUNT))
end

function tsl_shadow_directional_position(t::Real)
    yaw = 0.7 * Float64(t)
    local_z = 17.0 + sin(Float64(t)) * 5.0
    Vec3(cos(yaw) * 3.0 + sin(yaw) * local_z,
         12.0,
         -sin(yaw) * 3.0 + cos(yaw) * local_z)
end

function tsl_shadow_mask_texture(; size::Int=64)
    size > 0 || throw(ArgumentError("mask texture size must be positive"))
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        n = 0.5 + 0.5sin(32.0u + 17.0v + 5.0sin(19.0u - 11.0v))
        mask = n > 0.48 ? 1.0 : 0.0
        data[y, x, 1] = mask
        data[y, x, 2] = mask
        data[y, x, 3] = mask
    end
    Texture(data; wrap_s=:repeat, wrap_t=:repeat, filter=:linear,
            colorspace=:linear)
end

function tsl_shadow_ground_texture(; size::Int=128)
    size > 0 || throw(ArgumentError("ground texture size must be positive"))
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        n1 = 0.5 + 0.5sin(48.0u + 9.0sin(14.0v))
        n2 = 0.5 + 0.5cos(41.0v + 7.0sin(11.0u))
        shade = clamp(0.50 + 0.20 * (0.55n1 + 0.45n2), 0.0, 1.0)
        data[y, x, 1] = shade
        data[y, x, 2] = shade
        data[y, x, 3] = shade
    end
    Texture(data; repeat=Vec2(8.0, 8.0), wrap_s=:repeat, wrap_t=:repeat,
            filter=:linear, colorspace=:linear)
end

function tsl_shadow_phong_material(; map=nothing, alpha_map=nothing,
                                   transparent::Bool=false,
                                   alpha_test::Real=0.0,
                                   specular::Color3=TSL_SHADOW_TORUS_SPECULAR)
    MeshPhongMaterial(color=TSL_SHADOW_SHARED_COLOR,
                      specular=specular,
                      shininess=0.0,
                      map=map,
                      alpha_map=alpha_map,
                      transparent=transparent,
                      alpha_test=Float64(alpha_test))
end

function build_tsl_shadowmap_case()
    scene = Scene(background=TSL_SHADOW_BACKGROUND,
                  fog=Fog(color=TSL_SHADOW_BACKGROUND, near=50.0, far=100.0))

    add!(scene, AmbientLight(color=Color3(68 / 255, 68 / 255, 68 / 255),
                             intensity=2.0, name="tsl_shadow_ambient"))

    spot = SpotLight(color=Color3(1.0, 136 / 255, 136 / 255),
                     intensity=400.0,
                     angle=pi / 5,
                     penumbra=0.3,
                     decay=2.0,
                     position=Vec3(8.0, 10.0, 5.0),
                     target=Vec3(0.0, 0.0, 0.0),
                     cast_shadow=true,
                     shadow_pcf_radius=TSL_SHADOW_RADIUS,
                     name="tsl_shadow_spot")
    add!(scene, spot)

    dir = DirectionalLight(color=Color3(136 / 255, 136 / 255, 1.0),
                           intensity=3.0,
                           position=tsl_shadow_directional_position(0.0),
                           cast_shadow=true,
                           shadow_pcf_radius=TSL_SHADOW_RADIUS,
                           name="tsl_shadow_directional")
    add!(scene, dir)

    shared_material = tsl_shadow_phong_material()
    torus_material = tsl_shadow_phong_material(
        alpha_map=tsl_shadow_mask_texture(),
        transparent=true,
        alpha_test=0.48,
    )

    torus = Mesh(TorusKnotGeometry(radius=25.0, tube=8.0,
                                   tubular_segments=75, radial_segments=80),
                 torus_material; name="tsl_shadow_torus_knot",
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
                      name="tsl_shadow_pillar_$idx", cast_shadow=true)
        pillar.position = pos
        add!(scene, pillar)
    end

    ground = Mesh(PlaneGeometry(width=200.0, height=200.0),
                  tsl_shadow_phong_material(map=tsl_shadow_ground_texture(),
                                            specular=TSL_SHADOW_GROUND_SPECULAR);
                  name="tsl_shadow_ground", cast_shadow=true, receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    ground.scale = Vec3(3.0, 3.0, 3.0)
    add!(scene, ground)

    times = tsl_shadow_key_times()
    clip = AnimationClip("tsl_shadow_motion", TSL_SHADOW_DURATION,
                         AbstractKeyframeTrack[
        NumberKeyframeTrack(torus, "rotation.x", copy(times), [0.25t for t in times]),
        NumberKeyframeTrack(torus, "rotation.y", copy(times), [0.5t for t in times]),
        NumberKeyframeTrack(torus, "rotation.z", copy(times), [t for t in times]),
        KeyframeTrack(dir, :position, copy(times),
                      [tsl_shadow_directional_position(t) for t in times]),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9,
                               near=1.0, far=1000.0)
    camera.position = TSL_SHADOW_CAMERA_POSITION
    camera.target = TSL_SHADOW_TARGET

    WebGLExportCase("tsl-shadowmap", "TSL Shadowmap",
                    "TSL shadow map scene layout with supported Phong material and texture-node proxies.",
                    scene; camera=camera, target=TSL_SHADOW_TARGET,
                    radius=24.0, height=4.0, fov=45pi / 180,
                    animations=[clip], tone_mapping=:aces,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_tsl_shadowmap.html"),
                           [build_tsl_shadowmap_case()])
    println("WEBGL_TSL_SHADOWMAP_OK $html")
end

main()
