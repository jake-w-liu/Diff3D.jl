# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_points_sprites

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function star_points_geometry()
    positions = Float64[]
    colors = Float64[]
    n = 900
    for i in 0:(n - 1)
        t = i / n
        a = 34pi * t
        r = 0.25 + 3.0sqrt(t)
        y = 1.6sin(9pi * t)
        append!(positions, (r * cos(a), y, r * sin(a)))
        append!(colors, (0.7 + 0.3sin(a), 0.6 + 0.4sin(a + 2.0), 0.85 + 0.15cos(a)))
    end
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], n, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function sprite_texture()
    data = zeros(Float64, 32, 32, 4)
    for y in 1:32, x in 1:32
        dx = (x - 16.5) / 16
        dy = (y - 16.5) / 16
        r2 = dx * dx + dy * dy
        a = clamp(1.0 - r2, 0.0, 1.0)^2
        data[y, x, 1] = 1.0
        data[y, x, 2] = 0.9
        data[y, x, 3] = 0.35 + 0.65a
        data[y, x, 4] = a
    end
    Texture(data; filter=:linear)
end

function build_case()
    scene = Scene(background=Color3(0.005, 0.007, 0.014))
    add!(scene, AmbientLight(color=Color3(0.22, 0.24, 0.32), intensity=0.75))
    add!(scene, GridHelper(8.0, 16; color=Color3(0.10, 0.12, 0.17)))

    add!(scene, PointsObject(star_points_geometry(),
                             PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=7.0);
                             name="sprite_like_points"))

    sprite_map = sprite_texture()
    colors = (Color3(1.0, 0.32, 0.18), Color3(0.2, 0.8, 1.0), Color3(1.0, 0.86, 0.2))
    for i in 1:18
        a = 2pi * i / 18
        sp = Sprite(SpriteMaterial(color=colors[mod1(i, length(colors))],
                                   transparent=true,
                                   rotation=0.12 * i,
                                   size_attenuation=isodd(i),
                                   map=sprite_map);
                    name="sprite_marker_$i")
        sp.position = Vec3(2.2cos(a), 0.8sin(3a), 2.2sin(a))
        sp.scale = Vec3(0.18, 0.18, 0.18)
        add!(scene, sp)
    end

    WebGLExportCase("points_sprites", "Points Sprites",
                    "Textured billboard sprite quads exported from Three.jl Sprite proxies.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.0, height=2.6,
                    fov=pi/4.0)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_points_sprites.html"), [build_case()])
    println("WEBGL_POINTS_SPRITES_OK $html")
end

main()
