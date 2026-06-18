# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry_lines_indexed

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function indexed_snowflake_geometry(; iteration_count::Int=4, scale::Float64=1 / 430)
    iteration_count >= 1 || throw(ArgumentError("iteration_count must be positive"))
    positions = Float64[]
    colors = Float64[]
    indices = Int[]
    next_index = 1
    rangle = pi / 3

    function add_vertex(p::Vec3)
        q = Vec3((p.x - 1200.0) * scale, (p.y - 1350.0) * scale, p.z * scale)
        phase = 0.017 * p.x + 0.013 * p.y + 0.37 * next_index
        append!(positions, (q.x, q.y, q.z))
        append!(colors, (0.62 + 0.33 * (0.5 + 0.5sin(phase)),
                         0.58 + 0.34 * (0.5 + 0.5cos(phase * 1.37)),
                         1.0))
        out = next_index
        next_index += 1
        return out
    end

    function snowflake_iteration(p0::Vec3, p4::Vec3, depth::Int)
        depth -= 1
        if depth < 0
            i = next_index - 1
            add_vertex(p4)
            append!(indices, (i, i + 1))
            return
        end

        v = p4 - p0
        v_tier = v * (1 / 3)
        p1 = p0 + v_tier
        angle = atan(v.y, v.x) + rangle
        len = norm(v_tier)
        p2 = Vec3(p1.x + cos(angle) * len, p1.y + sin(angle) * len, p1.z)
        p3 = p0 + v_tier * 2.0

        snowflake_iteration(p0, p1, depth)
        snowflake_iteration(p1, p2, depth)
        snowflake_iteration(p2, p3, depth)
        snowflake_iteration(p3, p4, depth)
    end

    function snowflake(points::Vector{Vec3{Float64}}, loop::Bool, x_offset::Float64)
        for iteration in 0:(iteration_count - 1)
            add_vertex(points[1])
            for p_index in 1:(length(points) - 1)
                snowflake_iteration(points[p_index], points[p_index + 1], iteration)
            end
            loop && snowflake_iteration(points[end], points[1], iteration)
            for i in eachindex(points)
                points[i] = points[i] + Vec3(x_offset, 0.0, 0.0)
            end
        end
    end

    y = 0.0
    snowflake(Vec3{Float64}[Vec3(0.0, y, 0.0), Vec3(500.0, y, 0.0)], false, 600.0)

    y += 600.0
    snowflake(Vec3{Float64}[Vec3(0.0, y, 0.0), Vec3(250.0, y + 400.0, 0.0),
                            Vec3(500.0, y, 0.0)], true, 600.0)

    y += 600.0
    snowflake(Vec3{Float64}[Vec3(0.0, y, 0.0), Vec3(500.0, y, 0.0),
                            Vec3(500.0, y + 500.0, 0.0), Vec3(0.0, y + 500.0, 0.0)],
              true, 600.0)

    y += 1000.0
    snowflake(Vec3{Float64}[Vec3(250.0, y, 0.0), Vec3(500.0, y, 0.0),
                            Vec3(250.0, y, 0.0), Vec3(250.0, y + 250.0, 0.0),
                            Vec3(250.0, y, 0.0), Vec3(0.0, y, 0.0),
                            Vec3(250.0, y, 0.0), Vec3(250.0, y - 250.0, 0.0),
                            Vec3(250.0, y, 0.0)], false, 600.0)

    geo = BufferGeometry(positions, Float64[], Float64[], indices,
                         length(positions) ÷ 3, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    parent = Group(name="indexed_snowflake_parent")
    add!(scene, parent)

    line = LineSegments(indexed_snowflake_geometry(),
                        LineBasicMaterial(color=Color3(1.0, 1.0, 1.0), linewidth=1.0);
                        name="indexed_snowflake_line_segments")
    add!(parent, line)

    clip = AnimationClip("indexed_lines_turntable",
                         AbstractKeyframeTrack[
                             QuaternionKeyframeTrack(parent, :rotation, [0.0, 8.0],
                                                     [Quaternion(),
                                                      quat_from_euler(0.0, 0.0, 2pi)]),
                         ])

    WebGLExportCase("buffergeometry-lines-indexed", "BufferGeometry Lines Indexed",
                    "Indexed LineSegments preserve an explicit Koch-curve index buffer and per-vertex colors.",
                    scene; target=Vec3(0.0, 1.15, 0.0), radius=9.0, height=1.15,
                    fov=27pi / 180, animations=[clip])
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_lines_indexed.html"),
                           [build_case()])
    println("WEBGL_BUFFERGEOMETRY_LINES_INDEXED_OK $html")
end

main()
