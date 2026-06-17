# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_loader_obj

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function write_obj_assets!(dir::String)
    mtl_path = joinpath(dir, "diff3d_loader_obj.mtl")
    obj_path = joinpath(dir, "diff3d_loader_obj.obj")
    write(mtl_path, """
newmtl body
Kd 0.20 0.48 0.82
Ks 0.55 0.62 0.70
Ns 72

newmtl nose
Kd 0.96 0.66 0.18
Ks 0.70 0.62 0.42
Ns 96

newmtl fins
Kd 0.70 0.18 0.22
Ks 0.35 0.20 0.20
Ns 42
""")
    write(obj_path, """
mtllib diff3d_loader_obj.mtl
v -0.75 -0.65  0.75
v  0.75 -0.65  0.75
v  0.75  0.65  0.75
v -0.75  0.65  0.75
v -0.75 -0.65 -0.75
v  0.75 -0.65 -0.75
v  0.75  0.65 -0.75
v -0.75  0.65 -0.75
v  0.00  1.35  0.00
v -1.26 -0.20  0.30
v -0.75 -0.05  0.30
v -0.75 -0.38 -0.30
v -1.26 -0.55 -0.30
v  1.26 -0.20  0.30
v  0.75 -0.05  0.30
v  0.75 -0.38 -0.30
v  1.26 -0.55 -0.30
usemtl body
f 1 2 3 4
f 2 6 7 3
f 6 5 8 7
f 5 1 4 8
f 5 6 2 1
usemtl nose
f 4 3 9
f 3 7 9
f 7 8 9
f 8 4 9
usemtl fins
f 10 11 12 13
f 14 17 16 15
""")
    return obj_path
end

function subgeometry(geo::BufferGeometry, faces::AbstractVector{Int})
    positions = Float64[]
    normals = Float64[]
    indices = Int[]
    out_vi = 0
    for fi in faces
        for vi in get_face(geo, fi)
            p = get_vertex(geo, vi)
            n = get_normal(geo, vi)
            append!(positions, (p.x, p.y, p.z))
            append!(normals, (n.x, n.y, n.z))
            out_vi += 1
            push!(indices, out_vi)
        end
    end
    return BufferGeometry(positions, normals, Float64[], indices, out_vi, length(faces))
end

function loaded_obj_meshes()
    mktempdir() do dir
        obj_path = write_obj_assets!(dir)
        geo, face_materials, materials = load_obj_groups(obj_path)
        meshes = Mesh[]
        for name in ("body", "nose", "fins")
            faces = findall(==(name), face_materials)
            isempty(faces) && continue
            mat = get(materials, name,
                      MeshPhongMaterial(color=Color3(0.8, 0.8, 0.8),
                                        specular=Color3(0.3, 0.3, 0.3),
                                        shininess=40.0))
            push!(meshes, Mesh(subgeometry(geo, faces), mat;
                               name="loaded_obj_$name",
                               cast_shadow=true,
                               receive_shadow=true))
        end
        return meshes
    end
end

function build_case()
    scene = Scene(background=Color3(0.016, 0.020, 0.028),
                  fog=FogExp2(color=Color3(0.016, 0.020, 0.028), density=0.025))
    add!(scene, AmbientLight(color=Color3(0.34, 0.36, 0.44), intensity=0.55))
    add!(scene, HemisphereLight(color=Color3(0.55, 0.68, 0.92),
                                ground_color=Color3(0.16, 0.14, 0.12),
                                intensity=0.48))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.45,
                                 position=Vec3(-3.4, 5.0, 3.2),
                                 cast_shadow=true))
    add!(scene, PointLight(color=Color3(0.35, 0.74, 1.0), intensity=6.0,
                           distance=7.0, position=Vec3(2.4, 2.0, -2.4)))

    floor = Mesh(PlaneGeometry(width=6.5, height=6.5, width_segments=4, height_segments=4),
                 MeshStandardMaterial(color=Color3(0.22, 0.24, 0.28),
                                      roughness=0.84);
                 name="obj_loader_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -0.72, 0.0)
    add!(scene, floor)
    add!(scene, GridHelper(6.5, 13; color=Color3(0.11, 0.14, 0.19)))

    group = Group(name="loaded_obj_group")
    group.rotation = Euler(-0.16, 0.0, 0.0)
    add!(scene, group)
    for mesh in loaded_obj_meshes()
        add!(group, mesh)
    end

    clip = AnimationClip("obj_loader_turntable", AbstractKeyframeTrack[
        KeyframeTrack(group, :rotation, [0.0, 3.0, 6.0],
                      [Vec3(-0.16, 0.0, 0.0),
                       Vec3(0.08, pi, 0.0),
                       Vec3(-0.16, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("loader-obj", "OBJ/MTL Loader",
                    "Temporary OBJ and MTL assets loaded through Diff3D.jl and exported to WebGL.",
                    scene; target=Vec3(0.0, 0.15, 0.0), radius=5.8, height=2.0,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_obj.html"), [build_case()])
    println("WEBGL_LOADER_OBJ_OK $html")
end

main()
