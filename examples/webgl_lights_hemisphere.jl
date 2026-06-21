# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lights_hemisphere

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

lights_hemi_fract(x::Float64) = x - floor(x)

function lights_hemi_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = lights_hemi_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end

    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q

    function hue_to_rgb(t)
        t = lights_hemi_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end

    Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

const HEMI_SKY_COLOR = lights_hemi_hsl_to_rgb(0.6, 1.0, 0.6)
const HEMI_GROUND_COLOR = lights_hemi_hsl_to_rgb(0.095, 1.0, 0.75)
const HEMI_DIRECTIONAL_COLOR = lights_hemi_hsl_to_rgb(0.1, 1.0, 0.95)
const HEMI_BACKGROUND_COLOR = lights_hemi_hsl_to_rgb(0.6, 0.0, 1.0)
const HEMI_SKY_RADIUS = 4000.0
const HEMI_SKY_OFFSET = 33.0
const HEMI_SKY_EXPONENT = 0.6
const HEMI_GROUND_SIZE = 10_000.0
const HEMI_GROUND_Y = -33.0

function lights_hemi_mix(a::Color3, b::Color3, t::Float64)
    u = clamp(t, 0.0, 1.0)
    Color3(a.r * (1.0 - u) + b.r * u,
           a.g * (1.0 - u) + b.g * u,
           a.b * (1.0 - u) + b.b * u)
end

function lights_hemi_sky_geometry()
    geo = SphereGeometry(radius=HEMI_SKY_RADIUS, width_segments=32, height_segments=15)
    colors = Vector{Float64}(undef, 3 * geo.n_vertices)
    for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
        shifted = normalize(Vec3(p.x + HEMI_SKY_OFFSET,
                                 p.y + HEMI_SKY_OFFSET,
                                 p.z + HEMI_SKY_OFFSET))
        mix_amount = max(shifted.y, 0.0)^HEMI_SKY_EXPONENT
        c = lights_hemi_mix(Color3(1.0, 1.0, 1.0), HEMI_SKY_COLOR, mix_amount)
        base = 3 * (vi - 1) + 1
        colors[base] = c.r
        colors[base + 1] = c.g
        colors[base + 2] = c.b
    end
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function lights_hemi_ground()
    ground = Mesh(PlaneGeometry(width=HEMI_GROUND_SIZE, height=HEMI_GROUND_SIZE),
                  MeshLambertMaterial(color=HEMI_GROUND_COLOR);
                  name="hemisphere_ground", receive_shadow=true)
    ground.position = Vec3(0.0, HEMI_GROUND_Y, 0.0)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    return ground
end

function lights_hemi_sky()
    Mesh(lights_hemi_sky_geometry(),
         MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                           vertex_colors=true, side=:back);
         name="hemisphere_sky")
end

function add_flamingo_part!(parent::Group, geometry, material;
                            name::String, position=Vec3(), rotation=Euler(),
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

function build_flamingo_proxy()
    group = Group(name="hemisphere_flamingo_proxy")
    group.position = Vec3(0.0, 15.0, 0.0)
    group.rotation = Euler(0.0, -1.0, 0.0)
    group.scale = Vec3(0.35, 0.35, 0.35)

    body_mat = MeshPhongMaterial(color=Color3(1.0, 0.34, 0.46),
                                 specular=Color3(0.18, 0.08, 0.10),
                                 shininess=36.0)
    dark_mat = MeshPhongMaterial(color=Color3(0.86, 0.12, 0.20),
                                 specular=Color3(0.1, 0.04, 0.04),
                                 shininess=28.0)
    leg_mat = MeshLambertMaterial(color=Color3(0.16, 0.10, 0.12))
    beak_mat = MeshPhongMaterial(color=Color3(1.0, 0.88, 0.62),
                                 specular=Color3(0.2, 0.18, 0.12),
                                 shininess=22.0)

    add_flamingo_part!(group, SphereGeometry(radius=1.0, width_segments=32, height_segments=16),
                       body_mat; name="hemisphere_flamingo_body",
                       position=Vec3(0.0, 0.0, 0.0), scale=Vec3(26.0, 15.0, 10.0))

    add_flamingo_part!(group, CapsuleGeometry(radius=2.2, length=36.0,
                                              cap_segments=8, radial_segments=16),
                       body_mat; name="hemisphere_flamingo_neck",
                       position=Vec3(14.0, 26.0, 0.0),
                       rotation=Euler(0.0, 0.0, -0.36),
                       scale=Vec3(1.0, 1.0, 0.85))

    add_flamingo_part!(group, SphereGeometry(radius=1.0, width_segments=24, height_segments=12),
                       body_mat; name="hemisphere_flamingo_head",
                       position=Vec3(21.0, 47.0, 0.0), scale=Vec3(6.5, 5.0, 4.2))

    add_flamingo_part!(group, ConeGeometry(radius=2.0, height=9.0, radial_segments=16),
                       beak_mat; name="hemisphere_flamingo_beak",
                       position=Vec3(29.0, 46.0, 0.0),
                       rotation=Euler(0.0, 0.0, -pi / 2),
                       scale=Vec3(1.0, 0.72, 0.72), receive_shadow=false)

    left_wing = add_flamingo_part!(group,
        SphereGeometry(radius=1.0, width_segments=24, height_segments=12),
        dark_mat; name="hemisphere_flamingo_left_wing",
        position=Vec3(-2.0, -1.5, 8.0), rotation=Euler(0.0, 0.1, 0.2),
        scale=Vec3(18.0, 7.0, 2.2))
    right_wing = add_flamingo_part!(group,
        SphereGeometry(radius=1.0, width_segments=24, height_segments=12),
        dark_mat; name="hemisphere_flamingo_right_wing",
        position=Vec3(-2.0, -1.5, -8.0), rotation=Euler(0.0, -0.1, -0.2),
        scale=Vec3(18.0, 7.0, 2.2))

    for (name, x) in (("left", -5.0), ("right", 6.0))
        add_flamingo_part!(group, CylinderGeometry(radius_top=0.7, radius_bottom=0.7,
                                                   height=42.0, radial_segments=10),
                           leg_mat; name="hemisphere_flamingo_$(name)_leg",
                           position=Vec3(x, -34.0, 0.0),
                           scale=Vec3(1.0, 1.0, 1.0))
    end

    return group, left_wing, right_wing
end

function build_lights_hemisphere_case()
    scene = Scene(background=HEMI_BACKGROUND_COLOR,
                  fog=Fog(color=Color3(1.0, 1.0, 1.0), near=1.0, far=5000.0))

    hemi = HemisphereLight(color=HEMI_SKY_COLOR, ground_color=HEMI_GROUND_COLOR,
                           intensity=2.0, name="hemisphere_light")
    hemi.position = Vec3(0.0, 50.0, 0.0)
    add!(scene, hemi)
    add!(scene, HemisphereLightHelper(hemi, 10.0; color=HEMI_SKY_COLOR))

    dir = DirectionalLight(color=HEMI_DIRECTIONAL_COLOR, intensity=3.0,
                           position=Vec3(-30.0, 52.5, 30.0),
                           cast_shadow=true, shadow_bias=-0.0001,
                           name="hemisphere_directional_light")
    add!(scene, dir)
    add!(scene, DirectionalLightHelper(dir; color=HEMI_DIRECTIONAL_COLOR))

    add!(scene, lights_hemi_ground())
    add!(scene, lights_hemi_sky())
    flamingo, left_wing, right_wing = build_flamingo_proxy()
    add!(scene, flamingo)

    clip = AnimationClip("hemisphere_flamingo_wing_flap", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(left_wing, :rotation, [0.0, 0.5, 1.0],
                                [quat_from_euler(0.0, 0.1, 0.2),
                                 quat_from_euler(0.0, 0.35, 0.42),
                                 quat_from_euler(0.0, 0.1, 0.2)]),
        QuaternionKeyframeTrack(right_wing, :rotation, [0.0, 0.5, 1.0],
                                [quat_from_euler(0.0, -0.1, -0.2),
                                 quat_from_euler(0.0, -0.35, -0.42),
                                 quat_from_euler(0.0, -0.1, -0.2)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=30pi / 180, aspect=16 / 9, near=1.0, far=5000.0)
    camera.position = Vec3(0.0, 0.0, 250.0)
    camera.target = Vec3(0.0, 15.0, 0.0)

    WebGLExportCase("lights-hemisphere", "Lights Hemisphere",
                    "Hemisphere and directional light scene with sky, ground, helpers, and animated flamingo proxy.",
                    scene; camera=camera, target=camera.target, radius=250.0,
                    height=15.0, fov=30pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lights_hemisphere.html"),
                           [build_lights_hemisphere_case()])
    println("WEBGL_LIGHTS_HEMISPHERE_OK $html")
end

main()
