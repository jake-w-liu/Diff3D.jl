# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_variations_phong

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function glint_texture(; n::Int=32)
    data = ones(Float64, n, n, 4)
    cx = (n + 1) / 2
    cy = (n + 1) / 2
    for y in 1:n, x in 1:n
        dx = (x - cx) / n
        dy = (y - cy) / n
        r = sqrt(dx * dx + dy * dy)
        wave = 0.5 + 0.5 * cos(34.0 * r)
        data[y, x, 1] = 0.18 + 0.72 * wave
        data[y, x, 2] = 0.18 + 0.42 * (1.0 - r)
        data[y, x, 3] = 0.82
        data[y, x, 4] = 1.0
    end
    Texture(data; repeat=Vec2(1.8, 1.8), filter=:linear)
end

function add_phong_mesh!(group::Group, geometry, name::String, position::Vec3,
                         color::Color3, specular::Color3, shininess::Float64; map=nothing)
    material = MeshPhongMaterial(color=color,
                                 specular=specular,
                                 shininess=shininess,
                                 map=map,
                                 side=:double,
                                 depth_write=true)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.018, 0.02, 0.026),
                  fog=Fog(color=Color3(0.018, 0.02, 0.026), near=9.0, far=18.0))
    add!(scene, AmbientLight(color=Color3(0.52, 0.54, 0.6), intensity=0.24))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.95, 0.84), intensity=1.7,
                                 position=Vec3(3.2, 4.8, 4.0), cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.2, 0.5, 1.0), intensity=4.2,
                           distance=8.5, decay=2.0, position=Vec3(-2.8, 1.6, 2.3)))
    add!(scene, SpotLight(color=Color3(1.0, 0.52, 0.22), intensity=4.0,
                          distance=9.0, angle=0.48, penumbra=0.35, decay=2.0,
                          position=Vec3(2.8, 3.0, 2.2), target=Vec3(0.0, 0.25, 0.0)))

    group = Group(name="phong_material_group")
    add!(scene, group)

    tex = glint_texture()
    add_phong_mesh!(group,
                    TorusKnotGeometry(radius=0.72, tube=0.18,
                                      tubular_segments=112, radial_segments=14),
                    "phong_torus_knot", Vec3(-1.85, 0.72, 0.0),
                    Color3(0.95, 0.42, 0.22), Color3(0.9, 0.72, 0.45), 78.0)
    add_phong_mesh!(group,
                    SphereGeometry(radius=0.86, width_segments=48, height_segments=24),
                    "phong_textured_sphere", Vec3(0.0, -0.48, 0.0),
                    Color3(1.0, 1.0, 1.0), Color3(0.74, 0.82, 1.0), 96.0; map=tex)
    add_phong_mesh!(group,
                    BoxGeometry(width=1.25, height=1.25, depth=1.25),
                    "phong_box", Vec3(1.85, 0.7, 0.0),
                    Color3(0.26, 0.74, 0.62), Color3(0.8, 1.0, 0.9), 42.0)
    add_phong_mesh!(group,
                    IcosahedronGeometry(radius=0.78, detail=2),
                    "phong_icosahedron", Vec3(0.0, 1.45, -1.25),
                    Color3(0.78, 0.52, 0.96), Color3(0.98, 0.92, 1.0), 130.0)

    clip = AnimationClip("phong_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.32, pi, 0.24),
                                 quat_from_euler(0.64, 2pi, 0.48)])
    ]; loop=:repeat)

    WebGLExportCase("materials-variations-phong", "Materials Variations Phong",
                    "MeshPhongMaterial exports specular color and shininess into the compact browser material branch.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=7.0, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_variations_phong.html"), [build_case()])
    println("WEBGL_MATERIALS_VARIATIONS_PHONG_OK $html")
end

main()
