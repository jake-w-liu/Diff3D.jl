# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry_points

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function points_geometry()
    positions = Float64[]
    colors = Float64[]
    n = 2600
    golden = pi * (3.0 - sqrt(5.0))
    for i in 0:(n - 1)
        y = 1.0 - 2.0i / (n - 1)
        r = sqrt(max(0.0, 1.0 - y * y))
        a = i * golden
        shell = 2.7 + 0.35sin(11a)
        x = shell * r * cos(a)
        z = shell * r * sin(a)
        append!(positions, (x, shell * y, z))
        append!(colors, (0.48 + 0.52r, 0.58 + 0.35y, 0.75 + 0.25sin(a)))
    end
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], n, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.010, 0.012, 0.018))
    add!(scene, AmbientLight(color=Color3(0.28, 0.30, 0.36), intensity=0.7))
    add!(scene, GridHelper(7.0, 14; color=Color3(0.13, 0.15, 0.19)))

    add!(scene, PointsObject(points_geometry(),
                             PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=5.0);
                             name="buffergeometry_points_cloud"))

    WebGLExportCase("buffergeometry_points", "BufferGeometry Points",
                    "Point cloud generated from raw Three.jl BufferGeometry attributes.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=2.5,
                    fov=pi/4.0)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_points.html"), [build_case()])
    println("WEBGL_BUFFERGEOMETRY_POINTS_OK $html")
end

main()
