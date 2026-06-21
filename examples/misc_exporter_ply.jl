# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_exporter_ply

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const PLY_BOX_VERTEX_COUNT = 24
const PLY_BOX_FACE_COUNT = 12
const PLY_BINARY_PAYLOAD_SIZE = PLY_BOX_VERTEX_COUNT * 15 + PLY_BOX_FACE_COUNT * 13
const ASCII_PLY_PATH = joinpath(OUT, "misc_exporter_ply_box_ascii.ply")
const BINARY_PLY_PATH = joinpath(OUT, "misc_exporter_ply_box_binary_le.ply")

function colored_export_box_geometry()
    geo = BoxGeometry()
    colors = Float64[]
    sizehint!(colors, 3 * geo.n_vertices)

    for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
        append!(colors, (p.x > 0 ? 0.5 : 0.0,
                         p.y > 0 ? 0.5 : 0.0,
                         p.z > 0 ? 0.5 : 0.0))
    end

    set_attribute!(geo, :color, colors, 3)
    return geo
end

function vertex_color_u8(geo::BufferGeometry, vi::Int)
    attr = geo.attributes[:color]
    offset = 3 * (vi - 1)
    r = round(UInt8, clamp(attr.data[offset + 1], 0.0, 1.0) * 255)
    g = round(UInt8, clamp(attr.data[offset + 2], 0.0, 1.0) * 255)
    b = round(UInt8, clamp(attr.data[offset + 3], 0.0, 1.0) * 255)
    return r, g, b
end

write_le(io, value) = write(io, htol(value))

function write_ascii_ply!(path::String, geo::BufferGeometry)
    open(path, "w") do io
        println(io, "ply")
        println(io, "format ascii 1.0")
        println(io, "comment Diff3D.jl misc_exporter_ply ASCII box")
        println(io, "element vertex $(geo.n_vertices)")
        println(io, "property float x")
        println(io, "property float y")
        println(io, "property float z")
        println(io, "property uchar red")
        println(io, "property uchar green")
        println(io, "property uchar blue")
        println(io, "element face $(geo.n_faces)")
        println(io, "property list uchar int vertex_indices")
        println(io, "end_header")

        for vi in 1:geo.n_vertices
            p = get_vertex(geo, vi)
            r, g, b = vertex_color_u8(geo, vi)
            println(io, "$(p.x) $(p.y) $(p.z) $(r) $(g) $(b)")
        end

        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            println(io, "3 $(i1 - 1) $(i2 - 1) $(i3 - 1)")
        end
    end

    return path
end

function write_binary_little_endian_ply!(path::String, geo::BufferGeometry)
    header = """
ply
format binary_little_endian 1.0
comment Diff3D.jl misc_exporter_ply binary box
element vertex $(geo.n_vertices)
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face $(geo.n_faces)
property list uchar int vertex_indices
end_header
"""

    open(path, "w") do io
        write(io, codeunits(header))

        for vi in 1:geo.n_vertices
            p = get_vertex(geo, vi)
            r, g, b = vertex_color_u8(geo, vi)
            write_le(io, Float32(p.x))
            write_le(io, Float32(p.y))
            write_le(io, Float32(p.z))
            write(io, r)
            write(io, g)
            write(io, b)
        end

        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            write(io, UInt8(3))
            write_le(io, Int32(i1 - 1))
            write_le(io, Int32(i2 - 1))
            write_le(io, Int32(i3 - 1))
        end
    end

    filesize(path) > PLY_BINARY_PAYLOAD_SIZE ||
        error("binary PLY file is too small for header plus payload")
    return path
end

function exported_ply_meshes()
    source = colored_export_box_geometry()
    source.n_vertices == PLY_BOX_VERTEX_COUNT ||
        error("unexpected PLY source vertex count")
    source.n_faces == PLY_BOX_FACE_COUNT ||
        error("unexpected PLY source face count")

    write_ascii_ply!(ASCII_PLY_PATH, source)
    write_binary_little_endian_ply!(BINARY_PLY_PATH, source)

    ascii_geo = load_ply(ASCII_PLY_PATH)
    binary_geo = load_ply(BINARY_PLY_PATH)
    compute_vertex_normals!(ascii_geo)
    compute_vertex_normals!(binary_geo)

    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 specular=Color3(1.0, 1.0, 1.0),
                                 shininess=32.0,
                                 vertex_colors=true,
                                 side=:double)
    ascii_mesh = Mesh(ascii_geo, material; name="ascii_ply_export_roundtrip_box",
                      cast_shadow=true)
    ascii_mesh.position = Vec3(-0.8, 0.5, 0.0)

    binary_mesh = Mesh(binary_geo, material; name="binary_ply_export_roundtrip_box",
                       cast_shadow=true)
    binary_mesh.position = Vec3(0.8, 0.5, 0.0)
    return ascii_mesh, binary_mesh
end

function build_exporter_ply_case()
    scene = Scene(background=Color3(0.627, 0.627, 0.627),
                  fog=Fog(color=Color3(0.627, 0.627, 0.627), near=4.0, far=20.0))

    hemi = HemisphereLight(color=Color3(1.0, 1.0, 1.0),
                           ground_color=Color3(0.267, 0.267, 0.267),
                           intensity=3.0)
    hemi.position = Vec3(0.0, 20.0, 0.0)
    add!(scene, hemi)

    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                                 position=Vec3(0.0, 20.0, 10.0),
                                 cast_shadow=true))

    ground = Mesh(PlaneGeometry(width=40.0, height=40.0),
                  MeshPhongMaterial(color=Color3(0.796, 0.796, 0.796),
                                    depth_write=false);
                  name="ply_exporter_ground", receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, ground)
    add!(scene, GridHelper(40.0, 20; color=Color3(0.0, 0.0, 0.0)))

    ascii_mesh, binary_mesh = exported_ply_meshes()
    add!(scene, ascii_mesh)
    add!(scene, binary_mesh)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9,
                               near=0.1, far=100.0)
    camera.position = Vec3(4.0, 2.0, 4.0)
    camera.target = Vec3(0.0, 0.5, 0.0)
    orbit_update!(OrbitControls(camera, camera.target))

    WebGLExportCase("misc-exporter-ply", "PLY Exporter",
                    "ASCII and binary little-endian PLY boxes exported, reloaded, and rendered.",
                    scene; camera=camera, target=camera.target,
                    radius=5.75, height=1.0, fov=45pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_exporter_ply.html"),
                           [build_exporter_ply_case()];
                           title="Diff3D.jl misc_exporter_ply")
    println("MISC_EXPORTER_PLY_OK $html $ASCII_PLY_PATH $BINARY_PLY_PATH")
end

main()
