# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_buffergeometry_uint

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function uint_geometry()
    n = 65_537
    positions = zeros(Float64, 3n)
    colors = ones(Float64, 3n)

    function setv!(i, p::Vec3, c::Color3)
        j = 3i - 2
        positions[j] = p.x
        positions[j + 1] = p.y
        positions[j + 2] = p.z
        colors[j] = c.r
        colors[j + 1] = c.g
        colors[j + 2] = c.b
    end

    setv!(1, Vec3(-1.45, -0.9, 0.0), Color3(1.0, 0.25, 0.18))
    setv!(65_536, Vec3(1.45, -0.9, 0.0), Color3(0.20, 0.85, 1.0))
    setv!(65_537, Vec3(0.0, 1.25, 0.0), Color3(1.0, 0.85, 0.18))

    geo = BufferGeometry(positions, Float64[], Float64[], Int[1, 65_536, 65_537], n, 1)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.012, 0.015, 0.022))
    add!(scene, AmbientLight(color=Color3(0.30, 0.33, 0.38), intensity=0.7))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.96, 0.88), intensity=1.1,
                                 position=Vec3(2.0, 3.0, 4.0)))
    add!(scene, GridHelper(4.0, 8; color=Color3(0.16, 0.18, 0.22)))

    mesh = Mesh(uint_geometry(),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), side=:double);
                name="uint32_index_triangle")
    mesh.position = Vec3(0.0, 0.15, 0.0)
    add!(scene, mesh)

    WebGLExportCase("buffergeometry_uint", "BufferGeometry Uint",
                    "Indexed BufferGeometry crossing the 65k index boundary.",
                    scene; target=Vec3(0.0, 0.25, 0.0), radius=4.8, height=1.4,
                    fov=pi/4.5)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_uint.html"), [build_case()])
    println("WEBGL_BUFFERGEOMETRY_UINT_OK $html")
end

main()
