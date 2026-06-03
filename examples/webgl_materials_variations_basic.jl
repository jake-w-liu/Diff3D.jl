# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_materials_variations_basic

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function checker_texture(; n::Int=32)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        band = (fld(x - 1, 4) + fld(y - 1, 4)) % 2 == 0
        data[y, x, 1] = band ? 1.0 : 0.12
        data[y, x, 2] = band ? 0.86 : 0.22
        data[y, x, 3] = band ? 0.28 : 0.95
        data[y, x, 4] = 1.0
    end
    Texture(data; repeat=Vec2(2.0, 2.0), filter=:nearest)
end

function add_basic_mesh!(group::Group, geometry, name::String, position::Vec3,
                         color::Color3; map=nothing, opacity::Float64=1.0)
    material = MeshBasicMaterial(color=color,
                                 map=map,
                                 opacity=opacity,
                                 transparent=opacity < 1.0,
                                 side=:double)
    mesh = Mesh(geometry, material; name=name)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.02, 0.022, 0.028),
                  fog=Fog(color=Color3(0.02, 0.022, 0.028), near=8.0, far=18.0))

    add!(scene, AmbientLight(color=Color3(0.08, 0.08, 0.08), intensity=0.1))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.25, 0.1), intensity=5.0,
                                 position=Vec3(2.5, 4.0, 3.0)))
    add!(scene, PointLight(color=Color3(0.1, 0.45, 1.0), intensity=6.0,
                           distance=6.0, position=Vec3(-2.5, 1.5, 1.8)))

    group = Group(name="basic_material_group")
    add!(scene, group)

    tex = checker_texture()
    add_basic_mesh!(group,
                    TorusKnotGeometry(radius=0.72, tube=0.18,
                                      tubular_segments=112, radial_segments=14),
                    "basic_torus_knot", Vec3(-1.85, 0.72, 0.0),
                    Color3(1.0, 0.34, 0.18))
    add_basic_mesh!(group,
                    SphereGeometry(radius=0.86, width_segments=48, height_segments=24),
                    "basic_textured_sphere", Vec3(0.0, -0.48, 0.0),
                    Color3(1.0, 1.0, 1.0); map=tex)
    add_basic_mesh!(group,
                    BoxGeometry(width=1.25, height=1.25, depth=1.25),
                    "basic_box", Vec3(1.85, 0.72, 0.0),
                    Color3(0.28, 0.9, 0.62))
    add_basic_mesh!(group,
                    IcosahedronGeometry(radius=0.78, detail=2),
                    "basic_transparent_icosahedron", Vec3(0.0, 1.45, -1.2),
                    Color3(0.72, 0.48, 1.0); opacity=0.72)

    clip = AnimationClip("basic_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.34, pi, 0.22),
                                 quat_from_euler(0.68, 2pi, 0.44)])
    ]; loop=:repeat)

    WebGLExportCase("materials-variations-basic", "Materials Variations Basic",
                    "MeshBasicMaterial is exported through an unlit browser shader branch; scene lights are present but do not shade the objects.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=7.0, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_variations_basic.html"), [build_case()])
    println("WEBGL_MATERIALS_VARIATIONS_BASIC_OK $html")
end

main()
