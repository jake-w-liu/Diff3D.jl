# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function triangle_cloud_geometry()
    positions = Float64[]
    colors = Float64[]
    triangles = 180
    for i in 0:(triangles - 1)
        t = i / triangles
        a = 10pi * t
        center = Vec3(2.7cos(a) * (0.25 + t), 2.2(t - 0.5), 2.7sin(a) * (0.25 + t))
        radial = Vec3(cos(a), 0.0, sin(a))
        tangent = Vec3(-sin(a), 0.0, cos(a))
        lift = Vec3(0.0, 0.16 + 0.06sin(7a), 0.0)
        scale = 0.12 + 0.08sin(13a)^2
        pts = (center + scale * tangent,
               center - scale * tangent + lift,
               center - 0.8scale * radial - lift)
        c = Color3(0.5 + 0.5cos(a), 0.55 + 0.45sin(a + 1.4), 0.7 + 0.3sin(2a))
        for p in pts
            append!(positions, (p.x, p.y, p.z))
            append!(colors, (c.r, c.g, c.b))
        end
    end
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], 3triangles, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.011, 0.013, 0.020))
    add!(scene, AmbientLight(color=Color3(0.30, 0.32, 0.38), intensity=0.75))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.96, 0.86), intensity=0.9,
                                 position=Vec3(3.0, 5.0, 4.0)))
    add!(scene, GridHelper(8.0, 16; color=Color3(0.14, 0.16, 0.20)))

    add!(scene, Mesh(triangle_cloud_geometry(),
                     MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), side=:double);
                     name="buffergeometry_triangle_cloud"))

    WebGLExportCase("buffergeometry", "BufferGeometry",
                    "Non-indexed triangle cloud from raw Three.jl BufferGeometry attributes.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=2.4,
                    fov=pi/4.2)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry.html"), [build_case()])
    println("WEBGL_BUFFERGEOMETRY_OK $html")
end

main()
