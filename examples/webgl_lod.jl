# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_lod

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function lod_geometries()
    [
        (IcosahedronGeometry(radius=0.42, detail=3), 0.0),
        (IcosahedronGeometry(radius=0.42, detail=2), 4.0),
        (IcosahedronGeometry(radius=0.42, detail=1), 9.0),
        (IcosahedronGeometry(radius=0.42, detail=0), 16.0),
    ]
end

function deterministic_lod_position(i::Int)
    x = 22.0 * (mod(37i + 11, 101) / 100 - 0.5)
    y = 12.0 * (mod(53i + 19, 101) / 100 - 0.5)
    z = 22.0 * (mod(71i + 23, 101) / 100 - 0.5)
    Vec3(x, y, z)
end

function add_lod_cluster!(scene::Scene, index::Int, geometries, material)
    lod = LOD(name="lod_cluster_$(index)")
    lod.position = deterministic_lod_position(index)
    lod.rotation = Euler(0.18 * index, 0.11 * index, 0.07 * index)
    lod.scale = Vec3(1.5, 1.5, 1.5)

    for (level, (geo, distance)) in enumerate(geometries)
        mesh = Mesh(geo, material; name="lod_cluster_$(index)_level_$(level)")
        add_lod_level!(lod, distance, mesh; hysteresis=0.08)
    end
    add!(scene, lod)
    return lod
end

function build_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0),
                  fog=Fog(color=Color3(0.0, 0.0, 0.0), near=8.0, far=40.0))
    add!(scene, PointLight(color=Color3(1.0, 0.18, 0.04), intensity=4.2,
                           distance=0.0, decay=0.0, position=Vec3(0.0, 0.0, 0.0)))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=2.4,
                                 position=Vec3(0.0, 0.0, 1.0)))

    geometries = lod_geometries()
    material = MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                   wireframe=true, side=:double)
    for i in 1:72
        add_lod_cluster!(scene, i, geometries, material)
    end

    WebGLExportCase("lod-field", "Level Of Detail",
                    "Diff3D.jl LOD groups select progressively simpler IcosahedronGeometry levels by camera distance.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=26.0, height=7.0,
                    fov=45pi / 180, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lod.html"), [build_case()])
    println("WEBGL_LOD_OK $html")
end

main()
