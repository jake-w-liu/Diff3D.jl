# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lights_rectarealight

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const RECT_AREA_LIGHT_WIDTH = 4.0
const RECT_AREA_LIGHT_HEIGHT = 10.0
const RECT_AREA_LIGHT_INTENSITY = 5.0
const RECT_AREA_FLOOR_SIZE = 2000.0
const RECT_AREA_CHECKER_REPEAT = 400.0
const RECT_AREA_KNOT_POSITION = Vec3(0.0, 5.5, 0.0)
const RECT_AREA_CAMERA_POSITION = Vec3(0.0, 5.0, -15.0)

function rect_area_checker_texture(; repeat::Float64=RECT_AREA_CHECKER_REPEAT)
    data = zeros(Float64, 2, 2, 3)
    for y in 1:2, x in 1:2
        v = (x == y) ? 1.0 : 0.0
        data[y, x, 1] = v
        data[y, x, 2] = v
        data[y, x, 3] = v
    end
    Texture(data; repeat=Vec2(repeat, repeat), filter=:nearest,
            min_filter=:nearest, mag_filter=:nearest,
            wrap_s=:repeat, wrap_t=:repeat, colorspace=:linear)
end

function rect_area_floor()
    Mesh(BoxGeometry(width=RECT_AREA_FLOOR_SIZE, height=0.1,
                     depth=RECT_AREA_FLOOR_SIZE),
         MeshStandardMaterial(color=Color3(0.267, 0.267, 0.267),
                              roughness=1.0, metalness=0.0,
                              roughness_map=rect_area_checker_texture());
         name="rect_area_floor", receive_shadow=true)
end

function rect_area_knot()
    knot = Mesh(TorusKnotGeometry(radius=1.5, tube=0.5,
                                  tubular_segments=200, radial_segments=16),
                MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                     roughness=0.0, metalness=0.0);
                name="rect_area_knot", cast_shadow=true, receive_shadow=true)
    knot.position = RECT_AREA_KNOT_POSITION
    return knot
end

function rect_area_basis(light::RectAreaLight)
    forward = normalize(light.target - light.position)
    ref = abs(forward.y) < 0.95 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    u = normalize(cross(ref, forward))
    v = cross(forward, u)
    return forward, u, v
end

function rect_area_helper_panel(light::RectAreaLight)
    _, u, v = rect_area_basis(light)
    hx = light.width / 2
    hy = light.height / 2
    p = light.position
    a = p - u * hx - v * hy
    b = p + u * hx - v * hy
    c = p + u * hx + v * hy
    d = p - u * hx + v * hy
    positions = Float64[
        a.x, a.y, a.z,
        b.x, b.y, b.z,
        c.x, c.y, c.z,
        d.x, d.y, d.z,
    ]
    normals = Float64[]
    for _ in 1:4
        append!(normals, (0.0, 0.0, 1.0))
    end
    geo = BufferGeometry(positions, normals, Float64[], Int[1, 2, 3, 1, 3, 4], 4, 2)
    Mesh(geo, MeshBasicMaterial(color=light.color, opacity=0.32,
                                transparent=true, side=:double,
                                depth_write=false);
         name="$(light.name)_helper_panel")
end

function rect_area_light(name::String, color::Color3, position::Vec3)
    light = RectAreaLight(color=color, intensity=RECT_AREA_LIGHT_INTENSITY,
                          width=RECT_AREA_LIGHT_WIDTH,
                          height=RECT_AREA_LIGHT_HEIGHT,
                          position=position, name=name)
    light.target = RECT_AREA_KNOT_POSITION
    return light
end

function rotated_rect_target(light::RectAreaLight, radians::Float64)
    dir = normalize(RECT_AREA_KNOT_POSITION - light.position)
    turned = mat4_transform_direction(mat4_rotation_y(radians), dir)
    light.position + turned
end

function rect_area_target_track(light::RectAreaLight, angular_scale::Float64)
    times = [0.0, 3.0, 6.0]
    values = [rotated_rect_target(light, 0.0),
              rotated_rect_target(light, angular_scale * pi),
              rotated_rect_target(light, angular_scale * 2pi)]
    KeyframeTrack(light, :target, times, values)
end

function build_lights_rectarealight_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    rect1 = rect_area_light("rectLight1", Color3(1.0, 0.0, 0.0), Vec3(-5.0, 6.0, 5.0))
    rect2 = rect_area_light("rectLight2", Color3(0.0, 1.0, 0.0), Vec3(0.0, 6.0, 5.0))
    rect3 = rect_area_light("rectLight3", Color3(0.0, 0.0, 1.0), Vec3(5.0, 6.0, 5.0))

    for light in (rect1, rect2, rect3)
        add!(scene, light)
        add!(scene, rect_area_helper_panel(light))
    end

    add!(scene, rect_area_floor())
    add!(scene, rect_area_knot())

    clip = AnimationClip("rect_area_light_rotation", AbstractKeyframeTrack[
        rect_area_target_track(rect1, -1.0),
        rect_area_target_track(rect2, 0.5),
        rect_area_target_track(rect3, 1.0),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = RECT_AREA_CAMERA_POSITION
    camera.target = RECT_AREA_KNOT_POSITION

    WebGLExportCase("lights-rectarealight", "Lights RectAreaLight",
                    "Three animated RGB RectAreaLights over a checker-rough floor and torus knot.",
                    scene; camera=camera, target=camera.target, radius=16.0,
                    height=5.5, fov=45pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lights_rectarealight.html"),
                           [build_lights_rectarealight_case()])
    println("WEBGL_LIGHTS_RECTAREALIGHT_OK $html")
end

main()
