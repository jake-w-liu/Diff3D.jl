# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_extrude_shapes

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function catmull_rom_point(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3, t::Float64)
    t2 = t * t
    t3 = t2 * t
    return (p1 * 2.0 +
            (p2 - p0) * t +
            (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 +
            (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3) * 0.5
end

function sampled_catmull_rom(points::Vector{<:Vec3};
                             samples_per_segment::Int=12, closed::Bool=false)
    length(points) >= 2 || throw(ArgumentError("Catmull-Rom path needs at least two points"))
    samples_per_segment > 0 || throw(ArgumentError("samples_per_segment must be positive"))
    out = Vec3{Float64}[]
    n = length(points)
    segments = closed ? n : n - 1
    for i in 1:segments
        p0 = closed ? points[mod1(i - 1, n)] : points[max(i - 1, 1)]
        p1 = points[i]
        p2 = points[mod1(i + 1, n)]
        p3 = closed ? points[mod1(i + 2, n)] : points[min(i + 2, n)]
        for step in 0:(samples_per_segment - 1)
            push!(out, catmull_rom_point(p0, p1, p2, p3,
                                         step / Float64(samples_per_segment)))
        end
    end
    push!(out, closed ? out[1] : points[end])
    return out
end

function regular_polygon_shape(count::Int, radius::Float64; rotation::Float64=0.0)
    count >= 3 || throw(ArgumentError("regular polygon needs at least three points"))
    return Vec2[Vec2(cos(rotation + 2pi * i / count) * radius,
                     sin(rotation + 2pi * i / count) * radius)
                for i in 0:(count - 1)]
end

function star_shape(; points::Int=5, inner::Float64=0.18, outer::Float64=0.36)
    points >= 3 || throw(ArgumentError("star_shape needs at least three points"))
    shape = Vec2{Float64}[]
    for i in 0:(2 * points - 1)
        radius = isodd(i) ? inner : outer
        angle = pi / 2 + i * pi / points
        push!(shape, Vec2(cos(angle) * radius, sin(angle) * radius))
    end
    return shape
end

function closed_spline_path()
    points = Vec3[
        Vec3(-1.08, -1.80, 1.08),
        Vec3(-1.08, 0.36, 1.08),
        Vec3(-1.08, 2.16, 1.08),
        Vec3(1.08, 0.36, -1.08),
        Vec3(1.08, -1.80, -1.08),
    ]
    return sampled_catmull_rom(points; samples_per_segment=14, closed=true)
end

function deterministic_spline_path()
    points = Vec3{Float64}[]
    for i in 0:9
        x = (i - 4.5) * 0.52
        y = 0.58 * sin(1.37 * i)
        z = 0.54 * cos(0.91 * i)
        push!(points, Vec3(x, y, z))
    end
    return sampled_catmull_rom(points; samples_per_segment=16)
end

function add_extruded_mesh!(parent::Group, geo::BufferGeometry, name::String,
                            color::Color3, position::Vec3)
    mesh = Mesh(geo, MeshLambertMaterial(color=color, side=:double);
                name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(parent, mesh)
    wire = Mesh(geo, MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                                       opacity=0.24, transparent=true,
                                       wireframe=true, side=:double);
                name="$(name)_wire")
    add!(mesh, wire)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.13, 0.13, 0.13),
                  fog=Fog(color=Color3(0.13, 0.13, 0.13), near=7.0, far=15.0))
    add!(scene, AmbientLight(color=Color3(0.68, 0.68, 0.68), intensity=0.78))
    add!(scene, PointLight(color=Color3(1.0, 1.0, 1.0), intensity=4.0,
                           distance=18.0, position=Vec3(0.0, 2.8, 5.2)))
    add!(scene, GridHelper(7.0, 14; color=Color3(0.30, 0.30, 0.32)))

    parent = Group(name="extrude_shapes_parent")
    add!(scene, parent)

    triangle = regular_polygon_shape(3, 0.34; rotation=pi / 2)
    star = star_shape()

    add_extruded_mesh!(parent,
                       ExtrudeGeometry(triangle; extrude_path=closed_spline_path()),
                       "closed_spline_triangle", Color3(0.70, 0.0, 0.0),
                       Vec3(-1.85, 0.0, 0.0))
    add_extruded_mesh!(parent,
                       ExtrudeGeometry(star; extrude_path=deterministic_spline_path()),
                       "random_spline_star", Color3(1.0, 0.50, 0.0),
                       Vec3(1.35, -0.65, 0.0))

    static_star = add_extruded_mesh!(parent, ExtrudeGeometry(star, depth=0.42),
                                    "static_depth_star", Color3(0.70, 0.0, 0.0),
                                    Vec3(1.35, 1.28, 0.62))
    static_star.rotation = Euler(-0.35, 0.55, 0.15)

    clip = AnimationClip("extrude_shapes_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(parent, :rotation, [0.0, 5.0, 10.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-extrude-shapes", "Geometry Extrude Shapes",
                    "Triangle and star shapes swept along sampled Catmull-Rom paths with Diff3D.jl ExtrudeGeometry.",
                    scene; target=Vec3(0.0, 0.15, 0.0), radius=8.2, height=2.5,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_extrude_shapes.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_EXTRUDE_SHAPES_OK $html")
end

main()
