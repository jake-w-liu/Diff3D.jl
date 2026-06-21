# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lines_dashed

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const HILBERT_CORNERS = [
    Vec3(-1.0, -1.0, -1.0),
    Vec3(-1.0, -1.0,  1.0),
    Vec3(-1.0,  1.0,  1.0),
    Vec3(-1.0,  1.0, -1.0),
    Vec3( 1.0,  1.0, -1.0),
    Vec3( 1.0,  1.0,  1.0),
    Vec3( 1.0, -1.0,  1.0),
    Vec3( 1.0, -1.0, -1.0),
]

function hilbert3d_points(center::Vec3{Float64}, size::Float64, recursion::Int)
    recursion >= 0 || throw(ArgumentError("recursion must be non-negative"))
    half = size / 2
    recursion == 0 && return [center + corner * half for corner in HILBERT_CORNERS]

    points = Vec3{Float64}[]
    child_size = size / 2
    for corner in HILBERT_CORNERS
        append!(points, hilbert3d_points(center + corner * (size / 4),
                                         child_size, recursion - 1))
    end
    return points
end

function box_line_segments_geometry(width::Real, height::Real, depth::Real)
    w = Float64(width) / 2
    h = Float64(height) / 2
    d = Float64(depth) / 2
    positions = Float64[
        -w, -h, -d,  -w,  h, -d,
        -w,  h, -d,   w,  h, -d,
         w,  h, -d,   w, -h, -d,
         w, -h, -d,  -w, -h, -d,

        -w, -h,  d,  -w,  h,  d,
        -w,  h,  d,   w,  h,  d,
         w,  h,  d,   w, -h,  d,
         w, -h,  d,  -w, -h,  d,

        -w, -h, -d,  -w, -h,  d,
        -w,  h, -d,  -w,  h,  d,
         w,  h, -d,   w,  h,  d,
         w, -h, -d,   w, -h,  d,
    ]
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], length(positions) ÷ 3, 0)
    compute_line_distances!(geo; mode=:lines)
    return geo
end

function dashed_spline_geometry()
    points = hilbert3d_points(Vec3(0.0, 0.0, 0.0), 4.0, 1)
    curve = CatmullRomCurve(points; curve_type=:catmullrom, tension=0.5)
    geo = CatmullRomCurveGeometry(curve; segments=length(points) * 6)
    compute_line_distances!(geo; mode=:line_strip)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.067, 0.067, 0.067),
                  fog=Fog(color=Color3(0.067, 0.067, 0.067), near=12.0, far=18.0))

    group = Group(name="dashed_lines_group")
    add!(scene, group)

    spline = LineObject(dashed_spline_geometry(),
                        LineDashedMaterial(color=Color3(1.0, 1.0, 1.0),
                                           dash_size=0.18, gap_size=0.09);
                        name="hilbert_spline_dashed_line")
    add!(group, spline)

    box = LineSegments(box_line_segments_geometry(5.2, 5.2, 5.2),
                       LineDashedMaterial(color=Color3(1.0, 0.67, 0.0),
                                          dash_size=0.42, gap_size=0.14);
                       name="box_dashed_line_segments")
    add!(group, box)

    clip = AnimationClip("dashed_lines_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(pi / 2, pi / 2, 0.0),
                                 quat_from_euler(pi, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("lines-dashed", "Lines Dashed",
                    "Dashed LineObject and LineSegments using exported lineDistance attributes.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=10.0,
                    height=3.5, fov=pi / 4.0, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lines_dashed.html"), [build_case()])
    println("WEBGL_LINES_DASHED_OK $html")
end

main()
