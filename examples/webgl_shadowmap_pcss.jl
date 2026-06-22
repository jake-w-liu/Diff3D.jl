# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_pcss

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const PCSS_LIGHT_WORLD_SIZE = 0.005
const PCSS_LIGHT_FRUSTUM_WIDTH = 3.75
const PCSS_LIGHT_SIZE_UV = PCSS_LIGHT_WORLD_SIZE / PCSS_LIGHT_FRUSTUM_WIDTH
const PCSS_NEAR_PLANE = 9.5
const PCSS_NUM_SAMPLES = 17
const PCSS_NUM_RINGS = 11
const PCSS_BLOCKER_SEARCH_NUM_SAMPLES = PCSS_NUM_SAMPLES
const PCSS_SHADOW_MAP_SIZE = 1024
const PCSS_DIRECTIONAL_SHADOW_FAR = 20.0
const PCSS_SPHERE_COUNT = 20
const PCSS_ANIMATION_DURATION = 2pi
const PCSS_KEYFRAME_COUNT = 97
const PCSS_SCENE_COLOR = Color3(204 / 255, 224 / 255, 1.0)
const PCSS_GROUND_COLOR = Color3(137 / 255, 137 / 255, 137 / 255)
const PCSS_CAMERA_POSITION = Vec3(7.0, 13.0, 7.0)
const PCSS_TARGET = Vec3(0.0, 2.5, 0.0)

pcss_fract(x::Float64) = x - floor(x)

function pcss_key_times()
    collect(range(0.0, stop=PCSS_ANIMATION_DURATION,
                  length=PCSS_KEYFRAME_COUNT))
end

function pcss_sphere_phase(index::Integer)
    1 <= index <= PCSS_SPHERE_COUNT ||
        throw(ArgumentError("sphere index must be in 1:$PCSS_SPHERE_COUNT"))
    2pi * pcss_fract(sin(45.173 * index) * 129.971)
end

function pcss_sphere_radius(index::Integer)
    1 <= index <= PCSS_SPHERE_COUNT ||
        throw(ArgumentError("sphere index must be in 1:$PCSS_SPHERE_COUNT"))
    1.0 + 2.0 * pcss_fract(sin(19.919 * index) * 73.157)
end

function pcss_sphere_base_position(index::Integer)
    angle = 2pi * (index - 1) / PCSS_SPHERE_COUNT +
            0.28 * sin(1.7 * index)
    radius = pcss_sphere_radius(index)
    Vec3(cos(angle) * radius, 0.3, sin(angle) * radius)
end

pcss_sphere_y(t::Real, phase::Real) =
    abs(sin(Float64(t) + Float64(phase))) * 4.0 + 0.3

function pcss_sphere_color(index::Integer)
    r = pcss_fract(sin(12.9898 * index) * 43758.5453)
    g = pcss_fract(sin(78.233 * index) * 9514.721)
    b = pcss_fract(sin(37.719 * index) * 24634.6345)
    Color3(0.18 + 0.74r, 0.20 + 0.70g, 0.24 + 0.66b)
end

function pcss_shadow_camera(light::DirectionalLight)
    cam = OrthographicCamera(left=-5.0, right=5.0, bottom=-5.0, top=5.0,
                             near=0.5, far=PCSS_DIRECTIONAL_SHADOW_FAR,
                             name="pcss_directional_shadow_camera")
    cam.position = light.position
    cam.target = Vec3(0.0, 0.0, 0.0)
    return cam
end

function pcss_ground()
    ground = Mesh(PlaneGeometry(width=20000.0, height=20000.0,
                                width_segments=8, height_segments=8),
                  MeshPhongMaterial(color=PCSS_GROUND_COLOR);
                  name="pcss_ground", receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    return ground
end

function pcss_column()
    column = Mesh(BoxGeometry(width=1.0, height=4.0, depth=1.0),
                  MeshPhongMaterial(color=PCSS_GROUND_COLOR);
                  name="pcss_column", cast_shadow=true, receive_shadow=true)
    column.position = Vec3(0.0, 2.0, 0.0)
    return column
end

function pcss_spheres()
    geometry = SphereGeometry(radius=0.3, width_segments=20, height_segments=20)
    group = Group(name="pcss_bouncing_sphere_group")
    spheres = Mesh[]
    for index in 1:PCSS_SPHERE_COUNT
        phase = pcss_sphere_phase(index)
        material = MeshPhongMaterial(color=pcss_sphere_color(index))
        sphere = Mesh(geometry, material; name="pcss_sphere_$index",
                      cast_shadow=true, receive_shadow=true)
        base = pcss_sphere_base_position(index)
        sphere.position = Vec3(base.x, pcss_sphere_y(0.0, phase), base.z)
        add!(group, sphere)
        push!(spheres, sphere)
    end
    return group, spheres
end

function pcss_sphere_tracks(spheres::Vector{Mesh})
    times = pcss_key_times()
    tracks = AbstractKeyframeTrack[]
    for (index, sphere) in enumerate(spheres)
        phase = pcss_sphere_phase(index)
        values = [pcss_sphere_y(t, phase) for t in times]
        push!(tracks, NumberKeyframeTrack(sphere, "position.y",
                                          copy(times), values))
    end
    return tracks
end

function build_shadowmap_pcss_case()
    scene = Scene(background=PCSS_SCENE_COLOR,
                  fog=Fog(color=PCSS_SCENE_COLOR, near=5.0, far=100.0))

    add!(scene, AmbientLight(color=Color3(2 / 3, 2 / 3, 2 / 3),
                             intensity=3.0, name="pcss_ambient"))

    light = DirectionalLight(color=Color3(240 / 255, 246 / 255, 1.0),
                             intensity=4.5,
                             position=Vec3(2.0, 8.0, 4.0),
                             cast_shadow=true,
                             shadow_pcf_radius=4,
                             name="pcss_directional")
    add!(scene, light)
    add!(scene, CameraHelper(pcss_shadow_camera(light);
                             color=Color3(0.35, 0.52, 1.0)))

    group, spheres = pcss_spheres()
    add!(scene, group)
    add!(scene, pcss_ground())
    add!(scene, pcss_column())

    clip = AnimationClip("pcss_bouncing_spheres",
                         PCSS_ANIMATION_DURATION,
                         pcss_sphere_tracks(spheres); loop=:repeat)

    camera = PerspectiveCamera(fov=30pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = PCSS_CAMERA_POSITION
    camera.target = PCSS_TARGET

    WebGLExportCase("shadowmap-pcss", "Shadowmap PCSS",
                    "PCSS scene layout with compact PCF soft-shadow approximation and animated bouncing spheres.",
                    scene; camera=camera, target=PCSS_TARGET,
                    radius=18.0, height=2.5, fov=30pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_pcss.html"),
                           [build_shadowmap_pcss_case()])
    println("WEBGL_SHADOWMAP_PCSS_OK $html")
end

main()
