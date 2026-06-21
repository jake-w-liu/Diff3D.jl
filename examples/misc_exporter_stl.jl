# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_exporter_stl

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const STL_BOX_FACE_COUNT = 12
const STL_BINARY_SIZE = 84 + 50 * STL_BOX_FACE_COUNT
const EXPORTED_MESH_OFFSET = Vec3(0.0, 0.5, 0.0)
const EXPORTED_STL_PATH = joinpath(OUT, "misc_exporter_stl_box.stl")

function exported_box_geometry()
    source = transform_geometry(BoxGeometry(),
                                mat4_translation(EXPORTED_MESH_OFFSET.x,
                                                 EXPORTED_MESH_OFFSET.y,
                                                 EXPORTED_MESH_OFFSET.z))
    save_stl_binary(EXPORTED_STL_PATH, source)
    filesize(EXPORTED_STL_PATH) == STL_BINARY_SIZE ||
        error("unexpected binary STL size for exported box")

    loaded = load_stl(EXPORTED_STL_PATH)
    loaded.n_faces == STL_BOX_FACE_COUNT ||
        error("unexpected loaded STL face count")
    compute_vertex_normals!(loaded)
    return loaded
end

function build_exporter_stl_case()
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
                  MeshPhongMaterial(color=Color3(0.733, 0.733, 0.733),
                                    depth_write=false);
                  name="stl_exporter_ground", receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, ground)
    add!(scene, GridHelper(40.0, 20; color=Color3(0.0, 0.0, 0.0)))

    mesh = Mesh(exported_box_geometry(),
                MeshPhongMaterial(color=Color3(0.0, 1.0, 0.0));
                name="binary_stl_export_roundtrip_box", cast_shadow=true)
    add!(scene, mesh)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9,
                               near=0.1, far=100.0)
    camera.position = Vec3(4.0, 2.0, 4.0)
    camera.target = Vec3(0.0, 0.5, 0.0)
    orbit_update!(OrbitControls(camera, camera.target))

    WebGLExportCase("misc-exporter-stl", "STL Exporter",
                    "Binary STL box exported with save_stl_binary, reloaded with load_stl, then rendered.",
                    scene; camera=camera, target=camera.target,
                    radius=5.75, height=1.0, fov=45pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_exporter_stl.html"),
                           [build_exporter_stl_case()];
                           title="Diff3D.jl misc_exporter_stl")
    println("MISC_EXPORTER_STL_OK $html $EXPORTED_STL_PATH")
end

main()
