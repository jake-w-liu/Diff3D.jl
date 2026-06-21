# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmesh

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SHADOWMESH_BACKGROUND = Color3(0.0, 150 / 255, 1.0)
const SHADOWMESH_GROUND_COLOR = Color3(0.0, 130 / 255, 0.0)
const SHADOWMESH_LIGHT_POSITION = Vec3(5.0, 7.0, -1.0)
const SHADOWMESH_TARGET = Vec3(0.0, 2.0, 0.0)
const SHADOWMESH_CAMERA_POSITION = Vec3(0.0, 2.5, 10.0)
const SHADOWMESH_DURATION = 4pi
const SHADOWMESH_KEYFRAME_COUNT = 97

function shadowmesh_key_times()
    collect(range(0.0, stop=SHADOWMESH_DURATION,
                  length=SHADOWMESH_KEYFRAME_COUNT))
end

shadowmesh_horizontal_angle(t::Real) = 0.5 * Float64(t)
shadowmesh_vertical_angle(t::Real) = 1.5 * Float64(t)

function shadowmesh_cube_position(t::Real)
    Vec3(sin(shadowmesh_horizontal_angle(t)) * 4.0,
         sin(shadowmesh_vertical_angle(t)) * 2.0 + 2.9,
         -1.0)
end

function shadowmesh_cylinder_position(t::Real)
    Vec3(-sin(shadowmesh_horizontal_angle(t)) * 4.0,
         sin(shadowmesh_vertical_angle(t)) * 2.0 + 3.1,
         -2.5)
end

function shadowmesh_torus_position(t::Real)
    Vec3(cos(shadowmesh_horizontal_angle(t)) * 4.0,
         cos(shadowmesh_vertical_angle(t)) * 2.0 + 3.3,
         -6.0)
end

function shadowmesh_project_to_ground(pos::Vec3{Float64}; y::Real=0.018)
    factor = pos.y / SHADOWMESH_LIGHT_POSITION.y
    Vec3(pos.x - SHADOWMESH_LIGHT_POSITION.x * factor,
         Float64(y),
         pos.z - SHADOWMESH_LIGHT_POSITION.z * factor)
end

function shadowmesh_shadow_scale(pos::Vec3{Float64}; base_x::Real=1.0,
                                 base_z::Real=1.0)
    height_scale = 1.0 + clamp(pos.y, 0.0, 6.0) * 0.08
    Vec3(Float64(base_x) * height_scale, 1.0, Float64(base_z) * height_scale)
end

function shadowmesh_segment_geometry(a::Vec3{Float64}, b::Vec3{Float64})
    BufferGeometry(Float64[a.x, a.y, a.z, b.x, b.y, b.z],
                   Float64[], Float64[], Int[], 2, 0)
end

function shadowmesh_directional_helper(name::String, y_offset::Real)
    start = Vec3(SHADOWMESH_LIGHT_POSITION.x,
                 SHADOWMESH_LIGHT_POSITION.y + Float64(y_offset),
                 SHADOWMESH_LIGHT_POSITION.z)
    direction = normalize(Vec3(-SHADOWMESH_LIGHT_POSITION.x,
                               -SHADOWMESH_LIGHT_POSITION.y,
                               -SHADOWMESH_LIGHT_POSITION.z))
    finish = Vec3(start.x + direction.x * 1.25,
                  start.y + direction.y * 1.25,
                  start.z + direction.z * 1.25)
    LineSegments(shadowmesh_segment_geometry(start, finish),
                 LineBasicMaterial(color=Color3(1.0, 1.0, 0.0), linewidth=2.0);
                 name=name)
end

function shadowmesh_shadow_proxy(name::String, width::Real, depth::Real,
                                 position::Vec3{Float64};
                                 opacity::Real=0.28)
    shadow = Mesh(PlaneGeometry(width=Float64(width), height=Float64(depth)),
                  MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                                    opacity=Float64(opacity),
                                    transparent=true,
                                    side=:double,
                                    depth_write=false);
                  name=name)
    shadow.position = shadowmesh_project_to_ground(position)
    shadow.rotation = Euler(-pi / 2, 0.0, 0.0)
    shadow.scale = shadowmesh_shadow_scale(position)
    return shadow
end

function shadowmesh_rotation_values(times::Vector{Float64}, rate::Real)
    [Float64(rate) * t for t in times]
end

function shadowmesh_position_values(times::Vector{Float64}, f::Function)
    [f(t) for t in times]
end

function shadowmesh_shadow_positions(times::Vector{Float64}, f::Function)
    [shadowmesh_project_to_ground(f(t)) for t in times]
end

function shadowmesh_shadow_scales(times::Vector{Float64}, f::Function; base_x::Real=1.0,
                                  base_z::Real=1.0)
    [shadowmesh_shadow_scale(f(t); base_x=base_x, base_z=base_z) for t in times]
end

function build_shadowmesh_case()
    scene = Scene(background=SHADOWMESH_BACKGROUND)

    add!(scene, AmbientLight(color=Color3(0.28, 0.28, 0.28), intensity=1.0,
                             name="shadowmesh_ambient"))

    sun = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                           position=SHADOWMESH_LIGHT_POSITION,
                           name="shadowmesh_sun")
    add!(scene, sun)
    add!(scene, shadowmesh_directional_helper("shadowmesh_directional_arrow_1", 0.0))
    add!(scene, shadowmesh_directional_helper("shadowmesh_directional_arrow_2", 0.2))
    add!(scene, shadowmesh_directional_helper("shadowmesh_directional_arrow_3", -0.2))

    light_holder = Group(name="shadowmesh_point_light_holder")
    light_holder.visible = false
    light_holder.position = SHADOWMESH_LIGHT_POSITION
    light_bulb = Mesh(SphereGeometry(radius=0.18, width_segments=16, height_segments=8),
                      MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                      name="shadowmesh_point_light_sphere")
    add!(light_holder, light_bulb)
    add!(scene, light_holder)

    ground = Mesh(BoxGeometry(width=30.0, height=0.01, depth=40.0),
                  MeshLambertMaterial(color=SHADOWMESH_GROUND_COLOR);
                  name="shadowmesh_ground", receive_shadow=true)
    add!(scene, ground)

    cube = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                MeshLambertMaterial(color=Color3(1.0, 0.0, 0.0),
                                    emissive=Color3(0.125, 0.0, 0.0));
                name="shadowmesh_cube_caster", cast_shadow=true)
    cube.position = shadowmesh_cube_position(0.0)
    add!(scene, cube)

    cylinder = Mesh(CylinderGeometry(radius_top=0.3, radius_bottom=0.3,
                                     height=2.0, radial_segments=32),
                    MeshPhongMaterial(color=Color3(0.0, 0.0, 1.0),
                                      emissive=Color3(0.0, 0.0, 0.125));
                    name="shadowmesh_cylinder_caster", cast_shadow=true)
    cylinder.position = shadowmesh_cylinder_position(0.0)
    add!(scene, cylinder)

    torus = Mesh(TorusGeometry(radius=1.0, tube=0.2,
                               radial_segments=10, tubular_segments=16),
                 MeshPhongMaterial(color=Color3(1.0, 0.0, 1.0),
                                   emissive=Color3(0.125, 0.0, 0.125));
                 name="shadowmesh_torus_caster", cast_shadow=true)
    torus.position = shadowmesh_torus_position(0.0)
    add!(scene, torus)

    sphere = Mesh(SphereGeometry(radius=0.5, width_segments=20, height_segments=10),
                  MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                    emissive=Color3(0.133, 0.133, 0.133));
                  name="shadowmesh_sphere_caster", cast_shadow=true)
    sphere.position = Vec3(4.0, 0.5, 2.0)
    add!(scene, sphere)

    pyramid = Mesh(ConeGeometry(radius=0.5, height=2.0, radial_segments=4),
                   MeshPhongMaterial(color=Color3(1.0, 1.0, 0.0),
                                     emissive=Color3(0.267, 0.0, 0.0),
                                     shininess=0.0);
                   name="shadowmesh_pyramid_caster", flat_shading=true,
                   cast_shadow=true)
    pyramid.position = Vec3(-4.0, 1.0, 2.0)
    add!(scene, pyramid)

    cube_shadow =
        shadowmesh_shadow_proxy("shadowmesh_cube_shadow", 1.45, 1.25,
                                cube.position; opacity=0.31)
    cylinder_shadow =
        shadowmesh_shadow_proxy("shadowmesh_cylinder_shadow", 1.0, 2.1,
                                cylinder.position; opacity=0.29)
    torus_shadow =
        shadowmesh_shadow_proxy("shadowmesh_torus_shadow", 2.4, 2.4,
                                torus.position; opacity=0.26)
    sphere_shadow =
        shadowmesh_shadow_proxy("shadowmesh_sphere_shadow", 1.25, 1.25,
                                sphere.position; opacity=0.24)
    pyramid_shadow =
        shadowmesh_shadow_proxy("shadowmesh_pyramid_shadow", 1.15, 1.65,
                                pyramid.position; opacity=0.27)
    for shadow in (cube_shadow, cylinder_shadow, torus_shadow, sphere_shadow,
                   pyramid_shadow)
        add!(scene, shadow)
    end

    times = shadowmesh_key_times()
    clip = AnimationClip("shadowmesh_motion", SHADOWMESH_DURATION,
                         AbstractKeyframeTrack[
        KeyframeTrack(cube, :position, copy(times),
                      shadowmesh_position_values(times, shadowmesh_cube_position)),
        NumberKeyframeTrack(cube, "rotation.x", copy(times),
                            shadowmesh_rotation_values(times, 1.0)),
        NumberKeyframeTrack(cube, "rotation.y", copy(times),
                            shadowmesh_rotation_values(times, 1.0)),
        KeyframeTrack(cube_shadow, :position, copy(times),
                      shadowmesh_shadow_positions(times, shadowmesh_cube_position)),
        KeyframeTrack(cube_shadow, :scale, copy(times),
                      shadowmesh_shadow_scales(times, shadowmesh_cube_position;
                                               base_x=1.0, base_z=0.9)),

        KeyframeTrack(cylinder, :position, copy(times),
                      shadowmesh_position_values(times, shadowmesh_cylinder_position)),
        NumberKeyframeTrack(cylinder, "rotation.y", copy(times),
                            shadowmesh_rotation_values(times, 1.0)),
        NumberKeyframeTrack(cylinder, "rotation.z", copy(times),
                            shadowmesh_rotation_values(times, -1.0)),
        KeyframeTrack(cylinder_shadow, :position, copy(times),
                      shadowmesh_shadow_positions(times, shadowmesh_cylinder_position)),
        KeyframeTrack(cylinder_shadow, :scale, copy(times),
                      shadowmesh_shadow_scales(times, shadowmesh_cylinder_position;
                                               base_x=0.9, base_z=1.05)),

        KeyframeTrack(torus, :position, copy(times),
                      shadowmesh_position_values(times, shadowmesh_torus_position)),
        NumberKeyframeTrack(torus, "rotation.x", copy(times),
                            shadowmesh_rotation_values(times, -1.0)),
        NumberKeyframeTrack(torus, "rotation.y", copy(times),
                            shadowmesh_rotation_values(times, -1.0)),
        KeyframeTrack(torus_shadow, :position, copy(times),
                      shadowmesh_shadow_positions(times, shadowmesh_torus_position)),
        KeyframeTrack(torus_shadow, :scale, copy(times),
                      shadowmesh_shadow_scales(times, shadowmesh_torus_position;
                                               base_x=1.05, base_z=1.05)),

        NumberKeyframeTrack(pyramid, "rotation.y", copy(times),
                            shadowmesh_rotation_values(times, 0.5)),
        NumberKeyframeTrack(pyramid_shadow, "rotation.z", copy(times),
                            shadowmesh_rotation_values(times, 0.5)),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=55pi / 180, aspect=16 / 9, near=1.0, far=3000.0)
    camera.position = SHADOWMESH_CAMERA_POSITION
    camera.target = SHADOWMESH_TARGET

    WebGLExportCase("shadowmesh", "ShadowMesh",
                    "Directional ShadowMesh scene port with animated casters and planar proxy shadows.",
                    scene; camera=camera, target=SHADOWMESH_TARGET,
                    radius=14.0, height=2.5, fov=55pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmesh.html"),
                           [build_shadowmesh_case()])
    println("WEBGL_SHADOWMESH_OK $html")
end

main()
