# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_materials_matcap

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function demo_matcap_texture()
    data = zeros(Float64, 32, 32, 3)
    for y in 1:32, x in 1:32
        nx = (x - 16.5) / 16
        ny = (y - 16.5) / 16
        r = clamp(sqrt(nx^2 + ny^2), 0.0, 1.0)
        data[y, x, 1] = 0.25 + 0.75 * (1.0 - r)
        data[y, x, 2] = 0.35 + 0.55 * max(ny, 0.0)
        data[y, x, 3] = 0.45 + 0.45 * max(-nx, 0.0)
    end
    Texture(data; filter=:bilinear, wrap_s=:clamp, wrap_t=:clamp, colorspace=:linear)
end

function add_matcap_mesh!(group::Group, geometry, name::String, position::Vec3,
                          color::Color3; matcap=nothing)
    mesh = Mesh(geometry, MeshMatcapMaterial(color=color, matcap=matcap, side=:double); name=name)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(0.015, 0.017, 0.022),
                  fog=Fog(color=Color3(0.015, 0.017, 0.022), near=8.0, far=17.0))
    group = Group(name="matcap_material_group")
    add!(scene, group)
    matcap = demo_matcap_texture()

    add_matcap_mesh!(group,
                     TorusKnotGeometry(radius=0.72, tube=0.2,
                                       tubular_segments=112, radial_segments=14),
                     "matcap_torus_knot", Vec3(-1.85, 0.85, 0.0),
                     Color3(0.95, 0.45, 0.72); matcap=matcap)
    add_matcap_mesh!(group,
                     SphereGeometry(radius=0.9, width_segments=48, height_segments=24),
                     "matcap_sphere", Vec3(0.0, -0.45, 0.0),
                     Color3(0.38, 0.82, 0.95))
    add_matcap_mesh!(group,
                     IcosahedronGeometry(radius=0.78, detail=2),
                     "matcap_icosahedron", Vec3(1.85, 0.8, 0.0),
                     Color3(0.9, 0.72, 0.34))
    add_matcap_mesh!(group,
                     TorusGeometry(radius=0.62, tube=0.18,
                                   radial_segments=18, tubular_segments=72),
                     "matcap_torus", Vec3(0.0, 1.45, -1.3),
                     Color3(0.72, 0.55, 0.95))

    clip = AnimationClip("matcap_material_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.45, pi, 0.18),
                                 quat_from_euler(0.9, 2pi, 0.36)])
    ]; loop=:repeat)

    WebGLExportCase("materials-matcap", "Materials Matcap",
                    "MeshMatcapMaterial supports texture-backed matcaps with a procedural fallback in the Three.jl WebGL exporter.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=7.0, height=2.0,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_matcap.html"), [build_case()])
    println("WEBGL_MATERIALS_MATCAP_OK $html")
end

main()
