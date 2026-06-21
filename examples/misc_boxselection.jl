# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_boxselection

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const BOX_COUNT = 200
const SELECT_RECT = (-0.35, 0.35, -0.25, 0.25)

fract(x) = x - floor(x)

function deterministic_color(i::Int)
    Color3(0.25 + 0.65 * fract(i * 0.3183098861837907),
           0.25 + 0.65 * fract(i * 0.4142135623730951 + 0.23),
           0.25 + 0.65 * fract(i * 0.5772156649015329 + 0.41))
end

function build_box(i::Int, geometry::BufferGeometry)
    material = MeshLambertMaterial(color=deterministic_color(i),
                                   emissive=Color3(0.0, 0.0, 0.0))
    box = Mesh(geometry, material; name="boxselection_box_$(i)",
               cast_shadow=true, receive_shadow=true)

    box.position = Vec3(80.0 * (fract(i * 0.7548776662466927) - 0.5),
                        45.0 * (fract(i * 0.5698402909980532 + 0.17) - 0.5),
                        45.0 * (fract(i * 0.4385513373931324 + 0.31) - 0.5))
    box.rotation = Euler(2pi * fract(i * 0.246979603717467),
                         2pi * fract(i * 0.3819660112501051 + 0.11),
                         2pi * fract(i * 0.7071067811865476 + 0.37))
    box.scale = Vec3(1.0 + 2.0 * fract(i * 0.6180339887498949 + 0.19),
                     1.0 + 2.0 * fract(i * 0.7548776662466927 + 0.29),
                     1.0 + 2.0 * fract(i * 0.5698402909980532 + 0.43))

    return box
end

function projected_center(camera::PerspectiveCamera, box::Mesh)
    vp = projection_matrix(camera) * view_matrix(camera)
    mat4_transform_point(vp, box.position)
end

function box_is_selected(camera::PerspectiveCamera, box::Mesh)
    x_min, x_max, y_min, y_max = SELECT_RECT
    ndc = projected_center(camera, box)
    return x_min <= ndc.x <= x_max && y_min <= ndc.y <= y_max &&
           -1.0 <= ndc.z <= 1.0
end

function highlight_selected!(camera::PerspectiveCamera, boxes::Vector{Mesh})
    selected = Mesh[]

    for box in boxes
        if box_is_selected(camera, box)
            mat = box.material
            box.material = MeshLambertMaterial(color=mat.color,
                                               emissive=Color3(1.0, 1.0, 1.0),
                                               emissive_intensity=1.0)
            push!(selected, box)
        end
    end

    return selected
end

function build_boxselection_case()
    scene = Scene(background=Color3(0.941, 0.941, 0.941))

    add!(scene, AmbientLight(color=Color3(0.667, 0.667, 0.667), intensity=1.0))
    add!(scene, SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=10000.0,
                          distance=100.0, position=Vec3(0.0, 25.0, 50.0),
                          angle=pi / 5, cast_shadow=true))

    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9,
                               near=0.1, far=500.0)
    camera.position = Vec3(0.0, 0.0, 50.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    geometry = BoxGeometry()
    boxes = [build_box(i, geometry) for i in 1:BOX_COUNT]
    highlight_selected!(camera, boxes)

    for box in boxes
        add!(scene, box)
    end

    WebGLExportCase("misc-boxselection", "Box Selection",
                    "Deterministic SelectionBox snapshot with selected boxes emissive-highlighted.",
                    scene; camera=camera, target=camera.target,
                    radius=75.0, height=0.0, fov=70pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_boxselection.html"),
                           [build_boxselection_case()];
                           title="Diff3D.jl misc_boxselection")
    println("MISC_BOXSELECTION_OK $html")
end

main()
