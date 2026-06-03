# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_materials_physical_clearcoat

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function paint_texture(; n::Int=48)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        u = (x - 1) / max(n - 1, 1)
        v = (y - 1) / max(n - 1, 1)
        stripe = 0.5 + 0.5 * sin(30.0 * u + 8.0 * sin(6.0 * v))
        data[y, x, 1] = 0.72 + 0.2 * stripe
        data[y, x, 2] = 0.08 + 0.08 * v
        data[y, x, 3] = 0.06 + 0.08 * (1.0 - stripe)
        data[y, x, 4] = 1.0
    end
    Texture(data; repeat=Vec2(1.5, 1.5), filter=:linear)
end

function clearcoat_texture(; n::Int=48)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        u = (x - 1) / max(n - 1, 1)
        v = (y - 1) / max(n - 1, 1)
        rings = 0.5 + 0.5 * cos(36.0 * hypot(u - 0.5, v - 0.5))
        scratches = mod(fld(x + 2y, 5), 2) == 0 ? 0.85 : 0.45
        data[y, x, 1] = rings
        data[y, x, 2] = scratches
        data[y, x, 3] = 0.0
        data[y, x, 4] = 1.0
    end
    Texture(data; colorspace=:linear, repeat=Vec2(2.0, 2.0), filter=:linear)
end

function add_physical!(group::Group, geometry, name::String, position::Vec3, material)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.012, 0.014, 0.02),
                  fog=FogExp2(color=Color3(0.012, 0.014, 0.02), density=0.042))
    add!(scene, AmbientLight(color=Color3(0.45, 0.48, 0.56), intensity=0.28))
    add!(scene, HemisphereLight(color=Color3(0.45, 0.62, 1.0),
                                ground_color=Color3(0.12, 0.08, 0.06),
                                intensity=0.55))
    key = DirectionalLight(color=Color3(1.0, 0.95, 0.82), intensity=1.5,
                           position=Vec3(4.0, 5.2, 4.5), cast_shadow=true)
    key.target = Vec3(0.0, 0.2, 0.0)
    add!(scene, key)
    add!(scene, PointLight(color=Color3(0.25, 0.55, 1.0), intensity=8.0,
                           distance=9.5, decay=2.0, position=Vec3(-3.0, 2.2, 2.6)))

    floor = Mesh(PlaneGeometry(width=7.5, height=7.5),
                 MeshStandardMaterial(color=Color3(0.14, 0.15, 0.18), roughness=0.86);
                 name="clearcoat_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, floor)

    group = Group(name="physical_clearcoat_group")
    add!(scene, group)

    paint = paint_texture()
    coat = clearcoat_texture()
    base = MeshPhysicalMaterial(color=Color3(0.86, 0.12, 0.08),
                                roughness=0.34,
                                metalness=0.02,
                                clearcoat=0.0,
                                side=:double)
    glossy = MeshPhysicalMaterial(color=Color3(0.9, 0.16, 0.08),
                                  roughness=0.28,
                                  metalness=0.04,
                                  clearcoat=1.0,
                                  clearcoat_roughness=0.06,
                                  map=paint,
                                  side=:double)
    mapped = MeshPhysicalMaterial(color=Color3(0.96, 0.3, 0.12),
                                  roughness=0.24,
                                  metalness=0.03,
                                  clearcoat=1.0,
                                  clearcoat_roughness=0.22,
                                  map=paint,
                                  clearcoat_map=coat,
                                  clearcoat_roughness_map=coat,
                                  side=:double)

    add_physical!(group,
                  SphereGeometry(radius=0.9, width_segments=56, height_segments=28),
                  "physical_clearcoat_plain", Vec3(-1.75, 0.9, 0.0), base)
    add_physical!(group,
                  TorusKnotGeometry(radius=0.68, tube=0.18,
                                    tubular_segments=128, radial_segments=16),
                  "physical_clearcoat_glossy", Vec3(0.0, 0.92, 0.0), glossy)
    add_physical!(group,
                  SphereGeometry(radius=0.9, width_segments=56, height_segments=28),
                  "physical_clearcoat_mapped", Vec3(1.75, 0.9, 0.0), mapped)

    clip = AnimationClip("physical_clearcoat_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("materials-physical-clearcoat", "Materials Physical Clearcoat",
                    "MeshPhysicalMaterial clearcoat and clearcoat texture maps are exported through Three.jl's compact physical shader branch.",
                    scene; target=Vec3(0.0, 0.85, 0.0), radius=6.8, height=2.8,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_physical_clearcoat.html"), [build_case()])
    println("WEBGL_MATERIALS_PHYSICAL_CLEARCOAT_OK $html")
end

main()
