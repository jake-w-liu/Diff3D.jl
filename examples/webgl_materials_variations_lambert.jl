# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_variations_lambert

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function bands_texture(; n::Int=32)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        stripe = fld(x - 1, 4) % 2 == 0
        ring = fld(y - 1, 8) % 2 == 0
        data[y, x, 1] = stripe ? 0.94 : 0.18
        data[y, x, 2] = ring ? 0.72 : 0.28
        data[y, x, 3] = stripe ? 0.26 : 0.88
        data[y, x, 4] = 1.0
    end
    Texture(data; repeat=Vec2(2.0, 1.5), filter=:nearest)
end

function add_lambert_mesh!(group::Group, geometry, name::String, position::Vec3,
                           color::Color3; map=nothing, emissive=Color3(0, 0, 0))
    material = MeshLambertMaterial(color=color,
                                   emissive=emissive,
                                   map=map,
                                   side=:double,
                                   depth_write=true)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.018, 0.024, 0.028),
                  fog=Fog(color=Color3(0.018, 0.024, 0.028), near=9.0, far=18.0))
    add!(scene, AmbientLight(color=Color3(0.54, 0.58, 0.64), intensity=0.34))
    add!(scene, HemisphereLight(color=Color3(0.42, 0.62, 1.0),
                                ground_color=Color3(0.34, 0.22, 0.12),
                                intensity=0.62))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.78), intensity=1.8,
                                 position=Vec3(3.5, 5.0, 4.0), cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.18, 0.52, 1.0), intensity=2.2,
                           distance=8.5, decay=2.0, position=Vec3(-3.0, 1.6, 2.0)))

    group = Group(name="lambert_material_group")
    add!(scene, group)

    tex = bands_texture()
    add_lambert_mesh!(group,
                      TorusKnotGeometry(radius=0.72, tube=0.18,
                                        tubular_segments=112, radial_segments=14),
                      "lambert_torus_knot", Vec3(-1.8, 0.72, 0.0),
                      Color3(0.9, 0.34, 0.18);
                      emissive=Color3(0.025, 0.006, 0.002))
    add_lambert_mesh!(group,
                      SphereGeometry(radius=0.86, width_segments=48, height_segments=24),
                      "lambert_textured_sphere", Vec3(0.0, -0.48, 0.0),
                      Color3(1.0, 1.0, 1.0); map=tex)
    add_lambert_mesh!(group,
                      BoxGeometry(width=1.25, height=1.25, depth=1.25),
                      "lambert_box", Vec3(1.85, 0.7, 0.0),
                      Color3(0.28, 0.82, 0.58))
    add_lambert_mesh!(group,
                      IcosahedronGeometry(radius=0.78, detail=2),
                      "lambert_icosahedron", Vec3(0.0, 1.45, -1.25),
                      Color3(0.72, 0.48, 0.95);
                      emissive=Color3(0.018, 0.008, 0.026))

    clip = AnimationClip("lambert_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.28, pi, 0.18),
                                 quat_from_euler(0.56, 2pi, 0.36)])
    ]; loop=:repeat)

    WebGLExportCase("materials-variations-lambert", "Materials Variations Lambert",
                    "MeshLambertMaterial is exported through a diffuse-only browser material branch with scene lights.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=7.0, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_variations_lambert.html"), [build_case()])
    println("WEBGL_MATERIALS_VARIATIONS_LAMBERT_OK $html")
end

main()
