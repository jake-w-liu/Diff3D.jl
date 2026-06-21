# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_exporter_obj

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const OBJ_PATH = joinpath(OUT, "misc_exporter_obj_scene.obj")
const OBJ_CYLINDER_RADIAL_SEGMENTS = 30
const OBJ_POINT_COUNT = 4
const OBJ_MESH_FACE_COUNT = 1 + 12 + 120

function triangle_geometry()
    geo = BufferGeometry(Float64[
        -50.0, -50.0, 0.0,
         50.0, -50.0, 0.0,
         50.0,  50.0, 0.0,
    ], Float64[], Float64[], Int[1, 2, 3], 3, 1)
    compute_vertex_normals!(geo)
    return geo
end

function point_cloud_geometry()
    positions = Float64[
          0.0,   0.0, 0.0,
        100.0,   0.0, 0.0,
        100.0, 100.0, 0.0,
          0.0, 100.0, 0.0,
    ]
    colors = Float64[
        0.5, 0.0, 0.0,
        0.5, 0.0, 0.0,
        0.0, 0.5, 0.0,
        0.0, 0.5, 0.0,
    ]
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], OBJ_POINT_COUNT, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function transformed_mesh_geometries()
    rotation = mat4_rotation_y(pi / 4)
    cylinder = CylinderGeometry(radius_top=50.0, radius_bottom=50.0,
                                height=100.0,
                                radial_segments=OBJ_CYLINDER_RADIAL_SEGMENTS,
                                height_segments=1)
    cylinder.n_faces == 120 ||
        error("unexpected OBJ cylinder face count")

    return [
        ("triangle", transform_geometry(triangle_geometry(),
                                        mat4_translation(-200.0, 0.0, 0.0) * rotation)),
        ("cube", transform_geometry(BoxGeometry(width=100.0, height=100.0, depth=100.0),
                                    rotation)),
        ("cylinder", transform_geometry(cylinder,
                                        mat4_translation(200.0, 0.0, 0.0) * rotation)),
    ]
end

function transformed_point_cloud_geometry()
    transform_geometry(point_cloud_geometry(), mat4_translation(-50.0, -170.0, 0.0))
end

function obj_value(x::Real)
    value = Float64(x)
    return iszero(value) ? "0.0" : string(value)
end

function write_obj_mesh!(io::IO, name::String, geo::BufferGeometry,
                         vertex_offset::Int, normal_offset::Int)
    length(geo.normals) == 3geo.n_vertices ||
        error("OBJ mesh $name is missing per-vertex normals")

    println(io, "o $name")
    println(io, "usemtl green_lambert")

    for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
        println(io, "v $(obj_value(p.x)) $(obj_value(p.y)) $(obj_value(p.z))")
    end

    for vi in 1:geo.n_vertices
        n = get_normal(geo, vi)
        println(io, "vn $(obj_value(n.x)) $(obj_value(n.y)) $(obj_value(n.z))")
    end

    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        f1 = "$(vertex_offset + i1)//$(normal_offset + i1)"
        f2 = "$(vertex_offset + i2)//$(normal_offset + i2)"
        f3 = "$(vertex_offset + i3)//$(normal_offset + i3)"
        println(io, "f $f1 $f2 $f3")
    end

    return vertex_offset + geo.n_vertices, normal_offset + geo.n_vertices
end

function write_obj_points!(io::IO, name::String, geo::BufferGeometry,
                           vertex_offset::Int)
    haskey(geo.attributes, :color) ||
        error("OBJ point cloud $name is missing vertex colors")
    colors = geo.attributes[:color]
    colors.item_size == 3 ||
        error("OBJ point cloud $name has non-RGB colors")

    println(io, "o $name")

    for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
        base = 3 * (vi - 1)
        r = colors.data[base + 1]
        g = colors.data[base + 2]
        b = colors.data[base + 3]
        println(io, "v $(obj_value(p.x)) $(obj_value(p.y)) $(obj_value(p.z)) " *
                    "$(obj_value(r)) $(obj_value(g)) $(obj_value(b))")
    end

    point_indices = join((string(vertex_offset + vi) for vi in 1:geo.n_vertices), " ")
    println(io, "p $point_indices")
    return vertex_offset + geo.n_vertices
end

function write_obj_scene!(path::String)
    mesh_geometries = transformed_mesh_geometries()
    point_geo = transformed_point_cloud_geometry()

    open(path, "w") do io
        println(io, "# Diff3D.jl misc_exporter_obj geometry-only OBJ")

        vertex_offset = 0
        normal_offset = 0
        for (name, geo) in mesh_geometries
            vertex_offset, normal_offset =
                write_obj_mesh!(io, name, geo, vertex_offset, normal_offset)
        end

        write_obj_points!(io, "point cloud", point_geo, vertex_offset)
    end

    return path
end

function exported_obj_objects()
    write_obj_scene!(OBJ_PATH)
    loaded = load_obj(OBJ_PATH)
    loaded.n_faces == OBJ_MESH_FACE_COUNT ||
        error("unexpected loaded OBJ face count")

    mesh = Mesh(loaded,
                MeshLambertMaterial(color=Color3(0.0, 0.8, 0.0), side=:double);
                name="obj_export_roundtrip_mesh")
    points = PointsObject(transformed_point_cloud_geometry(),
                          PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=12.0);
                          name="obj_export_point_records")
    return mesh, points
end

function build_exporter_obj_case()
    scene = Scene(background=Color3(0.02, 0.024, 0.03))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=2.5,
                                 position=Vec3(0.0, 1.0, 1.0)))

    mesh, points = exported_obj_objects()
    add!(scene, mesh)
    add!(scene, points)

    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9,
                               near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 0.0, 400.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    orbit_update!(OrbitControls(camera, camera.target; enable_pan=false))

    WebGLExportCase("misc-exporter-obj", "OBJ Exporter",
                    "Transformed triangle, cube, cylinder, and point records exported to OBJ.",
                    scene; camera=camera, target=camera.target,
                    radius=400.0, height=0.0, fov=70pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_exporter_obj.html"),
                           [build_exporter_obj_case()];
                           title="Diff3D.jl misc_exporter_obj")
    println("MISC_EXPORTER_OBJ_OK $html $OBJ_PATH")
end

main()
