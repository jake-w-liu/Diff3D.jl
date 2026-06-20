# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_cubemap_mipmaps

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const FACE_COLORS = (
    (0.96, 0.20, 0.16), (0.18, 0.58, 0.96), (0.96, 0.82, 0.18),
    (0.24, 0.86, 0.46), (0.72, 0.36, 0.96), (0.96, 0.54, 0.18),
)

function face_gradient(face::Int, n::Int)
    data = Array{Float64}(undef, n, n, 3)
    base = FACE_COLORS[face]
    for y in 1:n, x in 1:n
        u = (x - 0.5) / n
        v = 1.0 - (y - 0.5) / n
        ring = 0.5 + 0.5 * cos(22.0 * hypot(u - 0.5, v - 0.5))
        stripe = mod(x + 3y + 5face, 11) < 5 ? 1.0 : 0.62
        value = 0.42 + 0.32 * ring + 0.20 * stripe + 0.10 * v
        data[y, x, 1] = clamp(base[1] * value, 0.0, 1.0)
        data[y, x, 2] = clamp(base[2] * value, 0.0, 1.0)
        data[y, x, 3] = clamp(base[3] * value, 0.0, 1.0)
    end
    data
end

function solid_level(rgb, n::Int)
    data = Array{Float64}(undef, n, n, 3)
    for y in 1:n, x in 1:n
        data[y, x, 1] = rgb[1]
        data[y, x, 2] = rgb[2]
        data[y, x, 3] = rgb[3]
    end
    data
end

function manual_mipmaps(face::Int, base_size::Int)
    base = FACE_COLORS[face]
    levels = Array{Float64,3}[]
    for level in 1:5
        n = max(1, base_size >> level)
        fade = 0.82 ^ level
        tint = 0.06 * level
        push!(levels, solid_level((clamp(base[1] * fade + tint, 0.0, 1.0),
                                   clamp(base[2] * fade + tint, 0.0, 1.0),
                                   clamp(base[3] * fade + tint, 0.0, 1.0)), n))
    end
    levels
end

function generated_mipmap_cube(; size::Int=32)
    CubeTexture(ntuple(face -> begin
        tex = Texture(face_gradient(face, size);
                      colorspace=:linear, filter=:linear,
                      min_filter=:linear_mipmap_linear)
        generate_mipmaps!(tex)
        tex
    end, 6))
end

function authored_mipmap_cube(; size::Int=32)
    CubeTexture(ntuple(face -> begin
        Texture(face_gradient(face, size);
                colorspace=:linear, filter=:linear,
                min_filter=:linear_mipmap_linear,
                mipmaps=manual_mipmaps(face, size))
    end, 6))
end

function add_reflector!(scene::Scene, geometry, name::String, position::Vec3,
                        env_map::CubeTexture, color::Color3)
    material = MeshStandardMaterial(color=color,
                                    metalness=1.0, roughness=0.72,
                                    envmap=env_map, env_map_intensity=1.0,
                                    side=:double)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(scene, mesh)
    return mesh
end

function build_case()
    generated_env = generated_mipmap_cube()
    authored_env = authored_mipmap_cube()
    scene = Scene(background=Color3(0.010, 0.012, 0.018),
                  fog=Fog(color=Color3(0.010, 0.012, 0.018), near=7.5, far=15.0))
    add!(scene, AmbientLight(color=Color3(0.36, 0.38, 0.44), intensity=0.30))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.95, 0.82), intensity=1.45,
                                 position=Vec3(3.2, 4.8, 3.6), cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.35, 0.64, 1.0), intensity=5.5,
                           distance=8.0, decay=2.0, position=Vec3(-2.8, 1.8, 2.4)))

    floor = Mesh(PlaneGeometry(width=7.2, height=5.4),
                 MeshStandardMaterial(color=Color3(0.13, 0.14, 0.17),
                                      metalness=0.12, roughness=0.86);
                 name="cubemap_mipmaps_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, floor)

    left = add_reflector!(scene,
                          TorusKnotGeometry(radius=0.74, tube=0.18,
                                            tubular_segments=128, radial_segments=16),
                          "generated_mipmap_reflector", Vec3(-1.45, 0.95, 0.0),
                          generated_env, Color3(0.92, 0.94, 1.0))
    right = add_reflector!(scene,
                           TorusKnotGeometry(radius=0.74, tube=0.18,
                                             tubular_segments=128, radial_segments=16),
                           "authored_mipmap_reflector", Vec3(1.45, 0.95, 0.0),
                           authored_env, Color3(1.0, 0.94, 0.88))

    clip = AnimationClip("cubemap_mipmaps_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(left, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.25, pi, 0.0),
                                 quat_from_euler(0.50, 2pi, 0.0)]),
        QuaternionKeyframeTrack(right, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(-0.25, -pi, 0.0),
                                 quat_from_euler(-0.50, -2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("materials-cubemap-mipmaps", "Materials Cubemap Mipmaps",
                    "Generated and authored CubeTexture mip chains feed rough MeshStandardMaterial reflections.",
                    scene; target=Vec3(0.0, 0.85, 0.0), radius=6.4, height=2.2,
                    fov=pi / 4.1, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_cubemap_mipmaps.html"), [build_case()])
    println("WEBGL_MATERIALS_CUBEMAP_MIPMAPS_OK $html")
end

main()
