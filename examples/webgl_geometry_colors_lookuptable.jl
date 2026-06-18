# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_geometry_colors_lookuptable

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const LUT_MAPS = Dict(
    "rainbow" => [(0.0, 0x0000ff), (0.2, 0x00ffff), (0.5, 0x00ff00),
                  (0.8, 0xffff00), (1.0, 0xff0000)],
    "cooltowarm" => [(0.0, 0x3c4ec2), (0.2, 0x9bbcff), (0.5, 0xdcdcdc),
                     (0.8, 0xf6a385), (1.0, 0xb40426)],
    "blackbody" => [(0.0, 0x000000), (0.2, 0x780000), (0.5, 0xe63200),
                    (0.8, 0xffff00), (1.0, 0xffffff)],
    "grayscale" => [(0.0, 0x000000), (0.2, 0x404040), (0.5, 0x7f7f80),
                    (0.8, 0xbfbfbf), (1.0, 0xffffff)],
)

function hex_color(hex::Integer)
    r = Float64((hex >> 16) & 0xff) / 255.0
    g = Float64((hex >> 8) & 0xff) / 255.0
    b = Float64(hex & 0xff) / 255.0
    Color3(r, g, b)
end

function lerp_color(a::Color3, b::Color3, t::Real)
    u = clamp(Float64(t), 0.0, 1.0)
    Color3(a.r + (b.r - a.r) * u,
           a.g + (b.g - a.g) * u,
           a.b + (b.b - a.b) * u)
end

function lut_map_color(map, alpha::Real)
    a = clamp(Float64(alpha), 0.0, 1.0)
    for i in 1:(length(map) - 1)
        lo_t, lo_hex = map[i]
        hi_t, hi_hex = map[i + 1]
        if a <= hi_t || i == length(map) - 1
            return lerp_color(hex_color(lo_hex), hex_color(hi_hex),
                              (a - lo_t) / max(hi_t - lo_t, eps(Float64)))
        end
    end
    return hex_color(last(map)[2])
end

function lut_color(map_name::String, value::Real; min_value::Float64=0.0,
                   max_value::Float64=2000.0, count::Int=32)
    map = get(LUT_MAPS, map_name, LUT_MAPS["rainbow"])
    span = max(max_value - min_value, eps(Float64))
    alpha = clamp((Float64(value) - min_value) / span, 0.0, 1.0)
    n = max(count, 1)
    return lut_map_color(map, round(Int, alpha * n) / n)
end

surface_z(x, y) = 0.38sin(2.1x) * cos(2.6y) + 0.16cos(3.4hypot(x, y))

function surface_normal(x, y)
    h = 1e-3
    dzdx = (surface_z(x + h, y) - surface_z(x - h, y)) / (2h)
    dzdy = (surface_z(x, y + h) - surface_z(x, y - h)) / (2h)
    normalize(Vec3(-dzdx, -dzdy, 1.0))
end

function pressure_value(x, y, z)
    raw = 1020.0 + 520.0sin(1.15x + 0.35) + 360.0cos(1.7y - 0.2) + 230.0z
    return clamp(raw, 0.0, 2000.0)
end

function pressure_surface_geometry(; rows::Int=34, cols::Int=50, color_map::String="rainbow")
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    pressures = Float64[]
    colors = Float64[]

    for j in 0:rows, i in 0:cols
        u = i / cols
        v = j / rows
        x = 5.4 * (u - 0.5)
        y = 3.4 * (v - 0.5)
        z = surface_z(x, y)
        n = surface_normal(x, y)
        pressure = pressure_value(x, y, z)
        color = lut_color(color_map, pressure)
        append!(positions, (x, y, z))
        append!(normals, (n.x, n.y, n.z))
        append!(uvs, (u, v))
        push!(pressures, pressure)
        append!(colors, (color.r, color.g, color.b))
    end

    stride = cols + 1
    for j in 0:(rows - 1), i in 0:(cols - 1)
        a = j * stride + i + 1
        b = a + 1
        c = a + stride
        d = c + 1
        append!(indices, (a, c, b, b, c, d))
    end

    geo = BufferGeometry(positions, normals, uvs, indices, (rows + 1) * (cols + 1),
                         length(indices) ÷ 3)
    set_attribute!(geo, :pressure, pressures, 1)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function lut_legend_texture(color_map::String; height::Int=128, width::Int=14)
    data = ones(Float64, height, width, 4)
    for y in 1:height
        value = 2000.0 * (1.0 - (y - 1) / max(height - 1, 1))
        color = lut_color(color_map, value)
        for x in 1:width
            data[y, x, 1] = color.r
            data[y, x, 2] = color.g
            data[y, x, 3] = color.b
        end
    end
    Texture(data; filter=:linear, colorspace=:srgb)
end

function build_case()
    scene = Scene(background=Color3(1.0, 1.0, 1.0))
    add!(scene, AmbientLight(color=Color3(0.42, 0.44, 0.48), intensity=0.55))
    add!(scene, PointLight(color=Color3(1.0, 1.0, 1.0), intensity=14.0,
                           distance=18.0, position=Vec3(0.0, 1.6, 8.0)))

    mesh = Mesh(pressure_surface_geometry(),
                MeshLambertMaterial(color=Color3(0.96, 0.96, 0.96),
                                    side=:double,
                                    vertex_colors=true);
                name="lookuptable_pressure_surface", cast_shadow=true,
                receive_shadow=true)
    mesh.rotation = Euler(-0.24, 0.0, 0.0)
    add!(scene, mesh)

    add!(scene, GridHelper(7.0, 14; color=Color3(0.78, 0.80, 0.84)))

    legend = Sprite(SpriteMaterial(color=Color3(1.0, 1.0, 1.0),
                                   map=lut_legend_texture("rainbow"),
                                   size_attenuation=false);
                    name="lookuptable_rainbow_legend")
    legend.position = Vec3(2.9, 0.0, 0.2)
    legend.scale = Vec3(0.36, 2.4, 1.0)
    add!(scene, legend)

    WebGLExportCase("geometry-colors-lookuptable", "Geometry Colors Lookuptable",
                    "A generated pressure attribute is mapped through a rainbow LUT into vertex colors.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=8.1, height=2.0,
                    fov=pi / 5.0, tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_colors_lookuptable.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_COLORS_LOOKUPTABLE_OK $html")
end

main()
