# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_teapot

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function teapot_uv_grid_texture(; n::Int=96)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        grid = (x - 1) % 12 == 0 || (y - 1) % 12 == 0
        check = (fld(x - 1, 12) + fld(y - 1, 12)) % 2 == 0
        data[y, x, 1] = grid ? 0.04 : (check ? 0.92 : 0.16)
        data[y, x, 2] = grid ? 0.04 : (check ? 0.78 : 0.32)
        data[y, x, 3] = grid ? 0.04 : (check ? 0.20 : 0.86)
        data[y, x, 4] = 1.0
    end
    return Texture(data; repeat=Vec2(2.0, 2.0), filter=:nearest,
                   min_filter=:nearest, colorspace=:srgb)
end

function teapot_environment(; width::Int=48, height::Int=24)
    data = Array{Float64}(undef, height, width, 3)
    for row in 1:height, col in 1:width
        u = (col - 0.5) / width
        v = 1.0 - (row - 0.5) / height
        horizon = 1.0 - abs(2v - 1.0)
        warm = 0.5 + 0.5 * cos(2pi * (u - 0.1))
        cool = 0.5 + 0.5 * sin(2pi * (u + 0.23))
        data[row, col, 1] = 0.10 + 0.52 * horizon + 0.25 * warm * v
        data[row, col, 2] = 0.12 + 0.46 * horizon + 0.16 * cool
        data[row, col, 3] = 0.18 + 0.56 * v + 0.18 * cool * horizon
    end
    tex = Texture(data; wrap_s=:repeat, wrap_t=:clamp,
                  filter=:linear, colorspace=:linear)
    return equirectangular_to_cubemap(tex; size=16, generate_mipmaps=true)
end

function add_teapot!(group::Group, geometry::BufferGeometry, material,
                     position::Vec3, name::String)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = position
    add!(group, mesh)
    return mesh
end

function build_case()
    texture = teapot_uv_grid_texture()
    env_map = teapot_environment()

    scene = Scene(background=Color3(0.72, 0.73, 0.75),
                  fog=Fog(color=Color3(0.72, 0.73, 0.75), near=8.0, far=18.0))
    add!(scene, AmbientLight(color=Color3(0.72, 0.72, 0.72), intensity=0.72))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=2.1,
                                 position=Vec3(0.7, 1.2, 1.5)))
    add!(scene, PointLight(color=Color3(0.42, 0.62, 1.0), intensity=3.0,
                           distance=8.0, position=Vec3(-3.5, 2.6, 3.0)))

    floor = Mesh(PlaneGeometry(width=9.0, height=7.0),
                 MeshStandardMaterial(color=Color3(0.43, 0.45, 0.48),
                                      metalness=0.05, roughness=0.75,
                                      envmap=env_map, env_map_intensity=0.25);
                 name="teapot_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -1.22, 0.0)
    add!(scene, floor)

    group = Group(name="teapot_variants")
    add!(scene, group)

    full_geometry = TeapotGeometry(2.0, 12; bottom=true, lid=true, body=true,
                                   fit_lid=false, blinn=true)
    textured = add_teapot!(group, full_geometry,
                           MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                             specular=Color3(0.18, 0.18, 0.18),
                                             shininess=90.0, map=texture,
                                             side=:double),
                           Vec3(-1.45, 0.0, 0.0), "teapot_textured")

    wire = Mesh(full_geometry,
                MeshBasicMaterial(color=Color3(0.02, 0.02, 0.025),
                                  opacity=0.35, transparent=true,
                                  wireframe=true, side=:double);
                name="teapot_textured_wire")
    add!(textured, wire)

    reflective_geometry = TeapotGeometry(1.15, 10; bottom=true, lid=true,
                                         body=true, fit_lid=true, blinn=false)
    add_teapot!(group, reflective_geometry,
                MeshStandardMaterial(color=Color3(0.78, 0.80, 0.84),
                                     metalness=0.82, roughness=0.20,
                                     envmap=env_map, env_map_intensity=0.95,
                                     side=:double),
                Vec3(1.65, -0.35, -0.75), "teapot_reflective_original_scale")

    body_geometry = TeapotGeometry(0.82, 7; bottom=false, lid=false, body=true)
    add_teapot!(group, body_geometry,
                MeshLambertMaterial(color=Color3(0.16, 0.56, 0.84),
                                    side=:double),
                Vec3(1.15, -0.54, 1.25), "teapot_body_only")

    lid_geometry = TeapotGeometry(0.82, 7; bottom=false, lid=true, body=false,
                                  fit_lid=true)
    add_teapot!(group, lid_geometry,
                MeshPhongMaterial(color=Color3(0.90, 0.42, 0.22),
                                  specular=Color3(0.28, 0.20, 0.16),
                                  shininess=120.0, side=:double),
                Vec3(2.55, -0.26, 1.25), "teapot_lid_only")

    bottom_geometry = TeapotGeometry(0.82, 7; bottom=true, lid=false, body=false)
    add_teapot!(group, bottom_geometry,
                MeshLambertMaterial(color=Color3(0.36, 0.68, 0.28),
                                    side=:double),
                Vec3(2.55, -0.92, 1.25), "teapot_bottom_only")

    clip = AnimationClip("teapot_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-teapot", "Geometry Teapot",
                    "Utah teapot Bezier patches with textured, reflective, and part-toggle variants.",
                    scene; target=Vec3(0.35, 0.15, 0.25), radius=7.1,
                    height=2.25, fov=pi / 4.4, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.02,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_teapot.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_TEAPOT_OK $html")
end

main()
