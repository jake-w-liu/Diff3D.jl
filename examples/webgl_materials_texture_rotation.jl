# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_texture_rotation

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function uv_grid_texture(; n::Int=128)
    data = zeros(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        u = (x - 1) / (n - 1)
        v = (y - 1) / (n - 1)
        checker = (fld(x - 1, 12) + fld(y - 1, 12)) % 2 == 0
        edge = x <= 4 || y <= 4 || x > n - 4 || y > n - 4
        vertical = abs(u - 0.5) < 0.025
        horizontal = abs(v - 0.5) < 0.025
        diagonal = abs(u - v) < 0.025
        antidiagonal = abs(u + v - 1.0) < 0.025

        base = checker ? 0.82 : 0.16
        data[y, x, 1] = base
        data[y, x, 2] = checker ? 0.90 : 0.20
        data[y, x, 3] = checker ? 0.98 : 0.30
        data[y, x, 4] = 1.0

        if edge
            data[y, x, 1] = 0.98
            data[y, x, 2] = 0.80
            data[y, x, 3] = 0.16
        elseif vertical || horizontal
            data[y, x, 1] = 0.04
            data[y, x, 2] = 0.08
            data[y, x, 3] = 0.12
        elseif diagonal
            data[y, x, 1] = 0.95
            data[y, x, 2] = 0.12
            data[y, x, 3] = 0.12
        elseif antidiagonal
            data[y, x, 1] = 0.12
            data[y, x, 2] = 0.32
            data[y, x, 3] = 0.95
        end

        if u > 0.70 && v > 0.70
            data[y, x, 1] = 0.12
            data[y, x, 2] = 0.88
            data[y, x, 3] = 0.34
        elseif u < 0.30 && v > 0.70
            data[y, x, 1] = 0.90
            data[y, x, 2] = 0.22
            data[y, x, 3] = 0.78
        end
    end
    return data
end

function textured_plane(name::String, position::Vec3, texture::Texture)
    material = MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                 map=texture,
                                 side=:double)
    mesh = Mesh(PlaneGeometry(width=2.0, height=2.0), material; name=name)
    mesh.position = position
    return mesh
end

function build_case()
    texture_data = uv_grid_texture()
    base_texture = Texture(copy(texture_data); filter=:nearest,
                           wrap_s=:repeat, wrap_t=:repeat)
    rotated_texture = Texture(copy(texture_data); filter=:nearest,
                              wrap_s=:repeat, wrap_t=:repeat,
                              repeat=Vec2(0.25, 0.25),
                              rotation=pi / 4,
                              center=Vec2(0.5, 0.5))
    offset_texture = Texture(copy(texture_data); filter=:nearest,
                             wrap_s=:repeat, wrap_t=:repeat,
                             offset=Vec2(0.18, 0.12),
                             repeat=Vec2(0.55, 0.35),
                             rotation=-pi / 8,
                             center=Vec2(0.25, 0.75))

    manual_matrix = Mat3{Float64}((0.35, 0.35, 0.15,
                                  -0.35, 0.35, 0.42,
                                   0.0,  0.0,  1.0))
    manual_texture = Texture(copy(texture_data); filter=:nearest,
                             wrap_s=:repeat, wrap_t=:repeat,
                             matrix=manual_matrix,
                             matrix_auto_update=false)

    scene = Scene(background=Color3(0.025, 0.028, 0.035),
                  fog=Fog(color=Color3(0.025, 0.028, 0.035), near=7.0, far=18.0))

    group = Group(name="texture_transform_group")
    add!(scene, group)
    add!(group, textured_plane("texture_base", Vec3(-2.75, 1.25, 0.0), base_texture))
    add!(group, textured_plane("texture_rotated_map", Vec3(0.0, 1.25, 0.0), rotated_texture))
    add!(group, textured_plane("texture_offset_repeat", Vec3(2.75, 1.25, 0.0), offset_texture))
    add!(group, textured_plane("texture_manual_matrix", Vec3(0.0, -1.45, 0.0), manual_texture))

    add!(scene, GridHelper(7.0, 14; color=Color3(0.12, 0.15, 0.19)))

    clip = AnimationClip("texture_rotation_motion", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, 0.20, 0.02),
                                 quat_from_euler(0.0, -0.20, -0.02)])
    ]; loop=:repeat)

    WebGLExportCase("materials-texture-rotation", "Materials Texture Rotation",
                    "Generated UV grid textures exercise Texture.offset, Texture.repeat, Texture.rotation, Texture.center, and manual matrix export.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=7.0, height=2.1,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_texture_rotation.html"), [build_case()])
    println("WEBGL_MATERIALS_TEXTURE_ROTATION_OK $html")
end

main()
