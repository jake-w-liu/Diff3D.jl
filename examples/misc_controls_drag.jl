# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_drag

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const BOX_COUNT = 200
const SELECTED_INDICES = (17, 63, 104, 149)
const GROUP_DRAG_DELTA = Vec3(1.5, 0.75, -0.5)

fract(x) = x - floor(x)

function deterministic_color(i::Int)
    Color3(0.25 + 0.65 * fract(i * 0.3183098861837907),
           0.25 + 0.65 * fract(i * 0.4142135623730951 + 0.23),
           0.25 + 0.65 * fract(i * 0.5772156649015329 + 0.41))
end

function build_drag_box(i::Int, geometry::BufferGeometry)
    selected = i in SELECTED_INDICES
    material = MeshLambertMaterial(color=deterministic_color(i),
                                   emissive=selected ? Color3(2 / 3, 2 / 3, 2 / 3) :
                                                        Color3(0.0, 0.0, 0.0))
    box = Mesh(geometry, material; name="drag_controls_box_$(i)",
               cast_shadow=true, receive_shadow=true)

    box.position = Vec3(30.0 * (fract(i * 0.7548776662466927) - 0.5),
                        15.0 * (fract(i * 0.5698402909980532 + 0.17) - 0.5),
                        20.0 * (fract(i * 0.4385513373931324 + 0.31) - 0.5))
    box.rotation = Euler(2pi * fract(i * 0.246979603717467),
                         2pi * fract(i * 0.3819660112501051 + 0.11),
                         2pi * fract(i * 0.7071067811865476 + 0.37))
    box.scale = Vec3(1.0 + 2.0 * fract(i * 0.6180339887498949 + 0.19),
                     1.0 + 2.0 * fract(i * 0.7548776662466927 + 0.29),
                     1.0 + 2.0 * fract(i * 0.5698402909980532 + 0.43))

    return box
end

function simulate_group_drag!(camera::PerspectiveCamera, group::Group,
                              selected_boxes::Vector{Mesh})
    controls = DragControls(AbstractObject3D[group], camera; transform_group=true)
    drag_start!(controls, first(selected_boxes))
    drag_move!(controls, GROUP_DRAG_DELTA)
    drag_end!(controls)
    return controls
end

function build_drag_controls_case()
    scene = Scene(background=Color3(0.941, 0.941, 0.941))

    add!(scene, AmbientLight(color=Color3(0.667, 0.667, 0.667), intensity=1.0))
    add!(scene, SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=10000.0,
                          distance=100.0, position=Vec3(0.0, 25.0, 50.0),
                          angle=pi / 9, cast_shadow=true))

    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9,
                               near=0.1, far=500.0)
    camera.position = Vec3(0.0, 0.0, 25.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    geometry = BoxGeometry()
    boxes = [build_drag_box(i, geometry) for i in 1:BOX_COUNT]
    selection_group = Group(name="drag_controls_selection_group")
    selected_boxes = Mesh[]

    for (i, box) in enumerate(boxes)
        if i in SELECTED_INDICES
            add!(selection_group, box)
            push!(selected_boxes, box)
        else
            add!(scene, box)
        end
    end

    add!(scene, selection_group)
    simulate_group_drag!(camera, selection_group, selected_boxes)

    WebGLExportCase("misc-controls-drag", "Drag Controls",
                    "Deterministic DragControls transform-group snapshot with selected boxes highlighted.",
                    scene; camera=camera, target=camera.target,
                    radius=28.0, height=0.0, fov=70pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_drag.html"),
                           [build_drag_controls_case()];
                           title="Diff3D.jl misc_controls_drag")
    println("MISC_CONTROLS_DRAG_OK $html")
end

main()
