# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_pointerlock

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const BOX_COUNT = 180
const FLOOR_SIZE = 2000.0
const FLOOR_SEGMENTS = 20
const WALK_DELTA = Vec3(40.0, 0.0, -60.0)

fract(x) = x - floor(x)

function color_triplet(i::Int; offset::Float64=0.0)
    hue = 0.5 + 0.3 * fract(offset + i * 0.3819660112501051)
    lightness = 0.75 + 0.25 * fract(offset + i * 0.6180339887498949)
    Color3(0.35 + 0.35 * hue,
           0.55 + 0.25 * lightness,
           0.82 + 0.16 * fract(offset + i * 0.7548776662466927))
end

function deterministic_floor_geometry()
    geo = transform_geometry(
        PlaneGeometry(width=FLOOR_SIZE, height=FLOOR_SIZE,
                      width_segments=FLOOR_SEGMENTS,
                      height_segments=FLOOR_SEGMENTS),
        quat_to_mat4(quat_from_euler(-pi / 2, 0.0, 0.0)))

    colors = Float64[]
    sizehint!(colors, 3 * geo.n_vertices)

    for vi in 1:geo.n_vertices
        p = 3vi - 2
        geo.positions[p] += 20.0 * (fract(vi * 0.7548776662466927) - 0.5)
        geo.positions[p + 1] += 2.0 * fract(vi * 0.5698402909980532 + 0.17)
        geo.positions[p + 2] += 20.0 * (fract(vi * 0.4385513373931324 + 0.31) - 0.5)
        c = color_triplet(vi; offset=0.19)
        append!(colors, (c.r, c.g, c.b))
    end

    set_attribute!(geo, :color, colors, 3)
    return geo
end

function colored_box_geometry()
    geo = BoxGeometry(width=20.0, height=20.0, depth=20.0)
    colors = Float64[]
    sizehint!(colors, 3 * geo.n_vertices)

    for vi in 1:geo.n_vertices
        c = color_triplet(vi; offset=0.47)
        append!(colors, (c.r, c.g, c.b))
    end

    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_pointerlock_box(i::Int, geometry::BufferGeometry)
    material = MeshPhongMaterial(color=color_triplet(i; offset=0.61),
                                 specular=Color3(1.0, 1.0, 1.0),
                                 shininess=22.0,
                                 vertex_colors=true)
    box = Mesh(geometry, material; name="pointerlock_box_$(i)",
               flat_shading=true)

    box.position = Vec3(20.0 * floor(20.0 * fract(i * 0.7548776662466927) - 10.0),
                        20.0 * floor(20.0 * fract(i * 0.5698402909980532 + 0.17)) + 10.0,
                        20.0 * floor(20.0 * fract(i * 0.4385513373931324 + 0.31) - 10.0))
    return box
end

function configure_pointerlock_camera(camera::PerspectiveCamera)
    controls = PointerLockControls(camera; pointer_speed=1.0,
                                   min_polar_angle=pi / 6,
                                   max_polar_angle=5pi / 6)
    pointerlock_lock!(controls)
    pointerlock_move!(controls, 120.0, -35.0)
    camera.position = camera.position + WALK_DELTA
    camera.target = camera.target + WALK_DELTA
    return controls
end

function build_pointerlock_controls_case()
    scene = Scene(background=Color3(1.0, 1.0, 1.0),
                  fog=Fog(color=Color3(1.0, 1.0, 1.0), near=0.0, far=750.0))

    hemi = HemisphereLight(color=Color3(0.933, 0.933, 1.0),
                           ground_color=Color3(0.467, 0.467, 0.533),
                           intensity=2.5)
    hemi.position = Vec3(0.5, 1.0, 0.75)
    add!(scene, hemi)

    floor = Mesh(deterministic_floor_geometry(),
                 MeshBasicMaterial(vertex_colors=true, side=:double);
                 name="pointerlock_floor")
    add!(scene, floor)

    geometry = colored_box_geometry()
    boxes = [build_pointerlock_box(i, geometry) for i in 1:BOX_COUNT]
    for box in boxes
        add!(scene, box)
    end

    camera = PerspectiveCamera(fov=75pi / 180, aspect=16 / 9,
                               near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 10.0, 0.0)
    camera.target = Vec3(0.0, 10.0, -1.0)
    configure_pointerlock_camera(camera)

    WebGLExportCase("misc-controls-pointerlock", "PointerLock Controls",
                    "Deterministic first-person pointer-lock snapshot over a colored floor and box field.",
                    scene; camera=camera, target=camera.target,
                    radius=220.0, height=10.0, fov=75pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_pointerlock.html"),
                           [build_pointerlock_controls_case()];
                           title="Diff3D.jl misc_controls_pointerlock")
    println("MISC_CONTROLS_POINTERLOCK_OK $html")
end

main()
