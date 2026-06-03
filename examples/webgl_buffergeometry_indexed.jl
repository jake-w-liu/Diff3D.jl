# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry_indexed

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function indexed_wave_geometry()
    cols = 42
    rows = 28
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    colors = Float64[]
    for y in 0:rows, x in 0:cols
        u = x / cols
        v = y / rows
        px = 5.2(u - 0.5)
        pz = 3.6(v - 0.5)
        py = 0.45sin(3pi * u) * cos(4pi * v)
        append!(positions, (px, py, pz))
        append!(normals, (0.0, 1.0, 0.0))
        append!(uvs, (u, v))
        append!(colors, (0.35 + 0.65u, 0.45 + 0.45v, 0.75 + 0.25sin(3pi * u)))
    end
    indices = Int[]
    stride = cols + 1
    for y in 0:(rows - 1), x in 0:(cols - 1)
        a = y * stride + x + 1
        b = a + 1
        c = a + stride
        d = c + 1
        append!(indices, (a, c, b, b, c, d))
    end
    geo = BufferGeometry(positions, normals, uvs, indices, (cols + 1) * (rows + 1),
                         length(indices) ÷ 3)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.011, 0.013, 0.020))
    add!(scene, AmbientLight(color=Color3(0.26, 0.28, 0.34), intensity=0.8))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.97, 0.90), intensity=1.15,
                                 position=Vec3(2.5, 4.5, 3.0)))
    add!(scene, GridHelper(7.0, 14; color=Color3(0.13, 0.15, 0.19)))

    mesh = Mesh(indexed_wave_geometry(),
                MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0), side=:double);
                name="indexed_wave_surface")
    mesh.position = Vec3(0.0, 0.2, 0.0)
    add!(scene, mesh)

    WebGLExportCase("buffergeometry_indexed", "BufferGeometry Indexed",
                    "Indexed mesh surface generated from Three.jl BufferGeometry indices.",
                    scene; target=Vec3(0.0, 0.1, 0.0), radius=7.0, height=2.4,
                    fov=pi/4.2)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_indexed.html"), [build_case()])
    println("WEBGL_BUFFERGEOMETRY_INDEXED_OK $html")
end

main()
