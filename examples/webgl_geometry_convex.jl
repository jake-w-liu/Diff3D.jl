# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_convex

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function smoothstep(edge0::Real, edge1::Real, x::Real)
    edge1 > edge0 || throw(ArgumentError("smoothstep edge1 must exceed edge0"))
    t = clamp((Float64(x) - Float64(edge0)) / (Float64(edge1) - Float64(edge0)), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

function disc_texture(; n::Int=48)
    n >= 2 || throw(ArgumentError("disc_texture size must be at least 2"))
    data = zeros(Float64, n, n, 4)
    center = (n + 1) / 2
    radius = 0.46 * n
    for y in 1:n, x in 1:n
        dx = (x - center) / radius
        dy = (y - center) / radius
        r = sqrt(dx^2 + dy^2)
        alpha = clamp(1.0 - smoothstep(0.72, 1.0, r), 0.0, 1.0)
        data[y, x, 1] = 1.0
        data[y, x, 2] = 1.0
        data[y, x, 3] = 1.0
        data[y, x, 4] = alpha
    end
    Texture(data; filter=:linear, min_filter=:linear_mipmap_linear,
            wrap_s=:clamp, wrap_t=:clamp, colorspace=:srgb)
end

function unique_vertices(geo::BufferGeometry)
    seen = Set{Tuple{Float64,Float64,Float64}}()
    out = Vec3{Float64}[]
    for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
        key = (round(p.x, digits=12), round(p.y, digits=12), round(p.z, digits=12))
        if !(key in seen)
            push!(seen, key)
            push!(out, p)
        end
    end
    return out
end

function points_geometry(points::Vector{<:Vec3})
    positions = Float64[]
    for p in points
        append!(positions, (p.x, p.y, p.z))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], length(points), 0)
end

function build_case()
    scene = Scene(background=Color3(0.018, 0.020, 0.026),
                  fog=Fog(color=Color3(0.018, 0.020, 0.026), near=24.0, far=58.0))
    add!(scene, AmbientLight(color=Color3(0.48, 0.48, 0.48), intensity=0.72))
    add!(scene, PointLight(color=Color3(1.0, 1.0, 1.0), intensity=4.2,
                           distance=80.0, position=Vec3(15.0, 20.0, 30.0)))
    add!(scene, AxesHelper(20.0))

    group = Group(name="convex_geometry_group")
    add!(scene, group)

    source = DodecahedronGeometry(radius=10.0)
    vertices = unique_vertices(source)
    hull = ConvexGeometry(vertices)

    points = PointsObject(points_geometry(vertices),
                          PointsMaterial(color=Color3(0.0, 0.5, 1.0),
                                         size=5.5, map=disc_texture(),
                                         alpha_test=0.35);
                          name="convex_source_points")
    add!(group, points)

    mesh = Mesh(hull,
                MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                    opacity=0.50, transparent=true,
                                    side=:double);
                name="convex_hull_mesh")
    add!(group, mesh)

    clip = AnimationClip("convex_geometry_spin", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-convex", "Geometry Convex",
                    "Dodecahedron vertices rendered as points and wrapped by Diff3D.jl ConvexGeometry.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=42.0, height=4.0,
                    fov=40pi / 180, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_convex.html"), [build_case()])
    println("WEBGL_GEOMETRY_CONVEX_OK $html")
end

main()
