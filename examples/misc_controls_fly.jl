# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_fly

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const EARTH_RADIUS = 6371.0
const EARTH_TILT = 0.41
const CLOUDS_SCALE = 1.005
const MOON_SCALE = 0.23
const ROTATION_DURATION = 40.0
const STAR_SHELL_RANGE = 10:29

fract(x) = x - floor(x)

function star_geometry(count::Int, radius::Float64, seed::Float64)
    positions = Float64[]
    sizehint!(positions, 3 * count)

    for i in 1:count
        x = 2.0 * fract(seed + i * 0.7548776662466927) - 1.0
        y = 2.0 * fract(seed + i * 0.5698402909980532 + 0.17) - 1.0
        z = 2.0 * fract(seed + i * 0.4385513373931324 + 0.31) - 1.0
        append!(positions, (radius * x, radius * y, radius * z))
    end

    BufferGeometry(positions, Float64[], Float64[], Int[], count, 0)
end

function build_star_shells(radius::Float64)
    geometries = (star_geometry(250, radius, 0.13),
                  star_geometry(1500, radius, 0.47))
    materials = (
        PointsMaterial(color=Color3(0.612, 0.612, 0.612), size=2.4),
        PointsMaterial(color=Color3(0.514, 0.514, 0.514), size=2.1),
        PointsMaterial(color=Color3(0.353, 0.353, 0.353), size=1.8),
    )
    shells = PointsObject[]

    for i in STAR_SHELL_RANGE
        stars = PointsObject(geometries[mod1(i, length(geometries))],
                             materials[mod1(i, length(materials))];
                             name="fly_controls_star_shell_$(i)")
        stars.rotation = Euler(6.0 * fract(i * 0.246979603717467),
                               6.0 * fract(i * 0.3819660112501051 + 0.11),
                               6.0 * fract(i * 0.7071067811865476 + 0.37))
        shell_scale = 10.0 * i
        stars.scale = Vec3(shell_scale, shell_scale, shell_scale)
        push!(shells, stars)
    end

    return shells
end

function configure_fly_controls(camera::PerspectiveCamera)
    controls = FlyControls(camera)
    fly_translate!(controls, EARTH_RADIUS * 0.25, EARTH_RADIUS * 0.03,
                   EARTH_RADIUS * 0.02)
    fly_rotate!(controls, pi / 36, -pi / 72)
    return controls
end

function build_planet_animation(planet::Mesh, clouds::Mesh)
    AnimationClip("fly_controls_planet_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(planet, :rotation, [0.0, ROTATION_DURATION],
                                [quat_from_euler(0.0, 0.0, EARTH_TILT),
                                 quat_from_euler(0.0, 2pi, EARTH_TILT)]),
        QuaternionKeyframeTrack(clouds, :rotation, [0.0, ROTATION_DURATION],
                                [quat_from_euler(0.0, 0.0, EARTH_TILT),
                                 quat_from_euler(0.0, 2.5pi, EARTH_TILT)])
    ]; loop=:repeat)
end

function build_fly_controls_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0),
                  fog=FogExp2(color=Color3(0.0, 0.0, 0.0), density=2.5e-7))

    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                                 position=normalize(Vec3(-1.0, 0.0, 1.0))))

    sphere = SphereGeometry(radius=EARTH_RADIUS, width_segments=64, height_segments=32)
    planet = Mesh(sphere,
                  MeshPhongMaterial(color=Color3(0.11, 0.32, 0.82),
                                    specular=Color3(0.486, 0.486, 0.486),
                                    shininess=15.0);
                  name="fly_controls_planet")
    planet.rotation = Euler(0.0, 0.0, EARTH_TILT)
    add!(scene, planet)

    clouds = Mesh(sphere,
                  MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                      opacity=0.34, transparent=true,
                                      depth_write=false);
                  name="fly_controls_clouds")
    clouds.scale = Vec3(CLOUDS_SCALE, CLOUDS_SCALE, CLOUDS_SCALE)
    clouds.rotation = Euler(0.0, 0.0, EARTH_TILT)
    add!(scene, clouds)

    moon = Mesh(sphere,
                MeshPhongMaterial(color=Color3(0.62, 0.62, 0.58),
                                  shininess=6.0);
                name="fly_controls_moon")
    moon.position = Vec3(EARTH_RADIUS * 5.0, 0.0, 0.0)
    moon.scale = Vec3(MOON_SCALE, MOON_SCALE, MOON_SCALE)
    add!(scene, moon)

    for shell in build_star_shells(EARTH_RADIUS)
        add!(scene, shell)
    end

    camera = PerspectiveCamera(fov=25pi / 180, aspect=16 / 9,
                               near=50.0, far=1.0e7)
    camera.position = Vec3(0.0, 0.0, EARTH_RADIUS * 5.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    configure_fly_controls(camera)

    WebGLExportCase("misc-controls-fly", "Fly Controls",
                    "Procedural Earth, moon, stars, and a programmed FlyControls camera snapshot.",
                    scene; camera=camera, target=camera.target,
                    radius=EARTH_RADIUS * 5.0, height=0.0, fov=25pi / 180,
                    animations=[build_planet_animation(planet, clouds)],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_fly.html"),
                           [build_fly_controls_case()];
                           title="Diff3D.jl misc_controls_fly")
    println("MISC_CONTROLS_FLY_OK $html")
end

main()
