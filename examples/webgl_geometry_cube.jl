# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_geometry_cube

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function crate_texture(n::Int=64)
    data = zeros(Float64, n, n, 3)
    for y in 1:n, x in 1:n
        u = (x - 1) / (n - 1)
        v = (y - 1) / (n - 1)
        border = u < 0.08 || u > 0.92 || v < 0.08 || v > 0.92
        stripe = abs(u - v) < 0.035 || abs((1.0 - u) - v) < 0.035
        groove = (mod(floor(Int, 8u) + floor(Int, 8v), 2) == 0)
        base = groove ? Color3(0.58, 0.36, 0.18) : Color3(0.44, 0.26, 0.12)
        accent = border || stripe ? Color3(0.82, 0.62, 0.35) : base
        data[y, x, 1] = accent.r
        data[y, x, 2] = accent.g
        data[y, x, 3] = accent.b
    end
    Texture(data; filter=:linear, colorspace=:srgb)
end

function build_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.35))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.96, 0.9), intensity=1.2,
                                 position=Vec3(3.0, 4.0, 5.0)))

    cube = Mesh(BoxGeometry(width=2.0, height=2.0, depth=2.0),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                  map=crate_texture(),
                                  side=:double);
                name="geometry_cube")
    add!(scene, cube)

    clip = AnimationClip("cube_spin", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(cube, :rotation, [0.0, 2.5, 5.0],
                                [Quaternion(),
                                 quat_from_euler(pi, pi / 2, 0.0),
                                 quat_from_euler(2pi, pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-cube", "Geometry Cube",
                    "Standalone rotating textured cube generated from Three.jl.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=5.0, height=1.4,
                    fov=pi / 4, animations=[clip])
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_cube.html"), [build_case()])
    println("WEBGL_GEOMETRY_CUBE_OK $html")
end

main()
