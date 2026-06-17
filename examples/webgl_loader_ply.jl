# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_loader_ply

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function write_ascii_ply!(path::String)
    write(path, """
ply
format ascii 1.0
comment Diff3D.jl deterministic colored pyramid
element vertex 5
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face 6
property list uchar int vertex_indices
end_header
-0.85 -0.65 -0.55 220 80 70
 0.85 -0.65 -0.55 250 190 70
 0.85 -0.65  0.55 80 200 110
-0.85 -0.65  0.55 80 150 245
 0.00  0.88  0.00 230 235 245
3 0 1 4
3 1 2 4
3 2 3 4
3 3 0 4
3 0 2 1
3 0 3 2
""")
    return path
end

function write_binary_ply!(path::String)
    header = """
ply
format binary_little_endian 1.0
comment Diff3D.jl deterministic colored wing
element vertex 6
property float x
property float y
property float z
property float nx
property float ny
property float nz
property uchar red
property uchar green
property uchar blue
element face 4
property list uchar int vertex_indices
end_header
"""
    vertices = [
        (-1.10, 0.00, -0.42, 0.0, 1.0, 0.0, 70, 130, 235),
        (-0.38, 0.16, -0.55, 0.0, 1.0, 0.0, 90, 190, 250),
        (0.36, 0.10, -0.42, 0.0, 1.0, 0.0, 110, 230, 190),
        (1.10, -0.03, -0.52, 0.0, 1.0, 0.0, 245, 190, 70),
        (-0.42, 0.06, 0.58, 0.0, 1.0, 0.0, 210, 90, 160),
        (0.45, -0.02, 0.56, 0.0, 1.0, 0.0, 245, 120, 90),
    ]
    faces = [(0, 1, 4), (1, 2, 4), (2, 5, 4), (2, 3, 5)]
    open(path, "w") do io
        write(io, codeunits(header))
        for v in vertices
            for k in 1:6
                write(io, Float32(v[k]))
            end
            write(io, UInt8(v[7]))
            write(io, UInt8(v[8]))
            write(io, UInt8(v[9]))
        end
        for face in faces
            write(io, UInt8(3))
            for idx in face
                write(io, Int32(idx))
            end
        end
    end
    return path
end

function loaded_ply_meshes()
    mktempdir() do dir
        ascii_path = write_ascii_ply!(joinpath(dir, "diff3d_loader_ascii.ply"))
        binary_path = write_binary_ply!(joinpath(dir, "diff3d_loader_binary.ply"))
        ascii_geo = load_ply(ascii_path)
        binary_geo = load_ply(binary_path)

        colored_mat = MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                           roughness=0.58,
                                           metalness=0.05,
                                           vertex_colors=true,
                                           side=:double)
        ascii_mesh = Mesh(ascii_geo, colored_mat;
                          name="loaded_ascii_ply_colors",
                          cast_shadow=true,
                          receive_shadow=true)
        ascii_mesh.position = Vec3(-1.15, 0.2, 0.0)
        ascii_mesh.rotation = Euler(0.0, 0.25, 0.0)

        binary_mesh = Mesh(binary_geo, colored_mat;
                           name="loaded_binary_ply_colors",
                           cast_shadow=true,
                           receive_shadow=true)
        binary_mesh.position = Vec3(1.15, 0.02, 0.0)
        binary_mesh.rotation = Euler(-0.1, -0.25, 0.0)
        return ascii_mesh, binary_mesh
    end
end

function build_case()
    scene = Scene(background=Color3(0.014, 0.018, 0.026),
                  fog=Fog(color=Color3(0.014, 0.018, 0.026), near=7.0, far=15.0))
    add!(scene, AmbientLight(color=Color3(0.34, 0.36, 0.44), intensity=0.55))
    add!(scene, HemisphereLight(color=Color3(0.58, 0.70, 0.92),
                                ground_color=Color3(0.16, 0.14, 0.12),
                                intensity=0.48))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.35,
                                 position=Vec3(-3.3, 5.2, 3.0),
                                 cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.32, 0.70, 1.0), intensity=6.2,
                           distance=7.2, position=Vec3(2.6, 2.1, -2.4)))

    floor = Mesh(PlaneGeometry(width=7.0, height=6.5, width_segments=4, height_segments=4),
                 MeshStandardMaterial(color=Color3(0.22, 0.24, 0.28),
                                      roughness=0.86);
                 name="ply_loader_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -0.72, 0.0)
    add!(scene, floor)
    add!(scene, GridHelper(7.0, 14; color=Color3(0.11, 0.14, 0.19)))

    group = Group(name="loaded_ply_group")
    add!(scene, group)
    ascii_mesh, binary_mesh = loaded_ply_meshes()
    add!(group, ascii_mesh)
    add!(group, binary_mesh)

    clip = AnimationClip("ply_loader_turntable", AbstractKeyframeTrack[
        KeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                      [Vec3(0.0, 0.0, 0.0),
                       Vec3(0.08, pi, 0.0),
                       Vec3(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("loader-ply", "PLY Loader",
                    "ASCII and binary PLY assets loaded through Diff3D.jl load_ply with vertex colors.",
                    scene; target=Vec3(0.0, 0.05, 0.0), radius=6.2, height=2.1,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_ply.html"), [build_case()])
    println("WEBGL_LOADER_PLY_OK $html")
end

main()
