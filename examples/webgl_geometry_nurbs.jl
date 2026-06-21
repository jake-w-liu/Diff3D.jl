# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_nurbs

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function uv_grid_texture(; n::Int=64)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        grid = (x - 1) % 8 == 0 || (y - 1) % 8 == 0
        check = (fld(x - 1, 8) + fld(y - 1, 8)) % 2 == 0
        data[y, x, 1] = grid ? 0.05 : (check ? 0.95 : 0.18)
        data[y, x, 2] = grid ? 0.05 : (check ? 0.72 : 0.34)
        data[y, x, 3] = grid ? 0.05 : (check ? 0.24 : 0.88)
        data[y, x, 4] = 1.0
    end
    return Texture(data; repeat=Vec2(2.0, 2.0), filter=:nearest,
                   min_filter=:nearest, colorspace=:srgb)
end

function nurbs_example_knots(degree::Int, count::Int)
    knots = Float64[]
    for _ in 0:degree
        push!(knots, 0.0)
    end
    for i in 0:(count - 1)
        push!(knots, clamp((i + 1) / (count - degree), 0.0, 1.0))
    end
    return knots
end

function example_curve()
    degree = 3
    count = 20
    control_points = Vec4{Float64}[]
    for i in 0:(count - 1)
        t = i / (count - 1)
        x = -2.0 + 4.0 * t
        y = 1.15 * sin(2.4pi * t) + 0.55 * cos(5.2pi * t)
        z = 0.95 * cos(1.8pi * t)
        weight = 1.0 + 0.8 * (0.5 + 0.5 * sin(4pi * t))
        push!(control_points, Vec4(x, y, z, weight))
    end
    return NURBSCurve(degree, nurbs_example_knots(degree, count), control_points)
end

function control_points_geometry(control_points::Vector{Vec4{Float64}})
    positions = Float64[]
    for cp in control_points
        append!(positions, (cp.x, cp.y, cp.z))
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[],
                          length(control_points), 0)
end

function scaled_point(x, y, z, w=1.0)
    Vec4(x / 120.0, y / 120.0, z / 120.0, w)
end

function example_surface()
    points = [
        [scaled_point(-200, -200, 100), scaled_point(-200, -100, -200),
         scaled_point(-200, 100, 250), scaled_point(-200, 200, -100)],
        [scaled_point(0, -200, 0), scaled_point(0, -100, -100, 5),
         scaled_point(0, 100, 150, 5), scaled_point(0, 200, 0)],
        [scaled_point(200, -200, -100), scaled_point(200, -100, 200),
         scaled_point(200, 100, -250), scaled_point(200, 200, 100)],
    ]
    return NURBSSurface(2, 3, [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
                        [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0],
                        points)
end

function volume_point(x, y, z, w=1.0)
    Vec4(x / 160.0, y / 160.0, z / 160.0, w)
end

function example_volume()
    points = [
        [
            [volume_point(-200, -200, -200), volume_point(-200, -200, 200)],
            [volume_point(-200, -100, -200), volume_point(-200, -100, 200)],
            [volume_point(-200, 100, -200), volume_point(-200, 100, 200)],
            [volume_point(-200, 200, -200), volume_point(-200, 200, 200)],
        ],
        [
            [volume_point(0, -200, -200), volume_point(0, -200, 200)],
            [volume_point(0, -100, -200), volume_point(0, -100, 200)],
            [volume_point(0, 100, -200), volume_point(0, 100, 200)],
            [volume_point(0, 200, -200), volume_point(0, 200, 200)],
        ],
        [
            [volume_point(200, -200, -200), volume_point(200, -200, 200)],
            [volume_point(200, -100, 0), volume_point(200, -100, 100)],
            [volume_point(200, 100, 0), volume_point(200, 100, 100)],
            [volume_point(200, 200, 0), volume_point(200, 200, 100)],
        ],
    ]
    return NURBSVolume(2, 3, 1,
                       [0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
                       [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0],
                       [0.0, 0.0, 1.0, 1.0],
                       points)
end

function add_curve!(group::Group)
    curve = example_curve()
    line = LineObject(NURBSCurveGeometry(curve; segments=200),
                      LineBasicMaterial(color=Color3(0.08, 0.08, 0.08),
                                        linewidth=2.0);
                      name="nurbs_curve")
    line.position = Vec3(0.0, -2.05, 0.0)
    add!(group, line)

    control = LineObject(control_points_geometry(curve.control_points),
                         LineBasicMaterial(color=Color3(0.20, 0.20, 0.20),
                                           opacity=0.32);
                         name="nurbs_curve_control_polygon")
    control.position = line.position
    add!(group, control)
    return curve
end

function add_surface!(group::Group, texture)
    mesh = Mesh(NURBSSurfaceGeometry(example_surface(); slices=24, stacks=24),
                MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                    map=texture, side=:double);
                name="nurbs_surface")
    mesh.position = Vec3(-2.85, 0.55, 0.0)
    add!(group, mesh)
end

function add_volume_slices!(group::Group, texture)
    volume = example_volume()
    material = MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0),
                                   map=texture, side=:double)
    slices = [
        ("front", (u, v) -> nurbs_point(volume, u, v, 0.0)),
        ("middle", (u, v) -> nurbs_point(volume, u, v, 0.5)),
        ("back", (u, v) -> nurbs_point(volume, u, v, 1.0)),
        ("top", (u, w) -> nurbs_point(volume, u, 1.0, w)),
        ("side", (v, w) -> nurbs_point(volume, 0.0, v, w)),
    ]
    for (name, fn) in slices
        mesh = Mesh(ParametricGeometry(fn, 18, 18), material;
                    name="nurbs_volume_$name")
        mesh.position = Vec3(2.95, 0.55, 0.0)
        mesh.scale = Vec3(0.72, 0.72, 0.72)
        add!(group, mesh)
    end
    return volume
end

function build_case()
    scene = Scene(background=Color3(0.941, 0.941, 0.941))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.85))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=2.4,
                                 position=Vec3(2.5, 3.0, 2.0)))

    group = Group(name="nurbs_group")
    group.position = Vec3(0.0, 0.35, 0.0)
    add!(scene, group)
    texture = uv_grid_texture()
    add_curve!(group)
    add_surface!(group, texture)
    add_volume_slices!(group, texture)

    clip = AnimationClip("nurbs_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=0.05, far=60.0)
    camera.position = Vec3(0.0, 4.3, 7.4)
    camera.target = Vec3(0.0, 0.25, 0.0)

    WebGLExportCase("geometry-nurbs", "Geometry NURBS",
                    "NURBS curve, surface, and volume slices generated through Diff3D.jl NURBS evaluators.",
                    scene; camera=camera,
                    target=Vec3(0.0, 0.25, 0.0), radius=8.0, height=3.4,
                    fov=50pi / 180, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_nurbs.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_NURBS_OK $html")
end

main()
