# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_progressive

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const PROGRESSIVE_BACKGROUND = Color3(148 / 255, 148 / 255, 148 / 255)
const PROGRESSIVE_SHADOW_MAP_RES = 512
const PROGRESSIVE_LIGHT_MAP_RES = 1024
const PROGRESSIVE_LIGHT_COUNT = 8
const PROGRESSIVE_BLEND_WINDOW = 200
const PROGRESSIVE_LIGHT_RADIUS = 50.0
const PROGRESSIVE_AMBIENT_WEIGHT = 0.5
const PROGRESSIVE_LIGHT_ORIGIN = Vec3(60.0, 150.0, 100.0)
const PROGRESSIVE_MODEL_POSITION = Vec3(0.0, -16.0, 0.0)
const PROGRESSIVE_MODEL_SCALE = Vec3(2.0, 2.0, 2.0)
const PROGRESSIVE_LIGHT_TARGET = Vec3(0.0, 4.0, 0.0)
const PROGRESSIVE_CAMERA_POSITION = Vec3(0.0, 100.0, 200.0)
const PROGRESSIVE_TARGET = Vec3(0.0, 100.0, 0.0)
const PROGRESSIVE_DURATION = 20pi
const PROGRESSIVE_KEYFRAME_COUNT = 121

function progressive_key_times()
    collect(range(0.0, stop=PROGRESSIVE_DURATION,
                  length=PROGRESSIVE_KEYFRAME_COUNT))
end

function progressive_lightmap_texture(; size::Int=96)
    size > 0 || throw(ArgumentError("lightmap texture size must be positive"))
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        center = exp(-3.2 * ((u - 0.45)^2 + (v - 0.58)^2))
        edge = max(abs(u - 0.5), abs(v - 0.5))
        stripe = 0.5 + 0.5sin(34.0u + 13.0v)
        shade = clamp(0.34 + 0.46center + 0.10stripe - 0.18edge, 0.0, 1.0)
        data[y, x, 1] = shade
        data[y, x, 2] = shade
        data[y, x, 3] = shade
    end
    Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:linear,
            colorspace=:linear)
end

function progressive_light_position(index::Integer, t::Real)
    1 <= index <= PROGRESSIVE_LIGHT_COUNT ||
        throw(ArgumentError("light index must be in 1:$PROGRESSIVE_LIGHT_COUNT"))
    phase = 2pi * (index - 1) / PROGRESSIVE_LIGHT_COUNT
    tt = Float64(t)
    if sin(tt + phase) > 2 * PROGRESSIVE_AMBIENT_WEIGHT - 1
        return Vec3(
            PROGRESSIVE_LIGHT_ORIGIN.x +
            PROGRESSIVE_LIGHT_RADIUS * (0.5 + 0.5sin(tt + phase)),
            PROGRESSIVE_LIGHT_ORIGIN.y +
            PROGRESSIVE_LIGHT_RADIUS * (0.5 + 0.5sin(2tt + phase + 0.7)),
            PROGRESSIVE_LIGHT_ORIGIN.z +
            PROGRESSIVE_LIGHT_RADIUS * (0.5 + 0.5cos(tt + phase + 1.4)),
        )
    end

    lambda = 0.5pi * sin(tt + phase)
    phi = 2pi * (0.5 + 0.5sin(0.5tt + phase))
    return Vec3(cos(lambda) * cos(phi) * 300.0 + PROGRESSIVE_MODEL_POSITION.x,
                abs(cos(lambda) * sin(phi) * 300.0) +
                PROGRESSIVE_MODEL_POSITION.y + 20.0,
                sin(lambda) * 300.0 + PROGRESSIVE_MODEL_POSITION.z)
end

function progressive_material(; color::Color3=Color3(1.0, 1.0, 1.0),
                              light_map_intensity::Real=0.65)
    MeshPhongMaterial(color=color, depth_write=true,
                      light_map=progressive_lightmap_texture(),
                      light_map_intensity=Float64(light_map_intensity))
end

function progressive_ground()
    ground = Mesh(PlaneGeometry(width=600.0, height=600.0),
                  progressive_material(light_map_intensity=0.55);
                  name="progressive_ground_mesh")
    ground.position = Vec3(0.0, -0.1, 0.0)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    return ground
end

function progressive_model_proxy()
    group = Group(name="progressive_loaded_mesh_proxy")
    group.position = PROGRESSIVE_MODEL_POSITION
    group.scale = PROGRESSIVE_MODEL_SCALE

    material = progressive_material(color=Color3(0.82, 0.84, 0.88),
                                    light_map_intensity=0.75)
    body = Mesh(IcosahedronGeometry(radius=18.0, detail=2),
                material; name="progressive_loaded_mesh",
                cast_shadow=true, receive_shadow=true)
    body.position = Vec3(0.0, 22.0, 0.0)
    body.rotation = Euler(0.0, pi / 5, 0.0)
    add!(group, body)

    base = Mesh(CylinderGeometry(radius_top=10.0, radius_bottom=18.0,
                                 height=18.0, radial_segments=32),
                material; name="progressive_loaded_mesh_base",
                cast_shadow=true, receive_shadow=true)
    base.position = Vec3(0.0, 8.0, 0.0)
    add!(group, base)

    return group
end

function progressive_directional_lights()
    lights = DirectionalLight[]
    for index in 1:PROGRESSIVE_LIGHT_COUNT
        light = DirectionalLight(color=Color3(1.0, 1.0, 1.0),
                                 intensity=pi / PROGRESSIVE_LIGHT_COUNT,
                                 position=progressive_light_position(index, 0.0),
                                 cast_shadow=index == 1,
                                 shadow_pcf_radius=index == 1 ? 1 : nothing,
                                 name="progressive_dir_light_$index")
        light.target = PROGRESSIVE_LIGHT_TARGET
        push!(lights, light)
    end
    return lights
end

function progressive_transform_controls(camera::PerspectiveCamera,
                                        light_origin::Group,
                                        object::Group)
    light_control = TransformControls(camera; mode=:translate, space=:world,
                                      axis=:XYZ)
    transform_attach!(light_control, light_origin)
    object_control = TransformControls(camera; mode=:translate, space=:world,
                                       axis=:XYZ)
    transform_attach!(object_control, object)
    return light_control, object_control
end

function build_shadowmap_progressive_case()
    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9,
                               near=1.0, far=1000.0, name="Camera")
    camera.position = PROGRESSIVE_CAMERA_POSITION
    camera.target = PROGRESSIVE_TARGET

    scene = Scene(background=PROGRESSIVE_BACKGROUND,
                  fog=Fog(color=PROGRESSIVE_BACKGROUND, near=1000.0, far=3000.0))

    light_origin = Group(name="progressive_light_origin")
    light_origin.position = PROGRESSIVE_LIGHT_ORIGIN
    add!(scene, light_origin)

    lights = progressive_directional_lights()
    for light in lights
        add!(scene, light)
    end

    add!(scene, progressive_ground())
    object = progressive_model_proxy()
    add!(scene, object)
    progressive_transform_controls(camera, light_origin, object)

    times = progressive_key_times()
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(light, :position, copy(times),
                      [progressive_light_position(index, t) for t in times])
        for (index, light) in enumerate(lights)
    ]
    clip = AnimationClip("progressive_light_sampling", PROGRESSIVE_DURATION,
                         tracks; loop=:repeat)

    WebGLExportCase("shadowmap-progressive", "Shadowmap Progressive",
                    "Progressive lightmap scene layout with deterministic light sampling and baked-lightmap texture proxies.",
                    scene; camera=camera, target=PROGRESSIVE_TARGET,
                    radius=260.0, height=80.0, fov=70pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_progressive.html"),
                           [build_shadowmap_progressive_case()])
    println("WEBGL_SHADOWMAP_PROGRESSIVE_OK $html")
end

main()
