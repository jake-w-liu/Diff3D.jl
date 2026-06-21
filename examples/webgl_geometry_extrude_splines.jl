# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_extrude_splines

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
                             samples_per_segment::Int=8, closed::Bool=false,
                             scale::Float64=1.0)
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
                                         step / Float64(samples_per_segment)) * scale)
        end
    end
    push!(out, (closed ? out[1] : points[end] * scale))
    return out
end

function pipe_spline_path()
    points = Vec3[
        Vec3(0.0, 10.0, -10.0), Vec3(10.0, 0.0, -10.0),
        Vec3(20.0, 0.0, 0.0), Vec3(30.0, 0.0, 10.0),
        Vec3(30.0, 0.0, 20.0), Vec3(20.0, 0.0, 30.0),
        Vec3(10.0, 0.0, 30.0), Vec3(0.0, 0.0, 30.0),
        Vec3(-10.0, 10.0, 30.0), Vec3(-10.0, 20.0, 30.0),
        Vec3(0.0, 30.0, 30.0), Vec3(10.0, 30.0, 30.0),
        Vec3(20.0, 30.0, 15.0), Vec3(10.0, 30.0, 10.0),
        Vec3(0.0, 30.0, 10.0), Vec3(-10.0, 20.0, 10.0),
        Vec3(-10.0, 10.0, 10.0), Vec3(0.0, 0.0, 10.0),
        Vec3(10.0, -10.0, 10.0), Vec3(20.0, -15.0, 10.0),
        Vec3(30.0, -15.0, 10.0), Vec3(40.0, -15.0, 10.0),
        Vec3(50.0, -15.0, 10.0), Vec3(60.0, 0.0, 10.0),
        Vec3(70.0, 0.0, 0.0), Vec3(80.0, 0.0, 0.0),
        Vec3(90.0, 0.0, 0.0), Vec3(100.0, 0.0, 0.0),
    ]
    return sampled_catmull_rom(points; samples_per_segment=5, scale=0.035)
end

function closed_sample_path()
    points = Vec3[
        Vec3(0.0, -40.0, -40.0), Vec3(0.0, 40.0, -40.0),
        Vec3(0.0, 140.0, -40.0), Vec3(0.0, 40.0, 40.0),
        Vec3(0.0, -40.0, 40.0),
    ]
    return sampled_catmull_rom(points; samples_per_segment=18, closed=true, scale=0.018)
end

function trefoil_knot_path(; samples::Int=150)
    samples >= 12 || throw(ArgumentError("trefoil path needs at least 12 samples"))
    pts = Vec3{Float64}[]
    for i in 0:samples
        t = 2pi * i / samples
        x = sin(t) + 2sin(2t)
        y = cos(t) - 2cos(2t)
        z = -sin(3t)
        push!(pts, Vec3(0.55x, 0.55z, 0.55y))
    end
    return pts
end

function helix_path(; samples::Int=130, turns::Int=4)
    samples >= 12 || throw(ArgumentError("helix path needs at least 12 samples"))
    turns > 0 || throw(ArgumentError("helix turns must be positive"))
    pts = Vec3{Float64}[]
    for i in 0:samples
        t = 2pi * turns * i / samples
        y = 3.1 * (i / samples - 0.5)
        push!(pts, Vec3(0.95cos(t), y, 0.95sin(t)))
    end
    return pts
end

function add_tube_case!(group::Group, path::Vector{<:Vec3}, name::String,
                        color::Color3, position::Vec3; radius::Float64,
                        radial_segments::Int)
    geo = TubeGeometry(path; radius=radius, radial_segments=radial_segments)
    geo.n_vertices > 0 || error("TubeGeometry produced no vertices for $name")

    mesh = Mesh(geo, MeshLambertMaterial(color=color, side=:double);
                name="$(name)_tube", cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)

    wire = Mesh(geo, MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                                       opacity=0.28, transparent=true,
                                       wireframe=true, side=:double);
                name="$(name)_wire")
    add!(mesh, wire)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.94, 0.94, 0.94),
                  fog=Fog(color=Color3(0.94, 0.94, 0.94), near=8.0, far=18.0))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.72))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=1.5,
                                 position=Vec3(0.0, 1.5, 3.0)))
    add!(scene, GridHelper(8.0, 16; color=Color3(0.72, 0.74, 0.78)))

    parent = Group(name="spline_extrusion_parent")
    add!(scene, parent)
    add_tube_case!(parent, pipe_spline_path(), "pipe_spline",
                   Color3(1.0, 0.0, 1.0), Vec3(-2.6, 0.0, -0.8);
                   radius=0.075, radial_segments=5)
    add_tube_case!(parent, trefoil_knot_path(), "trefoil_knot",
                   Color3(0.98, 0.42, 0.1), Vec3(1.4, 0.0, -0.25);
                   radius=0.075, radial_segments=6)
    add_tube_case!(parent, closed_sample_path(), "closed_catmull",
                   Color3(0.12, 0.44, 0.95), Vec3(-1.15, -0.05, 1.85);
                   radius=0.06, radial_segments=5)
    add_tube_case!(parent, helix_path(), "helix_curve",
                   Color3(0.18, 0.68, 0.28), Vec3(2.6, 0.05, 1.55);
                   radius=0.055, radial_segments=5)

    clip = AnimationClip("spline_extrusion_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(parent, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-extrude-splines", "Geometry Extrude Splines",
                    "Sampled curve paths rendered through Diff3D.jl TubeGeometry with transparent wireframe overlays.",
                    scene; target=Vec3(0.0, 0.45, 0.45), radius=8.8, height=2.7,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_extrude_splines.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_EXTRUDE_SPLINES_OK $html")
end

main()
