# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_spline_editor

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function spline_editor_seed_points()
    raw = [
        Vec3(289.76843686945404, 452.51481137238443, 56.10018915737797),
        Vec3(-53.56300074753207, 171.49711742836848, -14.495472686253045),
        Vec3(-91.40118730204415, 176.4306956436485, -6.958271935582161),
        Vec3(-383.785318791128, 491.1365363371675, 47.869296953772746),
    ]
    scale = 1 / 180.0
    offset = Vec3(0.0, -1.65, 0.0)
    return [p * scale + offset for p in raw]
end

function polyline_geometry(points::AbstractVector{<:Vec3})
    positions = Float64[]
    for p in points
        append!(positions, (p.x, p.y, p.z))
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[],
                          length(points), 0)
end

function add_helper_cubes!(scene::Scene, points::Vector{Vec3{Float64}})
    colors = [
        Color3(0.86, 0.22, 0.18),
        Color3(0.18, 0.54, 0.92),
        Color3(0.16, 0.64, 0.34),
        Color3(0.86, 0.62, 0.18),
    ]
    helpers = Mesh[]
    for (i, point) in enumerate(points)
        helper = Mesh(BoxGeometry(width=0.14, height=0.14, depth=0.14),
                      MeshLambertMaterial(color=colors[i]);
                      name="spline_editor_helper_$i",
                      cast_shadow=true, receive_shadow=true)
        helper.position = point
        push!(helpers, helper)
        add!(scene, helper)
    end
    return helpers
end

function apply_editor_controls!(helpers::Vector{Mesh}, camera::PerspectiveCamera)
    transform_controls = TransformControls(camera; mode=:translate, space=:world,
                                           axis=:Y, translation_snap=0.02)
    transform_attach!(transform_controls, helpers[2])
    transform_apply!(transform_controls, Vec3(0.0, 0.18, 0.0))

    drag_controls = DragControls(helpers, camera; recursive=false)
    drag_start!(drag_controls, helpers[3])
    drag_move!(drag_controls, Vec3(0.16, 0.0, 0.0))
    drag_end!(drag_controls)

    return [helper.position for helper in helpers]
end

function add_spline_line!(scene::Scene, points::Vector{Vec3{Float64}},
                          curve_type::Symbol, color::Color3, name::String)
    curve = CatmullRomCurve(points; curve_type=curve_type, tension=0.5)
    line = LineObject(CatmullRomCurveGeometry(curve; segments=200),
                      LineBasicMaterial(color=color, linewidth=2.0,
                                        opacity=0.62);
                      name=name)
    add!(scene, line)
    return line
end

function build_case()
    scene = Scene(background=Color3(0.95, 0.96, 0.98))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.82))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.97, 0.90), intensity=1.65,
                                 position=Vec3(1.8, 3.2, 2.2)))

    camera = PerspectiveCamera(fov=pi / 4, aspect=16 / 9, near=0.05, far=60.0)
    camera.position = Vec3(0.0, 2.15, 5.9)
    camera.target = Vec3(-0.45, 0.05, 0.05)

    ground = Mesh(PlaneGeometry(width=5.8, height=3.8),
                  MeshBasicMaterial(color=Color3(0.76, 0.78, 0.82),
                                    opacity=0.28, transparent=true,
                                    side=:double, depth_write=false);
                  name="spline_editor_ground")
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    ground.position = Vec3(-0.35, -1.08, 0.0)
    add!(scene, ground)

    grid = GridHelper(5.8, 14; color=Color3(0.52, 0.55, 0.60))
    grid.position = Vec3(-0.35, -1.07, 0.0)
    add!(scene, grid)

    helpers = add_helper_cubes!(scene, spline_editor_seed_points())
    points = apply_editor_controls!(helpers, camera)

    control = LineObject(polyline_geometry(points),
                         LineBasicMaterial(color=Color3(0.16, 0.17, 0.20),
                                           linewidth=1.0, opacity=0.72);
                         name="spline_editor_control_polygon")
    add!(scene, control)

    add_spline_line!(scene, points, :catmullrom, Color3(0.93, 0.18, 0.14),
                     "spline_editor_uniform")
    add_spline_line!(scene, points, :centripetal, Color3(0.12, 0.62, 0.32),
                     "spline_editor_centripetal")
    add_spline_line!(scene, points, :chordal, Color3(0.14, 0.36, 0.90),
                     "spline_editor_chordal")

    WebGLExportCase("geometry-spline-editor", "Geometry Spline Editor",
                    "Catmull-Rom spline modes with programmatic transform and drag handles.",
                    scene; camera=camera, target=camera.target,
                    radius=6.2, height=2.3, fov=pi / 4,
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_spline_editor.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_SPLINE_EDITOR_OK $html")
end

main()
