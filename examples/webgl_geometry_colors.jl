# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_geometry_colors

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function hsl_color(h::Real, s::Real, l::Real)
    h = mod(Float64(h), 1.0)
    s = clamp(Float64(s), 0.0, 1.0)
    l = clamp(Float64(l), 0.0, 1.0)
    if s == 0.0
        return Color3(l, l, l)
    end
    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q
    hue_channel(t) = begin
        t = mod(t, 1.0)
        if t < 1.0 / 6.0
            p + (q - p) * 6.0 * t
        elseif t < 0.5
            q
        elseif t < 2.0 / 3.0
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        else
            p
        end
    end
    return Color3(hue_channel(h + 1.0 / 3.0), hue_channel(h), hue_channel(h - 1.0 / 3.0))
end

function vertex_colored_icosahedron(mode::Symbol; radius::Float64=1.0)
    geo = IcosahedronGeometry(radius=radius, detail=1)
    colors = Float64[]
    for i in 1:geo.n_vertices
        y = geo.positions[3(i - 1) + 2]
        t = clamp((y / radius + 1.0) / 2.0, 0.0, 1.0)
        color = if mode === :height_hue
            hsl_color(t, 1.0, 0.52)
        elseif mode === :height_saturation
            hsl_color(0.0, t, 0.52)
        elseif mode === :warm_rgb
            Color3(1.0, 0.82 - 0.62t, 0.05)
        else
            throw(ArgumentError("unknown vertex-color mode: $mode"))
        end
        append!(colors, (color.r, color.g, color.b))
    end
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function soft_shadow_texture(; n::Int=64)
    data = ones(Float64, n, n, 4)
    c = (n + 1) / 2
    for y in 1:n, x in 1:n
        r = hypot((x - c) / c, (y - c) / c)
        shade = 1.0 - 0.54 * exp(-4.2 * r * r)
        data[y, x, 1] = shade
        data[y, x, 2] = shade
        data[y, x, 3] = shade
        data[y, x, 4] = 1.0
    end
    return Texture(data; filter=:linear, colorspace=:srgb)
end

function add_shadow!(scene::Scene, x::Float64)
    shadow = Mesh(PlaneGeometry(width=1.75, height=1.75),
                  MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                    map=soft_shadow_texture(),
                                    side=:double);
                  name="geometry_colors_shadow")
    shadow.position = Vec3(x, -1.28, 0.0)
    shadow.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, shadow)
    return shadow
end

function add_color_sphere!(parent, name::String, mode::Symbol, x::Float64; rotate_x=0.0)
    geo = vertex_colored_icosahedron(mode; radius=0.78)
    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 specular=Color3(0.0, 0.0, 0.0),
                                 shininess=0.0,
                                 vertex_colors=true,
                                 side=:double)
    mesh = Mesh(geo, material; name=name, flat_shading=true,
                cast_shadow=true, receive_shadow=true)
    mesh.position = Vec3(x, 0.0, 0.0)
    mesh.rotation = Euler(rotate_x, 0.0, 0.0)
    add!(parent, mesh)

    wire = Mesh(geo, MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                                       wireframe=true,
                                       transparent=true,
                                       opacity=0.42);
                name="$(name)_wireframe")
    add!(mesh, wire)
    return mesh
end

function build_case()
    scene = Scene(background=Color3(1.0, 1.0, 1.0))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.22))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=2.6,
                                 position=Vec3(0.0, 0.0, 3.0)))

    for x in (-1.9, 0.0, 1.9)
        add_shadow!(scene, x)
    end

    group = Group(name="geometry_colors_group")
    add!(scene, group)
    add_color_sphere!(group, "geometry_colors_height_hue", :height_hue, -1.9; rotate_x=-1.87)
    add_color_sphere!(group, "geometry_colors_height_saturation", :height_saturation, 1.9)
    add_color_sphere!(group, "geometry_colors_warm_rgb", :warm_rgb, 0.0)

    WebGLExportCase("geometry-colors", "Geometry Colors",
                    "Vertex color attributes on mesh BufferGeometry are exported and multiplied by material color.",
                    scene; target=Vec3(0.0, -0.05, 0.0), radius=5.4, height=1.0,
                    fov=pi / 5.2, tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_colors.html"), [build_case()])
    println("WEBGL_GEOMETRY_COLORS_OK $html")
end

main()
