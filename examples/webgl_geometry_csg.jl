# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_geometry_csg

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function csg_brush_pair()
    base = IcosahedronGeometry(radius=1.25, detail=1)
    cylinder = CylinderGeometry(radius_top=0.58, radius_bottom=0.58,
                                height=3.3, radial_segments=36,
                                height_segments=1)
    brush_matrix = mat4_rotation_z(pi / 2) *
                   mat4_rotation_y(0.42) *
                   mat4_rotation_x(-0.30) *
                   mat4_scaling(0.88, 1.0, 0.88)
    return base, transform_geometry(cylinder, brush_matrix)
end

function add_csg_result!(group::Group, geometry::BufferGeometry,
                         name::String, color::Color3, position::Vec3)
    material = MeshStandardMaterial(color=color, metalness=0.10,
                                    roughness=0.58, side=:double)
    mesh = Mesh(geometry, material; name=name, cast_shadow=true,
                receive_shadow=true)
    mesh.position = position
    add!(group, mesh)

    wire = Mesh(geometry,
                MeshBasicMaterial(color=Color3(0.02, 0.05, 0.05),
                                  opacity=0.28, transparent=true,
                                  wireframe=true, side=:double);
                name="$(name)_wireframe")
    add!(mesh, wire)
    return mesh
end

function add_source_wire!(group::Group, geometry::BufferGeometry,
                          name::String, color::Color3, position::Vec3)
    wire = Mesh(geometry,
                MeshBasicMaterial(color=color, opacity=0.18,
                                  transparent=true, wireframe=true,
                                  side=:double);
                name=name)
    wire.position = position
    add!(group, wire)
    return wire
end

function build_case()
    base, brush = csg_brush_pair()
    subtraction = csg_subtract(base, brush)
    intersection = csg_intersect(base, brush)
    addition = csg_union(base, brush)

    scene = Scene(background=Color3(0.98, 0.90, 0.94),
                  fog=Fog(color=Color3(0.98, 0.90, 0.94), near=9.0, far=18.0))
    add!(scene, HemisphereLight(color=Color3(1.0, 1.0, 1.0),
                                ground_color=Color3(0.72, 0.80, 0.78),
                                intensity=1.15))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=1.2,
                                 position=Vec3(2.0, 5.5, 4.0),
                                 cast_shadow=true))

    floor = Mesh(PlaneGeometry(width=8.5, height=5.8),
                 MeshBasicMaterial(color=Color3(0.78, 0.18, 0.38),
                                   opacity=0.10, transparent=true,
                                   side=:double, depth_write=false);
                 name="csg_shadow_plane", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -1.55, 0.0)
    add!(scene, floor)

    group = Group(name="csg_operation_results")
    add!(scene, group)

    add_csg_result!(group, subtraction, "csg_subtraction",
                    Color3(0.94, 0.26, 0.43), Vec3(-2.65, 0.0, 0.0))
    add_csg_result!(group, intersection, "csg_intersection",
                    Color3(0.20, 0.62, 0.58), Vec3(0.0, 0.0, 0.0))
    add_csg_result!(group, addition, "csg_addition",
                    Color3(0.95, 0.58, 0.16), Vec3(2.65, 0.0, 0.0))

    add_source_wire!(group, base, "csg_base_brush_wire",
                     Color3(0.06, 0.18, 0.16), Vec3(-2.65, 0.0, 0.0))
    add_source_wire!(group, brush, "csg_cutting_brush_wire",
                     Color3(0.00, 0.55, 0.49), Vec3(-2.65, 0.0, 0.0))

    clip = AnimationClip("csg_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("geometry-csg", "Geometry CSG",
                    "BSP CSG subtraction, intersection, and addition over an icosahedron brush and cylinder cutter.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=7.5,
                    height=2.7, fov=pi / 4.2, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_geometry_csg.html"),
                           [build_case()])
    println("WEBGL_GEOMETRY_CSG_OK $html")
end

main()
