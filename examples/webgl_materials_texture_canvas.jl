# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_materials_texture_canvas

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function drawing_canvas_texture(; n::Int=128)
    data = fill(0.96, n, n, 4)
    data[:, :, 4] .= 1.0
    for y in 1:n, x in 1:n
        u = (x - 1) / (n - 1)
        v = (y - 1) / (n - 1)
        border = x <= 5 || y <= 5 || x > n - 5 || y > n - 5
        grid = (x - 1) % 16 == 0 || (y - 1) % 16 == 0
        stroke_a = abs(v - (0.18 + 0.58u + 0.08sin(8pi * u))) < 0.028
        stroke_b = abs((u - 0.68)^2 + (v - 0.58)^2 - 0.045) < 0.018
        stroke_c = abs(u - (0.23 + 0.10sin(9pi * v))) < 0.024 && 0.18 < v < 0.82

        if border
            data[y, x, 1] = 0.10
            data[y, x, 2] = 0.12
            data[y, x, 3] = 0.16
        elseif stroke_a
            data[y, x, 1] = 0.96
            data[y, x, 2] = 0.18
            data[y, x, 3] = 0.10
        elseif stroke_b
            data[y, x, 1] = 0.08
            data[y, x, 2] = 0.46
            data[y, x, 3] = 0.92
        elseif stroke_c
            data[y, x, 1] = 0.12
            data[y, x, 2] = 0.70
            data[y, x, 3] = 0.32
        elseif grid
            data[y, x, 1] = 0.74
            data[y, x, 2] = 0.78
            data[y, x, 3] = 0.84
        else
            shade = 0.88 + 0.08 * (0.65u + 0.35v)
            data[y, x, 1] = shade
            data[y, x, 2] = shade
            data[y, x, 3] = min(1.0, shade + 0.025)
        end
    end
    CanvasTexture(data; filter=:nearest, colorspace=:srgb,
                  wrap_s=:clamp, wrap_t=:clamp)
end

function build_case()
    canvas_texture = drawing_canvas_texture()
    scene = Scene(background=Color3(0.02, 0.025, 0.032))

    cube = Mesh(BoxGeometry(width=2.0, height=2.0, depth=2.0),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), map=canvas_texture,
                                  side=:double);
                name="materials_texture_canvas_cube")
    add!(scene, cube)

    clip = AnimationClip("canvas_texture_cube_spin", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(cube, :rotation, [0.0, 2.5, 5.0],
                                [quat_from_euler(0.0, 0.0, 0.0),
                                 quat_from_euler(pi / 2, pi, 0.25),
                                 quat_from_euler(pi, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("materials-texture-canvas", "Materials Texture Canvas",
                    "Generated CanvasTexture bitmap mapped onto a rotating cube.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=5.0, height=1.4,
                    fov=pi / 4, animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_materials_texture_canvas.html"), [build_case()])
    println("WEBGL_MATERIALS_TEXTURE_CANVAS_OK $html")
end

main()
