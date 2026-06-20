# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_variations_standard

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function studio_environment(; width::Int=64, height::Int=32)
    data = Array{Float64}(undef, height, width, 3)
    for row in 1:height, col in 1:width
        u = (col - 0.5) / width
        v = 1.0 - (row - 0.5) / height
        horizon = 1.0 - abs(2v - 1.0)
        side = 0.5 + 0.5 * cos(2pi * (u - 0.18))
        rim = 0.5 + 0.5 * cos(4pi * (u + 0.05))
        data[row, col, 1] = 0.10 + 0.40 * horizon + 0.34 * side * horizon
        data[row, col, 2] = 0.12 + 0.46 * horizon + 0.18 * v
        data[row, col, 3] = 0.18 + 0.54 * v + 0.26 * rim * horizon
    end
    tex = Texture(data; wrap_s=:repeat, wrap_t=:clamp,
                  filter=:linear, colorspace=:linear)
    equirectangular_to_cubemap(tex; size=16, generate_mipmaps=true)
end

function add_standard_sphere!(group::Group, env_map::CubeTexture,
                              name::String, position::Vec3,
                              color::Color3, metalness::Float64,
                              roughness::Float64)
    material = MeshStandardMaterial(color=color,
                                    metalness=metalness, roughness=roughness,
                                    envmap=env_map, env_map_intensity=0.85,
                                    side=:double)
    mesh = Mesh(SphereGeometry(radius=0.46, width_segments=44, height_segments=22),
                material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    env_map = studio_environment()
    scene = Scene(background=Color3(0.012, 0.015, 0.022),
                  fog=Fog(color=Color3(0.012, 0.015, 0.022), near=8.0, far=16.0))
    add!(scene, AmbientLight(color=Color3(0.48, 0.52, 0.60), intensity=0.24))
    add!(scene, HemisphereLight(color=Color3(0.48, 0.62, 1.0),
                                ground_color=Color3(0.15, 0.12, 0.10),
                                intensity=0.52))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.93, 0.78), intensity=1.4,
                                 position=Vec3(3.5, 5.0, 4.0), cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.24, 0.52, 1.0), intensity=6.5,
                           distance=8.5, decay=2.0, position=Vec3(-3.2, 2.1, 2.5)))

    floor = Mesh(PlaneGeometry(width=8.4, height=8.4, width_segments=4, height_segments=4),
                 MeshStandardMaterial(color=Color3(0.13, 0.14, 0.17),
                                      metalness=0.08, roughness=0.82,
                                      envmap=env_map, env_map_intensity=0.32);
                 name="standard_variations_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, floor)

    group = Group(name="standard_material_variations")
    add!(scene, group)
    metalness_values = [0.0, 0.35, 0.70, 1.0]
    roughness_values = [0.08, 0.28, 0.56, 0.86]
    colors = [
        Color3(0.90, 0.36, 0.24),
        Color3(0.90, 0.72, 0.30),
        Color3(0.28, 0.74, 0.64),
        Color3(0.42, 0.60, 0.95),
    ]
    for (row, roughness) in pairs(roughness_values), (col, metalness) in pairs(metalness_values)
        x = (col - 2.5) * 1.18
        z = (row - 2.5) * 1.05
        color = colors[col] * (0.86 + 0.12 * row)
        add_standard_sphere!(group, env_map,
                             "standard_m$(col)_r$(row)",
                             Vec3(x, 0.48, z), color,
                             Float64(metalness), Float64(roughness))
    end

    clip = AnimationClip("standard_materials_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("materials-variations-standard", "Materials Variations Standard",
                    "MeshStandardMaterial roughness and metalness variants use a generated environment cubemap.",
                    scene; target=Vec3(0.0, 0.45, 0.0), radius=7.6, height=2.7,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.04,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_variations_standard.html"), [build_case()])
    println("WEBGL_MATERIALS_VARIATIONS_STANDARD_OK $html")
end

main()
