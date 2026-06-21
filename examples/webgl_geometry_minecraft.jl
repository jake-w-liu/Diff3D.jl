# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_minecraft

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function minecraft_height(width::Int, depth::Int)
    width >= 4 && depth >= 4 || throw(ArgumentError("minecraft terrain dimensions must be at least 4"))
    data = zeros(Int, depth, width)
    for z in 1:depth, x in 1:width
        u = (x - 1) / (width - 1)
        v = (z - 1) / (depth - 1)
        ridge = sin(7.0 * u + 2.0 * cos(4.0 * v))
        valley = cos(8.0 * v - 1.6 * sin(5.0 * u))
        blocks = round(Int, 3.6 + 1.8 * ridge + 1.4 * valley + 1.8 * u)
        data[z, x] = clamp(blocks, 1, 8)
    end
    return data
end

function minecraft_atlas_texture(; tile::Int=32)
    tile >= 8 || throw(ArgumentError("minecraft atlas tile size must be at least 8"))
    data = ones(Float64, tile, 2 * tile, 4)
    data[:, :, 4] .= 1.0
    for y in 1:tile, x in 1:(2 * tile)
        local_x = (x - 1) % tile + 1
        local_y = y
        if x <= tile
            checker = (fld(local_x - 1, 4) + fld(local_y - 1, 4)) % 2 == 0
            data[y, x, 1] = checker ? 0.26 : 0.18
            data[y, x, 2] = checker ? 0.62 : 0.48
            data[y, x, 3] = checker ? 0.18 : 0.12
        else
            band = local_y <= tile ÷ 5
            speckle = mod(13 * local_x + 17 * local_y, 9) / 90
            data[y, x, 1] = band ? 0.24 : 0.42 + speckle
            data[y, x, 2] = band ? 0.55 : 0.26 + speckle
            data[y, x, 3] = band ? 0.16 : 0.12 + speckle
        end
    end
    return Texture(data; filter=:nearest, min_filter=:nearest,
                   wrap_s=:clamp, wrap_t=:clamp, colorspace=:srgb)
end

function height_at(data::Matrix{Int}, x::Int, z::Int)
    depth, width = size(data)
    1 <= x <= width && 1 <= z <= depth || return 0
    return data[z, x]
end

function add_face!(positions::Vector{Float64}, normals::Vector{Float64},
                   uvs::Vector{Float64}, indices::Vector{Int},
                   corners::NTuple{4,Vec3{Float64}}, normal::Vec3{Float64},
                   tile::Symbol)
    uv = tile === :top ?
         ((0.0, 1.0), (0.5, 1.0), (0.5, 0.0), (0.0, 0.0)) :
         ((0.5, 1.0), (1.0, 1.0), (1.0, 0.0), (0.5, 0.0))
    start = length(positions) ÷ 3
    for (i, p) in enumerate(corners)
        push!(positions, p.x, p.y, p.z)
        push!(normals, normal.x, normal.y, normal.z)
        push!(uvs, uv[i]...)
    end
    push!(indices, start + 1, start + 2, start + 3, start + 1, start + 3, start + 4)
end

function minecraft_geometry(data::Matrix{Int}; block::Float64=0.16)
    depth, width = size(data)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    x0 = -width * block / 2
    z0 = -depth * block / 2
    for z in 1:depth, x in 1:width
        h = data[z, x]
        left = x0 + (x - 1) * block
        right = left + block
        back = z0 + (z - 1) * block
        front = back + block
        top = h * block
        add_face!(positions, normals, uvs, indices,
                  (Vec3(left, top, back), Vec3(right, top, back),
                   Vec3(right, top, front), Vec3(left, top, front)),
                  Vec3(0.0, 1.0, 0.0), :top)

        neighbors = (
            (:px, height_at(data, x + 1, z), Vec3(1.0, 0.0, 0.0)),
            (:nx, height_at(data, x - 1, z), Vec3(-1.0, 0.0, 0.0)),
            (:pz, height_at(data, x, z + 1), Vec3(0.0, 0.0, 1.0)),
            (:nz, height_at(data, x, z - 1), Vec3(0.0, 0.0, -1.0)),
        )
        for (side, nh, normal) in neighbors
            nh < h || continue
            low = nh * block
            if side === :px
                corners = (Vec3(right, low, front), Vec3(right, low, back),
                           Vec3(right, top, back), Vec3(right, top, front))
            elseif side === :nx
                corners = (Vec3(left, low, back), Vec3(left, low, front),
                           Vec3(left, top, front), Vec3(left, top, back))
            elseif side === :pz
                corners = (Vec3(left, low, front), Vec3(right, low, front),
                           Vec3(right, top, front), Vec3(left, top, front))
            else
                corners = (Vec3(right, low, back), Vec3(left, low, back),
                           Vec3(left, top, back), Vec3(right, top, back))
            end
            add_face!(positions, normals, uvs, indices, corners, normal, :side)
        end
    end
    return BufferGeometry(positions, normals, uvs, indices,
                          length(positions) ÷ 3, length(indices) ÷ 3)
end

function build_case()
    world_width = 40
    world_depth = 40
    data = minecraft_height(world_width, world_depth)
    scene = Scene(background=Color3(0.749, 0.820, 0.898))
    add!(scene, AmbientLight(color=Color3(0.93, 0.93, 0.93), intensity=1.55))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.8,
                                 position=Vec3(3.0, 4.2, 2.0)))

    mesh = Mesh(minecraft_geometry(data),
                MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                    map=minecraft_atlas_texture(),
                                    side=:double);
                name="minecraft_voxel_terrain")
    add!(scene, mesh)

    camera = PerspectiveCamera(fov=pi / 3, aspect=16 / 9, near=0.05, far=60.0)
    camera.position = Vec3(-3.4, data[world_depth ÷ 2, world_width ÷ 2] * 0.16 + 2.4, -4.4)
    camera.target = Vec3(0.15, 0.95, 0.10)

    WebGLExportCase("geometry-minecraft", "Geometry Minecraft",
                    "Deterministic voxel terrain with generated atlas texture and Lambert lighting.",
                    scene; camera=camera,
                    target=Vec3(0.0, 0.75, 0.0), radius=7.2, height=2.8,
                    fov=pi / 3,
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_minecraft.html"), [build_case()])
    println("WEBGL_GEOMETRY_MINECRAFT_OK $html")
end

main()
