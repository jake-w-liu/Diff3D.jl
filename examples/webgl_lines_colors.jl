# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_lines_colors

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function colored_line_geometry(points, colors)
    positions = Float64[]
    color_data = Float64[]
    for (p, c) in zip(points, colors)
        append!(positions, (p.x, p.y, p.z))
        append!(color_data, (c.r, c.g, c.b))
    end
    geo = BufferGeometry(positions, Float64[], Float64[], collect(1:length(points)),
                         length(points), 0)
    set_attribute!(geo, :color, color_data, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.015, 0.018, 0.024))
    add!(scene, AmbientLight(color=Color3(0.22, 0.24, 0.28), intensity=0.55))

    add!(scene, GridHelper(8.0, 16; color=Color3(0.18, 0.20, 0.23)))
    add!(scene, AxesHelper(2.4))

    pts = Vec3{Float64}[]
    cols = Color3{Float64}[]
    for i in 0:260
        t = i / 260
        a = 7.0 * pi * t
        r = 0.35 + 2.4 * t
        y = 1.5 * sin(4pi * t)
        push!(pts, Vec3(r * cos(a), y, r * sin(a)))
        push!(cols, Color3(0.5 + 0.5cos(a),
                           0.5 + 0.5sin(a + 1.7),
                           0.5 + 0.5sin(2.0a + 0.4)))
    end
    add!(scene, LineObject(colored_line_geometry(pts, cols),
                           LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                           name="vertex_color_spiral"))

    for band in 1:5
        ring_pts = Vec3{Float64}[]
        ring_cols = Color3{Float64}[]
        radius = 0.65 + 0.48band
        height = -1.25 + 0.5band
        for i in 0:96
            a = 2pi * i / 96
            push!(ring_pts, Vec3(radius * cos(a), height, radius * sin(a)))
            push!(ring_cols, Color3(0.3 + 0.12band, 0.75 - 0.08band, 0.95))
        end
        add!(scene, LineLoop(colored_line_geometry(ring_pts, ring_cols),
                             LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                             name="vertex_color_ring_$band"))
    end

    WebGLExportCase("lines_colors", "Lines Colors",
                    "Per-vertex line colors exported from Diff3D.jl BufferGeometry.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=3.0,
                    fov=pi/4.2)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lines_colors.html"), [build_case()])
    println("WEBGL_LINES_COLORS_OK $html")
end

main()
