# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_terrain

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function terrain_height(width::Int, depth::Int)
    width >= 4 && depth >= 4 || throw(ArgumentError("terrain dimensions must be at least 4"))
    data = zeros(Float64, depth, width)
    for z in 1:depth, x in 1:width
        u = (x - 1) / (width - 1)
        v = (z - 1) / (depth - 1)
        ridge = 0.5 + 0.5 * sin(7.2 * u + 2.6 * sin(4.0 * v))
        basin = 0.5 + 0.5 * cos(8.5 * v - 1.8 * cos(3.7 * u))
        detail = 0.5 + 0.5 * sin(26.0 * u + 17.0 * v) * cos(19.0 * v - 9.0 * u)
        slope = 0.52 * u + 0.30 * v
        data[z, x] = clamp(18.0 + 96.0 * ridge + 54.0 * basin +
                           22.0 * detail + 38.0 * slope,
                           0.0, 255.0)
    end
    return data
end

function terrain_value(data::Matrix{Float64}, x::Int, z::Int)
    h, w = size(data)
    return data[clamp(z, 1, h), clamp(x, 1, w)]
end

function terrain_texture(data::Matrix{Float64}; scale::Int=4)
    scale >= 1 || throw(ArgumentError("texture scale must be positive"))
    depth, width = size(data)
    tex = ones(Float64, depth * scale, width * scale, 4)
    sun = normalize(Vec3(1.0, 1.0, 1.0))
    for ty in 1:size(tex, 1), tx in 1:size(tex, 2)
        x = cld(tx, scale)
        z = cld(ty, scale)
        dx = terrain_value(data, x - 2, z) - terrain_value(data, x + 2, z)
        dz = terrain_value(data, x, z - 2) - terrain_value(data, x, z + 2)
        normal = normalize(Vec3(dx, 24.0, dz))
        shade = clamp(dot(normal, sun), 0.0, 1.0)
        height = data[z, x]
        grain = mod(17 * tx + 29 * ty, 7) / 255
        tex[ty, tx, 1] = clamp(((96 + shade * 128) * (0.50 + height * 0.007)) / 255 + grain,
                               0.0, 1.0)
        tex[ty, tx, 2] = clamp(((32 + shade * 96) * (0.50 + height * 0.007)) / 255 + grain,
                               0.0, 1.0)
        tex[ty, tx, 3] = clamp((shade * 96 * (0.50 + height * 0.007)) / 255 + grain,
                               0.0, 1.0)
        tex[ty, tx, 4] = 1.0
    end
    return CanvasTexture(tex; filter=:linear, min_filter=:linear_mipmap_linear,
                         wrap_s=:clamp, wrap_t=:clamp, colorspace=:srgb)
end

function terrain_geometry(data::Matrix{Float64}; width::Float64=7.5,
                          depth_size::Float64=7.5, height_scale::Float64=0.010)
    depth, columns = size(data)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    for z in 1:depth, x in 1:columns
        u = (x - 1) / (columns - 1)
        v = (z - 1) / (depth - 1)
        px = (u - 0.5) * width
        py = data[z, x] * height_scale
        pz = (v - 0.5) * depth_size
        dx = terrain_value(data, x - 1, z) - terrain_value(data, x + 1, z)
        dz = terrain_value(data, x, z - 1) - terrain_value(data, x, z + 1)
        n = normalize(Vec3(dx * height_scale, 2.0 / max(width, depth_size), dz * height_scale))
        push!(positions, px, py, pz)
        push!(normals, n.x, n.y, n.z)
        push!(uvs, u, 1.0 - v)
    end
    for z in 0:(depth - 2), x in 0:(columns - 2)
        a = z * columns + x + 1
        b = a + 1
        c = a + columns
        d = c + 1
        push!(indices, a, d, b, a, c, d)
    end
    return BufferGeometry(positions, normals, uvs, indices,
                          columns * depth, length(indices) ÷ 3)
end

function build_case()
    world_width = 96
    world_depth = 96
    data = terrain_height(world_width, world_depth)
    scene = Scene(background=Color3(0.937, 0.820, 0.710),
                  fog=FogExp2(color=Color3(0.937, 0.820, 0.710), density=0.18))

    terrain = Mesh(terrain_geometry(data),
                   MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                     map=terrain_texture(data), side=:double);
                   name="terrain_heightfield")
    add!(scene, terrain)

    camera = PerspectiveCamera(fov=pi / 3, aspect=16 / 9, near=0.05, far=60.0)
    camera.position = Vec3(0.20, 6.2, -6.0)
    camera.target = Vec3(-0.65, 3.2, -5.8)

    WebGLExportCase("geometry-terrain", "Geometry Terrain",
                    "Generated heightfield terrain with baked CanvasTexture lighting and exponential fog.",
                    scene; camera=camera,
                    target=Vec3(0.0, 0.9, 0.0), radius=8.6, height=4.0,
                    fov=pi / 3,
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_terrain.html"), [build_case()])
    println("WEBGL_GEOMETRY_TERRAIN_OK $html")
end

main()
