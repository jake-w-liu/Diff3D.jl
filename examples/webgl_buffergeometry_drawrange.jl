# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_drawrange

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const MAX_PARTICLE_COUNT = 180
const VISIBLE_PARTICLE_COUNT = 96
const MIN_CONNECTION_DISTANCE = 1.15
const MAX_CONNECTIONS = 5

fract(x) = x - floor(x)

function particle_points(max_count::Int)
    points = Vector{Vec3{Float64}}(undef, max_count)
    for i in 1:max_count
        x = 4.2 * (fract(i * 0.7548776662466927) - 0.5)
        y = 4.2 * (fract(i * 0.5698402909980532 + 0.17) - 0.5)
        z = 4.2 * (fract(i * 0.4385513373931324 + 0.31) - 0.5)
        points[i] = Vec3(x, y, z)
    end
    return points
end

function flat_positions(points::Vector{Vec3{Float64}})
    data = Float64[]
    sizehint!(data, 3length(points))
    for p in points
        push!(data, p.x, p.y, p.z)
    end
    return data
end

function particle_colors(points::Vector{Vec3{Float64}})
    colors = Float64[]
    sizehint!(colors, 3length(points))
    for p in points
        push!(colors,
              0.35 + 0.40 * (p.x + 2.1) / 4.2,
              0.45 + 0.35 * (p.y + 2.1) / 4.2,
              0.70 + 0.25 * (p.z + 2.1) / 4.2)
    end
    return colors
end

function drawrange_particles_geometry(points::Vector{Vec3{Float64}})
    geo = BufferGeometry(flat_positions(points), Float64[], Float64[], Int[],
                         length(points), 0)
    set_attribute!(geo, :color, particle_colors(points), 3)
    set_draw_range!(geo, 1, VISIBLE_PARTICLE_COUNT)
    return geo
end

function drawrange_lines_geometry(points::Vector{Vec3{Float64}})
    capacity_vertices = VISIBLE_PARTICLE_COUNT * MAX_CONNECTIONS
    positions = zeros(Float64, 3capacity_vertices)
    colors = zeros(Float64, 3capacity_vertices)
    connections = zeros(Int, VISIBLE_PARTICLE_COUNT)
    vertex_count = 0

    for i in 1:(VISIBLE_PARTICLE_COUNT - 1)
        connections[i] >= MAX_CONNECTIONS && continue
        pi = points[i]
        for j in (i + 1):VISIBLE_PARTICLE_COUNT
            connections[j] >= MAX_CONNECTIONS && continue
            pj = points[j]
            d = distance(pi, pj)
            d < MIN_CONNECTION_DISTANCE || continue
            vertex_count + 2 <= capacity_vertices || break

            alpha = 1.0 - d / MIN_CONNECTION_DISTANCE
            color = (0.28 + 0.42alpha, 0.55 + 0.35alpha, 0.95)
            for p in (pi, pj)
                base = 3vertex_count + 1
                positions[base] = p.x
                positions[base + 1] = p.y
                positions[base + 2] = p.z
                colors[base] = color[1]
                colors[base + 1] = color[2]
                colors[base + 2] = color[3]
                vertex_count += 1
            end
            connections[i] += 1
            connections[j] += 1
            connections[i] >= MAX_CONNECTIONS && break
        end
    end

    vertex_count > 0 || error("drawrange example generated no line connections")
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], capacity_vertices, 0)
    set_attribute!(geo, :color, colors, 3)
    set_draw_range!(geo, 1, vertex_count)
    return geo
end

function box_line_segments_geometry(size::Real)
    h = Float64(size) / 2
    positions = Float64[
        -h, -h, -h,  -h,  h, -h,
        -h,  h, -h,   h,  h, -h,
         h,  h, -h,   h, -h, -h,
         h, -h, -h,  -h, -h, -h,

        -h, -h,  h,  -h,  h,  h,
        -h,  h,  h,   h,  h,  h,
         h,  h,  h,   h, -h,  h,
         h, -h,  h,  -h, -h,  h,

        -h, -h, -h,  -h, -h,  h,
        -h,  h, -h,  -h,  h,  h,
         h,  h, -h,   h,  h,  h,
         h, -h, -h,   h, -h,  h,
    ]
    return BufferGeometry(positions, Float64[], Float64[], Int[], length(positions) ÷ 3, 0)
end

function build_case()
    points = particle_points(MAX_PARTICLE_COUNT)
    scene = Scene(background=Color3(0.025, 0.028, 0.034))
    group = Group(name="drawrange_particle_group")
    add!(scene, group)

    particles = PointsObject(drawrange_particles_geometry(points),
                             PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                                            size=6.0, size_attenuation=false);
                             name="drawrange_visible_particles")
    add!(group, particles)

    lines = LineSegments(drawrange_lines_geometry(points),
                         LineBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                           opacity=0.62, depth_write=false);
                         name="drawrange_connected_lines")
    add!(group, lines)

    bounds = LineSegments(box_line_segments_geometry(4.25),
                          LineBasicMaterial(color=Color3(0.30, 0.34, 0.42),
                                            opacity=0.55, depth_write=false);
                          name="drawrange_bounds")
    add!(group, bounds)

    clip = AnimationClip("drawrange_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 5.0, 10.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9, near=0.1, far=30.0)
    camera.position = Vec3(0.0, 0.0, 7.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-drawrange", "BufferGeometry Draw Range",
                    "Points and LineSegments restricted by BufferGeometry draw ranges.",
                    scene; camera=camera, target=camera.target, radius=7.0,
                    height=0.0, fov=45pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_drawrange.html"),
                           [build_case()])
    println("WEBGL_BUFFERGEOMETRY_DRAWRANGE_OK $html")
end

main()
