# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry_lines

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function line_segments_geometry()
    positions = Float64[]
    colors = Float64[]
    n = 220
    for i in 0:(n - 1)
        t = i / (n - 1)
        a = 12pi * t
        r = 0.35 + 2.5t
        p1 = Vec3(r * cos(a), 1.25sin(5pi * t), r * sin(a))
        p2 = Vec3((r + 0.45) * cos(a + 0.45), 1.25sin(5pi * t + 0.9),
                  (r + 0.45) * sin(a + 0.45))
        c = Color3(0.5 + 0.5cos(a), 0.5 + 0.5sin(a + 1.9), 0.5 + 0.5sin(2a))
        append!(positions, (p1.x, p1.y, p1.z, p2.x, p2.y, p2.z))
        append!(colors, (c.r, c.g, c.b, c.r, c.g, c.b))
    end
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], 2n, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.012, 0.014, 0.020))
    add!(scene, AmbientLight(color=Color3(0.25, 0.27, 0.32), intensity=0.6))
    add!(scene, GridHelper(8.0, 16; color=Color3(0.14, 0.16, 0.20)))
    add!(scene, AxesHelper(2.5))

    add!(scene, LineSegments(line_segments_geometry(),
                             LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                             name="buffergeometry_line_segments"))

    WebGLExportCase("buffergeometry_lines", "BufferGeometry Lines",
                    "LineSegments generated from raw Diff3D.jl BufferGeometry attributes.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=2.8,
                    fov=pi/4.2)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_lines.html"), [build_case()])
    println("WEBGL_BUFFERGEOMETRY_LINES_OK $html")
end

main()
